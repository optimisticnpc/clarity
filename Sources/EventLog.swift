import AppKit
import CoreGraphics
import Foundation

/// A plain-text diary of display events, for working out why windows or desktops moved.
///
/// Each entry records what happened (monitor plugged in, wake, scaling started…) and a snapshot:
/// which screens exist and which is main, which desktops (Spaces) belong to each screen, and
/// which apps have windows on each screen. Written to ~/Library/Logs/Clarity.log, which Console
/// can also open. Trimmed to its newest half once it passes 1 MB.
enum EventLog {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Clarity.log")

    static func record(_ event: String) {
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current,
                                                formatOptions: [.withInternetDateTime])
        write("[\(stamp)] \(event)\n\(snapshot())\n")
    }

    private static func snapshot() -> String {
        var lines: [String] = []
        let windows = windowOwnersByDisplay()
        for id in Arrangement.activeDisplays() {
            let b = CGDisplayBounds(id)
            let kind = CGDisplayIsBuiltin(id) != 0 ? "MacBook"
                : (CGDisplayVendorNumber(id) == Displays.virtualVendorID ? "virtual" : "monitor")
            let main = CGDisplayIsMain(id) != 0 ? " MAIN" : ""
            lines.append("  screen \(id) \(kind)\(main) at \(Int(b.minX)),\(Int(b.minY)) \(Int(b.width))×\(Int(b.height)) "
                + "uuid \(uuid(id).prefix(8)) apps: \(windows[id]?.sorted().joined(separator: ", ") ?? "none")")
        }
        for (display, spaces) in managedSpaces() {
            lines.append("  desktops on \(display.prefix(8)): \(spaces)")
        }
        return lines.joined(separator: "\n")
    }

    private static func uuid(_ id: CGDirectDisplayID) -> String {
        guard let ref = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return "?" }
        return CFUUIDCreateString(nil, ref) as String
    }

    /// App names with a normal window on each screen. Needs no permission: window titles are
    /// left out, owner names and positions are public.
    private static func windowOwnersByDisplay() -> [CGDirectDisplayID: Set<String>] {
        let info = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        let screens = Arrangement.activeDisplays().map { ($0, CGDisplayBounds($0)) }
        var result: [CGDirectDisplayID: Set<String>] = [:]
        for w in info where (w[kCGWindowLayer as String] as? Int) == 0 {
            guard let owner = w[kCGWindowOwnerName as String] as? String,
                  let dict = w[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: dict), rect.width > 50, rect.height > 50,
                  let screen = screens.first(where: { $0.1.contains(CGPoint(x: rect.midX, y: rect.midY)) })
            else { continue }
            result[screen.0, default: []].insert(owner)
        }
        return result
    }

    /// Desktop IDs per screen UUID, from the private SkyLight framework the Dock uses.
    private static func managedSpaces() -> [(String, String)] {
        guard let h = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW),
              let connSym = dlsym(h, "SLSMainConnectionID"),
              let copySym = dlsym(h, "SLSCopyManagedDisplaySpaces") else { return [] }
        typealias ConnFn = @convention(c) () -> Int32
        typealias CopyFn = @convention(c) (Int32) -> Unmanaged<CFArray>?
        let conn = unsafeBitCast(connSym, to: ConnFn.self)
        let copy = unsafeBitCast(copySym, to: CopyFn.self)
        guard let list = copy(conn())?.takeRetainedValue() as? [[String: Any]] else { return [] }
        return list.map { d in
            let spaces = (d["Spaces"] as? [[String: Any]]) ?? []
            let ids = spaces.map { s -> String in
                let id = s["ManagedSpaceID"].map { "\($0)" } ?? "?"
                return (s["type"] as? Int) == 4 ? "\(id)(full screen)" : id
            }
            return (d["Display Identifier"] as? String ?? "?", ids.joined(separator: " "))
        }
    }

    private static func write(_ text: String) {
        let fm = FileManager.default
        if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 1_000_000,
           let old = try? String(contentsOf: url, encoding: .utf8) {
            try? String(old.suffix(old.count / 2)).write(to: url, atomically: true, encoding: .utf8)
        }
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        handle.seekToEndOfFile()
        handle.write(Data(text.utf8))
        try? handle.close()
    }
}
