import AppKit
import Combine
import ServiceManagement

/// Saved settings for one monitor.
struct DisplayProfile: Codable, Equatable {
    /// 1.0 = native size (scaling off). 1.2 = everything 20% bigger.
    var zoom: Double = 1.0
    var color = ColorSettings()
    /// Make this monitor the main display while it is scaled, so trackpad swipes between desktops
    /// work on it (see ScalingEngine.setZoom).
    var makeMain: Bool = true

    init() {}

    // Settings saved by older versions lack `makeMain`; fill in the default instead of failing.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        zoom = try c.decodeIfPresent(Double.self, forKey: .zoom) ?? 1.0
        color = try c.decodeIfPresent(ColorSettings.self, forKey: .color) ?? ColorSettings()
        makeMain = try c.decodeIfPresent(Bool.self, forKey: .makeMain) ?? true
    }
}

@MainActor
final class AppModel: ObservableObject {
    static private(set) weak var shared: AppModel?

    @Published private(set) var displays: [PhysicalDisplay] = []
    @Published var selectedKey: String?
    @Published private(set) var profiles: [String: DisplayProfile] = [:]
    @Published private(set) var busy = false
    @Published var lastError: String?
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled

    let zoomRange: ClosedRange<Double> = 1.0...1.6
    let zoomPresets: [Double] = [1.0, 1.1, 1.2, 1.25, 1.33, 1.5]

    private let scaling = ScalingEngine()
    private let color = ColorEngine()
    private var refreshWork: DispatchWorkItem?
    private var saveWork: DispatchWorkItem?
    private var reassertTimer: Timer?

