import AppKit
import CoreGraphics
import SwiftUI

/// `Clarity.app/Contents/MacOS/Clarity --selftest [zoom] [seconds]`
/// Turns on scaling and a 10% warmer tint for the first external monitor, prints what macOS reports,
/// holds for a few seconds, then turns it all off and checks the monitor is back to normal.
/// Uses the engines directly, so saved settings are not touched.
@MainActor
enum SelfTest {
    /// True when launched with a test flag: the menu bar model then never touches the displays.
    static var isRequested: Bool {
        CommandLine.arguments.contains("--selftest") || CommandLine.arguments.contains("--render-ui")
    }

    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--render-ui"), args.count > index + 1 {
            renderUI(to: args[index + 1])
            exit(0)
        }
        guard let index = args.firstIndex(of: "--selftest") else { return false }
        let zoom = args.count > index + 1 ? Double(args[index + 1]) ?? 1.2 : 1.2
        let seconds = args.count > index + 2 ? Double(args[index + 2]) ?? 5 : 5
        Task { await run(zoom: zoom, hold: seconds) }
        return true
    }

    private static func run(zoom: Double, hold: Double) async {
        let scaling = ScalingEngine()
        let color = ColorEngine()
        guard let display = Displays.externalDisplays().first else {
            print("FAIL no external display"); exit(1)
        }
        print("display \(display.name) id=\(display.id) native=\(display.nativeWidth)x\(display.nativeHeight)")

        do {
            try await scaling.setZoom(zoom, for: display, makeMain: true)
        } catch {
            print("FAIL enable: \(error.localizedDescription)"); exit(1)
        }
        try? await Task.sleep(for: .seconds(1))

        let virtualID = scaling.sessions[display.key]!.virtualDisplay.displayID
        let mirrorOf = CGDisplayMirrorsDisplay(display.id)
        print("physical mirrors \(mirrorOf) (virtual is \(virtualID)) -> \(mirrorOf == virtualID ? "OK" : "FAIL")")
        if let m = CGDisplayCopyDisplayMode(virtualID) {
            print("virtual mode looks like \(m.width)x\(m.height), drawn at \(m.pixelWidth)x\(m.pixelHeight) @ \(m.refreshRate)Hz")
        }
        if let m = CGDisplayCopyDisplayMode(display.id) {
            print("physical mode \(m.width)x\(m.height) px \(m.pixelWidth)x\(m.pixelHeight) @ \(m.refreshRate)Hz")
        }
        let screens = NSScreen.screens.map { "\($0.localizedName) \(Int($0.frame.width))x\(Int($0.frame.height)) @\($0.backingScaleFactor)x" }
        print("screens: \(screens.joined(separator: " | "))")

        var warm = ColorSettings()
        warm.temperature = ColorSettings.temperature(forWarmthPercent: 10)
        color.apply(warm, to: display.id)
        try? await Task.sleep(for: .milliseconds(300))
        printWhite("gamma white after warm (\(Int(warm.temperature))K)", display.id)

        // Size changes must reuse the same virtual display, or windows and Spaces would move.
        for next in [1.0, 1.33, zoom] {
            try? await Task.sleep(for: .seconds(hold / 4))
            do { try await scaling.setZoom(next, for: display, makeMain: true) } catch {
                print("FAIL switch to \(next): \(error.localizedDescription)"); continue
            }
            try? await Task.sleep(for: .milliseconds(500))
            let sameDisplay = scaling.sessions[display.key]?.virtualDisplay.displayID == virtualID
            let stillMirrored = CGDisplayMirrorsDisplay(display.id) == virtualID
            let m = CGDisplayCopyDisplayMode(virtualID)
            print("  layout: \(layoutDescription(around: virtualID))")
            print("switched to \(next): looks like \(m?.width ?? 0)x\(m?.height ?? 0) drawn at \(m?.pixelWidth ?? 0)x\(m?.pixelHeight ?? 0); same display \(sameDisplay ? "OK" : "FAIL"), mirrored \(stillMirrored ? "OK" : "FAIL")")
        }
        try? await Task.sleep(for: .seconds(hold / 4))

        scaling.stop(display.key)
        color.resetEverything()
        try? await Task.sleep(for: .seconds(1.5))
        let restored = CGDisplayMirrorsDisplay(display.id) == kCGNullDirectDisplay
        print("after off: mirroring \(restored ? "off OK" : "STILL ON FAIL")")
        printWhite("gamma white after reset", display.id)
        exit(0)
    }

    private static func layoutDescription(around id: CGDirectDisplayID) -> String {
        let a = CGDisplayBounds(id)
        var parts = ["scaled monitor \(CGDisplayIsMain(id) != 0 ? "MAIN" : "not main") at \(Int(a.minX)),\(Int(a.minY)) \(Int(a.width))x\(Int(a.height))"]
        for other in Arrangement.activeDisplays() where other != id {
            let b = CGDisplayBounds(other)
            let edge = b.minY >= a.maxY - 1 ? "below" : b.maxY <= a.minY + 1 ? "above" : b.maxX <= a.minX + 1 ? "left" : "right"
            parts.append("display \(other) \(edge), centre at \(Int(((b.midX - a.minX) / a.width) * 100))% across")
        }
        return parts.joined(separator: "; ")
    }

    /// `--render-ui out.png`: saves the menu panel as an image, for checking the layout.
    private static func renderUI(to path: String) {
        for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            NSApp.appearance = NSAppearance(named: appearance)
            let view = MenuView().environmentObject(AppModel(live: false))
                .environment(\.colorScheme, suffix == "dark" ? .dark : .light)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
                print("render failed"); continue
            }
            let out = path.replacingOccurrences(of: ".png", with: "-\(suffix).png")
            try? png.write(to: URL(fileURLWithPath: out))
            print("wrote \(out)")
        }
    }

    private static func printWhite(_ label: String, _ id: CGDirectDisplayID) {
        var r = [CGGammaValue](repeating: 0, count: 256), g = r, b = r
        var count: UInt32 = 0
        CGGetDisplayTransferByTable(id, 256, &r, &g, &b, &count)
        print(String(format: "%@: R %.3f G %.3f B %.3f", label, r[255], g[255], b[255]))
    }
}
