import Foundation

// MARK: - JSON-RPC 2.0 over newline-delimited stdio (protocol v1)
//
// Contract (R03 Task common contract): one line = one message. Script → host
// messages are requests (id required); host → script messages are
// notifications (widget.load / widget.action / widget.timer) plus responses
// to script requests.

/// JSON-RPC id — number or string.
public enum JsonRpcID: Codable, Equatable, Hashable, Sendable {
    case number(Int)
    case string(String)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intValue = try? container.decode(Int.self) {
            self = .number(intValue)
        } else if let doubleValue = try? container.decode(Double.self) {
            // A JSON number too large for `Int` (e.g. `1e19` or `9999999999999999999`)
            // decodes as `Double` here; `Int(_:)` would trap on the out-of-range
            // value. Untrusted script stdout can send such an id, so reject it
            // cleanly instead of crashing the host.
            guard doubleValue.isFinite,
                  doubleValue >= Double(Int.min),
                  doubleValue < Double(Int.max) else {
                throw DecodingError.dataCorruptedError(
                    in: container, debugDescription: "id number out of Int range"
                )
            }
            self = .number(Int(doubleValue))
        } else if let stringValue = try? container.decode(String.self) {
            self = .string(stringValue)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "id must be a number or string"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .number(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        }
    }
}

/// JSON-RPC error object. Protocol v1 error codes:
/// `-32001 PermissionDenied`, `-32002 ExecNotFound`, `-32003 Timeout`,
/// `-32004 QuotaExceeded`, `-32005 ProtocolError` (plus the standard codes).
public struct JsonRpcError: Error, Codable, Equatable, Sendable {
    public var code: Int
    public var message: String
    public var data: JSONValue?

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    // Standard JSON-RPC 2.0 codes.
    public static let parseErrorCode = -32700
    public static let invalidRequestCode = -32600
    public static let methodNotFoundCode = -32601
    public static let invalidParamsCode = -32602
    public static let internalErrorCode = -32603

    // Protocol v1 codes (common contract).
    public static let permissionDeniedCode = -32001
    public static let execNotFoundCode = -32002
    public static let timeoutCode = -32003
    public static let quotaExceededCode = -32004
    public static let protocolErrorCode = -32005

    public static func permissionDenied(_ message: String) -> JsonRpcError {
        JsonRpcError(code: permissionDeniedCode, message: message)
    }
    public static func execNotFound(_ message: String) -> JsonRpcError {
        JsonRpcError(code: execNotFoundCode, message: message)
    }
    public static func timeout(_ message: String) -> JsonRpcError {
        JsonRpcError(code: timeoutCode, message: message)
    }
    public static func quotaExceeded(_ message: String) -> JsonRpcError {
        JsonRpcError(code: quotaExceededCode, message: message)
    }
    public static func protocolError(_ message: String) -> JsonRpcError {
        JsonRpcError(code: protocolErrorCode, message: message)
    }
    public static func methodNotFound(_ method: String) -> JsonRpcError {
        JsonRpcError(code: methodNotFoundCode, message: "method not found: \(method)")
    }
    public static func internalError(_ message: String) -> JsonRpcError {
        JsonRpcError(code: internalErrorCode, message: message)
    }
}

/// A request (`id` set) or notification (`id` nil).
public struct JsonRpcRequest: Codable, Equatable, Sendable {
    public var jsonrpc: String
    public var id: JsonRpcID?
    public var method: String
    public var params: JSONValue?

    public init(id: JsonRpcID? = nil, method: String, params: JSONValue? = nil) {
        self.jsonrpc = "2.0"
        self.id = id
        self.method = method
        self.params = params
    }

    public var isNotification: Bool { id == nil }
}

/// A response carrying either `result` or `error` (never both).
public struct JsonRpcResponse: Codable, Equatable, Sendable {
    public var jsonrpc: String
    public var id: JsonRpcID?
    public var result: JSONValue?
    public var error: JsonRpcError?

    public init(id: JsonRpcID?, result: JSONValue) {
        self.jsonrpc = "2.0"
        self.id = id
        self.result = result
        self.error = nil
    }

    public init(id: JsonRpcID?, error: JsonRpcError) {
        self.jsonrpc = "2.0"
        self.id = id
        self.result = nil
        self.error = error
    }

    private enum CodingKeys: String, CodingKey {
        case jsonrpc, id, result, error
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        jsonrpc = try container.decode(String.self, forKey: .jsonrpc)
        id = try container.decodeIfPresent(JsonRpcID.self, forKey: .id)
        result = try container.decodeIfPresent(JSONValue.self, forKey: .result)
        error = try container.decodeIfPresent(JsonRpcError.self, forKey: .error)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(jsonrpc, forKey: .jsonrpc)
        try container.encode(id, forKey: .id) // JSON-RPC: id is required in responses (null on parse errors)
        if let error {
            try container.encode(error, forKey: .error)
        } else {
            try container.encode(result ?? .null, forKey: .result)
        }
    }
}

