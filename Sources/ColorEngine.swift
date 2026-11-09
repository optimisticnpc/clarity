import CoreGraphics
import Foundation

/// Colour adjustments for one monitor. Neutral values change nothing.
struct ColorSettings: Codable, Equatable {
    /// White point in kelvin. 6500 K is neutral (what the MacBook and the monitor's 6500K preset use).
    var temperature: Double = 6500
    /// 0.3 to 1.0. Software dimming on top of the monitor's own backlight.
    var brightness: Double = 1.0
    /// 0.7 to 1.3. Stretches or squeezes tones around mid-grey.
    var contrast: Double = 1.0
    /// Target display gamma, 1.8 to 2.6. 2.2 is neutral; higher is darker and punchier in the midtones.
    var gamma: Double = 2.2
    /// Per-channel gain, 0.5 to 1.0, for fine-tuning the white balance by hand.
    var red: Double = 1.0
    var green: Double = 1.0
    var blue: Double = 1.0

    static let neutral = ColorSettings()
    var isNeutral: Bool { self == .neutral }

    /// How much warmer than 6500 K, as a percentage. Measured in mireds (1,000,000 / kelvin), the
    /// scale on which equal steps look like equal changes, so "10% warmer" is about 5900 K.
    var warmthPercent: Int {
        Int(((1_000_000 / temperature) / (1_000_000 / 6500) - 1) * 100)
    }

    static func temperature(forWarmthPercent percent: Double) -> Double {
        1_000_000 / ((1_000_000 / 6500) * (1 + percent / 100))
    }
}

/// Applies `ColorSettings` by rewriting the monitor's gamma lookup tables. This is the same
/// mechanism Night Shift-style apps use. It affects only the chosen monitor, needs no admin rights,
/// and macOS restores the original tables when the app quits.
@MainActor
final class ColorEngine {
    private static let tableSize = 256
    private var applied: [CGDirectDisplayID: ColorSettings] = [:]

    func apply(_ settings: ColorSettings, to id: CGDirectDisplayID) {
        if settings.isNeutral {
            if applied.removeValue(forKey: id) != nil { restoreAll() }
            return
        }
        let (r, g, b) = Self.tables(for: settings)
        CGSetDisplayTransferByTable(id, UInt32(Self.tableSize), r, g, b)
        applied[id] = settings
    }

    /// macOS resets gamma tables after sleep, display changes and sometimes Night Shift transitions.
    /// Called on a timer and after display changes: puts our tables back if they were replaced.
    func reassertIfNeeded() {
        for (id, settings) in applied where !tableMatches(settings, on: id) {
            let (r, g, b) = Self.tables(for: settings)
            CGSetDisplayTransferByTable(id, UInt32(Self.tableSize), r, g, b)
        }
    }

    func forget(_ id: CGDirectDisplayID) { applied.removeValue(forKey: id) }

    /// Puts every display back to its ColorSync profile.
    func restoreAll() {
        CGDisplayRestoreColorSyncSettings()
        // Restoring is global, so re-apply anything that should still be adjusted.
        for (id, settings) in applied {
            let (r, g, b) = Self.tables(for: settings)
            CGSetDisplayTransferByTable(id, UInt32(Self.tableSize), r, g, b)
        }
    }

    func resetEverything() {
        applied.removeAll()
        CGDisplayRestoreColorSyncSettings()
    }

    // MARK: - Maths

    private func tableMatches(_ settings: ColorSettings, on id: CGDirectDisplayID) -> Bool {
        var r = [CGGammaValue](repeating: 0, count: Self.tableSize)
        var g = r, b = r
        var count: UInt32 = 0
        guard CGGetDisplayTransferByTable(id, UInt32(Self.tableSize), &r, &g, &b, &count) == .success,
              count == UInt32(Self.tableSize) else { return true }
        let expected = Self.tables(for: settings)
        // Compare a few sample points; the hardware rounds, so allow a small tolerance.
        return [32, 128, 255].allSatisfy { i in
            abs(r[i] - expected.0[i]) < 0.01 && abs(g[i] - expected.1[i]) < 0.01 && abs(b[i] - expected.2[i]) < 0.01
        }
    }

    static func tables(for s: ColorSettings) -> ([CGGammaValue], [CGGammaValue], [CGGammaValue]) {
        let white = whitePoint(kelvin: s.temperature)
        var gains = (white.r * s.red, white.g * s.green, white.b * s.blue)
        // A gamma table can only dim a channel, never boost it, so scale the brightest channel to 1.
        let peak = max(gains.0, gains.1, gains.2)
        gains = (gains.0 / peak, gains.1 / peak, gains.2 / peak)

        let exponent = s.gamma / 2.2
        var r = [CGGammaValue](), g = [CGGammaValue](), b = [CGGammaValue]()
        r.reserveCapacity(tableSize); g.reserveCapacity(tableSize); b.reserveCapacity(tableSize)
        for i in 0..<tableSize {
            let x = Double(i) / Double(tableSize - 1)
            var v = pow(x, exponent)
            v = (v - 0.5) * s.contrast + 0.5
            v = min(max(v, 0), 1) * s.brightness
            r.append(CGGammaValue(min(max(v * gains.0, 0), 1)))
            g.append(CGGammaValue(min(max(v * gains.1, 0), 1)))
            b.append(CGGammaValue(min(max(v * gains.2, 0), 1)))
        }
        return (r, g, b)
    }

    /// Relative RGB of a black-body white at `kelvin`, normalised so 6500 K is (1, 1, 1).
    static func whitePoint(kelvin: Double) -> (r: Double, g: Double, b: Double) {
        let target = blackBody(kelvin)
        let reference = blackBody(6500)
        return (target.r / reference.r, target.g / reference.g, target.b / reference.b)
    }

    /// Tanner Helland's fit of black-body colour, 1000 K to 40000 K. Returns 0...1 per channel.
    private static func blackBody(_ kelvin: Double) -> (r: Double, g: Double, b: Double) {
        let t = min(max(kelvin, 1000), 40000) / 100
        let r = t <= 66 ? 255 : 329.698727446 * pow(t - 60, -0.1332047592)
        let g = t <= 66 ? 99.4708025861 * log(t) - 161.1195681661 : 288.1221695283 * pow(t - 60, -0.0755148492)
        let b = t >= 66 ? 255 : (t <= 19 ? 0 : 138.5177312231 * log(t - 10) - 305.0447927307)
        func clamp(_ v: Double) -> Double { min(max(v, 0), 255) / 255 }
        return (clamp(r), clamp(g), clamp(b))
    }
}
