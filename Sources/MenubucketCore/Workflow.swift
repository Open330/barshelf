import Foundation

// MARK: - Definition (workflow.json)

/// Declarative workflow v1: host-executed `sources` → pure `transforms` →
/// `${...}`-templated `view`. No arbitrary code — the expression language is
/// paths + the built-in functions in `WorkflowEngine.call`.
public struct WorkflowDefinition: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var kind: String?
    public var sources: [String: SourceDef]
    public var transforms: [String: TransformDef]?
    public var view: JSONValue
    public var empty: JSONValue?
    public var status: StatusDef?
    /// Declarative persistence: after a successful eval, each entry's `value`
    /// template is expanded and the host commits it to the widget's storage
    /// namespace (optionally with a TTL). Keeps the engine pure — it computes
    /// *what* to write; the host performs the side effect.
    public var store: [String: StoreDef]?

    public init(
        schemaVersion: Int = 1,
        kind: String? = "workflow",
        sources: [String: SourceDef],
        transforms: [String: TransformDef]? = nil,
        view: JSONValue,
        empty: JSONValue? = nil,
        status: StatusDef? = nil,
        store: [String: StoreDef]? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.kind = kind
        self.sources = sources
        self.transforms = transforms
        self.view = view
        self.empty = empty
        self.status = status
        self.store = store
    }

    /// The `widget.*` context key a workflow reads to find out whether its
    /// card is on screen right now.
    public static let visibilityPath = "widget.visible"

    /// True when any template in this workflow reads `widget.visible`.
    ///
    /// A workflow that samples less while nothing is displayed — the sensors
    /// widget reads 46 SMC keys instead of 129 with its card closed — would
    /// otherwise keep showing the cheap result until its next scheduled tick.
    /// The host watches this flag so it can refresh the instant the card opens.
    public var readsWidgetVisibility: Bool {
        for source in sources.values where Self.mentionsVisibility(source.with) {
            return true
        }
        for transform in (transforms ?? [:]).values {
            if Self.mentionsVisibility(transform.with) { return true }
            if transform.from?.contains(Self.visibilityPath) == true { return true }
        }
        if Self.mentionsVisibility(view) { return true }
        if Self.mentionsVisibility(empty) { return true }
        if let status {
            let templates = [status.label, status.tooltip, status.prefix, status.icon, status.tint]
            if templates.contains(where: { $0?.contains(Self.visibilityPath) == true }) {
                return true
            }
            if status.metrics?.contains(where: { metric in
                [metric.id, metric.label, metric.value, metric.format, metric.unit, metric.tint, metric.accessibilityLabel]
                    .contains(where: { $0?.contains(Self.visibilityPath) == true })
                    || Self.mentionsVisibility(metric.active) || Self.mentionsVisibility(metric.number)
                    || Self.mentionsVisibility(metric.precision)
            }) == true { return true }
            if let presentation = status.presentation,
               Self.mentionsVisibility(presentation.showValues) || Self.mentionsVisibility(presentation.showUnits)
                || Self.mentionsVisibility(presentation.precision) || Self.mentionsVisibility(presentation.valueWidth)
                || Self.mentionsVisibility(presentation.digits)
                || [presentation.color, presentation.width, presentation.alignment,
                    presentation.weight, presentation.size]
                    .contains(where: { $0?.contains(Self.visibilityPath) == true }) { return true }
        }
        return false
    }

    private static func mentionsVisibility(_ value: JSONValue?) -> Bool {
        switch value {
        case let .string(text):
            return text.contains(visibilityPath)
        case let .array(items):
            return items.contains { mentionsVisibility($0) }
        case let .object(object):
            return object.values.contains { mentionsVisibility($0) }
        default:
            return false
        }
    }

    public struct SourceDef: Codable, Equatable, Sendable {
        public var use: String
        public var with: JSONValue?

        public init(use: String, with: JSONValue? = nil) {
            self.use = use
            self.with = with
        }
    }

    public struct TransformDef: Codable, Equatable, Sendable {
        public var use: String
        public var from: String?
        public var with: JSONValue?

        public init(use: String, from: String? = nil, with: JSONValue? = nil) {
            self.use = use
            self.from = from
            self.with = with
        }
    }

    public struct StatusDef: Codable, Equatable, Sendable {
        public var label: String?
        public var tooltip: String?
        /// Text drawn before the value in the menu bar. Templated like the
        /// others, so a widget whose metric the user picks can say "CPU" or
        /// "Mem" as appropriate — something a fixed manifest field cannot.
        public var prefix: String?
        /// SF Symbol name for this refresh, overriding `statusItem.icon`.
        /// A manifest field cannot follow a value: this is what lets a battery
        /// widget move between `battery.25` and `battery.100`, or a network one
        /// between signal strengths.
        public var icon: String?
        /// Colour for this refresh, from the same vocabulary the view layer
        /// uses — `accent`, `good`, `warning`, `danger`, `secondary`. Nil keeps
        /// the menu bar's own colour, which is what most widgets should do.
        public var tint: String?
        /// Templated structured readings. `active` is JSON rather than Bool so
        /// a whole `${…}` expression can resolve to a boolean.
        public var metrics: [MetricDef]?
        /// Presentation values may be templates for refresh-dependent choices.
        public var presentation: PresentationDef?

        public init(
            label: String? = nil,
            tooltip: String? = nil,
            prefix: String? = nil,
            icon: String? = nil,
            tint: String? = nil,
            metrics: [MetricDef]? = nil,
            presentation: PresentationDef? = nil
        ) {
            self.label = label
            self.tooltip = tooltip
            self.prefix = prefix
            self.icon = icon
            self.tint = tint
            self.metrics = metrics
            self.presentation = presentation
        }
    }

    public struct PresentationDef: Codable, Equatable, Sendable {
        public var showValues: JSONValue?
        public var showUnits: JSONValue?
        public var precision: JSONValue?
        public var color: String?
        public var valueWidth: JSONValue?
        public var metricOrder: [String]?
        public var metricOverrides: [String: MenuBarMetricOverride]?
        /// `auto` / `fixed` / `fit`, `left`… — templated strings, resolved and
        /// validated like `color`: an unknown value reads as unset.
        public var width: String?
        public var digits: JSONValue?
        public var alignment: String?
        public var weight: String?
        public var size: String?
        public init(showValues: JSONValue? = nil, showUnits: JSONValue? = nil, precision: JSONValue? = nil,
                    color: String? = nil, valueWidth: JSONValue? = nil, metricOrder: [String]? = nil,
                    metricOverrides: [String: MenuBarMetricOverride]? = nil,
                    width: String? = nil, digits: JSONValue? = nil, alignment: String? = nil,
                    weight: String? = nil, size: String? = nil) {
            self.showValues = showValues; self.showUnits = showUnits; self.precision = precision
            self.color = color; self.valueWidth = valueWidth; self.metricOrder = metricOrder; self.metricOverrides = metricOverrides
            self.width = width; self.digits = digits; self.alignment = alignment
            self.weight = weight; self.size = size
        }
    }

    /// Template form of `StatusMetric` used in workflow definitions.
    public struct MetricDef: Codable, Equatable, Sendable {
        public var id: String?
        public var label: String?
        public var value: String?
        public var number: JSONValue?
        public var format: String?
        public var unit: String?
        public var precision: JSONValue?
        public var tint: String?
        public var active: JSONValue?
        public var accessibilityLabel: String?

        public init(
            id: String? = nil,
            label: String? = nil,
            value: String? = nil,
            number: JSONValue? = nil,
            format: String? = nil,
            unit: String? = nil,
            precision: JSONValue? = nil,
            tint: String? = nil,
            active: JSONValue? = nil,
            accessibilityLabel: String? = nil
        ) {
            self.id = id
            self.label = label
            self.value = value
            self.number = number
            self.format = format
            self.unit = unit
            self.precision = precision
            self.tint = tint
            self.active = active
            self.accessibilityLabel = accessibilityLabel
        }
    }

    /// One persisted key. `value` is a `${…}` template expanded in the same
    /// context as the view (so it can read `sources`, `transforms`, `storage`,
    /// `now()`, etc.). `ttlSec`, when set, expires the entry after that many
    /// seconds.
    public struct StoreDef: Codable, Equatable, Sendable {
        public var value: JSONValue
        public var ttlSec: Double?

        public init(value: JSONValue, ttlSec: Double? = nil) {
            self.value = value
            self.ttlSec = ttlSec
        }
    }

    public static func decode(from data: Data) throws -> WorkflowDefinition {
        try JSONDecoder().decode(WorkflowDefinition.self, from: data)
    }
}

