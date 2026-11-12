import Foundation

/// What an `optional` workflow source failed with, as data the view can
/// branch on (`errors.<id>`), instead of a refresh error that replaces the
/// whole card with the host's raw message.
///
/// Only failures of the data itself are caught: being offline, a timeout, an
/// HTTP status, a command that isn't installed or exited non-zero, a missing
/// file, unreadable JSON. Anything about permissions — a command, path or
/// host the manifest does not allow — still fails the refresh, so a widget
/// can never quietly route around what the user approved.
public struct WorkflowSourceFailure: Equatable, Sendable {
    public enum Kind: String, Sendable {
        /// No network: not connected, DNS failed, connection lost.
        case offline
        case timeout
        /// HTTP 429, or a CLI saying it was rate limited.
        case rateLimited
        /// HTTP 401/403, or a CLI asking to sign in.
        case auth
        /// HTTP 404, a file that isn't there, a command that isn't installed.
        case notFound
        /// The host answered but refused or failed (other HTTP status,
        /// connection refused).
        case unreachable
        /// A command exited non-zero for another reason.
        case exit
        /// The output was not what the source expected (bad JSON, too large).
        case invalid
    }

    public var kind: Kind
    /// HTTP status or process exit code, when there is one.
    public var code: Int?
    /// The command that was missing, for `notFound` from exec.
    public var command: String?
    /// One short line from the error (first line of stderr, clipped), for a
    /// tooltip or "Details". Not meant to be the card's headline.
    public var message: String

    public init(kind: Kind, code: Int? = nil, command: String? = nil, message: String) {
        self.kind = kind
        self.code = code
        self.command = command
        self.message = message
    }

    /// `{ "kind": …, "code": …, "command": …, "message": … }` for `errors.<id>`.
    public var value: JSONValue {
        var object: [String: JSONValue] = [
            "kind": .string(kind.rawValue),
            "message": .string(message),
        ]
        if let code { object["code"] = .number(Double(code)) }
        if let command { object["command"] = .string(command) }
        return .object(object)
    }

    static let messageLimit = 160

    /// The failure an optional source reports, or nil when the error must
    /// still fail the refresh (permissions, a malformed source, cancellation).
    public static func classify(_ error: Error) -> WorkflowSourceFailure? {
        if error is CancellationError { return nil }
        if let exec = error as? ExecService.ExecError {
            switch exec {
            case let .binaryNotFound(command, _):
                return .init(kind: .notFound, command: (command as NSString).lastPathComponent,
                             message: exec.errorDescription ?? "not found")
            case .timeout:
                return .init(kind: .timeout, message: exec.errorDescription ?? "timed out")
            case .outputTooLarge:
                return .init(kind: .invalid, message: exec.errorDescription ?? "output too large")
            case let .nonZeroExit(code, stderr):
                return .init(kind: kind(forOutput: stderr) ?? .exit, code: Int(code), message: clip(stderr))
            case .emptyCommand, .launchFailed:
                return nil
            }
        }
        if let http = error as? HttpSource.HttpSourceError {
            switch http {
            case let .httpStatus(code):
                return .init(kind: kind(forHTTPStatus: code), code: code,
                             message: http.errorDescription ?? "HTTP \(code)")
            case .invalidJSON, .responseTooLarge, .notHTTP:
                return .init(kind: .invalid, message: clip(http.errorDescription ?? "invalid response"))
            case .missingURL, .notHTTPS, .invalidURL:
                return nil
            }
        }
        if let url = error as? URLError {
            switch url.code {
            case .timedOut:
                return .init(kind: .timeout, message: url.localizedDescription)
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .dnsLookupFailed,
                 .dataNotAllowed, .internationalRoamingOff:
                return .init(kind: .offline, message: url.localizedDescription)
            case .cannotConnectToHost, .secureConnectionFailed, .badServerResponse:
                return .init(kind: .unreachable, message: url.localizedDescription)
            default:
                return nil
            }
        }
        if let file = error as? FileSource.FileSourceError {
            switch file {
            case .notADirectory, .notARegularFile:
                return .init(kind: .notFound, message: file.errorDescription ?? "not found")
            case let .posix(_, code) where code == ENOENT || code == ENOTDIR:
                return .init(kind: .notFound, message: file.errorDescription ?? "not found")
            case .tooLarge:
                return .init(kind: .invalid, message: file.errorDescription ?? "too large")
            default:
                return nil
            }
        }
        if error is DecodingError {
            return .init(kind: .invalid, message: "output is not valid JSON")
        }
        // JSONSerialization's own "not JSON" error (exec output, fs.json).
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, ns.code == NSPropertyListReadCorruptError {
            return .init(kind: .invalid, message: "output is not valid JSON")
        }
        return nil
    }

    public static func kind(forHTTPStatus code: Int) -> Kind {
        switch code {
        case 401, 403: return .auth
        case 404, 410: return .notFound
        case 429: return .rateLimited
        default: return .unreachable
        }
    }

    /// Reads a CLI's stderr for the failures people can act on. Order
    /// matters: an auth helper that can't reach the network says both.
    public static func kind(forOutput text: String) -> Kind? {
        let lower = text.lowercased()
        if offlineMarkers.contains(where: lower.contains) { return .offline }
        if authMarkers.contains(where: lower.contains) { return .auth }
        if lower.contains("rate limit") || lower.contains("too many requests") { return .rateLimited }
        if lower.contains("timed out") || lower.contains("timeout") { return .timeout }
        if lower.contains("connection refused") || lower.contains("unable to connect to the server")
            || lower.contains("cannot connect") { return .unreachable }
        return nil
    }

    static let offlineMarkers = [
        "could not resolve host", "could not resolve hostname", "no such host",
        "network is unreachable", "not connected to the internet", "temporary failure in name resolution",
        "nodename nor servname",
    ]

    static let authMarkers = [
        "auth login", "not logged in", "not logged into", "login required", "please log in",
        "please login", "unauthorized", "authentication required", "authentication failed",
        "nocredentials", "unable to locate credentials", "getting credentials", "token has expired",
        "expired token", "sso session", "permission denied (publickey",
    ]

    /// First non-empty line, clipped.
    static func clip(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        return line.count > messageLimit ? String(line.prefix(messageLimit - 1)) + "…" : line
    }
}
