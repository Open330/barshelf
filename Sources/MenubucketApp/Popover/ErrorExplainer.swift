import Foundation
import MenubucketCore

/// What went wrong with a widget's refresh, in words a person can act on.
struct ErrorExplanation: Equatable {
    enum Kind: Equatable {
        case commandNotFound(String?)
        case timedOut
        case httpStatus(Int)
        case networkUnreachable
        case invalidJSON
        case permissionDenied
        /// A CLI or service wants the user to sign in again.
        case signInRequired
        case rateLimited
        case manifestPermissionDenied
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
    /// What was being done when the error happened. The classification is
    /// the same everywhere; only the words that name the thing that failed
    /// change, so a failed install does not say "this widget couldn't
    /// refresh".
    enum Context: Equatable {
        /// A widget's refresh (the card, the menu bar, the Dock, VoiceOver).
        case refresh
        /// A button in a widget.
        case action
        /// Installing a widget from the gallery or a link.
        case install
        /// Checking for or installing a BarShelf update.
        case update
        /// A test run in the widget builder.
        case test
        /// Saving BarShelf's own settings.
        case save
    }

    static func explain(_ raw: String, context: Context = .refresh) -> ErrorExplanation {
        let text = raw.lowercased()
        // Kinds whose advice is about a widget (install a command it runs,
        // sign in to its tool, its data format, its permissions) apply only
        // where a widget ran. An install, an update check or a settings save
        // that happens to contain those words gets its own context's wording.
        let widgetRan = context == .refresh || context == .action || context == .test

        if widgetRan, text.contains("deno runtime not found") {
            return ErrorExplanation(kind: .commandNotFound("deno"),
                cause: String(localized: "This script widget needs Deno, which isn’t installed."),
                fix: String(localized: "Install Deno with “brew install deno”, then retry. Only script widgets need Deno."))
        }

        if widgetRan, text.contains("not covered by permissions.readpaths") {
            return ErrorExplanation(kind: .manifestPermissionDenied,
                cause: String(localized: "This folder is outside the widget’s allowed folders."),
                fix: String(localized: "Open this widget’s Settings and choose a folder listed under Allowed folders. Choosing another folder in macOS Privacy settings does not change the widget’s permissions."))
        }

        if widgetRan, text.contains("not permitted by manifest") || text.contains("not allowed by manifest")
            || text.contains("not covered by permissions.") || text.contains("requires manifest permissions.") {
            return ErrorExplanation(kind: .manifestPermissionDenied,
                cause: String(localized: "This widget’s declared permissions do not allow this action."),
                fix: String(localized: "Check for a widget update or ask its author to declare this capability. macOS Privacy settings cannot grant a missing widget capability."))
        }

        if widgetRan, let command = commandNotFound(in: raw, lowercased: text) {
            let cause = command.map { String(localized: "The command “\($0)” isn’t installed on this Mac.") }
                ?? String(localized: "A command this widget needs isn’t installed on this Mac.")
            return ErrorExplanation(
                kind: .commandNotFound(command),
                cause: cause,
                fix: String(localized: "Install it (for example with Homebrew), then retry.")
            )
        }

        // Before "timeout": CLIs that fail to sign in often print a URL with
        // `?timeout=8s` in it (kubectl does), which is not a timeout.
        switch WorkflowSourceFailure.kind(forOutput: raw) {
        case .auth? where widgetRan:
            return ErrorExplanation(
                kind: .signInRequired,
                cause: String(localized: "The tool this widget uses needs you to sign in again."),
                fix: String(localized: "Sign in with that tool in Terminal (for example “gh auth login” or “aws sso login”), then retry.")
            )
        case .rateLimited?:
            return ErrorExplanation(
                kind: .rateLimited,
                cause: String(localized: "The service is limiting requests."),
                fix: String(localized: "Wait a little; BarShelf retries on its own.")
            )
        default:
            break
        }

        if text.contains("timed out") || text.contains("timeout") {
            switch context {
            case .refresh, .action, .test:
                return ErrorExplanation(
                    kind: .timedOut,
                    cause: String(localized: "The widget took too long to answer."),
                    fix: String(localized: "Check the network or the service it reads, then retry.")
                )
            case .install, .update, .save:
                return ErrorExplanation(
                    kind: .timedOut,
                    cause: String(localized: "The server took too long to answer."),
                    fix: String(localized: "Check your internet connection, then try again.")
                )
            }
        }

        if let code = httpStatus(in: text) {
            switch context {
            case .install, .update:
                return ErrorExplanation(kind: .httpStatus(code), cause: downloadCause(code), fix: downloadFix(code, context: context))
            case .test:
                // The builder: the address and headers are on screen, not
                // in a widget's Settings yet.
                let fix = [401, 403].contains(code)
                    ? String(localized: "Check the token or API key in the headers, then test again.")
                    : String(localized: "Check the address and headers, then test again.")
                return ErrorExplanation(kind: .httpStatus(code), cause: downloadCause(code), fix: fix)
            case .refresh, .action, .save:
                return ErrorExplanation(kind: .httpStatus(code), cause: httpCause(code), fix: httpFix(code))
            }
        }

        // A download or update check that cannot reach its server is the
        // same advice in any words; a settings save never touches the network.
        if context != .save, networkMarkers.contains(where: text.contains) {
            return ErrorExplanation(
                kind: .networkUnreachable,
                cause: String(localized: "The server couldn’t be reached."),
                fix: String(localized: "Check your internet connection, then retry.")
            )
        }

        if permissionMarkers.contains(where: text.contains), context == .save {
            return ErrorExplanation(
                kind: .permissionDenied,
                cause: String(localized: "macOS didn’t let BarShelf write its settings file."),
                fix: String(localized: "Check the permissions of BarShelf’s folder in Application Support, then change the setting again.")
            )
        }

        if widgetRan, permissionMarkers.contains(where: text.contains) {
            return ErrorExplanation(
                kind: .permissionDenied,
                cause: String(localized: "macOS or the widget’s permissions blocked this."),
                fix: String(localized: "Review the widget’s permissions in BarShelf ▸ Privacy, or allow access in System Settings ▸ Privacy & Security.")
            )
        }

        if widgetRan, jsonMarkers.contains(where: text.contains) {
            return ErrorExplanation(
                kind: .invalidJSON,
                cause: String(localized: "The widget got data it couldn’t read."),
                fix: String(localized: "The source may have changed its format. Check for a widget update.")
            )
        }

        if let code = exitCode(in: text), context == .action {
            // A toast has no Details to open, and an exit code means nothing
            // to the person who pressed the button.
            return ErrorExplanation(
                kind: .exitCode(code),
                cause: String(localized: "The widget’s command reported an error."),
                fix: String(localized: "Try again. If it keeps failing, check the widget’s Settings.")
            )
        }

        if widgetRan, let code = exitCode(in: text) {
            return ErrorExplanation(
                kind: .exitCode(code),
                cause: String(localized: "The widget’s command failed (exit code \(code))."),
                fix: String(localized: "Open Details to see what it printed, then retry.")
            )
        }

        return generic(context)
    }

