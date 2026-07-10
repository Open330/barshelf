import Foundation

/// What a builtin adapter produces from raw source output (M1 contract).
public struct AdapterResult {
    /// The rendered tree (always present — adapters throw on hard failure).
    public var viewTree: UINode
    /// Deadline trigger: re-run the source exactly once at this epoch-ms time
    /// (host cancels the timer while the popup is closed).
    public var nextRefreshAtMs: Double?
    /// Menu-bar (XS) text candidate — decoded now, displayed in M2.
    public var statusText: String?

    public init(viewTree: UINode, nextRefreshAtMs: Double? = nil, statusText: String? = nil) {
        self.viewTree = viewTree
        self.nextRefreshAtMs = nextRefreshAtMs
        self.statusText = statusText
    }
}

extension AdapterResult: Sendable {}

/// Host services available to an adapter while it transforms source output.
///
/// `runAllowed` may only execute commands matching the widget manifest's
/// `permissions.exec` allowlist; the host injects declared env vars
/// (including Keychain-backed secrets) into the child process.
public protocol AdapterContext: Sendable {
    /// Effective manifest defaults overlaid with the user's saved settings.
    var settings: [String: JSONValue] { get }
    /// Runs `command` (argv, no shell) if the allowlist permits it and returns
    /// the process stdout. Throws `AdapterError.execNotAllowed` on a mismatch.
    func runAllowed(command: [String]) async throws -> Data
}

public extension AdapterContext {
    /// Backward-compatible default for adapters and test contexts that do not
    /// consume settings.
    var settings: [String: JSONValue] { [:] }
}

public enum AdapterError: Error, LocalizedError, Equatable {
    case execNotAllowed(String)
    case invalidPayload(String)
    case message(String)

    public var errorDescription: String? {
        switch self {
        case let .execNotAllowed(command):
            return "command not permitted by manifest allowlist: \(command)"
        case let .invalidPayload(detail):
            return detail
        case let .message(detail):
            return detail
        }
    }
}