public enum WorkflowError: Error, LocalizedError, Equatable {
    case badExpression(String)
    case unknownFunction(String)
    case unknownTransform(String)
    case transformCycle(String)
    case invalidTemplate(String)

    public var errorDescription: String? {
        switch self {
        case let .badExpression(expr): return "invalid expression: \(expr)"
        case let .unknownFunction(name): return "unknown function: \(name)"
        case let .unknownTransform(name): return "unknown transform: \(name)"
        case let .transformCycle(name): return "transform cycle involving: \(name)"
        case let .invalidTemplate(detail): return "invalid view template: \(detail)"
        }
    }
}

// MARK: - Engine

public enum WorkflowEngine {
    /// A key the host should commit to the widget's storage namespace after a
    /// successful eval.
    public struct StorageWrite: Sendable, Equatable {
        public var key: String
        public var value: JSONValue
        public var ttlMs: Double?

        public init(key: String, value: JSONValue, ttlMs: Double? = nil) {
            self.key = key
            self.value = value
            self.ttlMs = ttlMs
        }
    }

    public struct Output: Sendable {
        public var viewTree: UINode
        public var statusLabel: String?
        public var statusMetrics: [StatusMetric]?
        public var statusTooltip: String?
        /// Text the menu bar draws before the value, when the widget supplies
        /// one per refresh. See `StatusDef.prefix`.
        public var statusPrefix: String?
        /// SF Symbol the menu bar draws for this refresh. See `StatusDef.icon`.
        public var statusIcon: String?
        /// Semantic colour for this refresh. See `StatusDef.tint`.
        public var statusTint: String?
        public var statusPresentation: MenuBarPresentation?
        /// Total items produced by every `forEach` expansion.
        public var expandedItemCount: Int
        /// True when zero items were expanded and the `empty` node was used.
        public var usedEmpty: Bool
        /// Values the `store` block computed for the host to persist.
        public var writes: [StorageWrite]

