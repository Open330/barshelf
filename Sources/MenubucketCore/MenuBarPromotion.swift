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

// MARK: - Style

/// How one widget's cell is laid out in the menu bar.
public enum MenuBarStyle: String, Codable, Equatable, Sendable, CaseIterable {
    /// Label and value on one line: `CPU 23%`.
    case inline
    /// Label above the value, the way a system monitor fits two rows into the
    /// menu bar's 22 points. Needs the widget's own status item — the shared
    /// strip is a single run of text — so choosing it implies one.
    case stacked
    /// Up to two compact metric rows for related live readings.
    case metrics

    public static let `default` = MenuBarStyle.inline

    public var title: String {
        switch self {
        case .inline: return "Label beside the value"
        case .stacked: return "Label above the value"
        case .metrics: return "Two metric rows"
        }
    }
}

/// One independently labelled live reading in a promoted widget.
public struct StatusMetric: Codable, Equatable, Sendable {
    /// Stable key used by per-metric presentation preferences.
    public var id: String?
    public var label: String
    public var value: String
    /// Machine-readable value. When supplied, the menu-bar formatter owns the
    /// visible value; `value` remains the backwards-compatible wire field.
    public var number: Double?
    /// `decimal`, `percent`, `bytes`, or `bytesPerSecond`.
    public var format: String?
    public var unit: String?
    public var precision: Int?
    /// Semantic colour name from the RenderStatus tint vocabulary.
    public var tint: String?
    /// An activity indicator: filled when true, outlined when false, absent when nil.
    public var active: Bool?
    /// Spoken description for a terse or activity-only metric.
    public var accessibilityLabel: String?

    public init(
        id: String? = nil,
        label: String = "",
        value: String = "",
        number: Double? = nil,
        format: String? = nil,
        unit: String? = nil,
        precision: Int? = nil,
        tint: String? = nil,
        active: Bool? = nil,
        accessibilityLabel: String? = nil
    ) {
        self.id = id
        self.label = label
        self.value = value
        self.number = number?.isFinite == true ? number : nil
        self.format = Self.knownFormat(format)
        self.unit = unit
        self.precision = Self.validPrecision(precision)
        self.tint = tint
        self.active = active
        self.accessibilityLabel = accessibilityLabel
    }

    private enum CodingKeys: String, CodingKey {
        case id, label, value, number, format, unit, precision, tint, active, accessibilityLabel
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        label = try container.decodeIfPresent(String.self, forKey: .label) ?? ""
        value = try container.decodeIfPresent(String.self, forKey: .value) ?? ""
        let decodedNumber = try container.decodeIfPresent(Double.self, forKey: .number)
        number = decodedNumber?.isFinite == true ? decodedNumber : nil
        format = Self.knownFormat(try container.decodeIfPresent(String.self, forKey: .format))
        unit = try container.decodeIfPresent(String.self, forKey: .unit)
        precision = Self.validPrecision(try container.decodeIfPresent(Int.self, forKey: .precision))
        tint = try container.decodeIfPresent(String.self, forKey: .tint)
        active = try container.decodeIfPresent(Bool.self, forKey: .active)
        accessibilityLabel = try container.decodeIfPresent(String.self, forKey: .accessibilityLabel)
    }

    static func knownFormat(_ raw: String?) -> String? {
        guard let raw, ["decimal", "percent", "bytes", "bytesPerSecond"].contains(raw) else {
            return nil
        }
        return raw
    }

    static func validPrecision(_ value: Int?) -> Int? {
        guard let value, (0...3).contains(value) else { return nil }
        return value
    }
}

/// User and author supplied presentation choices for a promoted status item.
/// Every property is optional so values can layer user → live → manifest.
/// How a menu bar item decides its width.
///
/// A reading that goes from `9°` to `10°` used to widen its item and shove
/// every item to its left, because each redraw measured the text it had. A
/// menu bar is a row of fixed positions people glance at, so the default now
/// reserves room for the digits a reading normally has.
public enum MenuBarWidthMode: String, Codable, Equatable, Sendable, CaseIterable {
    /// Reserve room for `digits` integer digits (figure spaces pad a shorter
    /// number); an item that ever needs more keeps the wider size for the rest
    /// of the session rather than shrinking back.
    case auto
    /// The text column is `valueWidth` points. Content wider than that still
    /// grows the item — a clipped number is worse than a moved one.
    case fixed
    /// Exactly as wide as the current text: the old behaviour.
    case fit
}

/// How an item's rows sit inside the width it has — the label above the
/// value in a stacked item, the block of rows in a metrics one.
public enum MenuBarAlignment: String, Codable, Equatable, Sendable, CaseIterable {
    case leading, center, trailing
}

/// Which side of a reserved number the padding goes on — where the digits
/// sit when there are fewer of them than the room kept for them.
public enum MenuBarNumberAlignment: String, Codable, Equatable, Sendable, CaseIterable {
    /// Padding before the number: the ones digit and the unit never move
    /// (`␣4 W` / `15 W`). The default.
    case right
    /// Padding after the whole reading: the number starts at the same place
    /// as the label and the unit moves (`4 W␣` / `15 W`).
    case left
}

public enum MenuBarWeight: String, Codable, Equatable, Sendable, CaseIterable {
    case regular, medium, semibold, bold
}

public enum MenuBarTextSize: String, Codable, Equatable, Sendable, CaseIterable {
    case small, regular, large
}

/// A small graph an item draws beside its reading, from the history the host
/// keeps of it.
public enum MenuBarChart: String, Codable, Equatable, Sendable, CaseIterable {
    case none
    /// A sparkline of recent readings.
    case line
    /// Recent readings as bars.
    case bars
    /// The current reading as a ring, against its scale.
    case gauge
}

/// Recent values of one reading, for an item's chart.
public struct MenuBarChartHistory: Equatable, Sendable {
    /// The metric key the values came from.
    public var series: String
    /// 100 for a percentage, nil for a reading scaled to its own peak.
    public var scale: Double?
    /// Oldest first, at most `MenuBarPolicy.chartHistoryLimit`.
    public var values: [Double]
    /// When the last point was added.
    public var lastAt: TimeInterval?
    /// The highest reading since then, waiting to become the next point.
    public var pending: Double?

    public init(series: String, scale: Double?, values: [Double], lastAt: TimeInterval? = nil) {
        self.series = series
        self.scale = scale
        self.values = values
        self.lastAt = lastAt
    }
}

/// Which way a reading gets worse: a temperature going up, a battery or free
/// space going down.
public enum MenuBarThresholdDirection: String, Codable, Equatable, Sendable, CaseIterable {
    case above, below
}