/// Either side of the wire.
public enum JsonRpcMessage: Equatable, Sendable {
    case request(JsonRpcRequest)
    case response(JsonRpcResponse)
}

/// Newline-delimited framing codec. Encoded messages are single-line, compact,
/// deterministic (sorted keys) JSON without a trailing newline — the transport
/// appends `\n`.
public enum JsonRpcCodec {
    /// Shared decoder/encoder settings for every protocol message.
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    public static func encode(_ message: JsonRpcMessage) throws -> Data {
        switch message {
        case let .request(request): return try makeEncoder().encode(request)
        case let .response(response): return try makeEncoder().encode(response)
        }
    }

    /// Decodes one line. Throws `JsonRpcError` with `parseErrorCode` /
    /// `invalidRequestCode` / `protocolErrorCode` on malformed input.
    public static func decode(line: Data) throws -> JsonRpcMessage {
        let value: JSONValue
        do {
            value = try JSONDecoder().decode(JSONValue.self, from: line)
        } catch {
            throw JsonRpcError(code: JsonRpcError.parseErrorCode, message: "invalid JSON: \(error)")
        }
        guard case let .object(object) = value else {
            throw JsonRpcError(code: JsonRpcError.invalidRequestCode, message: "message must be a JSON object")
        }
        guard case .string("2.0")? = object["jsonrpc"] else {
            throw JsonRpcError(code: JsonRpcError.invalidRequestCode, message: "jsonrpc must be \"2.0\"")
        }
        if object["method"] != nil {
            do {
                return .request(try JSONDecoder().decode(JsonRpcRequest.self, from: line))
            } catch {
                throw JsonRpcError(code: JsonRpcError.invalidRequestCode, message: "malformed request: \(error)")
            }
        }
        if object["result"] != nil || object["error"] != nil {
            do {
                return .response(try JSONDecoder().decode(JsonRpcResponse.self, from: line))
            } catch {
                throw JsonRpcError.protocolError("malformed response: \(error)")
            }
        }
        throw JsonRpcError(code: JsonRpcError.invalidRequestCode, message: "message has neither method nor result/error")
    }
}

// MARK: - Dispatcher

/// Method-table dispatcher for incoming requests/notifications.
///
/// Thrown `JsonRpcError`s map to error responses; any other error maps to
/// `internalError`. Notifications never produce a response (errors are
/// swallowed after the optional `onNotificationError` hook).
public final class JsonRpcDispatcher: @unchecked Sendable {
    public typealias Handler = @Sendable (JSONValue?) async throws -> JSONValue

    private let lock = NSLock()
    private var handlers: [String: Handler] = [:]
    public var onNotificationError: (@Sendable (String, Error) -> Void)?

    public init() {}

    public func register(method: String, handler: @escaping Handler) {
        lock.lock()
        defer { lock.unlock() }
        handlers[method] = handler
    }

    public func registeredMethods() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return Array(handlers.keys)
    }

    /// Routes one request. Returns nil for notifications.
    public func dispatch(_ request: JsonRpcRequest) async -> JsonRpcResponse? {
        let handler = lock.withLock { handlers[request.method] }

        guard let handler else {
            if request.isNotification {
                onNotificationError?(request.method, JsonRpcError.methodNotFound(request.method))
                return nil
            }
            return JsonRpcResponse(id: request.id, error: .methodNotFound(request.method))
        }

        do {
            let result = try await handler(request.params)
            return request.isNotification ? nil : JsonRpcResponse(id: request.id, result: result)
        } catch let error as JsonRpcError {
            if request.isNotification {
                onNotificationError?(request.method, error)
                return nil
            }
            return JsonRpcResponse(id: request.id, error: error)
        } catch {
            if request.isNotification {
                onNotificationError?(request.method, error)
                return nil
            }
            return JsonRpcResponse(id: request.id, error: .internalError(String(describing: error)))
        }
    }
}

// MARK: - JSONValue conveniences

extension JSONValue {
    public var objectValue: [String: JSONValue]? {
        if case let .object(value) = self { return value }
        return nil
    }
    public var arrayValue: [JSONValue]? {
        if case let .array(value) = self { return value }
        return nil
    }
    public var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }
    public var numberValue: Double? {
        if case let .number(value) = self { return value }
        return nil
    }
    public var boolValue: Bool? {
        if case let .bool(value) = self { return value }
        return nil
    }
    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }
    public subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }

    /// Bridges any `Encodable` into a `JSONValue` (via JSON round-trip).
    public static func bridged<T: Encodable>(_ value: T) throws -> JSONValue {
        let data = try JsonRpcCodec.makeEncoder().encode(value)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Decodes this JSON value into a `Decodable` type (via JSON round-trip).
    public func decoded<T: Decodable>(_ type: T.Type) throws -> T {
        let data = try JsonRpcCodec.makeEncoder().encode(self)
        return try JSONDecoder().decode(type, from: data)
    }
}