        public init(
            viewTree: UINode,
            statusLabel: String? = nil,
            statusMetrics: [StatusMetric]? = nil,
            statusPrefix: String? = nil,
            statusIcon: String? = nil,
            statusTint: String? = nil,
            statusPresentation: MenuBarPresentation? = nil,
            statusTooltip: String? = nil,
            expandedItemCount: Int = 0,
            usedEmpty: Bool = false,
            writes: [StorageWrite] = []
        ) {
            self.viewTree = viewTree
            self.statusLabel = statusLabel
            self.statusMetrics = statusMetrics
            self.statusPrefix = statusPrefix
            self.statusIcon = statusIcon
            self.statusTint = statusTint
            self.statusPresentation = statusPresentation
            self.statusTooltip = statusTooltip
            self.expandedItemCount = expandedItemCount
            self.usedEmpty = usedEmpty
            self.writes = writes
        }
    }

    /// Phase 1 — interpolates each source's `with` params against `settings`
    /// so the caller can execute the I/O (exec / fs.directory).
    public static func resolvedSourceParams(
        _ definition: WorkflowDefinition,
        settings: JSONValue,
        storage: JSONValue = .object([:]),
        widget: JSONValue = .object([:]),
        nowMs: Double = Date().timeIntervalSince1970 * 1000
    ) throws -> [String: JSONValue] {
        var context = Context(
            root: [
                "settings": settings,
                "sources": .object([:]),
                "transforms": .object([:]),
                "storage": storage,
                "widget": widget,
            ],
            transforms: [:],
            nowMs: nowMs
        )
        var resolved: [String: JSONValue] = [:]
        for (id, source) in definition.sources {
            if source.use == "value" {
                resolved[id] = source.with ?? .null
            } else {
                resolved[id] = try context.expand(source.with ?? .object([:]))
            }
        }
        return resolved
    }

    /// Phase 2 — runs transforms and expands the view template.
    public static func evaluate(
        _ definition: WorkflowDefinition,
        sources: [String: JSONValue],
        settings: JSONValue,
        storage: JSONValue = .object([:]),
        widget: JSONValue = .object([:]),
        nowMs: Double = Date().timeIntervalSince1970 * 1000
    ) throws -> Output {
        var context = Context(
            root: [
                "settings": settings,
                "sources": .object(sources),
                "transforms": .object([:]),
                "storage": storage,
                "widget": widget,
            ],
            transforms: definition.transforms ?? [:],
            nowMs: nowMs
        )

        let expandedView = try context.expand(definition.view)
        var usedEmpty = false
        var tree = expandedView
        if context.expandedItemCount == 0, let empty = definition.empty {
            tree = try context.expand(empty)
            usedEmpty = true
        }

        let data = try JSONEncoder().encode(tree)
        let viewTree: UINode
        do {
            viewTree = try JSONDecoder().decode(UINode.self, from: data)
        } catch {
            throw WorkflowError.invalidTemplate("expanded view is not a UINode: \(error)")
        }

        var statusLabel: String?
        var statusTooltip: String?
        var statusPrefix: String?
        var statusIcon: String?
        var statusTint: String?
        var statusPresentation: MenuBarPresentation?
        var statusMetrics: [StatusMetric]?
        if let status = definition.status {
            if let label = status.label {
                statusLabel = try context.interpolate(label).stringified
            }
            if let tooltip = status.tooltip {
                statusTooltip = try context.interpolate(tooltip).stringified
            }
            if let prefix = status.prefix {
                statusPrefix = try context.interpolate(prefix).stringified
            }
            if let icon = status.icon {
                statusIcon = try context.interpolate(icon).stringified
            }
            if let tint = status.tint {
                statusTint = try context.interpolate(tint).stringified
            }
            if let presentation = status.presentation {
                let bool: (JSONValue?) throws -> Bool? = { value in
                    guard let value else { return nil }
                    return Self.metricActive(try context.expand(value))
                }
                let number: (JSONValue?) throws -> Double? = { value in
                    guard let value else { return nil }
                    switch try context.expand(value) {
                    case let .number(number): return number
                    case let .string(text): return Double(text)
                    default: return nil
                    }
                }
                statusPresentation = MenuBarPresentation(
                    showValues: try bool(presentation.showValues),
                    showUnits: try bool(presentation.showUnits),
                    precision: Self.validMetricPrecision(try number(presentation.precision)),
                    color: try presentation.color.map { try context.interpolate($0).stringified },
                    valueWidth: try number(presentation.valueWidth),
                    metricOrder: presentation.metricOrder,
                    metricOverrides: presentation.metricOverrides,
                    width: try presentation.width.flatMap {
                        MenuBarWidthMode(rawValue: try context.interpolate($0).stringified)
                    },
                    digits: try number(presentation.digits).map { Int($0) },
                    alignment: try presentation.alignment.flatMap {
                        MenuBarAlignment(rawValue: try context.interpolate($0).stringified)
                    },
                    weight: try presentation.weight.flatMap {
                        MenuBarWeight(rawValue: try context.interpolate($0).stringified)
                    },
                    size: try presentation.size.flatMap {
                        MenuBarTextSize(rawValue: try context.interpolate($0).stringified)
                    }
                )
            }
            if let metrics = status.metrics {
                statusMetrics = try metrics.map { metric in
                    let active: Bool?
                    if let template = metric.active {
                        active = Self.metricActive(try context.expand(template))
                    } else {
                        active = nil
                    }
                    return StatusMetric(
                        id: try metric.id.map { try context.interpolate($0).stringified },
                        label: try metric.label.map { try context.interpolate($0).stringified } ?? "",
                        value: try metric.value.map { try context.interpolate($0).stringified } ?? "",
                        number: try metric.number.flatMap { value in
                            switch try context.expand(value) {
                            case let .number(number): return number
                            case let .string(text): return Double(text)
                            default: return nil
                            }
                        },
                        format: try metric.format.map { try context.interpolate($0).stringified },
                        unit: try metric.unit.map { try context.interpolate($0).stringified },
                        precision: Self.validMetricPrecision(try metric.precision.flatMap { value in
                            switch try context.expand(value) {
                            case let .number(number): return number
                            case let .string(text): return Double(text)
                            default: return nil
                            }
                        }),
                        tint: try metric.tint.map { try context.interpolate($0).stringified },
                        active: active,
                        accessibilityLabel: try metric.accessibilityLabel.map {
                            try context.interpolate($0).stringified
                        }
                    )
                }
            }
        }

        var writes: [StorageWrite] = []
        if let store = definition.store {
            // Deterministic order so a `store` entry can read a sibling's
            // previous (pre-write) value and results are reproducible.
            for key in store.keys.sorted() {
                guard let entry = store[key] else { continue }
                let value = try context.expand(entry.value)
                writes.append(StorageWrite(
                    key: key,
                    value: value,
                    ttlMs: entry.ttlSec.map { $0 * 1000 }
                ))
            }
        }

        return Output(
            viewTree: viewTree,
            statusLabel: statusLabel,
            statusMetrics: statusMetrics,
            statusPrefix: statusPrefix,
            statusIcon: statusIcon,
            statusTint: statusTint,
            statusPresentation: statusPresentation,
            statusTooltip: statusTooltip,
            expandedItemCount: context.expandedItemCount,
            usedEmpty: usedEmpty,
            writes: writes
        )
    }