public struct MenuBarPresentation: Codable, Equatable, Sendable {
    public var showValues: Bool?
    public var showUnits: Bool?
    public var precision: Int?
    /// `automatic`, `monochrome`, or a `MenuBarTint` semantic name.
    public var color: String?
    /// Text column width in points, used by `width: fixed`.
    public var valueWidth: Double?
    /// The fixed column when none was chosen — the stepper shows it and every
    /// renderer draws it, so "Fixed" means the same thing everywhere.
    public static let defaultFixedWidth: Double = 48
    public var effectiveFixedWidth: Double { valueWidth ?? Self.defaultFixedWidth }
    public var metricOrder: [String]?
    public var metricOverrides: [String: MenuBarMetricOverride]?
    public var width: MenuBarWidthMode?
    /// Integer digits `width: auto` reserves room for (1–6).
    public var digits: Int?
    public var alignment: MenuBarAlignment?
    /// Weight of the value text.
    public var weight: MenuBarWeight?
    /// Size of the value text relative to the style's own.
    public var size: MenuBarTextSize?
    /// Where a short number sits in the digits reserved for it.
    public var numberAlignment: MenuBarNumberAlignment?
    /// A reading at or past this is tinted warning, and at or past
    /// `dangerAt` danger — in the unit the item shows (see
    /// `MenuBarPolicy.thresholdValue`). Either set replaces the widget's own
    /// warning colours for the item.
    public var warningAt: Double?
    public var dangerAt: Double?
    /// `above` unless a lower reading is the bad one.
    public var thresholdDirection: MenuBarThresholdDirection?
    /// The item only appears while a reading is at or past this. It keeps
    /// refreshing while hidden, so it comes back on its own.
    public var showWhen: Double?
    /// A graph beside the reading. Drawn only by an item with its own place
    /// in the menu bar; the shared strip is text.
    public var chart: MenuBarChart?
    public var effectiveChart: MenuBarChart { chart ?? .none }

    public init(showValues: Bool? = nil, showUnits: Bool? = nil, precision: Int? = nil,
                color: String? = nil, valueWidth: Double? = nil,
                metricOrder: [String]? = nil,
                metricOverrides: [String: MenuBarMetricOverride]? = nil,
                width: MenuBarWidthMode? = nil, digits: Int? = nil,
                alignment: MenuBarAlignment? = nil, weight: MenuBarWeight? = nil,
                size: MenuBarTextSize? = nil, numberAlignment: MenuBarNumberAlignment? = nil,
                warningAt: Double? = nil, dangerAt: Double? = nil,
                thresholdDirection: MenuBarThresholdDirection? = nil, showWhen: Double? = nil,
                chart: MenuBarChart? = nil) {
        self.chart = chart
        self.showValues = showValues
        self.showUnits = showUnits
        self.precision = StatusMetric.validPrecision(precision)
        self.color = Self.validColor(color)
        self.valueWidth = Self.validWidth(valueWidth)
        self.width = width
        self.digits = digits.flatMap { (1...6).contains($0) ? $0 : nil }
        self.alignment = alignment
        self.weight = weight
        self.size = size
        self.numberAlignment = numberAlignment
        self.warningAt = warningAt.flatMap { $0.isFinite ? $0 : nil }
        self.dangerAt = dangerAt.flatMap { $0.isFinite ? $0 : nil }
        self.thresholdDirection = thresholdDirection
        self.showWhen = showWhen.flatMap { $0.isFinite ? $0 : nil }
        self.metricOrder = metricOrder.map { order in
            var seen = Set<String>()
            return order.filter { !($0.isEmpty || !seen.insert($0).inserted) }
        }
        self.metricOverrides = metricOverrides
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(showValues: try c.decodeIfPresent(Bool.self, forKey: .showValues),
                  showUnits: try c.decodeIfPresent(Bool.self, forKey: .showUnits),
                  precision: try c.decodeIfPresent(Int.self, forKey: .precision),
                  color: try c.decodeIfPresent(String.self, forKey: .color),
                  valueWidth: try c.decodeIfPresent(Double.self, forKey: .valueWidth),
                  metricOrder: try c.decodeIfPresent([String].self, forKey: .metricOrder),
                  metricOverrides: try c.decodeIfPresent([String: MenuBarMetricOverride].self, forKey: .metricOverrides),
                  // Lenient like the rest of this type: a name from a newer
                  // vocabulary reads as "not set", never as a decode failure
                  // that would throw away the user's other choices.
                  width: Self.lenient(c, .width),
                  digits: (try? c.decodeIfPresent(Int.self, forKey: .digits)) ?? nil,
                  alignment: Self.lenient(c, .alignment),
                  weight: Self.lenient(c, .weight),
                  size: Self.lenient(c, .size),
                  numberAlignment: Self.lenient(c, .numberAlignment),
                  warningAt: (try? c.decodeIfPresent(Double.self, forKey: .warningAt)) ?? nil,
                  dangerAt: (try? c.decodeIfPresent(Double.self, forKey: .dangerAt)) ?? nil,
                  thresholdDirection: Self.lenient(c, .thresholdDirection),
                  showWhen: (try? c.decodeIfPresent(Double.self, forKey: .showWhen)) ?? nil,
                  chart: Self.lenient(c, .chart))
    }

    private enum CodingKeys: String, CodingKey {
        case showValues, showUnits, precision, color, valueWidth, metricOrder,
             metricOverrides, width, digits, alignment, weight, size, numberAlignment,
             warningAt, dangerAt, thresholdDirection, showWhen, chart
    }

    private static func lenient<T: RawRepresentable>(
        _ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys
    ) -> T? where T.RawValue == String {
        guard let raw = (try? c.decodeIfPresent(String.self, forKey: key)) ?? nil else { return nil }
        return T(rawValue: raw)
    }

    /// Effective values, with the defaults a user who never opened the
    /// settings gets.
    public var effectiveWidth: MenuBarWidthMode { width ?? .auto }
    public var effectiveDigits: Int { digits ?? MenuBarPolicy.defaultReservedDigits }
    /// Block alignment of the label and value rows. Leading is how items have
    /// always looked.
    public var effectiveAlignment: MenuBarAlignment { alignment ?? .leading }
    public var effectiveNumberAlignment: MenuBarNumberAlignment { numberAlignment ?? .right }
    public var hasThresholds: Bool { warningAt != nil || dangerAt != nil }

    /// Ready-made looks, applied over whatever is already chosen.
    public static let presets: [(name: String, presentation: MenuBarPresentation)] = [
        ("Compact", MenuBarPresentation(width: .fit, size: .small)),
        ("Steady", MenuBarPresentation(width: .auto, digits: 3, numberAlignment: .right)),
        ("Bold", MenuBarPresentation(weight: .bold, size: .large)),
        ("Minimal", MenuBarPresentation(showUnits: false, color: "monochrome", weight: .regular)),
        ("Graph", MenuBarPresentation(width: .auto, digits: 3, chart: .line)),
    ]

