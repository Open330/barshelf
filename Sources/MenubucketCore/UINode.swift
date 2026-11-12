import Foundation

/// Declarative view-tree node (server-driven UI contract, v0).
///
/// Forward-compatible by design: `type` is a plain string discriminator and every
/// other field is optional, so a payload containing unknown node types (or extra
/// fields on known types) still decodes successfully. The renderer decides what
/// to do with types it does not recognize (placeholder).
public struct UINode: Codable, Equatable {
    /// Stable identity for repeated nodes (SwiftUI identity + action routing).
    public var id: String?
    /// Node type discriminator. Known v0 types are listed in `UINode.KnownType`.
    public var type: String

    // Container fields
    public var children: [UINode]?
    /// `scroll` single child.
    public var child: UINodeBox?
    /// `scroll`: "vertical" | "horizontal" | "both".
    public var axis: String?
    /// SDK conditional rendering. Hidden nodes render no view.
    public var hidden: Bool?
    /// `list` rows.
    public var items: [UINode]?
    public var spacing: Double?
    /// `grid` fixed column count (nil → adaptive by `size`).
    public var columns: Int?
    /// `list`: when present, renders a local search field and filters rows by
    /// their visible text without re-running the widget.
    public var searchPlaceholder: String?

    // Text fields
    public var text: String?
    /// "title" | "body" | "caption" | "code"
    public var role: String?
    public var lineLimit: Int?
    public var monospacedDigit: Bool?

    // Section / button / empty
    public var title: String?
    /// `empty` secondary line.
    public var subtitle: String?

    // Image
    public var source: ImageSource?
    /// Image point size.
    public var size: Double?

    // Color hints ("primary"|"secondary"|"tertiary"|"accent"|"good"|"warning"|"danger"|"neutral")
    public var tint: String?
    public var tone: String?
    public var foreground: String?
    /// When set (a semantic color), the node is drawn on a filled circle of that
    /// color with contrasting text — e.g. today in a calendar grid.
    public var fill: String?

    // Progress
    /// 0.0 ... 1.0
    public var value: Double?
    public var label: String?
    /// Progress style: "linear" (default) | "ring".
    public var style: String?
    /// Host-driven countdown (used instead of `value`); host ticks 1 Hz while
    /// the popup is open — no script re-run needed.
    public var countdown: Countdown?
    /// "remainingSeconds" → render the remaining seconds as the ring's center
    /// label (or trailing label for linear style). "remaining" → the same as
    /// a short duration ("45s", "12m", "1h5m"), BarShelf 0.7.32.
    public var labelFrom: String?
    /// First matching rule overrides `tint` (e.g. danger under 10s).
    public var tintRules: [TintRule]?
    /// `progress` (linear): parts of one stacked meter, e.g. CPU user +
    /// system. Drawn left to right; the total is clamped to 1. When present
    /// the meter ignores `value`.
    public var segments: [ProgressSegment]?

    // Sparkline
    /// `sparkline` samples, oldest first. Decodes leniently (numbers and
    /// numeric strings; anything else is skipped) so a workflow expression
    /// that yields a ragged array still draws what it can.
    public var values: NumberList?
    /// `sparkline` value at the bottom / top edge. Absent → the data range
    /// with a little headroom.
    public var min: Double?
    public var max: Double?
    /// `sparkline` height in points (default 34, scaled by Compact density).
    public var height: Double?

    /// SF Symbol name (button / empty / banner leading icon).
    public var icon: String?

    public var action: NodeAction?

    // Layout modifiers
    public var padding: Double?
    public var widthFill: Bool?
    /// `hstack` cross-axis alignment: "center" (default) | "top" | "bottom"
    /// | "baseline" (first text baseline — big number + small caption rows).
    public var alignment: String?

    /// Present → the rendered view can be dragged out as a file
    /// (Finder / other apps), M2-b.
    public var drag: DragSpec?

