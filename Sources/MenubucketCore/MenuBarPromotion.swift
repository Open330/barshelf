import Foundation

/// Menu-bar promotion: which widgets get live text next to the BarShelf icon,
/// and what that text says.
///
/// BarShelf's premise is one menu bar icon, so promoted widgets share a single
/// status item by default — their labels are drawn as one strip. A widget can
/// be split into its own status item when the user wants to reorder or click
/// it independently (the shape a system monitor like Stats uses).
///
/// Everything here is pure and UI-free: the AppKit side owns `NSStatusItem`s
/// and calls into these rules.

// MARK: - Placement

/// Where one widget sits in the menu bar. Persisted per widget.
public struct MenuBarPlacement: Codable, Equatable, Sendable {
    /// Whether the widget appears in the menu bar at all.
    public var enabled: Bool
    /// True to give the widget its own status item instead of the shared strip.
    public var separate: Bool
    /// Sort key within the strip (lower is further left). Nil sorts after the
    /// explicitly ordered entries, by widget name.
    public var order: Double?

    public init(enabled: Bool, separate: Bool = false, order: Double? = nil) {
        self.enabled = enabled
        self.separate = separate
        self.order = order
    }

    /// Lenient decode so a prefs file written by an older build still loads.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        separate = try container.decodeIfPresent(Bool.self, forKey: .separate) ?? false
        order = try container.decodeIfPresent(Double.self, forKey: .order)
    }
}

// MARK: - Entries

/// One rendered menu-bar cell: what the AppKit layer draws for a widget.
public struct MenuBarEntry: Equatable, Sendable {
    public var widgetID: String
    /// Widget display name — the tooltip's first line and the separate item's
    /// accessibility label.
    public var name: String
    /// SF Symbol to draw, or nil when the widget's mode shows text only.
    public var symbol: String?
    /// Live text, or nil when the mode shows the icon only / nothing has been
    /// sampled yet.
    public var label: String?
    public var tooltip: String?
    /// True when the last successful sample is older than the widget's own
    /// refresh cadence allows — the value on screen is no longer current, so
    /// the strip dims it rather than passing off a frozen number as live.
    public var isStale: Bool
    public var separate: Bool

    public init(
        widgetID: String,
        name: String,
        symbol: String? = nil,
        label: String? = nil,
        tooltip: String? = nil,
        isStale: Bool = false,
        separate: Bool = false
    ) {
        self.widgetID = widgetID
        self.name = name
        self.symbol = symbol
        self.label = label
        self.tooltip = tooltip
        self.isStale = isStale
        self.separate = separate
    }

    /// Nothing to draw — neither a symbol nor text.
    public var isEmpty: Bool {
        symbol == nil && (label?.isEmpty ?? true)
    }
}

// MARK: - Policy

public enum MenuBarPolicy {
    /// Hard cap on promoted widgets. The menu bar is shared with every other
    /// app (and, on a notched Mac, with the notch), so BarShelf refuses to
    /// take it over no matter how many widgets declare a status item.
    public static let maxEntries = 5

    /// Longest live label drawn for one widget. A widget whose status template
    /// produces a long string is truncated rather than pushing its neighbours
    /// off the bar.
    public static let maxLabelCharacters = 14

    /// Separator drawn between entries sharing the strip.
    public static let stripSeparator = " · "

    /// How far past its refresh cadence a value may drift before it is drawn
    /// as stale. Three missed refreshes, and never less than 30 s so a widget
    /// with a fast cadence does not flicker between fresh and stale.
    ///
    /// `nil` when the widget has no interval at all: an event-driven or
    /// manual-refresh widget is as current as it is ever going to be, so
    /// there is no cadence to fall behind.
    public static func stalenessThreshold(interval: Double?) -> Double? {
        guard let interval, interval > 0 else { return nil }
        return max(interval * 3, 30)
    }

    public static func isStale(
        updatedAt: Date?,
        interval: Double?,
        now: Date = Date()
    ) -> Bool {
        guard let updatedAt else { return true } // never rendered
        guard let threshold = stalenessThreshold(interval: interval) else { return false }
        return now.timeIntervalSince(updatedAt) > threshold
    }

    /// The user's stored choice.
    ///
    /// With nothing stored a widget stays off the menu bar, whatever its
    /// author declared: `statusItem.mode` marks a widget *eligible*, and
    /// turning it on is the user's call. Taking over someone's menu bar (and
    /// its closed-popup polling) on an update is not a default worth having.
    public static func resolvedPlacement(
        stored: MenuBarPlacement?,
        statusItem: Manifest.StatusItem?
    ) -> MenuBarPlacement {
        stored ?? MenuBarPlacement(enabled: false)
    }