    /// The fields a preset may set. One list, so a new style field is one
    /// line here rather than a silent gap in `applying(preset:)`.
    private static let presetFields: [@Sendable (inout MenuBarPresentation, MenuBarPresentation) -> Void] = [
        { if let v = $1.showUnits { $0.showUnits = v } },
        { if let v = $1.color { $0.color = v } },
        { if let v = $1.valueWidth { $0.valueWidth = v } },
        { if let v = $1.width { $0.width = v } },
        { if let v = $1.digits { $0.digits = v } },
        { if let v = $1.alignment { $0.alignment = v } },
        { if let v = $1.weight { $0.weight = v } },
        { if let v = $1.size { $0.size = v } },
        { if let v = $1.numberAlignment { $0.numberAlignment = v } },
        { if let v = $1.chart { $0.chart = v } },
    ]

    /// This presentation with every field `preset` sets taken from it.
    public func applying(preset: MenuBarPresentation) -> MenuBarPresentation {
        var result = self
        for apply in Self.presetFields { apply(&result, preset) }
        return result
    }

    /// The presets that mean the same app-wide: those made only of fields the
    /// app-wide style carries. "Graph" and "Minimal" set a chart and units,
    /// which are each widget's own, and would half-apply.
    public static var appWidePresets: [(name: String, presentation: MenuBarPresentation)] {
        presets.filter { MenuBarPolicy.globalStyle($0.presentation) == $0.presentation }
    }

    static func validColor(_ color: String?) -> String? {
        guard let color, color == "automatic" || color == "monochrome" || MenuBarTint.named(color) != nil else { return nil }
        return color
    }
    static func validWidth(_ width: Double?) -> Double? {
        guard let width, width.isFinite, (32...120).contains(width) else { return nil }
        return width
    }
}

public struct MenuBarMetricOverride: Codable, Equatable, Sendable {
    public var label: String?
    public var hidden: Bool?
    public var tint: String?
    public init(label: String? = nil, hidden: Bool? = nil, tint: String? = nil) {
        self.label = label
        self.hidden = hidden
        self.tint = tint == "monochrome" ? tint : MenuBarTint.named(tint)?.rawValue
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(label: try c.decodeIfPresent(String.self, forKey: .label),
                  hidden: try c.decodeIfPresent(Bool.self, forKey: .hidden),
                  tint: try c.decodeIfPresent(String.self, forKey: .tint))
    }
}

// MARK: - Tint

/// The colours a widget may ask the menu bar for.
///
/// A closed vocabulary rather than an arbitrary colour, and the same one the
/// view layer already uses — so a widget that paints a bar `danger` says
/// `danger` in the menu bar too, and both follow the system's idea of red.
/// Nil is the normal case and means the menu bar's own colour, which also
/// keeps the item a template image: it then follows a light or dark bar and
/// inverts while held open, neither of which a fixed colour can do.
public enum MenuBarTint: String, Codable, Equatable, Sendable, CaseIterable {
    case accent
    case good
    case warning
    case danger
    case secondary

    /// Unknown names read as no tint rather than as an error: a widget written
    /// against a later vocabulary should lose its colour, not its value.
    public static func named(_ raw: String?) -> MenuBarTint? {
        guard let raw, !raw.isEmpty else { return nil }
        return MenuBarTint(rawValue: raw)
    }
}

// MARK: - Placement

/// What clicking an item with its own place in the menu bar does. A right
/// click (or control-click) always opens the item's menu.
public enum MenuBarClickAction: String, Codable, Equatable, Sendable, CaseIterable {
    /// Show the widget's card under the item — what a click always did.
    case card
    /// Refresh the reading now.
    case refresh
    /// Open `clickTarget`: an app (bundle id or path) or a URL.
    case open
    /// Open the BarShelf hub.
    case hub
}

/// Where one widget sits in the menu bar. Persisted per widget.
public struct MenuBarPlacement: Codable, Equatable, Sendable {
    /// Whether the widget appears in the menu bar at all.
    public var enabled: Bool
    /// True to give the widget its own status item instead of the shared strip.
    public var separate: Bool
    /// Sort key within the strip (lower is further left). Nil sorts after the
    /// explicitly ordered entries, by widget name.
    public var order: Double?
    /// What to draw instead of the widget's own icon.
    ///
    /// Nil keeps the widget's. An empty string means no icon at all. Anything
    /// else is used verbatim: an SF Symbol name when one exists by that name,
    /// and otherwise literal text — which is how an emoji gets in. Resolving
    /// which of the two it is needs AppKit, so it happens in the status item
    /// layer, not here.
    public var icon: String?
    /// Short text shown before the value, the way a system monitor labels its
    /// readouts ("CPU 23%"). Nil falls back to whatever the widget supplies;
    /// empty means the user asked for no label at all.
    public var label: String?
    /// Overrides the widget's own layout. Nil keeps it.
    public var style: MenuBarStyle?
    /// User choices layered over live and manifest presentation defaults.
    public var presentation: MenuBarPresentation?
    /// How often this item refreshes, in seconds, overriding the widget's own
    /// `refresh.interval` while it is in the menu bar. A temperature does not
    /// need the two seconds a CPU reading does, and an always-on menu bar item
    /// is where that difference is paid all day.
    public var interval: Double?
    /// What a click does; nil shows the card.
    public var clickAction: MenuBarClickAction?
    /// The app or link `clickAction: open` opens.
    public var clickTarget: String?
    public var effectiveClickAction: MenuBarClickAction { clickAction ?? .card }

    /// The choices offered in settings. Arbitrary values still decode (and
    /// are clamped), so a hand-edited prefs file is not rejected.
    public static let intervalChoices: [Double] = [1, 2, 3, 5, 10, 30, 60]

    public init(
        enabled: Bool,
        separate: Bool = false,
        order: Double? = nil,
        icon: String? = nil,
        label: String? = nil,
        style: MenuBarStyle? = nil,
        presentation: MenuBarPresentation? = nil,
        interval: Double? = nil,
        clickAction: MenuBarClickAction? = nil,
        clickTarget: String? = nil
    ) {
        self.clickAction = clickAction
        self.clickTarget = Self.validTarget(clickTarget)
        self.enabled = enabled
        self.separate = separate
        self.order = order
        self.icon = icon
        self.label = label
        self.style = style
        self.presentation = presentation
        self.interval = Self.validInterval(interval)
    }

