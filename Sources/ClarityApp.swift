import AppKit
import SwiftUI

@main
struct ClarityApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuView().environmentObject(delegate.model)
        } label: {
            Image(systemName: "sparkle.magnifyingglass")
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    lazy var model = AppModel(live: !SelfTest.isRequested)

    private var selfTesting = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        if SelfTest.runIfRequested() { selfTesting = true; return }
        _ = model // start right away, not when the menu is first opened
    }

    func applicationWillTerminate(_ notification: Notification) {
        if !selfTesting { model.shutDown() }
    }
}
