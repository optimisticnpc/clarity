import AppKit
import SwiftUI

@main
struct ClarityApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    /// Off by default: once it's set up there's no need to see Clarity all the time.
    @AppStorage(AppDelegate.menuBarIconKey) private var showMenuBarIcon = false

    var body: some Scene {
        MenuBarExtra(isInserted: $showMenuBarIcon) {
            MenuView().environmentObject(delegate.model)
        } label: {
            Image(systemName: "sparkle.magnifyingglass")
        }
        .menuBarExtraStyle(.window)
    }
}

/// Clarity is a normal window, not a menu bar app.
///
/// The app has to keep running after the window closes, because the virtual display that does
/// the sharp scaling only lives as long as the app. So closing the window just hides it: the Dock
/// icon goes away and Clarity carries on in the background. Opening Clarity again (Spotlight,
/// Finder, Launchpad) brings the window back. Quit Clarity to return the monitor to normal.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    static let menuBarIconKey = "showMenuBarIcon"

    lazy var model = AppModel(live: !SelfTest.isRequested)

    private var selfTesting = false
    private var window: NSWindow?
    private var launchedAtLogin = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        // A login item is opened with a "launched as login item" marker on its open event.
        let event = NSAppleEventManager.shared().currentAppleEvent
        launchedAtLogin = event?.eventID == AEEventID(kAEOpenApplication)
            && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if SelfTest.runIfRequested() { selfTesting = true; return }
        _ = model // start right away, not when the window is first opened
        // At login, apply the saved settings quietly; any other launch shows the window.
        if !launchedAtLogin { showWindow() }
    }

    /// Opening Clarity while it's already running (e.g. from Spotlight) brings the window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return false
    }

    /// Closing the window must not quit: that would remove the virtual display.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        if !selfTesting { model.shutDown() }
    }

    func showWindow() {
        if window == nil {
            let content = MenuView().environmentObject(model)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGSize.self, of: { $0.size }) { [weak self] size in
                    // Resize after the current layout pass, never during it (see below).
                    DispatchQueue.main.async { self?.fitWindow(to: size) }
                }
            let hosting = NSHostingController(rootView: content)
            // No automatic sizing constraints between SwiftUI and the window. With them, AppKit
            // crashed now and then ("needs update constraints" during a constraints pass) when
            // the screens changed while the window was opening. The window is sized by hand.
            hosting.sizingOptions = []
            let window = NSWindow(contentViewController: hosting)
            window.title = "Clarity"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.setFrameAutosaveName("ClarityWindow")
            if !window.setFrameUsingName("ClarityWindow") { window.center() }
            self.window = window
        }
        // A Dock icon and app menu while the window is open.
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// Fits the window to the content's height, keeping its top edge where it is.
    private func fitWindow(to size: CGSize) {
        guard let window, size.width > 0, size.height > 0 else { return }
        let current = window.contentRect(forFrameRect: window.frame)
        guard abs(current.height - size.height) > 0.5 || abs(current.width - size.width) > 0.5 else { return }
        var frame = window.frameRect(forContentRect: CGRect(origin: current.origin, size: size))
        frame.origin.y = window.frame.maxY - frame.height
        window.setFrame(frame, display: true)
    }

    func windowWillClose(_ notification: Notification) {
        // Back to running in the background, with no Dock icon.
        NSApp.setActivationPolicy(.accessory)
    }
}