    static func validTarget(_ target: String?) -> String? {
        let trimmed = target?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    static func validInterval(_ interval: Double?) -> Double? {
        guard let interval, interval.isFinite, interval > 0 else { return nil }
        return min(max(interval, 1), 3600)
    }

    /// Lenient decode so a prefs file written by an older build still loads.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        separate = try container.decodeIfPresent(Bool.self, forKey: .separate) ?? false
        order = try container.decodeIfPresent(Double.self, forKey: .order)
        icon = try container.decodeIfPresent(String.self, forKey: .icon)
        label = try container.decodeIfPresent(String.self, forKey: .label)
        // An unknown style from a newer build reads as "no override" rather
        // than failing the whole prefs file.
        style = try? container.decodeIfPresent(MenuBarStyle.self, forKey: .style)
        presentation = try? container.decodeIfPresent(MenuBarPresentation.self, forKey: .presentation)
        interval = Self.validInterval(
            (try? container.decodeIfPresent(Double.self, forKey: .interval)) ?? nil
        )
        clickAction = ((try? container.decodeIfPresent(String.self, forKey: .clickAction)) ?? nil)
            .flatMap(MenuBarClickAction.init(rawValue:))
        clickTarget = Self.validTarget((try? container.decodeIfPresent(String.self, forKey: .clickTarget)) ?? nil)
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, separate, order, icon, label, style, presentation, interval, clickAction, clickTarget
    }

