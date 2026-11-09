import AppKit
import CoreGraphics

/// A real, physical external monitor (never the built-in screen, never one of our virtual displays).
struct PhysicalDisplay: Identifiable, Hashable {
    let id: CGDirectDisplayID
    /// Stable identity across reconnects and reboots: vendor-model-serial.
    let key: String
    let name: String
    /// Native panel resolution in pixels.
    let nativeWidth: Int
    let nativeHeight: Int
    let sizeInMillimeters: CGSize
}

enum Displays {
    /// Vendor number stamped on the virtual displays this app creates, so we can tell them apart.
    static let virtualVendorID: UInt32 = 0xC1A

    static func key(for id: CGDirectDisplayID) -> String {
        "\(CGDisplayVendorNumber(id))-\(CGDisplayModelNumber(id))-\(CGDisplaySerialNumber(id))"
    }

    static func isOurVirtualDisplay(_ id: CGDirectDisplayID) -> Bool {
        CGDisplayVendorNumber(id) == virtualVendorID
    }

    /// Every connected external monitor, including ones currently mirroring one of our virtual displays.
    static func externalDisplays() -> [PhysicalDisplay] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }

        return ids.prefix(Int(count)).compactMap { id in
            guard CGDisplayIsBuiltin(id) == 0, !isOurVirtualDisplay(id) else { return nil }
            let native = nativeSize(of: id)
            let key = key(for: id)
            return PhysicalDisplay(
                id: id,
                key: key,
                name: name(of: id, key: key),
                nativeWidth: native.width,
                nativeHeight: native.height,
                sizeInMillimeters: CGDisplayScreenSize(id)
            )
        }
    }

    /// The panel's native resolution. While a monitor mirrors one of our virtual displays, macOS
    /// reports the virtual display's modes instead (e.g. 5732 × 2400), so the real size is
    /// remembered from a time it wasn't mirrored.
    static func nativeSize(of id: CGDirectDisplayID) -> (width: Int, height: Int) {
        let defaultsKey = "nativeSize.\(key(for: id))"
        let mirroring = CGDisplayMirrorsDisplay(id) != kCGNullDirectDisplay
        if mirroring, let saved = UserDefaults.standard.array(forKey: defaultsKey) as? [Int], saved.count == 2 {
            return (saved[0], saved[1])
        }
        let size = largestMode(of: id)
        if !mirroring { UserDefaults.standard.set([size.width, size.height], forKey: defaultsKey) }
        return size
    }

    /// The largest pixel mode the display currently offers.
    private static func largestMode(of id: CGDirectDisplayID) -> (width: Int, height: Int) {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        let modes = (CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode]) ?? []
        let best = modes.max { $0.pixelWidth * $0.pixelHeight < $1.pixelWidth * $1.pixelHeight }
        if let best { return (best.pixelWidth, best.pixelHeight) }
        return (Int(CGDisplayPixelsWide(id)), Int(CGDisplayPixelsHigh(id)))
    }

    /// The native mode of the display (largest pixel size, highest refresh rate).
    static func nativeMode(of id: CGDirectDisplayID) -> CGDisplayMode? {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        let modes = (CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode]) ?? []
        let native = nativeSize(of: id)
        return modes
            .filter { $0.pixelWidth == native.width && $0.pixelHeight == native.height && $0.width == native.width }
            .max { $0.refreshRate < $1.refreshRate }
    }

    /// The marketing name ("PHL 346B1C"). Only visible through NSScreen while the display is not
    /// mirrored, so it is remembered once seen.
    private static func name(of id: CGDirectDisplayID, key: String) -> String {
        let defaultsKey = "displayName.\(key)"
        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
        }
        if let name = screen?.localizedName {
            UserDefaults.standard.set(name, forKey: defaultsKey)
            return name
        }
        return UserDefaults.standard.string(forKey: defaultsKey) ?? "External display"
    }
}
