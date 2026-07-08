import Foundation

// MARK: - Definition (workflow.json)

/// Declarative workflow v1: host-executed `sources` → pure `transforms` →
/// `${...}`-templated `view`. No arbitrary code — the expression language is
/// paths + the built-in functions in `WorkflowEngine.call`.
public struct WorkflowDefinition: Codable, Sendable {
    public var schemaVersion: Int
    public var kind: String?
    public var sources: [String: SourceDef]
    public var transforms: [String: TransformDef]?
    public var view: JSONValue
    public var empty: JSONValue?
    public var status: StatusDef?

    public struct SourceDef: Codable, Sendable {
        public var use: String
        public var with: JSONValue?

        public init(use: String, with: JSONValue? = nil) {
            self.use = use
            self.with = with
        }
    }

    public struct TransformDef: Codable, Sendable {
        public var use: String
        public var from: String?
        public var with: JSONValue?
    }

    public struct StatusDef: Codable, Sendable {
        public var label: String?
        public var tooltip: String?
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
    public struct Output: Sendable {
        public var viewTree: UINode
        public var statusLabel: String?
        public var statusTooltip: String?
        /// Total items produced by every `forEach` expansion.
        public var expandedItemCount: Int
        /// True when zero items were expanded and the `empty` node was used.
        public var usedEmpty: Bool
    }

    /// Phase 1 — interpolates each source's `with` params against `settings`
    /// so the caller can execute the I/O (exec / fs.directory).
    public static func resolvedSourceParams(
        _ definition: WorkflowDefinition,
        settings: JSONValue,
        nowMs: Double = Date().timeIntervalSince1970 * 1000
    ) throws -> [String: JSONValue] {
        var context = Context(
            root: ["settings": settings, "sources": .object([:]), "transforms": .object([:])],
            transforms: [:],
            nowMs: nowMs
        )
        var resolved: [String: JSONValue] = [:]
        for (id, source) in definition.sources {
            resolved[id] = try context.expand(source.with ?? .object([:]))
        }
        return resolved
    }

    /// Phase 2 — runs transforms and expands the view template.
    public static func evaluate(
        _ definition: WorkflowDefinition,
        sources: [String: JSONValue],
        settings: JSONValue,
        nowMs: Double = Date().timeIntervalSince1970 * 1000
    ) throws -> Output {
        var context = Context(
            root: [
                "settings": settings,
                "sources": .object(sources),
                "transforms": .object([:]),
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
        if let status = definition.status {
            if let label = status.label {
                statusLabel = try context.interpolate(label).stringified
            }
            if let tooltip = status.tooltip {
                statusTooltip = try context.interpolate(tooltip).stringified
            }
        }

        return Output(
            viewTree: viewTree,
            statusLabel: statusLabel,
            statusTooltip: statusTooltip,
            expandedItemCount: context.expandedItemCount,
            usedEmpty: usedEmpty
        )
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

        private func splitArguments(_ inner: String) throws -> [String] {
            let trimmed = inner.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return [] }
            var args: [String] = []
            var depth = 0
            var current = ""
            for char in trimmed {
                switch char {
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
            case "text.truncate":
                guard let text = args.first?.stringValue else { return .string("") }
                let limit = Self.clampedInt(args.dropFirst().first?.numberValue ?? 0)
                if limit <= 0 || text.count <= limit { return .string(text) }
                return .string(String(text.prefix(limit)) + "…")
            default:
                throw WorkflowError.unknownFunction(name)
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
                guard case let .object(object) = value, let next = object[segment] else {
                    return .null
                }
                value = next
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