    /// What "Copy From" takes from another item: the layout and look it
    /// actually shows — `layout` and `look` resolved from its own choices and
    /// its widget's defaults, so an item following its manifest copies as it
    /// looks. What names that widget's own readings stays this item's: row
    /// order and overrides, precision, and the alert thresholds, which are in
    /// the other reading's unit (80 % means nothing to a temperature).
    public func copyingStyle(layout: MenuBarStyle, look: MenuBarPresentation) -> MenuBarPlacement {
        var copy = self
        copy.style = layout
        var presentation = look
        let mine = self.presentation
        presentation.metricOrder = mine?.metricOrder
        presentation.metricOverrides = mine?.metricOverrides
        presentation.precision = mine?.precision
        presentation.showValues = mine?.showValues
        presentation.warningAt = mine?.warningAt
        presentation.dangerAt = mine?.dangerAt
        presentation.thresholdDirection = mine?.thresholdDirection
        presentation.showWhen = mine?.showWhen
        copy.presentation = presentation == MenuBarPresentation() ? nil : presentation
        return copy
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
    /// The user's replacement for `symbol`, verbatim. Empty means they asked
    /// for no icon. See `MenuBarPlacement.icon`.
    public var iconOverride: String?
    /// Short text drawn before `label`, resolved from the user's override,
    /// the widget's own per-refresh prefix, or its manifest default.
    public var prefix: String?
    /// How the cell is laid out.
    public var style: MenuBarStyle = .default
    /// Colour the widget asked for, or nil for the menu bar's own.
    public var tint: MenuBarTint?
    /// Live text, or nil when the mode shows the icon only / nothing has been
    /// sampled yet.
    public var label: String?
    /// Structured readings for the metrics layout. An empty array preserves
    /// the legacy inline and stacked forms.
    public var metrics: [StatusMetric]
    public var tooltip: String?
    /// True when the last successful sample is older than the widget's own
    /// refresh cadence allows — the value on screen is no longer current, so
    /// the strip dims it rather than passing off a frozen number as live.
    public var isStale: Bool
    public var separate: Bool
    /// Fully resolved display configuration used by the renderer.
    public var presentation: MenuBarPresentation
    /// Recent values of the item's first numeric reading, oldest first, for
    /// its chart. Empty unless the item draws one — history on an item that
    /// does not would make every refresh look like a change.
    public var history: [Double] = []
    /// What a chart scales against: 0–100 for a percentage, else nil (the
    /// history's own peak).
    public var chartScale: Double?

    public init(
        widgetID: String,
        name: String,
        symbol: String? = nil,
        iconOverride: String? = nil,
        prefix: String? = nil,
        style: MenuBarStyle = .default,
        tint: MenuBarTint? = nil,
        label: String? = nil,
        metrics: [StatusMetric] = [],
        tooltip: String? = nil,
        isStale: Bool = false,
        separate: Bool = false,
        presentation: MenuBarPresentation = .init()
    ) {
        self.widgetID = widgetID
        self.name = name
        self.symbol = symbol
        self.iconOverride = iconOverride
        self.prefix = prefix
        self.style = style
        self.tint = tint
        self.label = label
        self.metrics = MenuBarPolicy.normalizedMetrics(metrics)
        self.tooltip = tooltip
        self.isStale = isStale
        self.separate = separate
        self.presentation = presentation
    }

    /// Nothing to draw — no icon of any kind and no text.
    public var isEmpty: Bool {
        let hasIcon = (iconOverride?.isEmpty == false) || (iconOverride == nil && symbol != nil)
        return !hasIcon && metrics.isEmpty && MenuBarPolicy.entryText(self).isEmpty
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

    /// Maximum visible readings per promoted cell.
    public static let maxMetrics = 2

    /// Separator drawn between entries sharing the strip.
    public static let stripSeparator = " · "

    /// Longest label a user may put before a value. Eight characters fits
    /// "Battery" with room to spare, and stops one widget from crowding out
    /// its neighbours on a shared strip.
    public static let maxPrefixCharacters = 8

    /// Longest icon override. An SF Symbol name is longer than this, so it is
    /// exempt — the cap exists to keep someone from pasting a sentence where a
    /// glyph goes.
    public static let maxIconCharacters = 4

    /// A user-supplied prefix, trimmed and capped. Nil when there is none to
    /// draw, so callers do not have to distinguish nil from "".
    public static func normalizedPrefix(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return String(trimmed.prefix(maxPrefixCharacters))
    }

    /// A user-supplied icon, trimmed. An empty string survives as an empty
    /// string: it means "no icon", which is different from "use the widget's".
    ///
    /// Anything without a space is passed through whole, because SF Symbol
    /// names are long and hyphenated; only free text is capped.
    public static func normalizedIcon(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return nil
        }
        if trimmed.isEmpty { return "" }
        if trimmed.contains(" ") {
            return String(trimmed.prefix(maxIconCharacters))
        }
        return trimmed
    }

    /// The label to draw, most specific source first: what the user typed,
    /// then what this refresh produced, then what the author declared.
    ///
    /// An empty user override is not "nothing set" — it is the user saying no
    /// label — so it stops the search rather than falling through.
    public static func resolvedPrefix(
        user: String?, live: String?, manifest: String?
    ) -> String? {
        if let user {
            // "" is kept, not turned into nil: it is the user saying "no
            // label", and renderers have to tell that apart from "none set",
            // which falls back to the widget's name or its metric's label.
            return user.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "" : normalizedPrefix(user)
        }
        return normalizedPrefix(live) ?? normalizedPrefix(manifest)
    }

    /// Which symbol to draw, most specific source first: the user's override,
    /// then what this refresh asked for, then the widget's declared icon, then
    /// its app icon.
    ///
    /// The user's empty string means "no icon" and stops the search, the same
    /// way an empty label does — a choice, not an absence.
    public static func resolvedIcon(
        user: String?, live: String?, statusItem: String?, manifest: String?
    ) -> String? {
        if let user = normalizedIcon(user) { return user.isEmpty ? nil : user }
        for candidate in [live, statusItem, manifest] {
            if let candidate, !candidate.isEmpty { return candidate }
        }
        return nil
    }

    public static func resolvedStyle(user: MenuBarStyle?, manifest: String?) -> MenuBarStyle {
        user ?? manifest.flatMap(MenuBarStyle.init(rawValue:)) ?? .default
    }

    /// Resolves sparse presentation layers independently. A user changing one
    /// switch never discards a live or manifest default for another.
    ///
    /// `global` is the app-wide menu bar style from App Settings. It ranks
    /// below the item's own choices and above the widget's: a user who asks
    /// for fit-width everywhere means the widgets too. Only its style fields
    /// take part (see `globalStyle`).
    public static func resolvedPresentation(
        user: MenuBarPresentation?, global: MenuBarPresentation? = nil,
        live: MenuBarPresentation?, manifest: MenuBarPresentation?
    ) -> MenuBarPresentation {
        let global = globalStyle(global)
        func pick<T>(_ key: KeyPath<MenuBarPresentation, T?>) -> T? {
            user?[keyPath: key] ?? global?[keyPath: key] ?? live?[keyPath: key] ?? manifest?[keyPath: key]
        }
        let ids = Set((user?.metricOverrides ?? [:]).keys)
            .union((live?.metricOverrides ?? [:]).keys)
            .union((manifest?.metricOverrides ?? [:]).keys)
        let overrides = ids.reduce(into: [String: MenuBarMetricOverride]()) { result, id in
            let u = user?.metricOverrides?[id]
            let l = live?.metricOverrides?[id]
            let m = manifest?.metricOverrides?[id]
            result[id] = MenuBarMetricOverride(
                label: u?.label ?? l?.label ?? m?.label,
                hidden: u?.hidden ?? l?.hidden ?? m?.hidden,
                tint: u?.tint ?? l?.tint ?? m?.tint
            )
        }
        return MenuBarPresentation(showValues: pick(\.showValues), showUnits: pick(\.showUnits),
                                   precision: pick(\.precision), color: pick(\.color),
                                   valueWidth: pick(\.valueWidth), metricOrder: pick(\.metricOrder),
                                   metricOverrides: overrides.isEmpty ? nil : overrides,
                                   width: pick(\.width), digits: pick(\.digits),
                                   alignment: pick(\.alignment), weight: pick(\.weight),
                                   size: pick(\.size), numberAlignment: pick(\.numberAlignment),
                                   // Alerts are the user's alone: a widget
                                   // that shipped its own could never be
                                   // cleared from a field showing blank.
                                   warningAt: user?.warningAt, dangerAt: user?.dangerAt,
                                   thresholdDirection: user?.thresholdDirection, showWhen: user?.showWhen,
                                   chart: pick(\.chart))
    }

    /// The fields an app-wide style may set: how an item is laid out and
    /// drawn, not what it shows. Precision, units, value visibility, row
    /// order and per-row overrides stay with each widget — a precision of 1
    /// suits a gigabyte reading and not a temperature. One list, so what
    /// `globalStyle` keeps and what `clearingGlobalStyle` drops cannot drift.
    private static let globalStyleFields: [@Sendable (inout MenuBarPresentation, MenuBarPresentation) -> Void] = [
        { $0.color = $1.color },
        { $0.valueWidth = $1.valueWidth },
        { $0.width = $1.width },
        { $0.digits = $1.digits },
        { $0.alignment = $1.alignment },
        { $0.weight = $1.weight },
        { $0.size = $1.size },
        { $0.numberAlignment = $1.numberAlignment },
    ]

    /// The part of a presentation that can apply to every item. nil when
    /// nothing is left.
    public static func globalStyle(_ presentation: MenuBarPresentation?) -> MenuBarPresentation? {
        guard let presentation else { return nil }
        var style = MenuBarPresentation()
        for copy in globalStyleFields { copy(&style, presentation) }
        return style == MenuBarPresentation() ? nil : style
    }

    /// `presentation` without the fields an app-wide style sets, so that
    /// style shows through. nil when nothing else was set.
    public static func clearingGlobalStyle(_ presentation: MenuBarPresentation?) -> MenuBarPresentation? {
        guard var presentation else { return nil }
        for copy in globalStyleFields { copy(&presentation, MenuBarPresentation()) }
        return presentation == MenuBarPresentation() ? nil : presentation
    }

    // MARK: Metric rows

    /// The key each metric row is known by — for ordering, hiding and
    /// relabelling — guaranteed unique.
    ///
    /// A row's `id` when it has one, `row:<index>` when it does not. Nothing
    /// stopped two rows from ending up with the same key (a render with two
    /// equal ids, or an id that is literally `row:1` next to an id-less second
    /// row), and the settings editor turned such a pair into a dictionary that
    /// trapped. A repeat now gets `#2`, `#3`… so every consumer can rely on
    /// the keys being distinct.
    public static func metricKeys(_ metrics: [StatusMetric]) -> [String] {
        var seen = Set<String>()
        return metrics.enumerated().map { index, metric in
            let base = metric.id.flatMap { $0.isEmpty ? nil : $0 } ?? "row:\(index)"
            var key = base
            var n = 2
            while !seen.insert(key).inserted {
                key = "\(base)#\(n)"
                n += 1
            }
            return key
        }
    }

    /// Position of each key in a stored order; a repeated key keeps its first
    /// position instead of trapping.
    public static func orderRanks(_ order: [String]) -> [String: Int] {
        order.enumerated().reduce(into: [String: Int]()) { ranks, pair in
            if ranks[pair.element] == nil { ranks[pair.element] = pair.offset }
        }
    }

    // MARK: Width

    /// Integer digits reserved when nobody said otherwise. Two covers the
    /// normal range of what menu bars show — CPU and memory percentages,
    /// temperatures, watts — and the rare `100%` grows the item once and keeps
    /// it, instead of every reading paying for a digit it never uses.
    public static let defaultReservedDigits = 2

    /// U+2007 FIGURE SPACE: exactly as wide as a digit in any font with
    /// tabular figures, which is every font the menu bar draws values in.
    public static let figureSpace: Character = "\u{2007}"

    /// Pads the integer part of the first number in `text` with figure spaces,
    /// in front of it, so it occupies `digits` digit widths.
    ///
    /// This is what keeps `9°` and `10°` the same width. By default the
    /// padding goes before the number — right-aligned, so the ones digit stays
    /// where it was when `8%` becomes `23%`; `numbers: .left` puts it after the
    /// reading instead, so the number starts where the label does. It is text rather than layout, so the shared strip (one
    /// attributed string for several widgets) gets stable cells the same way
    /// a separate item does. Text with no digits, or a number already that
    /// long, is returned unchanged.
    public static func reservingDigits(
        _ text: String, digits: Int, numbers: MenuBarNumberAlignment = .right
    ) -> String {
        guard digits > 0, let start = text.firstIndex(where: \.isASCIIDigit) else {
            return text
        }
        let run = text[start...].prefix(while: \.isASCIIDigit)
        let missing = digits - run.count
        guard missing > 0 else { return text }
        if numbers == .left {
            // After the whole reading, so the unit travels with the number
            // and the number starts where the label does.
            return text + String(repeating: figureSpace, count: missing)
        }
        // The pad goes before a sign, not between it and the digits: -5° is
        // drawn " -5°", never "- 5°".
        var at = start
        if at > text.startIndex {
            let before = text.index(before: at)
            if text[before] == "-" || text[before] == "\u{2212}" { at = before }
        }
        var padded = text
        padded.insert(contentsOf: String(repeating: figureSpace, count: missing), at: at)
        return padded
    }

    /// The value text as the menu bar should draw it under `presentation`.
    public static func reservedValue(_ text: String, presentation: MenuBarPresentation) -> String {
        guard presentation.effectiveWidth != .fit, !text.isEmpty else { return text }
        return reservingDigits(
            text, digits: presentation.effectiveDigits,
            numbers: presentation.effectiveNumberAlignment
        )
    }

    /// Formats a numeric metric according to the public SDK vocabulary.
    /// Missing/non-finite numeric values intentionally render as an em dash;
    /// they are never coerced to zero.
    public static func formattedMetricValue(_ metric: StatusMetric, presentation: MenuBarPresentation) -> String? {
        guard metric.number != nil || metric.format != nil else { return nil }
        guard let number = metric.number, number.isFinite else { return "—" }
        let precision = presentation.precision ?? metric.precision ?? 0
        let format = metric.format ?? "decimal"
        let shown: String
        switch format {
        case "percent": shown = fixed(number, precision: precision) + "%"
        case "bytes", "bytesPerSecond":
            let units = ["B", "kB", "MB", "GB", "TB"]
            var value = abs(number); var index = 0
            while value >= 1000, index < units.count - 1 { value /= 1000; index += 1 }
            let signed = number < 0 ? -value : value
            shown = fixed(signed, precision: precision) + " " + units[index] + (format == "bytesPerSecond" ? "/s" : "")
        default: shown = fixed(number, precision: precision)
        }
        guard presentation.showUnits != false else {
            if format == "percent" { return fixed(number, precision: precision) }
            if format == "bytes" || format == "bytesPerSecond" { return fixed(number < 0 ? -absByteMagnitude(number).0 : absByteMagnitude(number).0, precision: precision) }
            return shown
        }
        if let unit = normalizedLabel(metric.unit, limit: maxPrefixCharacters),
           !(format == "percent" && unit == "%") {
            return shown + (attachesToNumber(unit) ? "" : " ") + unit
        }
        return shown
    }

    /// Whether a unit is written against its number, the way `%` and `°`
    /// already are: symbols (`W`, `V`, `°C`, `Hz`) yes, words (`rpm`) no.
    ///
    /// Menu bar space is the scarcest there is, and the space in `12 W` was
    /// the whole difference between the power item and its neighbours — `W`
    /// is exactly as wide as `%`, so `12W` lines up with `23%` and `12 W`
    /// stood 3 pt wider.
    static func attachesToNumber(_ unit: String) -> Bool {
        unit.hasPrefix("°") || unit.count <= 2
    }

    private static func absByteMagnitude(_ number: Double) -> (Double, Int) {
        var value = abs(number); var index = 0
        while value >= 1000, index < 4 { value /= 1000; index += 1 }
        return (value, index)
    }
    private static func fixed(_ number: Double, precision: Int) -> String {
        String(format: "%.*f", precision, number)
    }

    /// Applies presentation once, before UI rendering. Metric ids are stable
    /// when supplied and otherwise use their original row index (`row:0`).
    public static func applyingPresentation(_ presentation: MenuBarPresentation, to entry: MenuBarEntry) -> MenuBarEntry {
        var entry = entry
        entry.presentation = presentation
        let original = Array(zip(metricKeys(entry.metrics), entry.metrics))
        let rank = orderRanks(presentation.metricOrder ?? [])
        let metrics = original.enumerated().sorted { left, right in
            let lhs = rank[left.element.0]
            let rhs = rank[right.element.0]
            switch (lhs, rhs) {
            case let (lhs?, rhs?) where lhs != rhs: return lhs < rhs
            case (_?, nil): return true
            case (nil, _?): return false
            default: return left.offset < right.offset
            }
        }.compactMap { _, pair -> StatusMetric? in
            let (key, inputMetric) = pair
            let override = presentation.metricOverrides?[key]
            guard override?.hidden != true else { return nil }
            var metric = inputMetric
            if let label = override?.label { metric.label = label }
            if let tint = override?.tint { metric.tint = tint }
            let formatted = formattedMetricValue(metric, presentation: presentation)
            if let formatted { metric.value = formatted }
            if presentation.showValues == false {
                if metric.accessibilityLabel == nil {
                    metric.accessibilityLabel = [metric.label, metric.value]
                        .filter { !$0.isEmpty }.joined(separator: " ")
                }
                metric.value = ""
            }
            // Padded last: the spoken description above is built from the
            // value as read, not as laid out.
            metric.value = reservedValue(metric.value, presentation: presentation)
            return metric
        }
        // Do not produce a blank cell when all configured rows are hidden.
        entry.metrics = normalizedMetrics(metrics)
        // Keep the legacy inline/stacked path coherent for a widget that has
        // graduated to one structured reading. The prefix stays independent,
        // so `CPU` + one `23%` metric never becomes `CPU CPU 23%`.
        if entry.metrics.count == 1 {
            entry.label = entry.metrics[0].value
        } else if entry.metrics.isEmpty {
            // A text-only widget's label (`status.label`) gets the same room.
            entry.label = entry.label.map { reservedValue($0, presentation: presentation) }
        }
        if presentation.color == "monochrome" {
            entry.tint = nil
            entry.metrics = entry.metrics.map { var m = $0; m.tint = nil; return m }
        } else if let color = MenuBarTint.named(presentation.color) {
            entry.tint = color
            entry.metrics = entry.metrics.map { var m = $0; m.tint = color.rawValue; return m }
        }
        // Last, so an alert shows through any colour choice: the user asked
        // for both, and the alert is the one that is about right now.
        if presentation.hasThresholds {
            entry = applyingThresholds(presentation, to: entry)
        }
        if entry.metrics.isEmpty, !original.isEmpty, entry.label?.isEmpty != false, entry.symbol == nil, entry.iconOverride?.isEmpty != false {
            entry.label = entry.name
        }
        return entry
    }

    // MARK: Charts

    /// How many past readings an item's chart keeps.
    public static let chartHistoryLimit = 40

    /// The reading an item's chart follows — its first numeric one, as shown
    /// — with the key it is known by and the scale to draw it against: 0–100
    /// for a percentage, nil for anything else.
    public static func chartSample(_ entry: MenuBarEntry) -> (key: String, value: Double, scale: Double?)? {
        let keys = metricKeys(entry.metrics)
        guard let index = entry.metrics.firstIndex(where: { thresholdValue($0) != nil }),
              let value = thresholdValue(entry.metrics[index])
        else { return nil }
        let metric = entry.metrics[index]
        let percent = metric.format == "percent" || metric.unit == "%"
        return (keys[index], value, percent ? 100 : nil)
    }

    /// The least time between two points of a chart. A chart that moves on
    /// every refresh redraws its item on every refresh — the RAM item whose
    /// number sat still started repainting every 2 s, most of what turning
    /// graphs on cost. A point is the highest reading of its step, so a
    /// spike between points still shows.
    public static let chartStep: TimeInterval = 5

    /// `history` with `sample` taken in at `now`. A sample from another
    /// reading (the rows were reordered or one hidden) or on another kind of
    /// scale starts a new series: joining memory onto CPU, or rpm onto °C,
    /// draws a line that means nothing.
    public static func recordingChart(
        _ history: MenuBarChartHistory?, _ sample: (key: String, value: Double, scale: Double?),
        at now: TimeInterval
    ) -> MenuBarChartHistory {
        guard var history, history.series == sample.key, history.scale == sample.scale else {
            return MenuBarChartHistory(series: sample.key, scale: sample.scale, values: [sample.value], lastAt: now)
        }
        let peak = max(history.pending ?? sample.value, sample.value)
        if let lastAt = history.lastAt, now - lastAt >= 0, now - lastAt < chartStep {
            history.pending = peak
            return history
        }
        history.values = Array((history.values + [peak]).suffix(chartHistoryLimit))
        history.lastAt = now
        history.pending = nil
        return history
    }

    /// The entry carrying `history` for its renderer. The scale is the
    /// history's own, so one refresh without a reading does not rescale the
    /// points already drawn.
    public static func applyingChart(_ entry: MenuBarEntry, history: MenuBarChartHistory?) -> MenuBarEntry {
        var entry = entry
        // A gauge shows only the current reading, on a fixed scale, rounded
        // to what its ring can show — so the item redraws when the ring would
        // move, not whenever a digit behind it does. Against 0–100 for a
        // percentage, the danger threshold when set, else the recent peak.
        if entry.presentation.effectiveChart == .gauge, let sample = chartSample(entry) {
            let danger = entry.presentation.dangerAt.flatMap { $0 > 0 ? $0 : nil }
            let top = sample.scale ?? danger ?? max(history?.values.max() ?? 0, sample.value, .leastNonzeroMagnitude)
            let steps = 48.0
            let share = (min(max(sample.value / top, 0), 1) * steps).rounded() / steps
            entry.history = [share * top]
            entry.chartScale = top
            return entry
        }
        entry.history = history?.values ?? []
        entry.chartScale = history?.scale
        return entry
    }

    // MARK: Thresholds

    /// A metric's number in the unit the item shows it in — what a threshold
    /// is compared with. Percentages as 0–100, bytes in GB and rates in MB/s,
    /// anything else as it comes. nil for a metric with no usable number.
    public static func thresholdValue(_ metric: StatusMetric) -> Double? {
        guard let number = metric.number, number.isFinite else { return nil }
        switch metric.format {
        case "bytes": return number / 1_000_000_000
        case "bytesPerSecond": return number / 1_000_000
        default: return number
        }
    }

    /// The unit a threshold for these readings is typed in, for the settings.
    public static func thresholdUnit(_ metrics: [StatusMetric]) -> String {
        guard let index = judgedMetrics(metrics).first else { return "" }
        let metric = metrics[index]
        switch metric.format {
        case "percent": return "%"
        case "bytes": return "GB"
        case "bytesPerSecond": return "MB/s"
        default: return normalizedLabel(metric.unit, limit: maxPrefixCharacters) ?? ""
        }
    }

    /// Which readings of an entry the thresholds judge: those in the same
    /// unit as the first numeric one. A threshold typed as "80 %" means
    /// nothing to a fan's 1800 rpm beside it.
    public static func judgedMetrics(_ metrics: [StatusMetric]) -> [Int] {
        func kind(_ metric: StatusMetric) -> String {
            "\(metric.format ?? "decimal")|\(metric.format == "percent" ? "" : metric.unit ?? "")"
        }
        guard let first = metrics.first(where: { thresholdValue($0) != nil }) else { return [] }
        let wanted = kind(first)
        return metrics.indices.filter { thresholdValue(metrics[$0]) != nil && kind(metrics[$0]) == wanted }
    }

    /// Tints each judged reading warning or danger. A reading short of both
    /// keeps the colour the user chose, or none — never the widget's own
    /// green, which the thresholds replace. The item's tint is its worst.
    static func applyingThresholds(_ presentation: MenuBarPresentation, to entry: MenuBarEntry) -> MenuBarEntry {
        var entry = entry
        let judged = judgedMetrics(entry.metrics)
        guard !judged.isEmpty else { return entry }
        let chosen = presentation.color == "monochrome" ? nil : MenuBarTint.named(presentation.color)
        var worst: MenuBarTint?
        for index in judged {
            guard let value = thresholdValue(entry.metrics[index]) else { continue }
            let level = thresholdLevel(value, presentation: presentation)
            entry.metrics[index].tint = (level ?? chosen)?.rawValue
            if level == .danger || (level == .warning && worst != .danger) { worst = level }
        }
        entry.tint = worst ?? chosen
        return entry
    }

    static func isPast(_ value: Double, _ limit: Double, _ direction: MenuBarThresholdDirection) -> Bool {
        direction == .below ? value <= limit : value >= limit
    }

    static func thresholdLevel(_ value: Double, presentation: MenuBarPresentation) -> MenuBarTint? {
        let direction = presentation.thresholdDirection ?? .above
        if let danger = presentation.dangerAt, isPast(value, danger, direction) { return .danger }
        if let warning = presentation.warningAt, isPast(value, warning, direction) { return .warning }
        return nil
    }

    /// Whether an entry's readings reach its `showWhen`: nil when there is
    /// no limit or nothing numeric to judge yet.
    public static func meetsShowWhen(_ entry: MenuBarEntry) -> Bool? {
        guard let limit = entry.presentation.showWhen else { return nil }
        let values = judgedMetrics(entry.metrics).compactMap { thresholdValue(entry.metrics[$0]) }
        guard !values.isEmpty else { return nil }
        let direction = entry.presentation.thresholdDirection ?? .above
        return values.contains { isPast($0, limit, direction) }
    }

    /// Whether `showWhen` keeps this entry out of the menu bar: none of its
    /// readings has reached it. An entry with no number to judge stays —
    /// hiding it for good would be worse than ignoring the setting.
    public static func isDormant(_ entry: MenuBarEntry) -> Bool {
        meetsShowWhen(entry) == false
    }

    /// What one entry contributes as text: the prefix and the value, or
    /// whichever of them exists.
    public static func entryText(_ entry: MenuBarEntry) -> String {
        if !entry.metrics.isEmpty {
            if entry.metrics.count == 1, entry.style == .inline {
                let metric = entry.metrics[0]
                let value = metric.value.isEmpty ? metric.active.map { $0 ? "●" : "○" } ?? "" : metric.value
                // The user turned the label off: the value alone, not the
                // metric's own label sneaking back in.
                if entry.prefix == "" { return value }
                if let prefix = normalizedPrefix(entry.prefix) {
                    return value.isEmpty ? prefix : "\(prefix) \(value)"
                }
            }
            let readings = entry.metrics.compactMap { metric -> String? in
                let visible = [metric.label, metric.value]
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
                if !visible.isEmpty { return visible }
                return metric.active.map { $0 ? "●" : "○" }
            }.joined(separator: " · ")
            if entry.style == .inline, let prefix = normalizedPrefix(entry.prefix) {
                return "\(prefix) \(readings)"
            }
            return readings
        }
        let value = entry.label ?? ""
        guard let prefix = normalizedPrefix(entry.prefix) else { return value }
        return value.isEmpty ? prefix : "\(prefix) \(value)"
    }

    /// Spoken form of an entry. Structured metrics use their explicit
    /// accessibility descriptions even when compact visible arrows or values
    /// are present; an unlabeled dot still announces its state.
    public static func accessibilityText(_ entry: MenuBarEntry) -> String {
        spoken(unpaddedAccessibilityText(entry))
    }

    /// Layout padding is not speech: figure spaces go, and the gaps they
    /// leave collapse.
    static func spoken(_ text: String) -> String {
        text.replacingOccurrences(of: String(figureSpace), with: "")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func unpaddedAccessibilityText(_ entry: MenuBarEntry) -> String {
        guard !entry.metrics.isEmpty else { return entryText(entry) }
        return entry.metrics.compactMap { metric in
            if let label = normalizedLabel(metric.accessibilityLabel, limit: maxLabelCharacters * 3) {
                return label
            }
            let spokenValue = metric.value.isEmpty
                ? formattedMetricValue(metric, presentation: MenuBarPresentation(
                    showValues: true, showUnits: entry.presentation.showUnits,
                    precision: entry.presentation.precision
                )) ?? ""
                : metric.value
            let visible = [metric.label, spokenValue]
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            if !visible.isEmpty { return visible }
            guard let active = metric.active else { return nil }
            return active ? "Active" : "Inactive"
        }.joined(separator: " · ")
    }

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
        // Figure spaces are layout, not whitespace: they are the padding that
        // holds a reading's width still, and collapsing them here — this runs
        // again inside the renderers — would undo it.
        let collapsed = label
            .split(whereSeparator: { $0.isWhitespace && $0 != figureSpace })
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(max(limit - 1, 1))) + "…"
    }

