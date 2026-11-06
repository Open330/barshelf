import Foundation

/// How promoted widgets sit in the menu bar.
public enum MenuBarLayout: String, Codable, CaseIterable, Sendable {
    /// Text beside the BarShelf icon, and an item of its own for each widget
    /// split out. How BarShelf has always drawn them.
    case items
    /// One small round chip per widget, overlapping beside the BarShelf icon.
    /// They fan out under the pointer, and each opens its own card.
    case cluster
}

/// One widget as a chip in the cluster: a coloured face with its symbol or
/// initial, a ring for a reading that is a share of something, and a dot
/// when the reading is in trouble.
public struct ClusterChip: Equatable, Sendable, Identifiable {
    /// The widget's id, or `widgetID#profile` for one of its profiles.
    public var id: String
    public var widgetID: String
    public var name: String
    /// SF Symbol for the face; nil draws `initial` instead.
    public var symbol: String?
    /// One or two characters: an emoji the user chose, or the name's first
    /// letter.
    public var initial: String
    /// 0...1 for the ring; nil when the reading is not a share of anything.
    public var fraction: Double?
    /// The reading's colour, for the ring and the peek.
    public var tint: MenuBarTint?
    /// The reading needs a look (a `danger` tint).
    public var alert: Bool
    public var isStale: Bool
    /// The reading as the strip would draw it, for the peek.
    public var reading: String
    /// The reading's value alone ("22%", "12W"), for the pill the chip
    /// grows into under the pointer. The peek names it.
    public var value: String
    /// What VoiceOver says for the chip.
    public var spoken: String

    public init(
        id: String? = nil,
        widgetID: String, name: String, symbol: String? = nil, initial: String,
        fraction: Double? = nil, tint: MenuBarTint? = nil, alert: Bool = false,
        isStale: Bool = false, reading: String = "", value: String? = nil, spoken: String = ""
    ) {
        self.id = id ?? widgetID
        self.widgetID = widgetID
        self.name = name
        self.symbol = symbol
        self.initial = initial
        self.fraction = fraction
        self.tint = tint
        self.alert = alert
        self.isStale = isStale
        self.reading = reading
        self.value = value ?? reading
        self.spoken = spoken
    }
}

extension MenuBarEntry {
    /// The readings that are profiles: the full list when the runtime kept
    /// one, else the metrics the item draws.
    var profileReadings: [StatusMetric] { profileMetrics.isEmpty ? metrics : profileMetrics }
}

public enum MenuBarClusterPolicy {
    /// More than this and the fanned-out strip gets wider than most of a
    /// menu bar can spare; the rest stay on the shelf.
    public static let maxChips = 8

    /// Every promoted widget becomes a chip, split-out ones included: in a
    /// cluster there is nothing to split out from.
    ///
    /// - Parameter isSymbol: whether a name is an SF Symbol. Core cannot
    ///   ask AppKit, so the app passes the answer in.
    public static func chips(
        from entries: [MenuBarEntry], isSymbol: (String) -> Bool = { _ in true }
    ) -> [ClusterChip] {
        let all: [ClusterChip] = MenuBarPolicy.promoted(entries).flatMap { entry -> [ClusterChip] in
            if entry.profiles, entry.profileReadings.count > 1 { return profileChips(entry) }
            return [widgetChip(entry, isSymbol: isSymbol)]
        }
        return Array(all.prefix(maxChips))
    }

    /// One chip per metric of a widget whose metrics are profiles: named
    /// by the metric's label, ringed by its own share and tint.
    static func profileChips(_ entry: MenuBarEntry) -> [ClusterChip] {
        entry.profileReadings.enumerated().map { index, metric in
            let name = metric.label.isEmpty ? entry.name : metric.label
            let tint = MenuBarTint.named(metric.tint)
            let value = metric.value.isEmpty ? metric.active.map { $0 ? "●" : "○" } ?? "" : metric.value
            let spoken = metric.accessibilityLabel ?? [name, value].filter { !$0.isEmpty }.joined(separator: " ")
            var single = entry
            single.metrics = [metric]
            single.label = nil
            return ClusterChip(
                id: "\(entry.widgetID)#\(metric.id ?? String(index))",
                widgetID: entry.widgetID,
                name: name,
                initial: initial(of: name),
                fraction: fraction(for: single),
                tint: tint,
                alert: tint == .danger,
                isStale: entry.isStale,
                reading: value,
                value: shortValue(value),
                spoken: "\(entry.name), \(spoken)"
            )
        }
    }