    /// The display mode a widget is actually drawn with.
    ///
    /// A widget the user promoted by hand may carry no author mode, or an
    /// explicit `"none"`; it then behaves as `"text"`, the form the shared
    /// strip can draw. One rule, so the settings pane and the renderer cannot
    /// disagree about what a widget will look like.
    public static func effectiveStatusItem(
        _ statusItem: Manifest.StatusItem?
    ) -> Manifest.StatusItem {
        guard let statusItem, statusItem.isPromotable else {
            return Manifest.StatusItem(mode: "text")
        }
        return statusItem
    }

    /// Collapses whitespace and clips to `maxLabelCharacters`, since a status
    /// label is a template that can expand to anything.
    public static func normalizedLabel(
        _ label: String?,
        limit: Int = maxLabelCharacters
    ) -> String? {
        guard let label else { return nil }
        let collapsed = label
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(max(limit - 1, 1))) + "…"
    }

    /// Orders entries by the user's explicit sort key, then by name, so the
    /// strip does not reshuffle when a widget happens to refresh first.
    public static func ordered(
        _ entries: [(entry: MenuBarEntry, order: Double?)]
    ) -> [MenuBarEntry] {
        entries
            .enumerated()
            .sorted { left, right in
                switch (left.element.order, right.element.order) {
                case let (lhs?, rhs?) where lhs != rhs:
                    return lhs < rhs
                case (nil, _?):
                    return false
                case (_?, nil):
                    return true
                default:
                    let byName = left.element.entry.name
                        .localizedCaseInsensitiveCompare(right.element.entry.name)
                    if byName != .orderedSame { return byName == .orderedAscending }
                    return left.offset < right.offset
                }
            }
            .map(\.element.entry)
    }

    /// The entries that are actually promoted, capped at `maxEntries`.
    ///
    /// This — not the drawn set — is what keeps polling while the popup is
    /// closed. The cap is applied before the "has something to draw" filter on
    /// purpose: a widget that has not rendered yet still needs its refresh to
    /// produce a first label, and a widget past the cap must not hold the
    /// closed-popup exemption for a value nobody can see.
    public static func promoted(_ entries: [MenuBarEntry]) -> [MenuBarEntry] {
        Array(entries.prefix(maxEntries))
    }

    /// Order keys after moving `id` `offset` places within `ids`.
    ///
    /// Returns an assignment for *every* id, not just the moved one: the stored
    /// keys can be nil, duplicated or sparse (a widget promoted before ordering
    /// existed has none), and re-deriving the whole run is the only way to get
    /// a predictable result from any of those starting points.
    ///
    /// `ids` must already be in displayed order — that is what the user sees
    /// and what "left" and "right" refer to.
    public static func reordered(
        _ ids: [String], moving id: String, by offset: Int
    ) -> [String: Double] {
        guard let from = ids.firstIndex(of: id), offset != 0 else {
            return Dictionary(
                uniqueKeysWithValues: ids.enumerated().map { ($1, Double($0)) }
            )
        }
        var moved = ids
        moved.remove(at: from)
        let to = min(max(from + offset, 0), moved.count)
        moved.insert(id, at: to)
        return Dictionary(
            uniqueKeysWithValues: moved.enumerated().map { ($1, Double($0)) }
        )
    }

    /// Whether the widget can move further in that direction — the callers use
    /// it to disable a control rather than offer a no-op.
    public static func canMove(_ id: String, by offset: Int, within ids: [String]) -> Bool {
        guard let index = ids.firstIndex(of: id) else { return false }
        let target = index + offset
        return target >= 0 && target < ids.count
    }

    /// Splits the promoted entries into the shared strip and the widgets that
    /// asked for their own status item, dropping those with nothing to draw.
    public static func partition(
        _ entries: [MenuBarEntry]
    ) -> (strip: [MenuBarEntry], separate: [MenuBarEntry]) {
        let drawable = promoted(entries).filter { !$0.isEmpty }
        return (
            strip: drawable.filter { !$0.separate },
            separate: drawable.filter(\.separate)
        )
    }

    /// Plain-text form of the shared strip — the accessibility label, and the
    /// fallback title when attributed drawing is unavailable.
    public static func stripText(_ entries: [MenuBarEntry]) -> String {
        entries
            .compactMap { entry in
                let label = entry.label ?? ""
                return label.isEmpty ? nil : label
            }
            .joined(separator: stripSeparator)
    }

    /// Multi-line tooltip: one line per entry, each "Name — value".
    public static func tooltip(for entries: [MenuBarEntry]) -> String? {
        let lines = entries.map { entry -> String in
            if let tooltip = entry.tooltip, !tooltip.isEmpty {
                return "\(entry.name) — \(tooltip)"
            }
            if let label = entry.label, !label.isEmpty {
                return "\(entry.name) — \(label)"
            }
            return entry.name
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}