    /// Bounds metric content before AppKit rendering. Active-only metrics stay
    /// present so callers can render a dot with an accessibility description.
    public static func normalizedMetrics(_ metrics: [StatusMetric]) -> [StatusMetric] {
        metrics.compactMap { metric in
            let label = normalizedLabel(metric.label, limit: maxPrefixCharacters) ?? ""
            let value = normalizedLabel(metric.value) ?? ""
            let accessibilityLabel = normalizedLabel(
                metric.accessibilityLabel,
                limit: maxLabelCharacters * 3
            )
            guard !label.isEmpty || !value.isEmpty || accessibilityLabel != nil || metric.active != nil
                || metric.number != nil || metric.format?.isEmpty == false else {
                return nil
            }
            return StatusMetric(
                id: metric.id,
                label: label,
                value: value,
                number: metric.number,
                // A template that rendered "" meant "no format".
                format: metric.format?.isEmpty == false ? metric.format : nil,
                unit: metric.unit,
                precision: metric.precision,
                tint: metric.tint?.trimmingCharacters(in: .whitespacesAndNewlines),
                active: metric.active,
                accessibilityLabel: accessibilityLabel
            )
        }
        .prefix(maxMetrics)
        .map { $0 }
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
            .map { stripCell($0) }
            .filter { !$0.isEmpty }
            .joined(separator: stripSeparator)
    }