    /// Optional explicit VoiceOver label for this node. When set, the renderer
    /// exposes it as the accessibility label of the rendered view (e.g. a
    /// meaningful symbol, button, or row). When nil the renderer keeps its
    /// default behavior (decorative images stay hidden, file thumbnails use
    /// the file name, etc.).
    public var accessibilityLabel: String?
    /// Hover text for the rendered view (BarShelf 0.7.32): the place for
    /// detail that would crowd the card, such as a failure's raw message.
    public var help: String? = nil
    /// SDK/schema-native nested accessibility metadata. The flat label stays
    /// supported for existing workflow widgets.
    public var accessibility: Accessibility?
    /// `spacer` minimum length in points.
    public var minLength: Double?
    /// What this node is to a macOS desktop widget, for an author who wants
    /// to say rather than leave it to BarShelf's reading of the tree:
    /// `item` (one choosable item), `title`, `subtitle`, `value`, `detail`,
    /// `status`, or `hide` (left out of desktop widgets). The popup ignores it.
    public var desktopRole: String?

    public struct Accessibility: Codable, Equatable, Sendable {
        public var label: String?
        public var hint: String?
        public var value: String?

        public init(label: String? = nil, hint: String? = nil, value: String? = nil) {
            self.label = label
            self.hint = hint
            self.value = value
        }
    }

    public struct DragSpec: Codable, Equatable, Sendable {
        public var filePath: String

        public init(filePath: String) {
            self.filePath = filePath
        }
    }

    public init(
        id: String? = nil,
        type: String,
        children: [UINode]? = nil,
        child: UINode? = nil,
        axis: String? = nil,
        hidden: Bool? = nil,
        items: [UINode]? = nil,
        spacing: Double? = nil,
        columns: Int? = nil,
        searchPlaceholder: String? = nil,
        text: String? = nil,
        role: String? = nil,
        lineLimit: Int? = nil,
        monospacedDigit: Bool? = nil,
        title: String? = nil,
        subtitle: String? = nil,
        source: ImageSource? = nil,
        size: Double? = nil,
        tint: String? = nil,
        tone: String? = nil,
        foreground: String? = nil,
        fill: String? = nil,
        value: Double? = nil,
        label: String? = nil,
        style: String? = nil,
        countdown: Countdown? = nil,
        labelFrom: String? = nil,
        tintRules: [TintRule]? = nil,
        segments: [ProgressSegment]? = nil,
        values: NumberList? = nil,
        min: Double? = nil,
        max: Double? = nil,
        height: Double? = nil,
        icon: String? = nil,
        action: NodeAction? = nil,
        padding: Double? = nil,
        widthFill: Bool? = nil,
        alignment: String? = nil,
        drag: DragSpec? = nil,
        accessibilityLabel: String? = nil,
        accessibility: Accessibility? = nil,
        minLength: Double? = nil,
        desktopRole: String? = nil
    ) {
        self.id = id
        self.type = type
        self.children = children
        self.child = child.map(UINodeBox.init)
        self.axis = axis
        self.hidden = hidden
        self.items = items
        self.spacing = spacing
        self.columns = columns
        self.searchPlaceholder = searchPlaceholder
        self.text = text
        self.role = role
        self.lineLimit = lineLimit
        self.monospacedDigit = monospacedDigit
        self.title = title
        self.subtitle = subtitle
        self.source = source
        self.size = size
        self.tint = tint
        self.tone = tone
        self.foreground = foreground
        self.fill = fill
        self.value = value
        self.label = label
        self.style = style
        self.countdown = countdown
        self.labelFrom = labelFrom
        self.tintRules = tintRules
        self.segments = segments
        self.values = values
        self.min = min
        self.max = max
        self.height = height
        self.icon = icon
        self.action = action
        self.padding = padding
        self.widthFill = widthFill
        self.alignment = alignment
        self.drag = drag
        self.accessibilityLabel = accessibilityLabel
        self.accessibility = accessibility
        self.minLength = minLength
        self.desktopRole = desktopRole
    }

