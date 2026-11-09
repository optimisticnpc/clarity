import CoreGraphics
import Foundation

/// Remembers where the other screens sit around one display, and puts them back after that
/// display changes size.
///
/// macOS re-lays out the screens whenever a display's resolution changes, which can undo a
/// vertical stack. So before a size change we record each other screen as "below the Philips,
/// centred 52% of the way along its bottom edge", and afterwards we rebuild the same layout
/// around the Philips's new size.
struct Arrangement {
    enum Edge { case above, below, left, right }

    struct Neighbour {
        let id: CGDirectDisplayID
        let edge: Edge
        /// Where the neighbour's centre sits along the shared edge: 0 = start, 1 = end.
        let fraction: Double
    }

    let neighbours: [Neighbour]
    /// Which screen was the main display (the one at 0,0) when this was captured.
    let mainID: CGDirectDisplayID

    /// Records the layout of every other active screen around `anchor`.
    static func capture(around anchor: CGDirectDisplayID) -> Arrangement {
        let a = CGDisplayBounds(anchor)
        let neighbours = activeDisplays().filter { $0 != anchor }.map { id -> Neighbour in
            let b = CGDisplayBounds(id)
            // Screen coordinates: y grows downwards.
            if b.minY >= a.maxY - 1 { return Neighbour(id: id, edge: .below, fraction: (b.midX - a.minX) / a.width) }
            if b.maxY <= a.minY + 1 { return Neighbour(id: id, edge: .above, fraction: (b.midX - a.minX) / a.width) }
            if b.maxX <= a.minX + 1 { return Neighbour(id: id, edge: .left, fraction: (b.midY - a.minY) / a.height) }
            return Neighbour(id: id, edge: .right, fraction: (b.midY - a.minY) / a.height)
        }
        return Arrangement(neighbours: neighbours, mainID: CGMainDisplayID())
    }

    /// Rebuilds the recorded layout around `anchor` at its current size. `anchorBecomesMain` puts
    /// `anchor` at 0,0, which makes it the main display; otherwise the previous main display stays
    /// main. `previousAnchor` is the display `anchor` replaced (the physical monitor, when a virtual
    /// display has just taken its place), so a main-display role it held carries over.
    @discardableResult
    func apply(around anchor: CGDirectDisplayID, anchorBecomesMain: Bool,
               previousAnchor: CGDirectDisplayID? = nil) -> Bool {
        let size = CGDisplayBounds(anchor).size
        var origins: [CGDirectDisplayID: CGPoint] = [anchor: .zero]
        for n in neighbours where CGDisplayIsActive(n.id) != 0 {
            let s = CGDisplayBounds(n.id).size
            let along = n.fraction * ((n.edge == .above || n.edge == .below) ? size.width : size.height)
            switch n.edge {
            case .below: origins[n.id] = CGPoint(x: along - s.width / 2, y: size.height)
            case .above: origins[n.id] = CGPoint(x: along - s.width / 2, y: -s.height)
            case .left: origins[n.id] = CGPoint(x: -s.width, y: along - s.height / 2)
            case .right: origins[n.id] = CGPoint(x: size.width, y: along - s.height / 2)
            }
        }

        // Shift everything so the right screen sits at 0,0 (that's what makes it the main display).
        var main = anchorBecomesMain ? anchor : mainID
        if main == previousAnchor { main = anchor }
        guard let mainOrigin = origins[main] else { return false }
        var config: CGDisplayConfigRef?
        CGBeginDisplayConfiguration(&config)
        for (id, o) in origins {
            CGConfigureDisplayOrigin(config, id, Int32((o.x - mainOrigin.x).rounded()), Int32((o.y - mainOrigin.y).rounded()))
        }
        return CGCompleteDisplayConfiguration(config, .forSession) == .success
    }

    /// Screens that are drawn to (a monitor that only mirrors another is left out).
    static func activeDisplays() -> [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(16, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }
}
