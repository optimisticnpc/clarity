import AppKit
import ApplicationServices

// Private Accessibility calls, used by window managers such as yabai and AltTab:
// the window number behind an Accessibility element, and an element built from a raw token.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError
@_silgen_name("_AXUIElementCreateWithRemoteToken")
private func _AXUIElementCreateWithRemoteToken(_ token: CFData) -> Unmanaged<AXUIElement>?

/// Puts windows back into full screen when they drop out of it as the screens change.
///
/// Some apps (Microsoft Teams, seen twice) leave full screen when Clarity rebuilds the scaled
/// screen, e.g. when the monitor is plugged in after waking. Clarity notes which windows are full
/// screen every few seconds while nothing is changing, and after each screen change it asks any
/// that dropped out to go full screen again. macOS adds the new full-screen desktop at the end of
/// that screen's desktops.
///
/// Changing another app's window needs the Accessibility permission.
enum FullScreenKeeper {
    /// Windows that are full screen right now (each with its app's process ID), read from the
    /// desktops list. Split View desktops hold two windows; both count.
    static func current() -> [CGWindowID: pid_t] {
        var result: [CGWindowID: pid_t] = [:]
        for screen in Desktops.rawScreens() {
            for space in (screen["Spaces"] as? [[String: Any]]) ?? [] where (space["type"] as? Int) == 4 {
                if let wid = (space["fs_wid"] as? NSNumber)?.uint32Value, let pid = (space["pid"] as? NSNumber)?.int32Value {
                    result[wid] = pid
                }
                let tiles = (space["TileLayoutManager"] as? [String: Any])?["TileSpaces"] as? [[String: Any]] ?? []
                for tile in tiles {
                    if let wid = (tile["TileWindowID"] as? NSNumber)?.uint32Value, let pid = (tile["pid"] as? NSNumber)?.int32Value {
                        result[wid] = pid
                    }
                }
            }
        }
        return result
    }

    static var isAllowed: Bool { AXIsProcessTrusted() }

    /// Shows macOS's "Clarity would like to control this computer" prompt.
    static func askForPermission() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Puts back any window from `before` that still exists but is no longer full screen.
    /// Returns the names of the apps it put back, and of those it could not.
    static func restore(_ before: [CGWindowID: pid_t]) -> (restored: [String], failed: [String]) {
        let now = current()
        let existing = Set(((CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]) ?? [])
            .compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value })
        var restored: [String] = [], failed: [String] = []
        for (wid, pid) in before where now[wid] == nil && existing.contains(wid) {
            let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)"
            if isAllowed, let window = element(for: wid, pid: pid),
               AXUIElementSetAttributeValue(window, "AXFullScreen" as CFString, kCFBooleanTrue) == .success {
                restored.append(name)
            } else {
                failed.append(name)
            }
        }
        return (restored, failed)
    }

    /// The Accessibility element for a window. Windows on desktops that aren't showing are missing
    /// from the app's window list, so fall back to trying element tokens for that app.
    private static func element(for wid: CGWindowID, pid: pid_t) -> AXUIElement? {
        func matches(_ e: AXUIElement) -> Bool {
            var id: CGWindowID = 0
            return _AXUIElementGetWindow(e, &id) == .success && id == wid
        }
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
        if let found = ((value as? [AXUIElement]) ?? []).first(where: matches) { return found }

        // Token layout: process ID, 0, the "coco" marker, then the element's number.
        var token = Data(count: 20)
        token.replaceSubrange(0..<4, with: withUnsafeBytes(of: pid) { Data($0) })
        token.replaceSubrange(8..<12, with: withUnsafeBytes(of: Int32(0x636f636f)) { Data($0) })
        for number in UInt64(0)..<3000 {
            token.replaceSubrange(12..<20, with: withUnsafeBytes(of: number) { Data($0) })
            if let e = _AXUIElementCreateWithRemoteToken(token as CFData)?.takeRetainedValue(), matches(e) { return e }
        }
        return nil
    }
}