    /// Only explicit booleans (or their string wire representation) control
    /// activity. Numbers and arbitrary strings cannot accidentally animate a
    /// menu-bar indicator.
    private static func metricActive(_ value: JSONValue) -> Bool? {
        switch value {
        case let .bool(active): return active
        case let .string(text):
            switch text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true": return true
            case "false": return false
            default: return nil
            }
        default: return nil
        }
    }

    /// Converts a workflow number only after proving it is safe to turn into
    /// an `Int`. `Int(Double.nan)`, infinity, and enormous doubles trap.
    private static func validMetricPrecision(_ value: Double?) -> Int? {
        guard let value, value.isFinite, value.rounded(.towardZero) == value,
              (0...3).contains(value) else { return nil }
        return Int(value)
    }

    // MARK: - Evaluation context

    private struct Context {
        var root: [String: JSONValue]
        var transforms: [String: WorkflowDefinition.TransformDef]
        var nowMs: Double

        var scopes: [[String: JSONValue]] = []
        var resolvedTransforms: [String: JSONValue] = [:]
        var resolvingTransforms: Set<String> = []
        var expandedItemCount = 0
        var depth = 0

        /// Guards against stack overflow from pathologically nested templates or
        /// expressions (e.g. `count(count(count(…)))` or deeply nested arrays).
        /// Legitimate widget views nest a handful of levels; 256 is generous.
        static let maxDepth = 256

        /// Non-crashing `Double`→`Int`. Swift's `Int(_:)` traps on NaN,
        /// infinity, and finite-but-out-of-range values — all reachable from
        /// untrusted expression literals (`Double("1e400")` → ∞) and JSON
        /// settings (`1e19` is representable but > `Int.max`).
        static func clampedInt(_ value: Double) -> Int {
            if value.isNaN { return 0 }
            if value >= Double(Int.max) { return Int.max }
            if value <= Double(Int.min) { return Int.min }
            return Int(value)
        }

        // MARK: template expansion

        mutating func expand(_ value: JSONValue) throws -> JSONValue {
            depth += 1
            defer { depth -= 1 }
            guard depth <= Self.maxDepth else {
                throw WorkflowError.invalidTemplate("template nesting exceeds \(Self.maxDepth) levels")
            }
            switch value {
            case let .string(text):
                return try interpolate(text)
            case let .array(items):
                return .array(try items.map { try expand($0) })
            case let .object(object):
                if case let .string(path)? = object["forEach"] {
                    return try expandForEach(path: path, spec: object)
                }
                if object["switch"] != nil {
                    return try expandSwitch(spec: object)
                }
                var out: [String: JSONValue] = [:]
                for (key, item) in object {
                    out[key] = try expand(item)
                }
                return .object(out)
            default:
                return value
            }
        }

        private mutating func expandForEach(path: String, spec: [String: JSONValue]) throws -> JSONValue {
            guard case let .string(name)? = spec["as"], let template = spec["template"] else {
                throw WorkflowError.invalidTemplate("forEach needs \"as\" and \"template\"")
            }
            let list = try evaluateExpression(path)
            guard case let .array(items) = list else {
                throw WorkflowError.badExpression("forEach path is not a list: \(path)")
            }
            expandedItemCount += items.count
            var out: [JSONValue] = []
            out.reserveCapacity(items.count)
            for item in items {
                scopes.append([name: item])
                defer { scopes.removeLast() }
                out.append(try expand(template))
            }
            return .array(out)
        }

        /// `{ "switch": "<expr>", "cases": { key: node }, "default": node }` —
        /// evaluates the selector, expands ONLY the matching case (or `default`,
        /// else a spacer). Unlike the `if()` function, unmatched branches are
        /// never expanded, so their forEach loops don't run.
        private mutating func expandSwitch(spec: [String: JSONValue]) throws -> JSONValue {
            let selector = spec["switch"] ?? .null
            let key: String
            if case let .string(text) = selector {
                key = try interpolate(text).stringified
            } else {
                key = try expand(selector).stringified
            }
            if let chosen = spec["cases"]?.objectValue?[key] {
                return try expand(chosen)
            }
            if let fallback = spec["default"] {
                return try expand(fallback)
            }
            return .object(["type": .string("spacer")])
        }

        // MARK: interpolation

        /// `"${expr}"` alone keeps the expression's type; anything else
        /// becomes string concatenation.
        mutating func interpolate(_ text: String) throws -> JSONValue {
            guard text.contains("${") else { return .string(text) }
            var pieces: [JSONValue] = []
            var literal = ""
            var rest = Substring(text)
            while let start = rest.range(of: "${") {
                literal += rest[..<start.lowerBound]
                guard let end = rest[start.upperBound...].firstIndex(of: "}") else {
                    throw WorkflowError.badExpression(text)
                }
                if !literal.isEmpty {
                    pieces.append(.string(literal))
                    literal = ""
                }
                pieces.append(try evaluateExpression(String(rest[start.upperBound..<end])))
                rest = rest[rest.index(after: end)...]
            }
            literal += rest
            if !literal.isEmpty { pieces.append(.string(literal)) }
            if pieces.count == 1 { return pieces[0] }
            return .string(pieces.map(\.stringified).joined())
        }

        // MARK: expressions — number literal | function call | path

        mutating func evaluateExpression(_ raw: String) throws -> JSONValue {
            depth += 1
            defer { depth -= 1 }
            guard depth <= Self.maxDepth else {
                throw WorkflowError.badExpression("expression nesting exceeds \(Self.maxDepth) levels")
            }
            let expr = raw.trimmingCharacters(in: .whitespaces)
            guard !expr.isEmpty else { throw WorkflowError.badExpression(raw) }
            if let number = Double(expr) { return .number(number) }
            // String literal: 'text' or "text" (quotes let comparisons/coalesce
            // reference constants, e.g. eq(status, "success")).
            if expr.count >= 2,
               let first = expr.first, let last = expr.last, first == last,
               first == "\"" || first == "'" {
                return .string(String(expr.dropFirst().dropLast()))
            }
            if expr == "true" { return .bool(true) }
            if expr == "false" { return .bool(false) }
            if expr == "null" { return .null }
            if expr.hasSuffix(")"), let paren = expr.firstIndex(of: "(") {
                let name = String(expr[..<paren])
                let inner = String(expr[expr.index(after: paren)..<expr.index(before: expr.endIndex)])
                if isFunctionName(name) {
                    let args = try splitArguments(inner).map { try evaluateExpression($0) }
                    return try call(name, args: args)
                }
            }
            return try resolvePath(expr)
        }

        private func isFunctionName(_ name: String) -> Bool {
            !name.isEmpty && name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" }
        }

        /// Splits a call's arguments on top-level commas.
        ///
        /// Commas inside nested calls *and* inside string literals are part of
        /// the argument, not separators — `concat(a, ', ', b)` joins three
        /// arguments, the middle one being a literal comma.
        private func splitArguments(_ inner: String) throws -> [String] {
            if let cached = ArgumentSplitCache.shared.lookup(inner) { return cached }
            let split = Self.split(inner)
            ArgumentSplitCache.shared.store(split, for: inner)
            return split
        }

        private static func split(_ inner: String) -> [String] {
            let trimmed = inner.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return [] }
            var args: [String] = []
            var depth = 0
            var quote: Character?
            var current = ""
            for char in trimmed {
                if let open = quote {
                    current.append(char)
                    if char == open { quote = nil }
                    continue
                }
                switch char {
                case "'", "\"": quote = char; current.append(char)
                case "(": depth += 1; current.append(char)
                case ")": depth -= 1; current.append(char)
                case "," where depth == 0:
                    args.append(current)
                    current = ""
                default: current.append(char)
                }
            }
            args.append(current)
            return args
        }

        private mutating func call(_ name: String, args: [JSONValue]) throws -> JSONValue {
            switch name {
            case "string":
                // Coerce any value to a string. A lone `${…}` interpolation
                // preserves its JSON type, so numeric/bool fields dropped into
                // a text node would fail UINode decoding — wrap them in
                // string() to make text nodes type-safe.
                return .string(args.first?.stringified ?? "")
            case "now":
                return .number(nowMs)
            case "count":
                guard let first = args.first else { return .number(0) }
                if case let .array(items) = first { return .number(Double(items.count)) }
                if case let .object(object) = first { return .number(Double(object.count)) }
                return .number(0)
            case "coalesce":
                for arg in args {
                    if arg.isNull { continue }
                    if case let .string(text) = arg, text.isEmpty { continue }
                    return arg
                }
                return .null
            case "date.relative":
                guard let ms = args.first?.numberValue, ms.isFinite else { return .string("") }
                return .string(Self.relative(fromMs: ms, nowMs: nowMs))
            case "file.basename":
                guard let path = args.first?.stringValue else { return .string("") }
                return .string((path as NSString).lastPathComponent)
            case "file.extension":
                guard let path = args.first?.stringValue else { return .string("") }
                return .string((path as NSString).pathExtension)
            case "concat":
                // Joins every argument's string form. The only way to build a
                // string *inside* an expression — a template can concatenate
                // around `${…}`, but not within a branch of `if(…)`, which is
                // what a conditional unit ("45 °C" vs "—") needs.
                return .string(args.map(\.stringified).joined())
            case "text.truncate":
                guard let text = args.first?.stringValue else { return .string("") }
                let limit = Self.clampedInt(args.dropFirst().first?.numberValue ?? 0)
                if limit <= 0 || text.count <= limit { return .string(text) }
                return .string(String(text.prefix(limit)) + "…")

            // MARK: logic — condition + branches
            case "if":
                // if(cond, thenValue, elseValue). Args are eagerly evaluated
                // (the language is pure, so this only selects a value).
                guard args.count >= 2 else { return .null }
                return Self.truthy(args[0]) ? args[1] : (args.count >= 3 ? args[2] : .null)
            case "not":
                return .bool(!Self.truthy(args.first ?? .null))
            case "and":
                return .bool(args.allSatisfy(Self.truthy))
            case "or":
                return .bool(args.contains(where: Self.truthy))
            case "default":
                // default(value, fallback) — fallback when value is falsy.
                let value = args.first ?? .null
                return Self.truthy(value) ? value : (args.dropFirst().first ?? .null)

            // MARK: comparison
            case "eq":
                return .bool(args.count >= 2 && args[0] == args[1])
            case "ne":
                return .bool(args.count >= 2 && args[0] != args[1])
            case "gt", "gte", "lt", "lte":
                guard args.count >= 2 else { return .bool(false) }
                return .bool(Self.compare(name, args[0], args[1]))
            case "contains":
                // contains(haystack, needle) — substring or array membership.
                guard args.count >= 2 else { return .bool(false) }
                if case let .array(items) = args[0] { return .bool(items.contains(args[1])) }
                let haystack = args[0].stringified
                return .bool(haystack.contains(args[1].stringified))

            // MARK: arithmetic
            case "add", "sub", "mul", "div":
                let lhs = Self.asNumber(args.first) ?? 0
                let rhs = Self.asNumber(args.dropFirst().first) ?? 0
                switch name {
                case "add": return .number(lhs + rhs)
                case "sub": return .number(lhs - rhs)
                case "mul": return .number(lhs * rhs)
                default: return .number(rhs == 0 ? 0 : lhs / rhs)
                }
            case "min", "max":
                let numbers = args.compactMap(Self.asNumber)
                guard let first = numbers.first else { return .null }
                return .number(name == "min" ? numbers.min() ?? first : numbers.max() ?? first)
            case "round":
                guard let value = Self.asNumber(args.first) else { return .null }
                let digits = Self.clampedInt(Self.asNumber(args.dropFirst().first) ?? 0)
                if digits <= 0 { return .number(value.rounded()) }
                let factor = pow(10.0, Double(digits))
                return .number((value * factor).rounded() / factor)
            case "number":
                return Self.asNumber(args.first).map { JSONValue.number($0) } ?? .null

            default:
                throw WorkflowError.unknownFunction(name)
            }
        }

        /// Falsy: null, false, 0, "", empty array, empty object. Everything else
        /// is truthy — mirrors the intuition for `if`/`and`/`or`/`default`.
        static func truthy(_ value: JSONValue) -> Bool {
            switch value {
            case .null: return false
            case let .bool(flag): return flag
            case let .number(number): return number != 0
            case let .string(text): return !text.isEmpty
            case let .array(items): return !items.isEmpty
            case let .object(object): return !object.isEmpty
            }
        }

        /// Numeric coercion that also parses numeric strings (CLI output often
        /// arrives as `"42"`), so `add(field, 1)` works without a cast.
        static func asNumber(_ value: JSONValue?) -> Double? {
            guard let value else { return nil }
            if let number = value.numberValue { return number }
            if let string = value.stringValue { return Double(string) }
            if let flag = value.boolValue { return flag ? 1 : 0 }
            return nil
        }

        /// Ordered comparison: numeric when both coerce to numbers, else a
        /// lexical compare of the stringified operands.
        static func compare(_ op: String, _ lhs: JSONValue, _ rhs: JSONValue) -> Bool {
            let ordering: Int
            if let ln = asNumber(lhs), let rn = asNumber(rhs) {
                ordering = ln < rn ? -1 : (ln > rn ? 1 : 0)
            } else {
                let ls = lhs.stringified, rs = rhs.stringified
                ordering = ls < rs ? -1 : (ls > rs ? 1 : 0)
            }
            switch op {
            case "gt": return ordering > 0
            case "gte": return ordering >= 0
            case "lt": return ordering < 0
            case "lte": return ordering <= 0
            default: return false
            }
        }

        static func relative(fromMs: Double, nowMs: Double) -> String {
            let seconds = max(0, (nowMs - fromMs) / 1000)
            if seconds < 60 { return "just now" }
            // A finite-but-huge delta (e.g. `date.relative(-1e300)`) overflows a
            // plain `Int(seconds / 60)`; clamp so it degrades instead of trapping.
            let minutes = clampedInt(seconds / 60)
            if minutes < 60 { return "\(minutes)m ago" }
            let hours = minutes / 60
            if hours < 24 { return "\(hours)h ago" }
            return "\(hours / 24)d ago"
        }

        // MARK: path resolution

        private mutating func resolvePath(_ raw: String) throws -> JSONValue {
            var path = raw
            if path.hasPrefix("$.") { path.removeFirst(2) }
            let segments = path.split(separator: ".").map(String.init)
            guard let head = segments.first else { throw WorkflowError.badExpression(raw) }

            var value: JSONValue
            var tail: ArraySlice<String>
            if let scoped = scopes.reversed().first(where: { $0[head] != nil })?[head] {
                value = scoped
                tail = segments.dropFirst()
            } else if head == "transforms", segments.count > 1 {
                value = try resolveTransform(segments[1])
                tail = segments.dropFirst(2)
            } else if let rooted = root[head] {
                value = rooted
                tail = segments.dropFirst()
            } else {
                throw WorkflowError.badExpression(raw)
            }

            for segment in tail {
                if case let .object(object) = value, let next = object[segment] {
                    value = next
                } else if case let .array(items) = value,
                          let index = Int(segment), index >= 0, index < items.count {
                    // Numeric segment indexes into an array (e.g. `result.0.meta`).
                    value = items[index]
                } else {
                    return .null
                }
            }
            return value
        }

        // MARK: transforms (lazy, cycle-guarded)

        private mutating func resolveTransform(_ id: String) throws -> JSONValue {
            if let cached = resolvedTransforms[id] { return cached }
            guard let transform = transforms[id] else { throw WorkflowError.unknownTransform(id) }
            guard resolvingTransforms.insert(id).inserted else { throw WorkflowError.transformCycle(id) }
            defer { resolvingTransforms.remove(id) }

            var input: JSONValue = .null
            if let from = transform.from {
                input = try evaluateExpression(from)
            }
            let params = try expand(transform.with ?? .object([:]))
            let output = try apply(transform.use, input: input, params: params)
            resolvedTransforms[id] = output
            return output
        }

        private func apply(_ use: String, input: JSONValue, params: JSONValue) throws -> JSONValue {
            switch use {
            case "assign":
                return input
            case "limit":
                guard case let .array(items) = input else { return input }
                let count = Self.clampedInt(params.objectValue?["count"]?.numberValue ?? 0)
                guard count > 0 else { return input }
                return .array(Array(items.prefix(count)))
            case "filter":
                guard case let .array(items) = input,
                      let field = params.objectValue?["field"]?.stringValue else { return input }
                let equals = params.objectValue?["equals"]
                let notEquals = params.objectValue?["notEquals"]
                return .array(items.filter { item in
                    let value = item.objectValue?[field] ?? .null
                    if let expected = equals { return value == expected }
                    if let excluded = notEquals { return value != excluded }
                    return true
                })
            case "sort":
                guard case let .array(items) = input,
                      let by = params.objectValue?["by"]?.stringValue else { return input }
                let descending = params.objectValue?["direction"]?.stringValue == "descending"
                let sorted = items.sorted { lhs, rhs in
                    let left = lhs.objectValue?[by] ?? .null
                    let right = rhs.objectValue?[by] ?? .null
                    let ascending: Bool
                    if let ln = left.numberValue, let rn = right.numberValue {
                        ascending = ln < rn
                    } else {
                        ascending = (left.stringValue ?? "") < (right.stringValue ?? "")
                    }
                    return descending ? !ascending : ascending
                }
                return .array(sorted)
            default:
                throw WorkflowError.unknownTransform(use)
            }
        }
    }
}

