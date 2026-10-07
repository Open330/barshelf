import Foundation

// What a desktop widget actually draws (R14-B): each item boiled down to a
// title, a value, a fraction, a tone, and one line of detail, so the widget
// lays it out in a native template instead of shrinking the popup's view.

extension SharedShelf {
    /// One reading inside an item: "5h · 97% left" with its bar.
    public struct Metric: Codable, Equatable, Sendable {
        public var label: String?
        public var value: String?
        /// 0…1, from the item's `progress` node.
        public var fraction: Double?
        /// A BarShelf colour name (`good`, `warning`, `danger`, …).
        public var tone: String?
        /// The other short text next to it ("reset 4.1h").
        public var detail: String?

        public init(label: String? = nil, value: String? = nil, fraction: Double? = nil, tone: String? = nil, detail: String? = nil) {
            self.label = label
            self.value = value
            self.fraction = fraction
            self.tone = tone
            self.detail = detail
        }
    }

    /// An item as a widget template reads it.
    public struct Summary: Codable, Equatable, Sendable {
        public var title: String?
        /// The line under the title ("e-ed@callabo.ai", "Claude Code").
        public var subtitle: String?
        /// The headline: the first metric's value, or the largest text.
        public var value: String?
        public var fraction: Double?
        public var tone: String?
        /// One line of context ("7d · reset 1.7d", "Last reset 820h ago").
        public var detail: String?
        /// A short trailing status ("1s", "pro").
        public var status: String?
        public var metrics: [Metric]
        /// An SF Symbol the item leads with, when it has one.
        public var symbol: String?
        /// The colour of a leading status dot (muxa's agents).
        public var dotTone: String?
        /// Local file the item shows a thumbnail of. Read by BarShelf only:
        /// it exports a small PNG and clears this before sharing.
        public var imagePath: String?
        /// That PNG, by file name inside the shared `images/` folder.
        public var thumbnail: String?

        public init(
            title: String? = nil, subtitle: String? = nil, value: String? = nil, fraction: Double? = nil,
            tone: String? = nil, detail: String? = nil, status: String? = nil, metrics: [Metric] = [],
            symbol: String? = nil, dotTone: String? = nil, imagePath: String? = nil, thumbnail: String? = nil
        ) {
            self.title = title
            self.subtitle = subtitle
            self.value = value
            self.fraction = fraction
            self.tone = tone
            self.detail = detail
            self.status = status
            self.metrics = metrics
            self.symbol = symbol
            self.dotTone = dotTone
            self.imagePath = imagePath
            self.thumbnail = thumbnail
        }
    }

    /// The layouts a desktop widget can use.
    public enum Template: String, Codable, Sendable, CaseIterable {
        /// One number, large, with a line of context and a bar.
        case bigValue
        /// Label-value-bar rows; rings in the small size.
        case meters
        /// Rows of name · value · bar, or name · status with a dot.
        case list
        /// Thumbnails with names.
        case grid
    }

    /// The template that suits a set of items, when the user has not picked
    /// one: thumbnails make a grid, items that are each just a reading make
    /// meters, anything else a list. No items means one big value.
    public static func automaticTemplate(for summaries: [Summary]) -> Template {
        guard !summaries.isEmpty else { return .bigValue }
        if summaries.contains(where: { $0.thumbnail != nil || $0.imagePath != nil }) { return .grid }
        // Each item a single label-value reading (a bar is optional):
        // System's CPU/Memory/Disk, Sensors' rows.
        let plainReadings = summaries.allSatisfy { summary in
            summary.metrics.count == 1 && summary.subtitle == nil
        }
        return plainReadings ? .meters : .list
    }

    // MARK: - Summarizing

    private struct TextBit {
        let text: String
        let role: String?
        let size: Double?
        let foreground: String?
        var isBadge = false
        var isCaption: Bool { role == "caption" || isBadge }
        var hasDigit: Bool { text.contains { $0.isNumber } }
        /// How much it reads as the headline: big type first, then a number,
        /// then not being a caption.
        var valueScore: Double { (size ?? 0) * 10 + (hasDigit ? 5 : 0) + (isCaption ? 0 : 1) }
    }