    public var effectiveAccessibilityLabel: String? {
        accessibilityLabel ?? accessibility?.label
    }
}

extension UINode: Sendable {}
extension UINode.Countdown: Sendable {}
extension UINode.TintRule: Sendable {}
extension UINode.ProgressSegment: Sendable {}
extension ImageSource: Sendable {}
extension NodeAction: Sendable {}

extension UINode {
    /// Countdown window for `progress` nodes, in epoch milliseconds.
    public struct Countdown: Codable, Equatable {
        public var from: Double
        public var until: Double

        public init(from: Double, until: Double) {
            self.from = from
            self.until = until
        }
    }

    /// Conditional tint override for countdown progress nodes.
    public struct TintRule: Codable, Equatable {
        public var whenRemainingLtSeconds: Double?
        public var tint: String?

        public init(whenRemainingLtSeconds: Double? = nil, tint: String? = nil) {
            self.whenRemainingLtSeconds = whenRemainingLtSeconds
            self.tint = tint
        }
    }

    /// Remaining seconds for the countdown window (clamped at 0), or nil if
    /// this node has no countdown.
    public func countdownRemainingSeconds(nowMs: Double) -> Double? {
        guard let countdown else { return nil }
        return Swift.max((countdown.until - nowMs) / 1000, 0)
    }

    /// Remaining fraction (1 → just started, 0 → expired), clamped to 0...1.
    public func countdownFraction(nowMs: Double) -> Double? {
        guard let countdown, countdown.until > countdown.from else { return nil }
        return Swift.min(Swift.max((countdown.until - nowMs) / (countdown.until - countdown.from), 0), 1)
    }

    /// Effective tint after applying `tintRules` (first match wins), falling
    /// back to the node's static `tint`.
    public func countdownTint(nowMs: Double) -> String? {
        guard let remaining = countdownRemainingSeconds(nowMs: nowMs) else { return tint }
        for rule in tintRules ?? [] {
            if let threshold = rule.whenRemainingLtSeconds, remaining < threshold,
               let ruleTint = rule.tint {
                return ruleTint
            }
        }
        return tint
    }

    /// Node types the v0 renderer understands. Unknown types must still decode.
    public enum KnownType: String, CaseIterable {
        case vstack, hstack, zstack, scroll, list, grid, section, card, text, image, progress
        case button, badge, banner, empty, divider, spacer, none
        case sparkline
    }

    /// One part of a stacked `progress` meter.
    public struct ProgressSegment: Codable, Equatable {
        /// Share of the whole meter, 0...1.
        public var value: Double
        public var tint: String?
        public var label: String?

        public init(value: Double, tint: String? = nil, label: String? = nil) {
            self.value = value
            self.tint = tint
            self.label = label
        }

        private enum CodingKeys: String, CodingKey { case value, tint, label }

