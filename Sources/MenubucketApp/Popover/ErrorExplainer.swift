import Foundation

/// What went wrong with a widget's refresh, in words a person can act on.
struct ErrorExplanation: Equatable {
    enum Kind: Equatable {
        case commandNotFound(String?)
        case timedOut
        case httpStatus(Int)
        case networkUnreachable
        case invalidJSON
        case permissionDenied
        case exitCode(Int)
        case generic
    }

    let kind: Kind
    /// One line: what happened.
    let cause: String
    /// One line: what to try.
    let fix: String
}

/// Turns the raw error a refresh produced — an exec, HTTP, JSON, or script
/// message — into a cause and a suggested fix. The raw text stays available
/// behind "Details"; this is what the card leads with.
///
/// Pure and string-based on purpose: errors reach the card as the message the
/// runtime stored in the snapshot, after crossing process and cache
/// boundaries, so there is no typed error left to switch on.
enum ErrorExplainer {
    static func explain(_ raw: String) -> ErrorExplanation {
        let text = raw.lowercased()

        if let command = commandNotFound(in: raw, lowercased: text) {
            let cause = command.map { String(localized: "The command “\($0)” isn’t installed on this Mac.") }
                ?? String(localized: "A command this widget needs isn’t installed on this Mac.")
            return ErrorExplanation(
                kind: .commandNotFound(command),
                cause: cause,
                fix: String(localized: "Install it (for example with Homebrew), then retry.")
            )
        }

        if text.contains("timed out") || text.contains("timeout") {
            return ErrorExplanation(
                kind: .timedOut,
                cause: String(localized: "The widget took too long to answer."),
                fix: String(localized: "Check the network or the service it reads, then retry.")
            )
        }

        if let code = httpStatus(in: text) {
            return ErrorExplanation(kind: .httpStatus(code), cause: httpCause(code), fix: httpFix(code))
        }

        if networkMarkers.contains(where: text.contains) {
            return ErrorExplanation(
                kind: .networkUnreachable,
                cause: String(localized: "The server couldn’t be reached."),
                fix: String(localized: "Check your internet connection, then retry.")
            )
        }

        if jsonMarkers.contains(where: text.contains) {
            return ErrorExplanation(
                kind: .invalidJSON,
                cause: String(localized: "The widget got data it couldn’t read."),
                fix: String(localized: "The source may have changed its format. Check for a widget update.")
            )
        }

        if permissionMarkers.contains(where: text.contains) {
            return ErrorExplanation(
                kind: .permissionDenied,
                cause: String(localized: "macOS or the widget’s permissions blocked this."),
                fix: String(localized: "Review the widget’s permissions in Settings, or allow access in System Settings › Privacy & Security.")
            )
        }

        if let code = exitCode(in: text) {
            return ErrorExplanation(
                kind: .exitCode(code),
                cause: String(localized: "The widget’s command failed (exit code \(code))."),
                fix: String(localized: "Open Details to see what it printed, then retry.")
            )
        }

        return ErrorExplanation(
            kind: .generic,
            cause: String(localized: "This widget couldn’t refresh."),
            fix: String(localized: "Retry, or open Details to see the full message.")
        )
    }

    // MARK: - Classifiers

    private static let networkMarkers = [
        "offline", "not connected to the internet", "could not connect",
        "couldn’t connect", "could not be found", "hostname", "network connection was lost",
        "network is unreachable", "nsurlerrordomain", "connection refused", "dns",
    ]

    private static let jsonMarkers = [
        "not valid json", "invalid json", "json", "isn’t in the correct format",
        "isn't in the correct format", "unexpected character", "decod",
    ]

    private static let permissionMarkers = [
        "permission denied", "operation not permitted", "not permitted by manifest",
        "not allowed", "eacces", "eperm", "access denied",
    ]

    /// `'gh' not found (searched: …)`, `zsh: command not found: gh`,
    /// `env: gh: No such file or directory`. The command name when it can be
    /// read out, `.some(nil)` when the error is this kind but nameless.
    private static func commandNotFound(in raw: String, lowercased text: String) -> String?? {
        if let match = raw.firstMatch(of: #/'([^']+)' not found/#) {
            return .some(String(match.1))
        }
        if let match = raw.firstMatch(of: #/command not found:\s*(\S+)/#) {
            return .some(String(match.1))
        }
        if text.contains("command not found") || text.contains("executable not found") {
            return .some(nil)
        }
        if let match = raw.firstMatch(of: #/(?:env: )?([\w.\-\/]+): No such file or directory/#) {
            return .some(String(match.1))
        }
        return nil
    }

    /// `HTTP 404`, `(HTTP 503)`, `status code 401`.
    private static func httpStatus(in text: String) -> Int? {
        if let match = text.firstMatch(of: #/http\s*(\d{3})/#) { return Int(match.1) }
        if let match = text.firstMatch(of: #/status(?: code)?[:\s]+(\d{3})/#) { return Int(match.1) }
        return nil
    }

    /// `exited with code 2`, `exit status 1`, `exit code 127`.
    private static func exitCode(in text: String) -> Int? {
        guard let match = text.firstMatch(of: #/exit(?:ed)?(?: with)? (?:code|status) (-?\d+)/#) else { return nil }
        return Int(match.1)
    }

    private static func httpCause(_ code: Int) -> String {
        switch code {
        case 401, 403: return String(localized: "The server refused the request (HTTP \(code)).")
        case 404: return String(localized: "The address this widget reads wasn’t found (HTTP 404).")
        case 429: return String(localized: "The server is limiting requests (HTTP 429).")
        case 500...599: return String(localized: "The server had a problem (HTTP \(code)).")
        default: return String(localized: "The server answered with an error (HTTP \(code)).")
        }
    }

    private static func httpFix(_ code: Int) -> String {
        switch code {
        case 401, 403: return String(localized: "Check the widget’s token or API key in Settings.")
        case 404: return String(localized: "Check the address in the widget’s Settings.")
        case 429: return String(localized: "Wait a little; BarShelf retries on its own.")
        case 500...599: return String(localized: "This is usually temporary. Retry in a few minutes.")
        default: return String(localized: "Check the widget’s Settings, then retry.")
        }
    }
}