    /// Boils a view-tree node down to what a widget template shows.
    ///
    /// Readings first: every container that directly holds a `progress`
    /// becomes a metric — its largest text the value, its first other text
    /// the label, the rest detail. The title is the first text outside the
    /// readings (else the first reading's label); a caption right after it
    /// is the subtitle; a short trailing caption is the status.
    public static func summarize(_ node: UINode, fallbackTitle: String? = nil) -> Summary {
        var metrics: [Metric] = []
        var outside: [TextBit] = []
        var symbol: String?
        var dotTone: String?
        var imagePath: String?
        var cardTone: String?

        func texts(in node: UINode, skipping skip: (UINode) -> Bool) -> [TextBit] {
            if node.hidden == true || node.desktopRole == "hide" || skip(node) { return [] }
            if node.type == "text", let text = node.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                return [TextBit(text: text, role: node.role, size: node.size, foreground: node.foreground)]
            }
            if node.type == "badge", let text = (node.text ?? node.title)?.trimmingCharacters(in: .whitespaces), !text.isEmpty {
                return [TextBit(text: text, role: "caption", size: nil, foreground: node.tint ?? node.tone, isBadge: true)]
            }
            return children(of: node).flatMap { texts(in: $0, skipping: skip) }
        }

        func holdsProgress(_ node: UINode) -> Bool {
            children(of: node).contains { $0.type == "progress" && $0.hidden != true }
        }

        func metric(from container: UINode) -> Metric {
            let progress = children(of: container).first { $0.type == "progress" }
            // The container's own texts; a nested reading inside it is its own.
            let bits = children(of: container).flatMap { texts(in: $0, skipping: holdsProgressNode) }
            // Ties go to the later text: a value follows its label.
            let valueBit = bits.enumerated()
                .max { ($0.element.valueScore, $0.offset) < ($1.element.valueScore, $1.offset) }?.element
            // The label is the short caption beside the value ("5h"), else
            // the first other text ("CPU").
            var others = bits.filter { $0.text != valueBit?.text }
            if let index = others.firstIndex(where: { $0.isCaption && $0.text.count <= 6 }), index > 0 {
                others.insert(others.remove(at: index), at: 0)
            }
            let fraction = progress?.value
                ?? progress?.countdown.flatMap { countdown in
                    countdown.until > countdown.from
                        ? max(0, min(1, (countdown.until - Date().timeIntervalSince1970 * 1000) / (countdown.until - countdown.from)))
                        : nil
                }
            return Metric(
                label: others.first?.text,
                value: valueBit.map { $0.text },
                fraction: fraction.map { matchingBar(min(max($0, 0), 1), value: valueBit?.text) },
                tone: progress?.tint ?? valueBit?.foreground,
                detail: others.dropFirst().map { $0.text }.joined(separator: " · ").nilIfEmpty
            )
        }

        func walk(_ node: UINode) {
            guard node.hidden != true, node.desktopRole != "hide" else { return }
            if node.type == "card", cardTone == nil { cardTone = node.tone ?? node.tint }
            if node.type == "image", let source = node.source {
                switch source.kind {
                case "sfSymbol":
                    if (node.size ?? 13) <= 10 {
                        dotTone = dotTone ?? node.tint ?? node.foreground
                    } else {
                        symbol = symbol ?? source.name
                    }
                case "fileThumbnail", "fileIcon":
                    imagePath = imagePath ?? source.path
                default:
                    break
                }
            }
            if holdsProgress(node) {
                metrics.append(metric(from: node))
                return
            }
            if node.type == "text" || node.type == "badge" {
                outside += texts(in: node) { _ in false }
                return
            }
            for child in children(of: node) { walk(child) }
        }

        walk(node)

        // The item is itself one reading (Codex Reset): its first text in
        // reading order names it, not the short caption next to the value.
        if holdsProgress(node), metrics.count == 1, outside.isEmpty {
            let bits = children(of: node).flatMap { texts(in: $0, skipping: holdsProgressNode) }
            if let first = bits.first(where: { $0.text != metrics[0].value }) {
                let others = bits.filter { $0.text != first.text && $0.text != metrics[0].value }
                metrics[0].label = nil
                metrics[0].detail = others.map { $0.text }.joined(separator: " · ").nilIfEmpty
                outside = [first]
            }
        }

