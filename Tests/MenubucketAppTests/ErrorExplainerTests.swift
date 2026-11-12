import XCTest
@testable import MenubucketApp

/// Raw refresh errors, as the runtime stores them, become a cause and a fix.
final class ErrorExplainerTests: XCTestCase {
    private func kind(_ raw: String) -> ErrorExplanation.Kind {
        ErrorExplainer.explain(raw).kind
    }

    func testCommandNotFoundNamesTheCommand() {
        XCTAssertEqual(
            kind("'gh' not found (searched: /opt/homebrew/bin, /usr/local/bin, /usr/bin)"),
            .commandNotFound("gh")
        )
        XCTAssertEqual(kind("zsh: command not found: jq"), .commandNotFound("jq"))
        XCTAssertEqual(kind("env: kubectl: No such file or directory"), .commandNotFound("kubectl"))
        XCTAssertTrue(ErrorExplainer.explain("'gh' not found (searched: )").cause.contains("gh"))
    }

    func testSignInBeatsTheTimeoutInAURL() {
        // kubectl prints the API URL with ?timeout=8s when the AWS login lapsed.
        XCTAssertEqual(kind("""
        exited with code 1: aws: [ERROR]: An error occurred (NoCredentials): Unable to locate credentials.
        Get "https://x.eks.amazonaws.com/api?timeout=8s": getting credentials: exec: executable aws failed
        """), .signInRequired)
        XCTAssertEqual(kind("exited with code 4: To get started with GitHub CLI, please run:  gh auth login"), .signInRequired)
        XCTAssertEqual(kind("API rate limit exceeded for user"), .rateLimited)
    }

    func testTimeout() {
        XCTAssertEqual(kind("timed out after 5000 ms"), .timedOut)
        XCTAssertEqual(kind("The request timed out."), .timedOut)
    }

    func testHTTPStatusGetsAStatusSpecificFix() {
        XCTAssertEqual(kind("http source failed (HTTP 404)"), .httpStatus(404))
        XCTAssertEqual(kind("HTTP 503"), .httpStatus(503))
        let unauthorized = ErrorExplainer.explain("http source failed (HTTP 401)")
        XCTAssertEqual(unauthorized.kind, .httpStatus(401))
        XCTAssertTrue(unauthorized.fix.contains("token"))
    }

    func testNetworkUnreachable() {
        XCTAssertEqual(kind("The Internet connection appears to be offline."), .networkUnreachable)
        XCTAssertEqual(kind("A server with the specified hostname could not be found."), .networkUnreachable)
        XCTAssertEqual(kind("Could not connect to the server."), .networkUnreachable)
    }

    func testInvalidJSON() {
        XCTAssertEqual(kind("http response is not valid JSON: unexpected end of input"), .invalidJSON)
        XCTAssertEqual(
            kind("The data couldn’t be read because it isn’t in the correct format."),
            .invalidJSON
        )
    }

    func testPermissionDenied() {
        XCTAssertEqual(kind("command not permitted by manifest allowlist: /bin/rm"), .manifestPermissionDenied)
        XCTAssertEqual(kind("open: Operation not permitted"), .permissionDenied)
        XCTAssertEqual(kind("cat: /etc/secret: Permission denied"), .permissionDenied)
        XCTAssertEqual(kind("config.json: Permission denied"), .permissionDenied)
        XCTAssertEqual(kind("path is not covered by permissions.readPaths: ~/Downloads/config.json"), .manifestPermissionDenied)
        let folder = ErrorExplainer.explain("path is not covered by permissions.readPaths: ~/Documents")
        XCTAssertTrue(folder.fix.contains("Allowed folders"))
        XCTAssertFalse(folder.fix.contains("ask its author"))
        XCTAssertEqual(kind("exited with code 2: missing config.json"), .exitCode(2))
    }

    func testMissingScriptRuntimeGetsSpecificRecovery() {
        let explanation = ErrorExplainer.explain("Deno runtime not found. Install Deno: brew install deno")
        XCTAssertEqual(explanation.kind, .commandNotFound("deno"))
        XCTAssertTrue(explanation.fix.contains("brew install deno"))
        XCTAssertTrue(explanation.fix.contains("Workflow"))
    }

