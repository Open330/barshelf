import AppKit

/// When a pointer on or near the menu bar cluster counts as being there.
///
/// Where the pointer is and what the user means differ at the edges: a hand
/// resting on a chip drifts a point below the bar, a pointer sweeping across
/// the bar to another item passes over the cluster on its way, and one
/// heading down to read a peek leaves the item to do it. The cluster
/// answers the intent: it unfolds at once, keeps a margin around the item,
/// and folds only after the pointer has been away a moment, a little longer
/// when it went down towards the peek.
enum ClusterHoverPolicy {
    /// Room below the menu bar that still counts as on the item: a pointer
    /// resting on a chip drifts down a little.
    static let slackBelow: CGFloat = 10
    /// Room either side of the item, so the chip at an end does not fold
    /// when the pointer slips a point past it.
    static let slackSides: CGFloat = 4
    /// Away this long before the chips fold.
    static let leaveGrace: TimeInterval = 0.2
    /// Away towards the peek below: it is being read, give it longer.
    static let peekGrace: TimeInterval = 0.45

    enum Zone: Equatable {
        /// On the item: `x` along it, from its left edge.
        case on(x: CGFloat)
        /// In the margin around it: neither a chip nor away.
        case margin
        case away
    }

    /// Where `point` is with respect to the item's frame on its menu bar.
    static func zone(of point: NSPoint, item frame: NSRect) -> Zone {
        // The menu bar's full height counts, and its top edge too (a
        // pointer pushed against the top of the screen).
        if point.x >= frame.minX, point.x < frame.maxX, point.y >= frame.minY, point.y <= frame.maxY + 1 {
            return .on(x: point.x - frame.minX)
        }
        if point.x >= frame.minX - slackSides, point.x < frame.maxX + slackSides,
           point.y >= frame.minY - slackBelow, point.y <= frame.maxY + 1 {
            return .margin
        }
        return .away
    }

    /// How long the chips stay open once the pointer is away. Below the
    /// item and within the peek's reach means it went to read the peek.
    static func grace(leavingAt point: NSPoint, item frame: NSRect, peek: NSRect?) -> TimeInterval {
        guard let peek else { return leaveGrace }
        let reach = peek.union(frame).insetBy(dx: -slackSides * 2, dy: 0)
        return reach.contains(point) && point.y < frame.minY ? peekGrace : leaveGrace
    }
}