// MARK: - http workflow source (R12)

/// `http` workflow source: fetches a JSON document that then feeds the same
/// transform/template pipeline as `exec`/`fs.directory` sources.
///
/// Security contract (matches the manifest `network` permission gate enforced
/// by the host): GET only, **https only**, no redirect downgrade to a
/// non-https URL, a 20 s timeout, a 5 MB response cap, and a default
/// `Accept: application/json` header (overridable per request).
public enum HttpSource {
    public static let timeoutSec: TimeInterval = 20
    public static let maxResponseBytes = 5 * 1024 * 1024

    public struct Params: Sendable, Equatable {
        public var url: String
        public var headers: [String: String]

        public init(url: String, headers: [String: String] = [:]) {
            self.url = url
            self.headers = headers
        }

        /// Parses the interpolated source `with` object.
        public init(from params: JSONValue) throws {
            guard let object = params.objectValue,
                  let url = object["url"]?.stringValue,
                  !url.trimmingCharacters(in: .whitespaces).isEmpty
            else { throw HttpSourceError.missingURL }
            self.url = url
            var headers: [String: String] = [:]
            if case let .object(rawHeaders)? = object["headers"] {
                for (key, value) in rawHeaders {
                    if let string = value.stringValue { headers[key] = string }
                }
            }
            self.headers = headers
        }
    }