    func testNonZeroExitKeepsTheCode() {
        XCTAssertEqual(kind("exited with code 2: usage: foo [-h]"), .exitCode(2))
        XCTAssertEqual(kind("script exited with status 1"), .exitCode(1))
        XCTAssertTrue(ErrorExplainer.explain("exited with code 127").cause.contains("127"))
    }

    func testAnythingElseIsGenericButStillHasAFix() {
        let explanation = ErrorExplainer.explain("script exited unexpectedly")
        XCTAssertEqual(explanation.kind, .generic)
        XCTAssertFalse(explanation.cause.isEmpty)
        XCTAssertFalse(explanation.fix.isEmpty)
    }

    func testEveryExplanationIsOneLine() {
        for raw in [
            "'gh' not found (searched: /usr/bin)", "timed out after 1 ms", "HTTP 500",
            "offline", "not valid JSON", "Permission denied", "exited with code 3", "boom",
        ] {
            let explanation = ErrorExplainer.explain(raw)
            XCTAssertFalse(explanation.cause.contains("\n"), raw)
            XCTAssertFalse(explanation.fix.contains("\n"), raw)
        }
    }

    /// What a script widget's JSON.parse throws in JavaScriptCore and V8.
    func testScriptJSONParseErrorsReadAsUnreadableData() {
        XCTAssertEqual(ErrorExplainer.explain("SyntaxError: Unexpected end of JSON input").kind, .invalidJSON)
        XCTAssertEqual(ErrorExplainer.explain("SyntaxError: Unexpected token } in JSON at position 5").kind, .invalidJSON)
        XCTAssertEqual(ErrorExplainer.explain("SyntaxError: JSON.parse: unexpected character").kind, .invalidJSON)
    }

    // MARK: Contexts

    /// The classification is shared; only the words naming what failed
    /// change, so an install never says "this widget couldn't refresh".
    func testContextsNameWhatFailed() {
        let refresh = ErrorExplainer.explain("boom")
        let install = ErrorExplainer.explain("boom", context: .install)
        let update = ErrorExplainer.explain("boom", context: .update)
        let action = ErrorExplainer.explain("boom", context: .action)
        let save = ErrorExplainer.explain("boom", context: .save)
        XCTAssertEqual(Set([refresh.cause, install.cause, update.cause, action.cause, save.cause]).count, 5)
        XCTAssertFalse(install.cause.lowercased().contains("refresh"))
        XCTAssertEqual(install.kind, .generic)
    }

    func testDownloadHTTPErrorsSpeakOfTheLinkNotTheWidgetsSettings() {
        let install = ErrorExplainer.explain("HTTP 404", context: .install)
        XCTAssertEqual(install.kind, .httpStatus(404))
        XCTAssertFalse(install.fix.contains("Settings"))
        XCTAssertTrue(install.fix.contains("link"))
        XCTAssertTrue(ErrorExplainer.explain("HTTP 503", context: .update).cause.contains("503"))
        XCTAssertEqual(ErrorExplainer.explain("The request timed out.", context: .install).kind, .timedOut)
        XCTAssertFalse(ErrorExplainer.explain("The request timed out.", context: .install).cause.contains("widget"))
    }

    /// Widget-shaped advice ("install the command", "the data format
    /// changed") never reaches an install, an update check or a save.
    func testWidgetAdviceStaysOutOfOtherContexts() {
        for context: ErrorExplainer.Context in [.install, .update, .save] {
            // A save has its own permission wording (its settings file).
            let raws = ["zsh: command not found: gh", "not valid JSON", "exited with code 2"]
                + (context == .save ? [] : ["Permission denied"])
            for raw in raws {
                XCTAssertEqual(ErrorExplainer.explain(raw, context: context).kind, .generic, "\(context) \(raw)")
            }
        }
        XCTAssertEqual(ErrorExplainer.explain("zsh: command not found: gh", context: .refresh).kind, .commandNotFound("gh"))
        XCTAssertEqual(ErrorExplainer.explain("The Internet connection appears to be offline.", context: .save).kind, .generic)
        XCTAssertEqual(ErrorExplainer.explain("The Internet connection appears to be offline.", context: .install).kind, .networkUnreachable)
        XCTAssertEqual(ErrorExplainer.explain("not valid JSON", context: .install).cause,
                       ErrorExplainer.explain("boom", context: .install).cause)
    }
}
