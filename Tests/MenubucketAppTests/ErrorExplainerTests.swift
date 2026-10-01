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
        XCTAssertEqual(kind("command not permitted by manifest allowlist: /bin/rm"), .permissionDenied)
        XCTAssertEqual(kind("open: Operation not permitted"), .permissionDenied)
        XCTAssertEqual(kind("cat: /etc/secret: Permission denied"), .permissionDenied)
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
}
