// Draws Clarity's app icon (the blue-to-purple badge from the window header) and writes
// Support/AppIcon.icns. Run from the repo root:  swift scripts/make-icon.swift
import AppKit

func render(_ size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024
    // macOS icon grid: an 824-point rounded square centred in the 1024 canvas.
    let rect = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let path = NSBezierPath(roundedRect: rect, xRadius: 185 * s, yRadius: 185 * s)

    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowBlurRadius = 20 * s
    shadow.shadowOffset = NSSize(width: 0, height: -8 * s)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSColor.black.setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(starting: NSColor(red: 0.25, green: 0.55, blue: 1.0, alpha: 1),
               ending: NSColor(red: 0.55, green: 0.35, blue: 0.95, alpha: 1))!
        .draw(in: path, angle: -45)

    let config = NSImage.SymbolConfiguration(pointSize: 470 * s, weight: .semibold)
        .applying(.init(paletteColors: [.white]))
    if let symbol = NSImage(systemSymbolName: "sparkle.magnifyingglass", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let sz = symbol.size
        symbol.draw(in: NSRect(x: rect.midX - sz.width / 2, y: rect.midY - sz.height / 2, width: sz.width, height: sz.height))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! render(CGFloat(base * scale)).representation(using: .png, properties: [:])!
            .write(to: iconset.appendingPathComponent(name))
    }
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", "Support/AppIcon.icns"]
try! task.run(); task.waitUntilExit()
try! render(1024).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "docs/icon.png"))
print(task.terminationStatus == 0 ? "Wrote Support/AppIcon.icns" : "iconutil failed")
