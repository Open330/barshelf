import Foundation

/// Widget manifest (`widget.json`) — full schema v0.1 (M1).
///
/// Unknown top-level keys (e.g. `version`, `$schema`, future fields) are
/// tolerated: `JSONDecoder` ignores keys that are not declared here.
public struct Manifest: Codable, Equatable {
    public var schemaVersion: Int
    public var id: String
    public var name: String
    public var icon: String?
    public var bucket: Bucket?
    public var entry: Entry
    public var source: Source?
    public var refresh: Refresh?
    /// M1: decoded, only `mode: "none"` is honored (display is M2).
    public var statusItem: StatusItem?
    public var permissions: Permissions?
    /// M1: decode-only (settings UI is M2).
    public var settings: [Setting]?
    /// R12: author-provided default theming. Lenient decode (invalid values →
    /// nil fields, never a decode failure) via `WidgetAppearance`.
    public var appearance: WidgetAppearance?

    public init(
        schemaVersion: Int,
        id: String,
        name: String,
        icon: String? = nil,
        bucket: Bucket? = nil,
        entry: Entry,
        source: Source? = nil,
        refresh: Refresh? = nil,
        statusItem: StatusItem? = nil,
        permissions: Permissions? = nil,
        settings: [Setting]? = nil,
        appearance: WidgetAppearance? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.name = name
        self.icon = icon
        self.bucket = bucket
        self.entry = entry
        self.source = source
        self.refresh = refresh
        self.statusItem = statusItem
        self.permissions = permissions
        self.settings = settings
        self.appearance = appearance
    }

    public struct Bucket: Codable, Equatable {
        public var group: String?
        public var order: Int?
        /// "XS" | "S" | "M" | "L"
        public var size: String?

        public init(group: String? = nil, order: Int? = nil, size: String? = nil) {
            self.group = group
            self.order = order
            self.size = size
        }
    }

    public struct Entry: Codable, Equatable {
        /// "exec" | "script" | "workflow" | "builtin" (M2 handles exec/script/workflow)
        public var kind: String
        /// Script runtime identifier — v1 supports `"deno-ts@1"` only.
        public var runtime: String?
        /// Entry file relative to the widget directory. Defaults:
        /// script → "index.ts", workflow → "workflow.json".
        public var main: String?

        public init(kind: String, runtime: String? = nil, main: String? = nil) {
            self.kind = kind
            self.runtime = runtime
            self.main = main
        }
    }

    public struct Source: Codable, Equatable {
        public var kind: String?
        public var command: [String]?
        /// Binary discovery candidates: "$ENVVAR", "~/abs/path", "/abs/path", "PATH".
        public var discover: [String]?
        public var timeoutMs: Int?
        /// "viewtree" | "data"
        public var output: String?
        /// Builtin adapter name when `output == "data"`.
        public var adapter: String?

        public init(
            kind: String? = nil,
            command: [String]? = nil,
            discover: [String]? = nil,
            timeoutMs: Int? = nil,
            output: String? = nil,
            adapter: String? = nil
        ) {
            self.kind = kind
            self.command = command
            self.discover = discover
            self.timeoutMs = timeoutMs
            self.output = output
            self.adapter = adapter
        }
    }

    public struct Refresh: Codable, Equatable {
        public var onOpen: Bool?
        /// Seconds. `null` (nil) = no interval polling (cache-first default).
        public var interval: Double?
        public var staleAfterSec: Double?
        /// Reserved (unused): adapters return `nextRefreshAtMs` instead.
        public var deadlineField: String?
        /// FSEvents-watched paths (250 ms debounce). `~` expansion supported.
        public var watchPaths: [String]?
        /// Allow relaxed interval polling while the popup is closed.
        public var runInBackground: Bool?
        /// R12 event triggers (`refresh.triggers`). Lenient decode: the array
        /// accepts mixed strings and objects; unrecognized entries are dropped
        /// (never a decode failure). `nil` when the key is absent.
        public var triggers: [TriggerSpec]?

        public init(
            onOpen: Bool? = nil,
            interval: Double? = nil,
            staleAfterSec: Double? = nil,
            deadlineField: String? = nil,
            watchPaths: [String]? = nil,
            runInBackground: Bool? = nil,
            triggers: [TriggerSpec]? = nil
        ) {
            self.onOpen = onOpen
            self.interval = interval
            self.staleAfterSec = staleAfterSec
            self.deadlineField = deadlineField
            self.watchPaths = watchPaths
            self.runInBackground = runInBackground
            self.triggers = triggers
        }

        private enum CodingKeys: String, CodingKey {
            case onOpen, interval, staleAfterSec, deadlineField, watchPaths
            case runInBackground, triggers
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            onOpen = try container.decodeIfPresent(Bool.self, forKey: .onOpen)
            interval = try container.decodeIfPresent(Double.self, forKey: .interval)
            staleAfterSec = try container.decodeIfPresent(Double.self, forKey: .staleAfterSec)
            deadlineField = try container.decodeIfPresent(String.self, forKey: .deadlineField)
            watchPaths = try container.decodeIfPresent([String].self, forKey: .watchPaths)
            runInBackground = try container.decodeIfPresent(Bool.self, forKey: .runInBackground)
            // Lenient: decode as raw JSON first, then map each entry through
            // `TriggerSpec(json:)`, silently dropping anything unrecognized.
            if let raw = try container.decodeIfPresent([JSONValue].self, forKey: .triggers) {
                triggers = raw.compactMap(TriggerSpec.init(json:))
            } else {
                triggers = nil
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(onOpen, forKey: .onOpen)
            try container.encodeIfPresent(interval, forKey: .interval)
            try container.encodeIfPresent(staleAfterSec, forKey: .staleAfterSec)
            try container.encodeIfPresent(deadlineField, forKey: .deadlineField)
            try container.encodeIfPresent(watchPaths, forKey: .watchPaths)
            try container.encodeIfPresent(runInBackground, forKey: .runInBackground)
            try container.encodeIfPresent(triggers?.map(\.json), forKey: .triggers)
        }
    }

