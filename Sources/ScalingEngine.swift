import CoreGraphics
import Foundation

/// Makes a monitor show everything bigger while keeping text sharp.
///
/// How it works (the same trick BetterDisplay uses):
///  1. Create a virtual display in HiDPI mode at the "looks like" size, e.g. 2866 × 1200 points.
///     HiDPI means macOS renders it at 2× pixels: 5732 × 2400.
///  2. Make the real monitor mirror that virtual display. macOS shrinks the 5732 × 2400 image onto
///     the 3440 × 1440 panel, which is supersampling, so text stays crisp instead of being stretched.
///
/// Keeping windows and desktops in place:
///  - Swapping the real monitor for a virtual one looks to macOS like unplugging one screen and
///    plugging in another, which shuffles windows and Spaces. So the swap happens once, and from
///    then on the same virtual display stays up. Every size, including Native (1:1, no scaling),
///    is a mode of that one display, so changing size is an ordinary resolution change.
///  - The virtual display has the same identity every time for a given monitor, so macOS
///    recognises it at each launch and restores its Spaces and arrangement.
///
/// The virtual display only lives as long as this app. If the app quits or crashes, macOS removes
/// it and the monitor goes back to normal on its own.
@MainActor
final class ScalingEngine {
    struct Session {
        let physical: PhysicalDisplay
        let virtualDisplay: CGVirtualDisplay
        var zoom: Double
    }

    enum ScalingError: LocalizedError {
        case createFailed, applyFailed, virtualNeverAppeared, modeMissing(Int, Int), configFailed(CGError)

        var errorDescription: String? {
            switch self {
            case .createFailed: "macOS refused to create the virtual display."
            case .applyFailed: "macOS refused the virtual display's resolutions."
            case .virtualNeverAppeared: "The virtual display did not come online."
            case let .modeMissing(w, h): "No sharp (HiDPI) mode at \(w) × \(h)."
            case let .configFailed(err): "Changing the display arrangement failed (error \(err.rawValue))."
            }
        }
    }

    /// Zoom levels the virtual display offers: every 5% step plus the presets.
    static let zoomSteps: [Double] = Array(stride(from: 1.05, through: 1.6001, by: 0.05)) + [1.33]

    private(set) var sessions: [String: Session] = [:]

    /// The "looks like" size, in points, for a zoom factor (1.2 = everything 20% bigger).
    /// Kept even and at the panel's aspect ratio so the mirror fills the screen exactly.
    static func pointSize(for display: PhysicalDisplay, zoom: Double) -> (width: Int, height: Int) {
        if zoom <= 1.0001 { return (display.nativeWidth, display.nativeHeight) }
        func even(_ value: Double) -> Int { Int((value / 2).rounded()) * 2 }
        let width = even(Double(display.nativeWidth) / zoom)
        let height = even(Double(width) * Double(display.nativeHeight) / Double(display.nativeWidth))
        return (width, height)
    }

    func zoom(for key: String) -> Double? { sessions[key]?.zoom }
    func isActive(_ key: String) -> Bool { sessions[key] != nil }

    /// Sets a monitor's size. The first call swaps the monitor onto its virtual display; later calls,
    /// including going back to Native, only change the virtual display's resolution.
    ///
    /// `makeMain` makes the scaled monitor the main display. Needed for trackpad swipes between
    /// desktops: the Dock works out which screen a swipe is on from the physical monitor under the
    /// pointer, finds it has no desktops of its own (they belong to the virtual display it mirrors),
    /// and falls back to the main display. With the scaled monitor as main, that fallback is right.
    func setZoom(_ zoom: Double, for display: PhysicalDisplay, makeMain: Bool) async throws {
        if var session = sessions[display.key] {
            let id = session.virtualDisplay.displayID
            let layout = Arrangement.capture(around: id)
            if try switchMode(session, to: zoom) {
                // macOS re-lays out the screens after a resolution change; put the user's layout back.
                try? await Task.sleep(for: .milliseconds(300))
                layout.apply(around: id, anchorBecomesMain: makeMain)
            }
            session.zoom = zoom
            sessions[display.key] = session
            return
        }
        // Native and not yet swapped: nothing to do, the monitor is already at native size.
        guard zoom > 1.0001 else { return }
        try await start(display, zoom: zoom, makeMain: makeMain)
    }

    /// Re-applies the arrangement, e.g. after the "main display" setting changes.
    func rearrange(_ key: String, makeMain: Bool) {
        guard let session = sessions[key] else { return }
        let id = session.virtualDisplay.displayID
        let layout = Arrangement.capture(around: id)
        if !makeMain, CGDisplayIsMain(id) != 0 {
            // Hand the main role back to another screen (the built-in one if there is one).
            let others = layout.neighbours.map(\.id)
            let fallback = others.first { CGDisplayIsBuiltin($0) != 0 } ?? others.first
            guard let fallback else { return }
            Arrangement(neighbours: layout.neighbours, mainID: fallback).apply(around: id, anchorBecomesMain: false)
        } else {
            layout.apply(around: id, anchorBecomesMain: makeMain)
        }
    }

    /// Fully undoes the swap: the monitor stops mirroring and the virtual display is removed.
    /// Only used when quitting, or when the monitor is unplugged.
    func stop(_ key: String) {
        guard let session = sessions.removeValue(forKey: key) else { return }
        var config: CGDisplayConfigRef?
        CGBeginDisplayConfiguration(&config)
        CGConfigureDisplayMirrorOfDisplay(config, session.physical.id, kCGNullDirectDisplay)
        CGCompleteDisplayConfiguration(config, .forSession)
        // `session` goes out of scope here, which releases the last reference to the virtual
        // display, and macOS removes it.
    }