        // A two-text row with no bar is still a reading ("GPU" "41°").
        if metrics.isEmpty, outside.count == 2 {
            let pair = outside
            let valueIndex: Int
            if pair[0].hasDigit != pair[1].hasDigit {
                valueIndex = pair[0].hasDigit ? 0 : 1
            } else if pair[0].isCaption != pair[1].isCaption {
                valueIndex = pair[0].isCaption ? 1 : 0
            } else {
                valueIndex = 1
            }
            metrics = [Metric(label: pair[1 - valueIndex].text, value: pair[valueIndex].text, tone: pair[valueIndex].foreground)]
            outside = []
        }

        var title: String?
        var subtitle: String?
        var status: String?
        var rest = outside
        if let index = rest.firstIndex(where: { !$0.isCaption }) ?? rest.indices.first {
            title = rest.remove(at: index).text
        }
        // A badge ("pro") or a short time ("1s", "21m") is the status; the
        // first longer caption is the subtitle.
        if let index = rest.firstIndex(where: { $0.isBadge })
            ?? rest.firstIndex(where: { $0.isCaption && $0.text.count <= 6 && $0.hasDigit }) {
            status = rest.remove(at: index).text
        }
        if let index = rest.firstIndex(where: { $0.isCaption && $0.text.count > 1 }) {
            subtitle = rest.remove(at: index).text
        }
        if title == nil, let label = metrics.first?.label {
            title = label
            metrics[0].label = nil
        }

        // An item with no bar still has a headline: its largest text.
        var value = metrics.first?.value
        if value == nil, let big = rest.filter({ ($0.size ?? 0) >= 18 }).max(by: { ($0.size ?? 0) < ($1.size ?? 0) }) {
            value = big.text
            rest.removeAll { $0.text == big.text }
        }
        let metricContext = [metrics.first?.label, metrics.first?.detail].compactMap { $0 }
        let detail = metricContext.isEmpty
            ? rest.prefix(2).map { $0.text }.joined(separator: " · ").nilIfEmpty
            : metricContext.joined(separator: " · ")

        // What the author said outranks what BarShelf read.
        let said = authorRoles(in: node)
        title = said["title"] ?? title
        subtitle = said["subtitle"] ?? subtitle
        status = said["status"] ?? status
        if let saidValue = said["value"] { value = saidValue }
        let saidDetail = said["detail"]

        return Summary(
            title: title ?? fallbackTitle,
            subtitle: subtitle,
            value: value,
            fraction: metrics.first?.fraction,
            tone: metrics.first?.tone ?? cardTone,
            detail: saidDetail ?? detail,
            status: status,
            metrics: metrics,
            symbol: symbol,
            dotTone: dotTone,
            imagePath: imagePath
        )
    }

    /// A bar that fills the other way from the number beside it ("97% left"
    /// over a bar of what is used) is turned around, so bar and number agree.
    static func matchingBar(_ fraction: Double, value: String?) -> Double {
        guard let value, let range = value.range(of: #"\d+(\.\d+)?(?=\s*%)"#, options: .regularExpression),
              let percent = Double(value[range]).map({ $0 / 100 })
        else { return fraction }
        return abs(fraction - percent) > 0.25 && abs(1 - fraction - percent) < 0.05 ? 1 - fraction : fraction
    }

    /// The first text under each node an author gave a `desktopRole`
    /// (other than `item` and `hide`).
    static func authorRoles(in node: UINode) -> [String: String] {
        var roles: [String: String] = [:]
        func firstText(_ node: UINode) -> String? {
            guard node.hidden != true, node.desktopRole != "hide" else { return nil }
            if let text = (node.type == "text" ? node.text : node.type == "badge" ? (node.text ?? node.title) : nil)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                return text
            }
            if let title = node.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty,
               ["card", "section"].contains(node.type) {
                return title
            }
            return children(of: node).lazy.compactMap(firstText).first
        }
        func walk(_ node: UINode) {
            guard node.hidden != true, node.desktopRole != "hide" else { return }
            if let role = node.desktopRole, ["title", "subtitle", "value", "detail", "status"].contains(role),
               roles[role] == nil, let text = firstText(node) {
                roles[role] = text
            }
            for child in children(of: node) { walk(child) }
        }
        walk(node)
        return roles
    }

    static func children(of node: UINode) -> [UINode] {
        (node.children ?? []) + (node.items ?? []) + [node.child?.node].compactMap { $0 }
    }

    /// Whether a node directly holds a progress bar (a nested reading).
    static func holdsProgressNode(_ node: UINode) -> Bool {
        children(of: node).contains { $0.type == "progress" && $0.hidden != true }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