    /// Menu-bar (XS) promotion config. M1 decodes it; only "none" is active.
    public struct StatusItem: Codable, Equatable {
        /// "none" | "icon" | "text" | "dynamic"
        public var mode: String?
        public var icon: String?
        public var labelFrom: String?
        public var tooltipFrom: String?

        public init(
            mode: String? = nil,
            icon: String? = nil,
            labelFrom: String? = nil,
            tooltipFrom: String? = nil
        ) {
            self.mode = mode
            self.icon = icon
            self.labelFrom = labelFrom
            self.tooltipFrom = tooltipFrom
        }
    }

    public struct Permissions: Codable, Equatable {
        public var exec: [ExecPermission]?
        public var network: [String]?
        public var readPaths: [String]?
        /// Environment variable names the widget's processes may receive.
        public var env: [String]?
        /// Allow Keychain-backed secret injection into declared env vars.
        public var keychain: Bool?
        /// Allow `host.notify.show` (script runtime).
        public var notifications: Bool?

        public init(
            exec: [ExecPermission]? = nil,
            network: [String]? = nil,
            readPaths: [String]? = nil,
            env: [String]? = nil,
            keychain: Bool? = nil,
            notifications: Bool? = nil
        ) {
            self.exec = exec
            self.network = network
            self.readPaths = readPaths
            self.env = env
            self.keychain = keychain
            self.notifications = notifications
        }
    }

    /// One exec allowlist entry. `allowedArgs` is a list of argv patterns
    /// (excluding the command itself); `"*"` matches exactly one argument.
    public struct ExecPermission: Codable, Equatable {
        public var command: String
        public var allowedArgs: [[String]]?
        public var env: [String]?
        public var maxOutputBytes: Int?
        public var sensitiveOutput: Bool?

        public init(
            command: String,
            allowedArgs: [[String]]? = nil,
            env: [String]? = nil,
            maxOutputBytes: Int? = nil,
            sensitiveOutput: Bool? = nil
        ) {
            self.command = command
            self.allowedArgs = allowedArgs
            self.env = env
            self.maxOutputBytes = maxOutputBytes
            self.sensitiveOutput = sensitiveOutput
        }
    }

    /// Declarative widget setting (decode-only in M1; UI generated in M2).
    public struct Setting: Codable, Equatable {
        public var key: String?
        public var type: String?
        public var label: String?
        public var title: String?
        public var options: [String]?
        public var min: Double?
        public var max: Double?
        public var defaultValue: JSONValue?

        private enum CodingKeys: String, CodingKey {
            case key, type, label, title, options, min, max
            case defaultValue = "default"
        }

        public init(
            key: String? = nil,
            type: String? = nil,
            label: String? = nil,
            title: String? = nil,
            options: [String]? = nil,
            min: Double? = nil,
            max: Double? = nil,
            defaultValue: JSONValue? = nil
        ) {
            self.key = key
            self.type = type
            self.label = label
            self.title = title
            self.options = options
            self.min = min
            self.max = max
            self.defaultValue = defaultValue
        }
    }
}

/// R12 refresh trigger (`refresh.triggers`). The manifest array is decoded
/// leniently: strings map to the parameterless cases, `{ "fs": "<path>" }`
/// objects map to `.fs`, and anything else is dropped.
public enum TriggerSpec: Equatable, Sendable {
    /// `NSWorkspace.didWakeNotification`.
    case wake
    /// Every popup open (debounced ≥5 s per widget).
    case popupOpen
    /// Directory/file change (FSEvents), coalesced ~2 s. `~` expansion applies
    /// at watch time.
    case fs(path: String)
    /// `barshelf://refresh?widget=<id>`.
    case url

    /// Lenient parse of one manifest array entry (`nil` when unrecognized).
    public init?(json: JSONValue) {
        switch json {
        case let .string(token):
            switch token {
            case "wake": self = .wake
            case "popup-open", "popupOpen", "open": self = .popupOpen
            case "url": self = .url
            default: return nil
            }
        case let .object(object):
            guard case let .string(path)? = object["fs"],
                  !path.trimmingCharacters(in: .whitespaces).isEmpty
            else { return nil }
            self = .fs(path: path)
        default:
            return nil
        }
    }

    /// Canonical manifest form (round-trips through `init(json:)`).
    public var json: JSONValue {
        switch self {
        case .wake: return .string("wake")
        case .popupOpen: return .string("popup-open")
        case .url: return .string("url")
        case let .fs(path): return .object(["fs": .string(path)])
        }
    }
}

/// Minimal JSON value for schema fields whose type is intentionally open
/// (e.g. `settings[].default`).
public indirect enum JSONValue: Codable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
        } else if let object = try? container.decode([String: JSONValue].self) {
            self = .object(object)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "unsupported JSON value"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }
}

extension Manifest {
    public static func decode(from data: Data) throws -> Manifest {
        try JSONDecoder().decode(Manifest.self, from: data)
    }
}

extension Manifest: Sendable {}
extension Manifest.Bucket: Sendable {}
extension Manifest.Entry: Sendable {}
extension Manifest.Source: Sendable {}
extension Manifest.Refresh: Sendable {}
extension Manifest.StatusItem: Sendable {}
extension Manifest.Permissions: Sendable {}
extension Manifest.ExecPermission: Sendable {}
extension Manifest.Setting: Sendable {}
extension JSONValue: Sendable {}