        /// A template can yield `"0.4"` or `null` for `value`; both decode
        /// (as 0.4 and 0) instead of failing the whole view tree.
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            value = (try? container.decodeIfPresent(LenientNumber.self, forKey: .value))?.value ?? 0
            tint = try? container.decodeIfPresent(String.self, forKey: .tint)
            label = try? container.decodeIfPresent(String.self, forKey: .label)
        }
    }

    /// `segments` ready to draw: negative and non-finite values read as 0,
    /// and the running total stops at 1 — a segment that would overflow the
    /// meter is cut to the room left, and any after it get none. Nil when
    /// the node has no segments (draw `value` instead).
    public var clampedSegments: [ProgressSegment]? {
        guard let segments else { return nil }
        var remaining = 1.0
        return segments.map { segment in
            var clamped = segment
            let value = segment.value.isFinite ? Swift.max(segment.value, 0) : 0
            clamped.value = Swift.min(value, remaining)
            remaining -= clamped.value
            return clamped
        }
    }

    /// The value range a `sparkline` maps to its bottom and top edges.
    ///
    /// An explicit `min`/`max` wins. Otherwise each open end takes the data's
    /// own extreme plus 10 % of the span as headroom, so the line never sits
    /// on the frame. A flat series (or one pinned by a single explicit end)
    /// gets a unit of room so it draws as a level line, not a division by
    /// zero. Nil when there are no finite values.
    public var sparklineDomain: ClosedRange<Double>? {
        let data = (values?.values ?? []).filter(\.isFinite)
        guard let low = data.min(), let high = data.max() else { return nil }
        let span = high - low
        let headroom = span > 0 ? span * 0.1 : Swift.max(Swift.abs(high) * 0.1, 1)
        var lower = min ?? (low - headroom)
        var upper = max ?? (high + headroom)
        if !lower.isFinite { lower = low - headroom }
        if !upper.isFinite { upper = high + headroom }
        if upper <= lower {
            if max == nil { upper = lower + headroom } else { lower = upper - headroom }
        }
        return lower...upper
    }

    public var isKnownType: Bool {
        KnownType(rawValue: type) != nil
    }

    /// Whether every whitespace-delimited query term appears somewhere in the
    /// node's visible text. Action payloads are deliberately excluded so local
    /// list search never indexes hidden secrets such as copy values.
    public func matchesSearch(_ query: String) -> Bool {
        let terms = query
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard !terms.isEmpty else { return true }
        let haystack = searchableText()
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return terms.allSatisfy { haystack.range(of: $0, options: options) != nil }
    }

    private func searchableText() -> String {
        let own = [text, title, subtitle, label, accessibilityLabel].compactMap { $0 }
        let descendants = ((children ?? []) + (items ?? []) + [child?.node].compactMap { $0 })
            .map { $0.searchableText() }
        return (own + descendants).joined(separator: " ")
    }
}

/// A list of numbers that decodes leniently: each element may be a number
/// or a numeric string, and anything else (null, objects, words) is
/// skipped. A non-array decodes as an empty list. Encodes as a plain array.
public struct NumberList: Codable, Equatable, Sendable, ExpressibleByArrayLiteral {
    public var values: [Double]

    public init(_ values: [Double]) { self.values = values }

    public init(arrayLiteral elements: Double...) { self.values = elements }

    public init(from decoder: Decoder) throws {
        guard var container = try? decoder.unkeyedContainer() else {
            values = []
            return
        }
        var values: [Double] = []
        while !container.isAtEnd {
            if (try? container.decodeNil()) == true { continue }
            if let number = try? container.decode(LenientNumber.self).value {
                if number.isFinite { values.append(number) }
            } else if (try? container.decode(SkippedValue.self)) == nil {
                // Could not step past the element; stop rather than spin.
                break
            }
        }
        self.values = values
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(values)
    }

    private struct SkippedValue: Decodable {
        init(from decoder: Decoder) throws {}
    }
}

/// A number written as a JSON number or a numeric string.
struct LenientNumber: Decodable {
    var value: Double

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Double.self) {
            value = number
        } else if let text = try? container.decode(String.self),
                  let number = Double(text.trimmingCharacters(in: .whitespaces)) {
            value = number
        } else {
            throw DecodingError.typeMismatch(
                Double.self,
                .init(codingPath: decoder.codingPath, debugDescription: "not a number")
            )
        }
    }
}

/// Reference wrapper permits the schema's single recursive `scroll.child`
/// shape while keeping `UINode` a value type. It encodes transparently as the
/// child node object (there is no wrapper key in JSON).
public final class UINodeBox: Codable, Equatable, @unchecked Sendable {
    public var node: UINode

    public init(_ node: UINode) { self.node = node }

    public required init(from decoder: Decoder) throws {
        node = try UINode(from: decoder)
    }

    public func encode(to encoder: Encoder) throws {
        try node.encode(to: encoder)
    }

    public static func == (lhs: UINodeBox, rhs: UINodeBox) -> Bool {
        lhs.node == rhs.node
    }
}

