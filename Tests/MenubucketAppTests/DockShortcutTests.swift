import XCTest
@testable import BarShelfDock

/// A Shortcut tile whose run fails must say so: `shortcuts run` exits
/// non-zero for a renamed or deleted Shortcut, and nothing used to notice.
/// The tool itself is never run here; its outcome is injected.
@MainActor
final class DockShortcutTests: XCTestCase {
    func testANonZeroExitIsReportedWithTheShortcutsName() {
        let reported = expectation(description: "failure reported")
        var failures: [ShortcutFailure] = []
        DockActions.runShortcut(
            named: "Morning Routine",
            launch: { _ in ShortcutRun(status: 1, errors: "Error: Couldn’t find shortcut\n") },
            onFailure: { failure in
                failures.append(failure)
                reported.fulfill()
            }
        )
        wait(for: [reported], timeout: 10)
        XCTAssertEqual(
            failures,
            [ShortcutFailure(name: "Morning Routine", status: 1, detail: "Error: Couldn’t find shortcut")]
        )
    }

    func testAToolThatCouldNotStartIsReported() {
        let reported = expectation(description: "failure reported")
        var failures: [ShortcutFailure] = []
        DockActions.runShortcut(
            named: "Morning Routine",
            launch: { _ in ShortcutRun(status: ShortcutRun.notStarted, errors: "") },
            onFailure: { failure in
                failures.append(failure)
                reported.fulfill()
            }
        )
        wait(for: [reported], timeout: 10)
        XCTAssertEqual(
            failures,
            [ShortcutFailure(name: "Morning Routine", status: ShortcutRun.notStarted, detail: nil)]
        )
    }

    func testAZeroExitReportsNothing() {
        let ran = expectation(description: "shortcut ran")
        let reported = expectation(description: "failure reported")
        reported.isInverted = true
        DockActions.runShortcut(
            named: "Morning Routine",
            // Chatter on standard error is not a failure; the exit status is.
            launch: { name in
                ran.fulfill()
                return ShortcutRun(status: 0, errors: "warning: \(name) took a while\n")
            },
            onFailure: { _ in reported.fulfill() }
        )
        wait(for: [ran], timeout: 10)
        wait(for: [reported], timeout: 0.5)
        XCTAssertNil(DockActions.shortcutFailure(named: "Morning Routine", run: ShortcutRun(status: 0, errors: "noise")))
    }
}