    private static func generic(_ context: Context) -> ErrorExplanation {
        switch context {
        case .refresh:
            return ErrorExplanation(kind: .generic,
                cause: String(localized: "This widget couldn’t refresh."),
                fix: String(localized: "Retry, or open Details to see the full message."))
        case .action:
            return ErrorExplanation(kind: .generic,
                cause: String(localized: "The widget’s command didn’t finish."),
                fix: String(localized: "Try again. If it keeps failing, check the widget’s Settings."))
        case .install:
            return ErrorExplanation(kind: .generic,
                cause: String(localized: "The widget couldn’t be installed."),
                fix: String(localized: "Try again. If it keeps failing, the widget’s author may need to fix it."))
        case .update:
            return ErrorExplanation(kind: .generic,
                cause: String(localized: "BarShelf couldn’t reach its update page."),
                fix: String(localized: "Try again later, or open the releases page."))
        case .test:
            return ErrorExplanation(kind: .generic,
                cause: String(localized: "The test didn’t work."),
                fix: String(localized: "Open Details to see the full message, fix the source, then test again."))
        case .save:
            return ErrorExplanation(kind: .generic,
                cause: String(localized: "BarShelf couldn’t save your settings."),
                fix: String(localized: "Make sure your disk has free space, then change the setting again."))
        }
    }

    // MARK: - Classifiers

    private static let networkMarkers = [
        "offline", "not connected to the internet", "could not connect",
        "couldn’t connect", "could not be found", "hostname", "network connection was lost",
        "network is unreachable", "nsurlerrordomain", "connection refused", "dns",
    ]

    private static let jsonMarkers = [
        "not valid json", "invalid json", "json parse", "json.parse", "in json at position", "of json input", "json error", "jsonserialization", "isn’t in the correct format",
        "isn't in the correct format", "unexpected character", "decod",
    ]

    private static let permissionMarkers = [
        "permission denied", "operation not permitted", "not permitted by manifest",
        "not allowed", "eacces", "eperm", "access denied",
        "not covered by permissions.",
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

    /// A download (a widget, an update) answered with an error.
    private static func downloadCause(_ code: Int) -> String {
        switch code {
        case 404: return String(localized: "Nothing was found at this address (HTTP 404).")
        case 401, 403: return String(localized: "The server refused the request (HTTP \(code)).")
        case 429: return String(localized: "The server is limiting requests (HTTP 429).")
        case 500...599: return String(localized: "The server had a problem (HTTP \(code)).")
        default: return String(localized: "The server answered with an error (HTTP \(code)).")
        }
    }

    private static func downloadFix(_ code: Int, context: Context) -> String {
        switch code {
        case 429, 500...599:
            return String(localized: "This is usually temporary. Try again in a few minutes.")
        case 401, 403, 404:
            return context == .install
                ? String(localized: "Check the link. A private repository can’t be installed from.")
                : String(localized: "Try again later, or open the releases page.")
        default:
            return context == .install
                ? String(localized: "Check the link, then try again.")
                : String(localized: "Try again later, or open the releases page.")
        }
    }

    private static func httpFix(_ code: Int) -> String {
        switch code {
        case 401, 403: return String(localized: "Check the token or API key in the widget’s Settings.")
        case 404: return String(localized: "Check the address in the widget’s Settings.")
        case 429: return String(localized: "Wait a little; BarShelf retries on its own.")
        case 500...599: return String(localized: "This is usually temporary. Retry in a few minutes.")
        default: return String(localized: "Check the widget’s Settings, then retry.")
        }
    }
}