    static func widgetChip(_ entry: MenuBarEntry, isSymbol: (String) -> Bool) -> ClusterChip {
        let override = entry.iconOverride.flatMap { $0.isEmpty ? nil : $0 }
        let symbolName = override ?? entry.symbol
        let symbol = symbolName.flatMap { isSymbol($0) ? $0 : nil }
        let glyph = override.flatMap { isSymbol($0) ? nil : $0 }
        let tint = tint(for: entry)
        let reading = MenuBarPolicy.normalizedLabel(MenuBarPolicy.entryText(entry), limit: 28) ?? ""
        let spoken = MenuBarPolicy.accessibilityText(entry)
        return ClusterChip(
            widgetID: entry.widgetID,
            name: entry.name,
            symbol: symbol,
            initial: glyph.map { String($0.prefix(2)) } ?? initial(of: entry.name),
            fraction: fraction(for: entry),
            tint: tint,
            alert: tint == .danger,
            isStale: entry.isStale,
            reading: reading,
            value: shortValue(value(of: entry) ?? reading),
            spoken: spoken.isEmpty ? entry.name : "\(entry.name), \(spoken)"
        )
    }

    /// The first reading's value, without its label; nil when the entry
    /// has no metrics.
    static func value(of entry: MenuBarEntry) -> String? {
        guard let metric = entry.metrics.first else { return nil }
        if !metric.value.isEmpty { return metric.value }
        return metric.active.map { $0 ? "●" : "○" }
    }

    /// At most `valueLimit` characters, so a pill stays a pill.
    static let valueLimit = 8
    static func shortValue(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.count > valueLimit else { return trimmed }
        return String(trimmed.prefix(valueLimit - 1)) + "…"
    }

    /// The first letter that is a letter or digit, upper-cased.
    static func initial(of name: String) -> String {
        guard let first = name.first(where: { $0.isLetter || $0.isNumber }) else { return "•" }
        return String(first).uppercased()
    }

    /// The entry's own tint, else the first reading's.
    static func tint(for entry: MenuBarEntry) -> MenuBarTint? {
        if let tint = entry.tint { return tint }
        return entry.metrics.lazy.compactMap { MenuBarTint.named($0.tint) }.first
    }

    /// A share the ring can show: the first reading that is a percentage
    /// (by its unit, format, or a trailing %), clamped to 0...1.
    static func fraction(for entry: MenuBarEntry) -> Double? {
        for metric in entry.metrics {
            let isPercent = metric.unit == "%" || metric.format == "percent"
                || metric.value.trimmingCharacters(in: .whitespaces).hasSuffix("%")
            guard isPercent else { continue }
            if let number = metric.number { return clamp(number / 100) }
            if let parsed = leadingNumber(metric.value) { return clamp(parsed / 100) }
        }
        if entry.metrics.isEmpty, let label = entry.label,
           label.trimmingCharacters(in: .whitespaces).hasSuffix("%"),
           let parsed = leadingNumber(label) {
            return clamp(parsed / 100)
        }
        return nil
    }

    static func leadingNumber(_ text: String) -> Double? {
        let digits = text.unicodeScalars.drop { !CharacterSet.decimalDigits.contains($0) }
            .prefix { CharacterSet.decimalDigits.contains($0) || $0 == "." }
        return Double(String(String.UnicodeScalarView(digits)))
    }

    private static func clamp(_ value: Double) -> Double { min(max(value, 0), 1) }
}