    /// `live: false` builds a read-only model for rendering the UI to an image: it lists displays
    /// but never changes them.
    init(live: Bool = true) {
        profiles = Self.loadProfiles()
        guard live else {
            displays = Displays.externalDisplays()
            selectedKey = displays.first?.key
            return
        }
        Self.shared = self
        CGDisplayRegisterReconfigurationCallback(displayReconfigured, nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated {
            EventLog.record("Woke from sleep")
            AppModel.shared?.scheduleRefresh(after: 1.5)
        } }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { _ in EventLog.record("Going to sleep") }
        reassertTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            MainActor.assumeIsolated { AppModel.shared?.color.reassertIfNeeded() }
        }
        refreshDisplays()
        EventLog.record("Clarity started")
        Task {
            await applySavedProfiles()
            EventLog.record("Saved settings applied at launch")
        }
    }

    // MARK: - Current display

    var selected: PhysicalDisplay? {
        displays.first { $0.key == selectedKey } ?? displays.first
    }

    var profile: DisplayProfile {
        guard let key = selected?.key else { return DisplayProfile() }
        return profiles[key] ?? DisplayProfile()
    }

    func looksLike(zoom: Double) -> String {
        guard let display = selected else { return "" }
        if zoom <= 1.0001 { return "\(display.nativeWidth) × \(display.nativeHeight)" }
        let size = ScalingEngine.pointSize(for: display, zoom: zoom)
        return "\(size.width) × \(size.height)"
    }

    // MARK: - Scaling

    /// Changes the zoom from the UI and keeps it.
    func setZoom(_ zoom: Double) {
        guard let display = selected, !busy else { return }
        guard abs(profile.zoom - zoom) > 0.001 else { return }
        Task {
            guard await applyZoom(zoom, to: display) else { return }
            updateProfile(display.key) { $0.zoom = zoom }
        }
    }

    @discardableResult
    private func applyZoom(_ zoom: Double, to display: PhysicalDisplay) async -> Bool {
        busy = true
        defer { busy = false }
        lastError = nil
        do {
            try await scaling.setZoom(zoom, for: display, makeMain: profiles[display.key]?.makeMain ?? true)
            // Mirroring and mode changes can reset the gamma tables, so put the colours back.
            try? await Task.sleep(for: .milliseconds(400))
            color.apply(profiles[display.key]?.color ?? .neutral, to: display.id)
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func setMakeMain(_ on: Bool) {
        guard let display = selected else { return }
        updateProfile(display.key) { $0.makeMain = on }
        scaling.rearrange(display.key, makeMain: on)
    }

    // MARK: - Colour

    func setColor(_ update: (inout ColorSettings) -> Void) {
        guard let display = selected else { return }
        var settings = profile.color
        update(&settings)
        color.apply(settings, to: display.id)
        updateProfile(display.key) { $0.color = settings }
    }

    func resetColor() { setColor { $0 = .neutral } }

    // MARK: - Everything off

    /// Native size and neutral colours for every monitor. Windows stay where they are: the
    /// virtual display stays up and simply switches to its 1:1 Native mode.
    func revertAll() {
        color.resetEverything()
        for key in profiles.keys { profiles[key] = DisplayProfile() }
        saveSoon()
        Task {
            for display in displays where scaling.isActive(display.key) {
                await applyZoom(1.0, to: display)
            }
        }
    }

    func shutDown() {
        EventLog.record("Clarity quitting")
        scaling.stopAll()
        color.resetEverything()
        saveNow()
    }

    // MARK: - Launch at login

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            lastError = "Launch at login: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: - Display changes

    fileprivate func scheduleRefresh(after delay: Double = 0.6) {
        refreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in await self?.handleDisplayChange() }
        }
        refreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func handleDisplayChange() async {
        guard !busy else { scheduleRefresh(); return }
        let before = Set(displays.map(\.key))
        refreshDisplays()
        let onlineKeys = Set(displays.map(\.key))
        let added = onlineKeys.subtracting(before), removed = before.subtracting(onlineKeys)
        let changed = !added.isEmpty || !removed.isEmpty
        if changed {
            EventLog.record("Monitors changed: plugged in \(added.sorted()), unplugged \(removed.sorted())")
        }
        // A monitor that was unplugged while scaled would leave an invisible virtual screen behind.
        for key in scaling.sessions.keys where !onlineKeys.contains(key) {
            scaling.stop(key)
        }
        await applySavedProfiles()
        color.reassertIfNeeded()
        if changed {
            EventLog.record("Settings re-applied after the monitor change")
            // Where things ended up once macOS has finished shuffling.
            try? await Task.sleep(for: .seconds(5))
            EventLog.record("5 seconds later")
        }
    }

    private func refreshDisplays() {
        displays = Displays.externalDisplays()
        if selectedKey == nil || !displays.contains(where: { $0.key == selectedKey }) {
            selectedKey = displays.first?.key
        }
    }

    /// On launch and when a monitor is plugged in: bring back its saved zoom and colours.
    private func applySavedProfiles() async {
        for display in displays {
            let saved = profiles[display.key] ?? DisplayProfile()
            let current = scaling.zoom(for: display.key) ?? 1.0
            if abs(current - saved.zoom) > 0.001 {
                await applyZoom(saved.zoom, to: display)
            } else {
                color.apply(saved.color, to: display.id)
            }
        }
    }

    // MARK: - Persistence

    private func updateProfile(_ key: String, _ change: (inout DisplayProfile) -> Void) {
        var p = profiles[key] ?? DisplayProfile()
        change(&p)
        profiles[key] = p
        saveSoon()
    }

    private func saveSoon() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.saveNow() } }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func saveNow() {
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: "profiles")
        }
    }

    private static func loadProfiles() -> [String: DisplayProfile] {
        guard let data = UserDefaults.standard.data(forKey: "profiles"),
              let profiles = try? JSONDecoder().decode([String: DisplayProfile].self, from: data) else { return [:] }
        return profiles
    }
}

/// Called by macOS whenever a display is added, removed or rearranged.
private func displayReconfigured(_ display: CGDirectDisplayID, _ flags: CGDisplayChangeSummaryFlags,
                                 _ userInfo: UnsafeMutableRawPointer?) {
    guard !flags.contains(.beginConfigurationFlag) else { return }
    DispatchQueue.main.async {
        MainActor.assumeIsolated { AppModel.shared?.scheduleRefresh() }
    }
}
