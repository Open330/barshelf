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
    /// label (or trailing label for linear style).
    public var labelFrom: String?
    /// First matching rule overrides `tint` (e.g. danger under 10s).
    public var tintRules: [TintRule]?

    /// SF Symbol name (button / empty / banner leading icon).
    public var icon: String?

    public var action: NodeAction?

    // Layout modifiers
    public var padding: Double?
    public var widthFill: Bool?

    /// Present → the rendered view can be dragged out as a file
    /// (Finder / other apps), M2-b.
    public var drag: DragSpec?

    /// Optional explicit VoiceOver label for this node. When set, the renderer
    /// exposes it as the accessibility label of the rendered view (e.g. a
    /// meaningful symbol, button, or row). When nil the renderer keeps its
    /// default behavior (decorative images stay hidden, file thumbnails use
    /// the file name, etc.).
    public var accessibilityLabel: String?

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
        icon: String? = nil,
        action: NodeAction? = nil,
        padding: Double? = nil,
        widthFill: Bool? = nil,
        drag: DragSpec? = nil,
        accessibilityLabel: String? = nil
    ) {
        self.id = id
        self.type = type
        self.children = children
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
        self.icon = icon
        self.action = action
        self.padding = padding
        self.widthFill = widthFill
        self.drag = drag
        self.accessibilityLabel = accessibilityLabel
    }
}

extension UINode: Sendable {}
extension UINode.Countdown: Sendable {}
extension UINode.TintRule: Sendable {}
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
        return max((countdown.until - nowMs) / 1000, 0)
    }

    /// Remaining fraction (1 → just started, 0 → expired), clamped to 0...1.
    public func countdownFraction(nowMs: Double) -> Double? {
        guard let countdown, countdown.until > countdown.from else { return nil }
        return min(max((countdown.until - nowMs) / (countdown.until - countdown.from), 0), 1)
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
        case vstack, hstack, list, grid, section, card, text, image, progress
        case button, badge, banner, empty, divider, spacer
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
        let descendants = ((children ?? []) + (items ?? [])).map { $0.searchableText() }
        return (own + descendants).joined(separator: " ")
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
///         | "refresh" | "run" | "event"
/// `openApp` opens an application by bundle id ("com.apple.iCal"), display name
/// ("Activity Monitor"), or a full `.app` path, carried in `value`.
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

    public init(
        type: String,
        value: String? = nil,
        url: String? = nil,
        path: String? = nil,
        id: String? = nil,
        toast: String? = nil,
        command: [String]? = nil,
        thenRefresh: Bool? = nil,
        clearAfterSec: Int? = nil
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
    }
}