/// Where each chip sits, folded and fanned out.
///
/// x is measured from the left edge of the stack. Folded, chips overlap and
/// the later one is drawn on top; fanned out, they sit side by side. The
/// chip under the pointer when the fan opens stays where it was, so the
/// pointer is still on it afterwards: the strip opens around it.
public struct ClusterGeometry: Equatable, Sendable {
    public var count: Int

    /// A chip's square, including the ring around its face.
    public static let slot: Double = 26
    /// Folded: each chip shows this much of itself past the next.
    public static let collapsedStep: Double = 11
    /// Fanned out: centre to centre.
    public static let expandedStep: Double = 28
    /// Between the last chip and the BarShelf icon.
    public static let markGap: Double = 4
    /// The BarShelf icon's square.
    public static let markWidth: Double = 22

    public init(count: Int) { self.count = max(count, 0) }

    public func collapsedX(_ index: Int) -> Double {
        Double(index) * Self.collapsedStep
    }

    /// Fanned out around `anchor`, which keeps its folded position.
    public func expandedX(_ index: Int, anchor: Int) -> Double {
        Double(index) * Self.expandedStep + Double(clampedAnchor(anchor)) * (Self.collapsedStep - Self.expandedStep)
    }

    /// The stack alone, folded.
    public var collapsedWidth: Double {
        count == 0 ? 0 : Double(count - 1) * Self.collapsedStep + Self.slot
    }

    /// The status item: the folded stack, then the BarShelf icon.
    public var itemWidth: Double {
        count == 0 ? Self.markWidth : collapsedWidth + Self.markGap + Self.markWidth
    }

    public var collapsedMarkX: Double { count == 0 ? 0 : collapsedWidth + Self.markGap }

    public func expandedMarkX(anchor: Int) -> Double {
        count == 0 ? 0 : expandedX(count - 1, anchor: anchor) + Self.slot + Self.markGap
    }

    /// Everything the fanned-out strip covers, icon included.
    public func expandedSpan(anchor: Int) -> ClosedRange<Double> {
        guard count > 0 else { return 0...Self.markWidth }
        return expandedX(0, anchor: anchor)...(expandedMarkX(anchor: anchor) + Self.markWidth)
    }

    /// The chip under `x` while folded: the topmost one, which is the later
    /// one where two overlap. nil over the icon or outside the stack.
    public func collapsedIndex(at x: Double) -> Int? {
        guard count > 0, x >= 0, x < collapsedWidth else { return nil }
        for index in stride(from: count - 1, through: 0, by: -1) where x >= collapsedX(index) {
            return index
        }
        return nil
    }

    /// The chip under `x` while fanned out around `anchor`: the nearest one,
    /// gaps included, so moving along the strip never falls between chips.
    public func expandedIndex(at x: Double, anchor: Int) -> Int? {
        guard count > 0 else { return nil }
        let first = expandedX(0, anchor: anchor)
        let last = expandedX(count - 1, anchor: anchor) + Self.slot
        guard x >= first - Self.markGap, x <= last + Self.markGap / 2 else { return nil }
        let raw = ((x - first - Self.slot / 2) / Self.expandedStep).rounded()
        return min(max(Int(raw), 0), count - 1)
    }

    /// Folded centre-to-centre distance that leaves a chip whole: its disc
    /// plus a hair of gap.
    public static let revealStep: Double = 21

    /// Whether the BarShelf icon steps out of the way while `focus` is
    /// uncovered, giving its room to the chips. A lone chip has nothing to
    /// make room for, so the icon stays.
    public func hidesMark(focus: Int?) -> Bool {
        guard let focus else { return false }
        return count > 1 && focus >= 0 && focus < count
    }

    /// How far the focused chip steps away from the one before it.
    public static var focusShift: Double { revealStep - collapsedStep }
    /// A chip's disc, inside its slot.
    public static let disc: Double = 18
    /// The slot's empty edge either side of a disc or pill.
    public static var slotInset: Double { (slot - disc) / 2 }

