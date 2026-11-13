import Foundation

/// Which "show only when" items are hidden for now, and the memory that
/// keeps one in the menu bar a while after it stopped qualifying.
public struct MenuBarShowWhenHold: Equatable {
    /// How long an item stays after its last qualifying reading.
    public let hold: TimeInterval
    /// When each "show only when" item last had a reading that qualified.
    public private(set) var metAt: [String: Date]

    public init(hold: TimeInterval = 60) {
        self.hold = hold
        self.metAt = [:]
    }

    /// Stamps the entries whose reading qualifies now, returns the ids that
    /// are dormant, and forgets the stamps of ids not in `owned`.
    public mutating func dormant(among owned: [MenuBarEntry], now: Date) -> Set<String> {
        var dormant = Set<String>()
        for entry in owned {
            switch MenuBarPolicy.meetsShowWhen(entry) {
            case nil:
                // No limit, or no reading yet: nothing to hide, and nothing
                // that should start the hold either.
                continue
            case true?:
                metAt[entry.widgetID] = now
            case false?:
                // Held a while after its last qualifying reading, so a
                // reading hovering at the limit does not blink the item.
                let held = metAt[entry.widgetID]
                    .map { now.timeIntervalSince($0) < hold } ?? false
                if !held { dormant.insert(entry.widgetID) }
            }
        }
        metAt = metAt.filter { id, _ in owned.contains { $0.widgetID == id } }
        return dormant
    }
}
