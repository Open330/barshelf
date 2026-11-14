import XCTest
import MenubucketCore
@testable import MenubucketApp

final class ShelfAttentionReasonTests: XCTestCase {
    private let files = ShelfAttention.Problem(widgetID: "files", name: "Recent Files", message: "The folder doesn't exist.")
    private let awake = ShelfAttention.Problem(widgetID: "awake", name: "Keep Awake", message: "PowerDisplayGuard isn’t answering")

    /// The dot says why it is on: each widget and what is wrong with it,
    /// then anything else waiting.
    func testSummaryNamesEveryReason() {
        let lines = ShelfAttention.summary(
            reasons: [.widgetError, .approvalNeeded, .updateAvailable],
            problems: [files, awake], waitingCount: 2
        )
        XCTAssertEqual(lines.first, "Recent Files: The folder doesn't exist.")
        XCTAssertEqual(lines[1], "Keep Awake: PowerDisplayGuard isn’t answering")
        XCTAssertEqual(lines.count, 4)
        XCTAssertTrue(ShelfAttention.summary(reasons: [], problems: [files], waitingCount: 0).isEmpty)
    }

    func testSummaryCapsTheWidgetList() {
        let many = (0..<5).map { ShelfAttention.Problem(widgetID: "w\($0)", name: "W\($0)", message: "x") }
        let lines = ShelfAttention.summary(reasons: [.widgetError], problems: many, waitingCount: 0)
        XCTAssertEqual(lines.count, 4)
    }

    /// The banner is for problems the popup is not showing.
    func testBannerListsOnlyProblemsOnOtherPages() {
        XCTAssertEqual(WidgetProblemBanner.elsewhere([files, awake], currentPageIDs: ["files"]), [awake])
        XCTAssertTrue(WidgetProblemBanner.elsewhere([files], currentPageIDs: ["files"]).isEmpty)
    }

    /// `status.problem`: text when something is wrong, nothing when empty.
    func testWorkflowStatusProblem() throws {
        func run(_ state: String) throws -> String? {
            var definition = WorkflowDefinition(sources: [:], view: .object(["type": .string("text"), "text": .string("x")]))
            definition.status = .init(problem: "${switch('\(state)', 'stale', 'Not answering', '')}")
            return try WorkflowEngine.evaluate(definition, sources: [:], settings: .object([:])).statusProblem
        }
        XCTAssertEqual(try run("stale"), "Not answering")
        XCTAssertNil(try run("ok"))
    }
}