    /// Where every chip starts with `focus` uncovered and drawn as a pill
    /// `pill` wide (a disc's width when its reading has no room or none).
    ///
    /// A gap opens on each side of the focused chip: it steps away from the
    /// one before it, and the chips after it step away from its right end.
    /// Every other gap stays folded. The layout grows to the right first,
    /// into the hidden icon's room; what does not fit there moves the whole
    /// layout left, into room the item takes on its left while a chip is in
    /// focus (`hoverLead`). x is in stack coordinates: the folded stack
    /// starts at 0, so a negative x is in that room. nil is the plain fold.
    public func pillLayout(focus: Int?, pill: Double) -> [Double] {
        guard hidesMark(focus: focus), let focus else { return (0..<count).map(collapsedX) }
        let width = max(pill, Self.disc)
        var xs: [Double] = []
        var x = 0.0
        for index in 0..<count {
            xs.append(x)
            if index == focus - 1 {
                x += Self.revealStep
            } else if index == focus {
                x += width + Self.revealStep - Self.disc
            } else {
                x += Self.collapsedStep
            }
        }
        let end = focus == count - 1 ? xs[focus] + width + 2 * Self.slotInset : xs[count - 1] + Self.slot
        let shift = min(0, itemWidth - end)
        return xs.map { $0 + shift }
    }

    /// The room the item takes on its left while a chip is in focus: enough
    /// for the widest pill, so the item keeps one width while the pointer
    /// moves between chips.
    public func hoverLead(pills: [Double]) -> Double {
        guard count > 1 else { return 0 }
        var lead = 0.0
        for focus in 0..<count {
            let pill = focus < pills.count ? pills[focus] : Self.disc
            lead = max(lead, -(pillLayout(focus: focus, pill: pill).first ?? 0))
        }
        // In steps of 4, so a reading that changes by a digit does not
        // nudge the menu bar.
        return (lead / 4).rounded(.up) * 4
    }

    /// The chip the pointer at stack x selects in the pill layout. The
    /// focused chip owns the gap before it and everything up to the next
    /// chip, so a pointer that has not moved stays on it; elsewhere the
    /// later chip wins where two overlap. Folded, only the stack selects a
    /// chip, so the icon stays the icon.
    public func pillIndex(at x: Double, focus: Int?, pill: Double) -> Int? {
        guard count > 0 else { return nil }
        let xs = pillLayout(focus: focus, pill: pill)
        guard hidesMark(focus: focus), let focus else {
            guard x >= 0, x < collapsedWidth else { return nil }
            return stride(from: count - 1, through: 0, by: -1).first { x >= xs[$0] }
        }
        let width = max(pill, Self.disc)
        let end = focus == count - 1 ? xs[focus] + width + 2 * Self.slotInset : xs[count - 1] + Self.slot
        guard x >= xs[0], x < end else { return nil }
        let start = xs[focus] - (focus > 0 ? Self.focusShift : 0)
        let stop = focus == count - 1 ? end : xs[focus + 1]
        if x >= start, x < stop { return focus }
        return stride(from: count - 1, through: 0, by: -1).first { x >= xs[$0] }
    }

    /// `pillLayout` with the focused chip as a plain disc.
    public func focusedX(_ index: Int, focus: Int?) -> Double {
        let xs = pillLayout(focus: focus, pill: Self.disc)
        return xs.indices.contains(index) ? xs[index] : collapsedX(index)
    }

    /// `pillIndex` with the focused chip as a plain disc.
    public func focusedIndex(at x: Double, focus: Int?) -> Int? {
        pillIndex(at: x, focus: focus, pill: Self.disc)
    }

    /// Whether `x` is on the BarShelf icon while folded.
    public func isOnMark(collapsedX x: Double) -> Bool {
        x >= collapsedMarkX - Self.markGap / 2 && x <= collapsedMarkX + Self.markWidth
    }

    public func isOnMark(expandedX x: Double, anchor: Int) -> Bool {
        let mark = expandedMarkX(anchor: anchor)
        return x >= mark - Self.markGap / 2 && x <= mark + Self.markWidth
    }

    private func clampedAnchor(_ anchor: Int) -> Int {
        count == 0 ? 0 : min(max(anchor, 0), count - 1)
    }
}
