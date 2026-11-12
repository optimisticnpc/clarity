import AppKit
import CoreGraphics
import Foundation

/// Keeps the MacBook's desktops (Spaces) on the MacBook when the monitor is unplugged and plugged
/// back in while the Mac is awake.
///
/// macOS rules, tested on macOS 26:
///  1. When a screen goes away while the Mac is awake, its desktops are merged onto the remaining
///     screen, and macOS remembers which ones they were. When that screen comes back, they move
///     back to it.
///  2. When the main role moves from one screen to another, the two screens swap desktops.
///  3. The main display's desktops go to whichever screen is main when the monitor comes back.
///
/// The usual fix is in ScalingEngine.stopAfterUnplug: it undoes the swap macOS makes when the
/// monitor is unplugged, so the desktops are filed correctly. This is the backstop. If the
/// MacBook's own desktops ever come back on the virtual display as it is recreated, mirroring
/// straight away would merge them with the monitor's for good. Instead Clarity makes the MacBook
/// main and then the virtual display main: two swaps that put each set back on its own screen.
///
/// To recognise the MacBook's desktops, Clarity remembers their IDs while everything is in place.
enum Desktops {
    private static let rememberedKey = "macBookDesktops"

    /// The Dock's list of screens and their desktops, from the private SkyLight framework.
    static func rawScreens() -> [[String: Any]] {
        guard let h = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW),
              let connSym = dlsym(h, "SLSMainConnectionID"),
              let copySym = dlsym(h, "SLSCopyManagedDisplaySpaces") else { return [] }
        typealias ConnFn = @convention(c) () -> Int32
        typealias CopyFn = @convention(c) (Int32) -> Unmanaged<CFArray>?
        let conn = unsafeBitCast(connSym, to: ConnFn.self)
        let copy = unsafeBitCast(copySym, to: CopyFn.self)
        return copy(conn())?.takeRetainedValue() as? [[String: Any]] ?? []
    }

    /// Desktop IDs on each screen, by the screen's UUID.
    static func byScreen() -> [String: [Int]] {
        var result: [String: [Int]] = [:]
        for screen in rawScreens() {
            guard let uuid = screen["Display Identifier"] as? String else { continue }
            let spaces = (screen["Spaces"] as? [[String: Any]]) ?? []
            result[uuid] = spaces.compactMap { ($0["ManagedSpaceID"] as? NSNumber)?.intValue }
        }
        return result
    }

    static func uuid(of id: CGDirectDisplayID) -> String {
        guard let ref = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return "?" }
        return CFUUIDCreateString(nil, ref) as String
    }

    static var builtIn: CGDirectDisplayID? {
        Arrangement.activeDisplays().first { CGDisplayIsBuiltin($0) != 0 }
    }

    /// Records the MacBook's desktop IDs. Call only while everything is in place: the monitor
    /// mirrors its virtual display and the virtual display is main.
    static func rememberMacBookDesktops() {
        guard let mac = builtIn, CGDisplayIsMain(mac) == 0,
              let ids = byScreen()[uuid(of: mac)], !ids.isEmpty else { return }
        UserDefaults.standard.set(ids, forKey: rememberedKey)
    }

    /// True when most of the MacBook's remembered desktops are on `screen` instead of the MacBook.
    static func macBookDesktopsAreOn(_ screen: CGDirectDisplayID) -> Bool {
        guard let mac = builtIn,
              let remembered = UserDefaults.standard.array(forKey: rememberedKey) as? [Int] else { return false }
        let mine = Set(remembered), all = byScreen()
        let onScreen = mine.intersection(all[uuid(of: screen)] ?? []).count
        let onMac = mine.intersection(all[uuid(of: mac)] ?? []).count
        return onScreen > 0 && onScreen > onMac
    }

    /// Makes `id` the main display for this login session by moving it to 0,0 and everything else
    /// by the same amount, so the arrangement is unchanged.
    @discardableResult
    static func makeMain(_ id: CGDirectDisplayID) -> Bool {
        let origin = CGDisplayBounds(id).origin
        var config: CGDisplayConfigRef?
        CGBeginDisplayConfiguration(&config)
        for other in Arrangement.activeDisplays() where CGDisplayMirrorsDisplay(other) == kCGNullDirectDisplay {
            let b = CGDisplayBounds(other)
            CGConfigureDisplayOrigin(config, other, Int32(b.minX - origin.x), Int32(b.minY - origin.y))
        }
        return CGCompleteDisplayConfiguration(config, .forSession) == .success
    }
}
