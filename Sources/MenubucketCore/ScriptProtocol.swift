import Foundation

// MARK: - Script runtime protocol v1 (common contract, R03)
//
// Transport: newline-delimited JSON-RPC 2.0 over stdio (one line = one message).
//
// Host → Script (notifications):
//   widget.load   {widgetId, reason: "install"|"open"|"manual"|"timer"|"interval",
//                  now, locale, appearance: "light"|"dark", settings, lastRenderRevision}
//   widget.action {actionId, payload, now}
//   widget.timer  {id, now}
//
// Script → Host (requests, id required; host answers with result or error):
//   host.render        {root, status?, nextRefreshAt?, cacheTtlMs?, sensitive?} → {revision}
//   host.exec.run      {command, args, parse?, timeoutMs?, sensitive?, env?}
//                      → {exitCode, stdout, stderr, json?, durationMs}
//   host.storage.get/set/delete/list  {key, value?, prefix?} → value / key list
//   host.secret.get/set               {key, value?}
//   host.timer.once/after/every/clear {id, atMs?/delayMs?/intervalMs?}
//   host.notify.show   {title, body?}
//   host.log           {level, message}
//
// Error codes: -32001 PermissionDenied, -32002 ExecNotFound, -32003 Timeout,
//              -32004 QuotaExceeded, -32005 ProtocolError.

public enum ScriptMethod {
    // Host → Script notifications
    public static let widgetLoad = "widget.load"
    public static let widgetAction = "widget.action"
    public static let widgetTimer = "widget.timer"

    // Script → Host requests
    public static let hostRender = "host.render"
    public static let hostExecRun = "host.exec.run"
    public static let hostStorageGet = "host.storage.get"
    public static let hostStorageSet = "host.storage.set"
    public static let hostStorageDelete = "host.storage.delete"
    public static let hostStorageList = "host.storage.list"
    public static let hostSecretGet = "host.secret.get"
    public static let hostSecretSet = "host.secret.set"
    public static let hostTimerOnce = "host.timer.once"
    public static let hostTimerAfter = "host.timer.after"
    public static let hostTimerEvery = "host.timer.every"
    public static let hostTimerClear = "host.timer.clear"
    public static let hostNotifyShow = "host.notify.show"
    public static let hostLog = "host.log"
}

/// `widget.load` reasons.
public enum WidgetLoadReason: String, Codable, Sendable {
    case install, open, manual, timer, interval
}

public struct WidgetLoadParams: Codable, Equatable, Sendable {
    public var widgetId: String
    public var reason: String
    public var now: Double
    public var locale: String
    public var appearance: String
    public var settings: JSONValue?
    public var lastRenderRevision: Int?

    public init(
        widgetId: String,
        reason: String,
        now: Double,
        locale: String,
        appearance: String,
        settings: JSONValue? = nil,
        lastRenderRevision: Int? = nil
    ) {
        self.widgetId = widgetId
        self.reason = reason
        self.now = now
        self.locale = locale
        self.appearance = appearance
        self.settings = settings
        self.lastRenderRevision = lastRenderRevision
    }
}

public struct WidgetActionParams: Codable, Equatable, Sendable {
    public var actionId: String
    public var payload: JSONValue?
    public var now: Double

    public init(actionId: String, payload: JSONValue? = nil, now: Double) {
        self.actionId = actionId
        self.payload = payload
        self.now = now
    }
}

public struct WidgetTimerParams: Codable, Equatable, Sendable {
    public var id: String
    public var now: Double

    public init(id: String, now: Double) {
        self.id = id
        self.now = now
    }
}

// MARK: host.render

public struct RenderStatus: Codable, Equatable, Sendable {
    public var label: String?
    public var tooltip: String?

    public init(label: String? = nil, tooltip: String? = nil) {
        self.label = label
        self.tooltip = tooltip
    }
}

public struct RenderParams: Codable, Equatable, Sendable {
    public var root: UINode
    public var status: RenderStatus?
    public var nextRefreshAt: Double?
    public var cacheTtlMs: Double?
    public var sensitive: Bool?

    public init(
        root: UINode,
        status: RenderStatus? = nil,
        nextRefreshAt: Double? = nil,
        cacheTtlMs: Double? = nil,
        sensitive: Bool? = nil
    ) {
        self.root = root
        self.status = status
        self.nextRefreshAt = nextRefreshAt
        self.cacheTtlMs = cacheTtlMs
        self.sensitive = sensitive
    }
}

public struct RenderResult: Codable, Equatable, Sendable {
    public var revision: Int

    public init(revision: Int) {
        self.revision = revision
    }
}

// MARK: host.exec.run

public struct ExecRunParams: Codable, Equatable, Sendable {
    public var command: String
    public var args: [String]?
    /// "text" | "json" | "lines"
    public var parse: String?
    public var timeoutMs: Int?
    public var sensitive: Bool?
    public var env: [String: String]?

    public init(
        command: String,
        args: [String]? = nil,
        parse: String? = nil,
        timeoutMs: Int? = nil,
        sensitive: Bool? = nil,
        env: [String: String]? = nil
    ) {
        self.command = command
        self.args = args
        self.parse = parse
        self.timeoutMs = timeoutMs
        self.sensitive = sensitive
        self.env = env
    }
}

public struct ExecRunResult: Codable, Equatable, Sendable {
    public var exitCode: Int
    public var stdout: String
    public var stderr: String
    public var json: JSONValue?
    public var durationMs: Double

    public init(exitCode: Int, stdout: String, stderr: String, json: JSONValue? = nil, durationMs: Double) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.json = json
        self.durationMs = durationMs
    }
}

// MARK: host.storage.* / host.secret.*

public struct StorageParams: Codable, Equatable, Sendable {
    public var key: String?
    public var value: JSONValue?
    public var prefix: String?
    /// Optional TTL extension (SDK `storage.set` options).
    public var ttlMs: Double?

    public init(key: String? = nil, value: JSONValue? = nil, prefix: String? = nil, ttlMs: Double? = nil) {
        self.key = key
        self.value = value
        self.prefix = prefix
        self.ttlMs = ttlMs
    }
}

public struct SecretParams: Codable, Equatable, Sendable {
    public var key: String
    public var value: String?

    public init(key: String, value: String? = nil) {
        self.key = key
        self.value = value
    }
}

// MARK: host.timer.*

public struct TimerParams: Codable, Equatable, Sendable {
    public var id: String
    public var atMs: Double?
    public var delayMs: Double?
    public var intervalMs: Double?

    public init(id: String, atMs: Double? = nil, delayMs: Double? = nil, intervalMs: Double? = nil) {
        self.id = id
        self.atMs = atMs
        self.delayMs = delayMs
        self.intervalMs = intervalMs
    }
}

// MARK: host.notify.show / host.log

public struct NotifyParams: Codable, Equatable, Sendable {
    public var title: String
    public var body: String?

    public init(title: String, body: String? = nil) {
        self.title = title
        self.body = body
    }
}

public struct LogParams: Codable, Equatable, Sendable {
    /// "debug" | "info" | "warn" | "error"
    public var level: String
    public var message: String

    public init(level: String, message: String) {
        self.level = level
        self.message = message
    }
}

// MARK: - Manifest helpers

extension Manifest {
    /// Default settings object sent in `widget.load` (declared `settings[]`
    /// defaults; settings UI values will be layered on top in a later
    /// milestone).
    public func settingsDefaults() -> JSONValue {
        var object: [String: JSONValue] = [:]
        for setting in settings ?? [] {
            guard let key = setting.key else { continue }
            object[key] = setting.defaultValue ?? .null
        }
        return .object(object)
    }
}