/// Image source descriptor.
/// `sfSymbol` uses `name`; `fileIcon`/`fileThumbnail` (M2-b) use `path`, and
/// `fileThumbnail` keys its cache on `modifiedAt` (epoch ms) staleness.
/// `url` fetches a remote image over https — the host only loads it when the
/// widget's `permissions.network` allowlist covers the URL's host — and
/// `monogram` (also a standalone kind) is the letter fallback shown while the
/// image loads, fails, or is blocked.
public struct ImageSource: Codable, Equatable {
    public var kind: String
    public var name: String?
    public var path: String?
    public var modifiedAt: Double?
    public var url: String?
    public var monogram: String?

    public init(
        kind: String,
        name: String? = nil,
        path: String? = nil,
        modifiedAt: Double? = nil,
        url: String? = nil,
        monogram: String? = nil
    ) {
        self.kind = kind
        self.name = name
        self.path = path
        self.modifiedAt = modifiedAt
        self.url = url
        self.monogram = monogram
    }
}

/// Declarative action attached to a node. Buttons carry one; any other node
/// with an `action` becomes tappable as a whole (a file row, a grid tile, or an
/// entire widget card — so a widget can behave like a native one: click → open).
/// `type`: "copyText" | "openURL" | "openFile" | "revealFile" | "openApp"
///         | "quitApp" | "refresh" | "run" | "event"
/// `openApp` opens an application by bundle id ("com.apple.iCal"), display name
/// ("Activity Monitor"), or a full `.app` path, carried in `value`.
/// `quitApp` asks the user, then politely quits the running app named by a
/// bundle id or pid in `value` (needs `permissions.quitApps`).
///
/// `value` also accepts a JSON number (a pid from a `system` source row, say)
/// and holds it as its decimal string.
public struct NodeAction: Codable, Equatable {
    public var type: String
    public var value: String?
    public var url: String?
    public var path: String?
    public var id: String?
    public var toast: String?
    /// `run`: argv to execute — must match a `permissions.exec` allowlist entry.
    public var command: [String]?
    /// `run`: refresh the widget after the command succeeds.
    public var thenRefresh: Bool?
    /// `copyText`: clear the clipboard after N seconds (only if the pasteboard
    /// was not changed by someone else in the meantime). For sensitive values.
    public var clearAfterSec: Int?
    /// `vaultCopy`: which field of the item `value` (an opaque handle)
    /// names — "username", "password" or "totp".
    public var field: String?

    public init(
        type: String,
        value: String? = nil,
        url: String? = nil,
        path: String? = nil,
        id: String? = nil,
        toast: String? = nil,
        command: [String]? = nil,
        thenRefresh: Bool? = nil,
        clearAfterSec: Int? = nil,
        field: String? = nil
    ) {
        self.type = type
        self.value = value
        self.url = url
        self.path = path
        self.id = id
        self.toast = toast
        self.command = command
        self.thenRefresh = thenRefresh
        self.clearAfterSec = clearAfterSec
        self.field = field
    }

    private enum CodingKeys: String, CodingKey {
        case type, value, url, path, id, toast, command, thenRefresh, clearAfterSec, field
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        if let text = try? container.decodeIfPresent(String.self, forKey: .value) {
            value = text
        } else if let number = try? container.decodeIfPresent(Double.self, forKey: .value) {
            value = number.rounded() == number && Swift.abs(number) < 1e15
                ? String(Int64(number)) : String(number)
        } else {
            value = nil
        }
        url = try container.decodeIfPresent(String.self, forKey: .url)
        path = try container.decodeIfPresent(String.self, forKey: .path)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        toast = try container.decodeIfPresent(String.self, forKey: .toast)
        command = try container.decodeIfPresent([String].self, forKey: .command)
        thenRefresh = try container.decodeIfPresent(Bool.self, forKey: .thenRefresh)
        clearAfterSec = try container.decodeIfPresent(Int.self, forKey: .clearAfterSec)
        field = try container.decodeIfPresent(String.self, forKey: .field)
    }
}