    public enum HttpSourceError: Error, LocalizedError, Equatable {
        case missingURL
        case notHTTPS(String)
        case invalidURL(String)
        case notHTTP
        case httpStatus(Int)
        case responseTooLarge(limitBytes: Int)
        case invalidJSON(String)

        public var errorDescription: String? {
            switch self {
            case .missingURL: return "http source needs a non-empty \"url\""
            case let .notHTTPS(url): return "http source requires https:// (got \(url))"
            case let .invalidURL(url): return "invalid http source url: \(url)"
            case .notHTTP: return "http source received a non-HTTP response"
            case let .httpStatus(code): return "http source failed (HTTP \(code))"
            case let .responseTooLarge(limit):
                return "http response exceeds the \(limit / (1024 * 1024)) MB limit"
            case let .invalidJSON(detail): return "http response is not valid JSON: \(detail)"
            }
        }
    }

    /// Blocks redirects that downgrade or leave the approved origin. The host
    /// checks the initial URL against the widget allowlist; keeping every hop
    /// same-origin makes that authorization valid for the whole request.
    private final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private let origin: URL

        init(origin: URL) { self.origin = origin }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            if let destination = request.url,
               HttpSource.redirectAllowed(from: origin, to: destination) {
                completionHandler(request)
            } else {
                completionHandler(nil) // stop — no downgrade to http
            }
        }
    }

    static func redirectAllowed(from origin: URL, to destination: URL) -> Bool {
        guard origin.scheme?.lowercased() == "https",
              destination.scheme?.lowercased() == "https",
              origin.host?.lowercased() == destination.host?.lowercased()
        else { return false }
        return (origin.port ?? 443) == (destination.port ?? 443)
    }

    public static func fetch(
        _ params: Params,
        session: URLSession = .shared
    ) async throws -> JSONValue {
        guard let url = URL(string: params.url) else {
            throw HttpSourceError.invalidURL(params.url)
        }
        guard url.scheme?.lowercased() == "https" else {
            throw HttpSourceError.notHTTPS(params.url)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeoutSec
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (key, value) in params.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let guardDelegate = RedirectGuard(origin: url)
        let (bytes, response) = try await session.bytes(for: request, delegate: guardDelegate)
        guard let http = response as? HTTPURLResponse else {
            throw HttpSourceError.notHTTP
        }
        guard (200..<300).contains(http.statusCode) else {
            throw HttpSourceError.httpStatus(http.statusCode)
        }
        if http.expectedContentLength > Int64(maxResponseBytes) {
            throw HttpSourceError.responseTooLarge(limitBytes: maxResponseBytes)
        }

        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > maxResponseBytes {
                throw HttpSourceError.responseTooLarge(limitBytes: maxResponseBytes)
            }
        }

        do {
            return try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw HttpSourceError.invalidJSON(String(describing: error))
        }
    }
}