    func stopAll() {
        for key in Array(sessions.keys) { stop(key) }
    }

    // MARK: - Swap

    private func start(_ display: PhysicalDisplay, zoom: Double, makeMain: Bool) async throws {
        // Where the other screens sit around the monitor, to rebuild around the virtual display.
        let layout = Arrangement.capture(around: display.id)

        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.queue = .main
        descriptor.name = "Clarity · \(display.name)"
        // Room for every mode: at most 2× the native panel.
        descriptor.maxPixelsWide = UInt32(display.nativeWidth * 2)
        descriptor.maxPixelsHigh = UInt32(display.nativeHeight * 2)
        descriptor.sizeInMillimeters = display.sizeInMillimeters
        // Same vendor, product and serial every time for this monitor, so macOS sees the same
        // display at every launch and restores its Spaces and window arrangement.
        descriptor.vendorID = Displays.virtualVendorID
        descriptor.productID = 0x0001
        descriptor.serialNum = Self.stableSerial(for: display.key)

        guard let virtualDisplay = CGVirtualDisplay(descriptor: descriptor) else { throw ScalingError.createFailed }
        guard virtualDisplay.apply(Self.settings(for: display)) else { throw ScalingError.applyFailed }
        guard await waitUntilOnline(virtualDisplay.displayID) else { throw ScalingError.virtualNeverAppeared }

        let session = Session(physical: display, virtualDisplay: virtualDisplay, zoom: zoom)
        try switchMode(session, to: zoom)
        try Self.configure("mirror") { CGConfigureDisplayMirrorOfDisplay($0, display.id, virtualDisplay.displayID) }
        sessions[display.key] = session
        // Put the virtual display where the monitor was (e.g. above the MacBook). Cosmetic, so a
        // failure here is not fatal.
        try? await Task.sleep(for: .milliseconds(300))
        layout.apply(around: virtualDisplay.displayID, anchorBecomesMain: makeMain, previousAnchor: display.id)
    }

    /// Returns true if the resolution actually changed.
    @discardableResult
    private func switchMode(_ session: Session, to zoom: Double) throws -> Bool {
        let id = session.virtualDisplay.displayID
        let points = Self.pointSize(for: session.physical, zoom: zoom)
        guard let mode = Self.mode(on: id, width: points.width, height: points.height, hiDPI: zoom > 1.0001) else {
            throw ScalingError.modeMissing(points.width, points.height)
        }
        if let current = CGDisplayCopyDisplayMode(id), current.width == mode.width,
           current.height == mode.height, current.pixelWidth == mode.pixelWidth { return false }
        try Self.configure("size") { CGConfigureDisplayWithDisplayMode($0, id, mode, nil) }
        return true
    }

    // MARK: - Helpers

    /// Every size the virtual display can switch between without being rebuilt.
    private static func settings(for display: PhysicalDisplay) -> CGVirtualDisplaySettings {
        var sizes: [(Int, Int)] = [(display.nativeWidth, display.nativeHeight)] // Native, 1:1
        for zoom in zoomSteps {
            let p = pointSize(for: display, zoom: zoom)
            // With hiDPI on, macOS offers the sharp "w × h drawn at 2×" mode only when both the 2× and
            // the 1× size are listed (tested on macOS 26).
            sizes.append((p.width * 2, p.height * 2))
            sizes.append((p.width, p.height))
        }
        var seen = Set<String>()
        let modes = sizes.filter { seen.insert("\($0.0)x\($0.1)").inserted }
            .map { CGVirtualDisplayMode(width: UInt32($0.0), height: UInt32($0.1), refreshRate: 60) }

        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 1
        settings.modes = modes
        return settings
    }

    /// A mode that looks like width × height: drawn at 2× pixels (sharp scaling) or 1:1 (Native).
    private static func mode(on id: CGDirectDisplayID, width: Int, height: Int, hiDPI: Bool) -> CGDisplayMode? {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        let modes = (CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode]) ?? []
        let pixelWidth = hiDPI ? width * 2 : width
        return modes.first { $0.width == width && $0.height == height && $0.pixelWidth == pixelWidth }
    }

    /// A serial number handed out once per monitor and kept forever (1 for the first monitor ever
    /// scaled, 2 for the next…). macOS files each display's Spaces under an ID built from vendor,
    /// product and serial, so the number must never change or the monitor's desktops are lost.
    private static func stableSerial(for key: String) -> UInt32 {
        let defaults = UserDefaults.standard
        var assigned = defaults.dictionary(forKey: "virtualSerials") as? [String: Int] ?? [:]
        if let serial = assigned[key] { return UInt32(serial) }
        let serial = (assigned.values.max() ?? 0) + 1
        assigned[key] = serial
        defaults.set(assigned, forKey: "virtualSerials")
        return UInt32(serial)
    }

    private static func configure(_ step: String, _ change: (CGDisplayConfigRef?) -> CGError) throws {
        var config: CGDisplayConfigRef?
        CGBeginDisplayConfiguration(&config)
        let staged = change(config)
        guard staged == .success else {
            CGCancelDisplayConfiguration(config)
            NSLog("Clarity: %@ rejected (%d)", step, staged.rawValue)
            throw ScalingError.configFailed(staged)
        }
        let result = CGCompleteDisplayConfiguration(config, .forSession)
        guard result == .success else {
            NSLog("Clarity: %@ failed (%d)", step, result.rawValue)
            throw ScalingError.configFailed(result)
        }
    }

    private func waitUntilOnline(_ id: CGDirectDisplayID) async -> Bool {
        for _ in 0..<30 {
            if CGDisplayIsOnline(id) != 0, CGDisplayCopyDisplayMode(id) != nil { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }
}
