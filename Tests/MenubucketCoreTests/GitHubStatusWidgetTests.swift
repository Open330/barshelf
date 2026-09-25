import XCTest
@testable import MenubucketCore

/// The status page API reports its indicator as `none`, `minor`, `major` or
/// `critical`. The widget used to print that raw value, so an all-clear read
/// "none" in both the badge and the menu bar.
final class GitHubStatusWidgetTests: XCTestCase {
    private func definition() throws -> WorkflowDefinition {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try WorkflowDefinition.decode(
            from: try Data(contentsOf: root.appendingPathComponent("widgets/github-status/workflow.json"))
        )
    }

    private func render(indicator: JSONValue) throws -> WorkflowEngine.Output {
        try WorkflowEngine.evaluate(
            try definition(),
            sources: ["github": .object([
                "page": .object(["name": .string("GitHub")]),
                "status": .object([
                    "indicator": indicator,
                    "description": .string("All Systems Operational"),
                ]),
            ])],
            settings: .object([:])
        )
    }

    private func badge(_ node: UINode) -> UINode? {
        if node.type == "badge" { return node }
        return (node.children ?? []).lazy.compactMap(badge).first
    }

    func testAllClearReadsOKInGreen() throws {
        let output = try render(indicator: .string("none"))
        let badge = try XCTUnwrap(badge(output.viewTree))
        XCTAssertEqual(badge.text, "OK")
        XCTAssertEqual(badge.tint, "good")
        XCTAssertEqual(output.statusLabel, "GitHub OK")
    }

    func testIncidentLevelsAreNamedAndColored() throws {
        let cases: [(String, String, String)] = [
            ("minor", "Minor", "warning"),
            ("major", "Major", "danger"),
            ("critical", "Critical", "danger"),
        ]
        for (indicator, label, tint) in cases {
            let badge = try XCTUnwrap(badge(try render(indicator: .string(indicator)).viewTree))
            XCTAssertEqual(badge.text, label, indicator)
            XCTAssertEqual(badge.tint, tint, indicator)
        }
    }

    func testMissingIndicatorSaysUnknown() throws {
        let badge = try XCTUnwrap(badge(try render(indicator: .null).viewTree))
        XCTAssertEqual(badge.text, "Unknown")
        XCTAssertEqual(badge.tint, "secondary")
    }
}