extension JSONValue {
    /// Human-readable form for `${}` string concatenation and status text.
    var stringified: String {
        switch self {
        case let .string(text): return text
        case let .number(value):
            return value == value.rounded() && abs(value) < 1e15
                ? String(Int(value))
                : String(value)
        case let .bool(flag): return flag ? "true" : "false"
        case .null: return ""
        case .array, .object:
            guard let data = try? JsonRpcCodec.makeEncoder().encode(self) else { return "" }
            return String(data: data, encoding: .utf8) ?? ""
        }
    }
}


// MARK: - Argument split cache

/// Argument lists already split, keyed by the text inside a call's parentheses.
///
/// Splitting walks the text character by character and rebuilds each argument
/// as a new string, and it runs for every call in every expression on every
/// refresh. A menu bar widget evaluates the same expressions every couple of
/// seconds all day — profiled, this split was the largest single cost of
/// evaluation. The result depends on nothing but the text, and the texts come
/// from workflow files, so the set is small and repeats exactly.
///
/// Bounded anyway: a runaway set of distinct expressions (a template that
/// interpolates into its own expression text) empties the cache instead of
/// growing it. Thread-safe — widgets evaluate concurrently off the main actor.
final class ArgumentSplitCache: @unchecked Sendable {
    static let shared = ArgumentSplitCache()
    static let limit = 4096

    private let lock = NSLock()
    private var entries: [String: [String]] = [:]

    func lookup(_ key: String) -> [String]? {
        lock.lock()
        defer { lock.unlock() }
        return entries[key]
    }

    func store(_ value: [String], for key: String) {
        lock.lock()
        defer { lock.unlock() }
        if entries.count >= Self.limit { entries.removeAll(keepingCapacity: true) }
        entries[key] = value
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }
}