    /// One entry as it appears in the shared strip.
    ///
    /// An icon override that is literal text — an emoji — is drawn here,
    /// because text is all the strip can draw. An SF Symbol needs an image and
    /// belongs to a separate item, so it is left out; the status item layer
    /// decides which kind it has and passes only the text kind through.
    public static func stripCell(_ entry: MenuBarEntry, glyph: String? = nil) -> String {
        let text = entryText(entry)
        guard let glyph, !glyph.isEmpty else { return text }
        return text.isEmpty ? glyph : "\(glyph) \(text)"
    }

    /// Multi-line tooltip: one line per entry, each "Name — value".
    public static func tooltip(for entries: [MenuBarEntry]) -> String? {
        let lines = entries.map { entry -> String in
            if let tooltip = entry.tooltip, !tooltip.isEmpty {
                return "\(entry.name) — \(tooltip)"
            }
            if !entry.metrics.isEmpty {
                let text = entry.metrics.compactMap { metric -> String? in
                    let visible = [metric.label, metric.value]
                        .filter { !$0.isEmpty }
                        .joined(separator: " ")
                    if !visible.isEmpty { return visible }
                    if let accessibilityLabel = metric.accessibilityLabel { return accessibilityLabel }
                    if metric.active != nil { return metric.active == true ? "Active" : "Inactive" }
                    return nil
                }.joined(separator: " · ")
                if !text.isEmpty { return "\(entry.name) — \(text)" }
            }
            if let label = entry.label, !label.isEmpty {
                return "\(entry.name) — \(label)"
            }
            return entry.name
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}

private extension Character {
    /// `0`–`9` only. `isNumber` would also match superscripts and other
    /// scripts' numerals, which are not tabular and must not be padded.
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}
