import XCTest
import BarShelfKit
import MenubucketCore

/// `barshelf validate` error reporting — broken manifests must surface
/// file:field-level issues.
final class WidgetValidatorTests: XCTestCase {
    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("barshelf-validate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workDir, withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    private func writeWidget(_ manifest: String, extra: [String: String] = [:]) throws -> URL {
        let dir = workDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try manifest.write(
            to: dir.appendingPathComponent("widget.json"),
            atomically: true, encoding: .utf8
        )
        for (name, contents) in extra {
            try contents.write(
                to: dir.appendingPathComponent(name),
                atomically: true, encoding: .utf8
            )
        }
        return dir
    }

    func testMissingManifestFile() throws {
        let dir = workDir.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let report = WidgetValidator.validate(directory: dir)
        XCTAssertFalse(report.isValid)
        XCTAssertEqual(report.issues.first?.file, "widget.json")
    }

    func testMissingRequiredFieldReportsFieldPath() throws {
        // no "entry"
        let dir = try writeWidget("""
        { "schemaVersion": 1, "id": "broken", "name": "Broken" }
        """)
        let report = WidgetValidator.validate(directory: dir)
        XCTAssertFalse(report.isValid)
        let issue = try XCTUnwrap(report.issues.first)
        XCTAssertEqual(issue.file, "widget.json")
        XCTAssertEqual(issue.field, "entry")
        XCTAssertTrue(issue.message.contains("missing"))
    }

    func testNestedMissingFieldReportsDottedPath() throws {
        // entry present but entry.kind missing
        let dir = try writeWidget("""
        { "schemaVersion": 1, "id": "broken", "name": "Broken", "entry": {} }
        """)
        let report = WidgetValidator.validate(directory: dir)
        let issue = try XCTUnwrap(report.issues.first)
        XCTAssertEqual(issue.field, "entry.kind")
    }

    func testTypeMismatchReportsField() throws {
        let dir = try writeWidget("""
        { "schemaVersion": "one", "id": "broken", "name": "Broken",
          "entry": { "kind": "exec" } }
        """)
        let report = WidgetValidator.validate(directory: dir)
        let issue = try XCTUnwrap(report.issues.first)
        XCTAssertEqual(issue.field, "schemaVersion")
        XCTAssertTrue(issue.message.contains("wrong type"))
    }

    func testInvalidJSONSyntax() throws {
        let dir = try writeWidget("{ not json")
        let report = WidgetValidator.validate(directory: dir)
        XCTAssertFalse(report.isValid)
        XCTAssertEqual(report.issues.first?.file, "widget.json")
        XCTAssertTrue(report.issues.first?.message.contains("JSON") == true)
    }

    func testInvalidWidgetID() throws {
        let dir = try writeWidget("""
        { "schemaVersion": 1, "id": "../escape", "name": "Escape",
          "entry": { "kind": "exec" },
          "source": { "kind": "exec", "command": ["./x.sh"] } }
        """)
        let report = WidgetValidator.validate(directory: dir)
        XCTAssertEqual(report.issues.first?.field, "id")
    }

    func testUnknownEntryKind() throws {
        let dir = try writeWidget("""
        { "schemaVersion": 1, "id": "odd", "name": "Odd",
          "entry": { "kind": "binary" } }
        """)
        let report = WidgetValidator.validate(directory: dir)
        XCTAssertTrue(report.issues.contains { $0.field == "entry.kind" })
    }

    func testExecWithoutCommand() throws {
        let dir = try writeWidget("""
        { "schemaVersion": 1, "id": "no-cmd", "name": "No Command",
          "entry": { "kind": "exec" } }
        """)
        let report = WidgetValidator.validate(directory: dir)
        XCTAssertTrue(report.issues.contains { $0.field == "source.command" })
    }

    func testWorkflowMainMissing() throws {
        let dir = try writeWidget("""
        { "schemaVersion": 1, "id": "wf", "name": "WF",
          "entry": { "kind": "workflow", "main": "workflow.json" } }
        """)
        let report = WidgetValidator.validate(directory: dir)
        XCTAssertTrue(report.issues.contains {
            $0.file == "workflow.json" && $0.message.contains("not found")
        })
    }

    func testBrokenWorkflowDefinitionReportsFile() throws {
        let dir = try writeWidget("""
        { "schemaVersion": 1, "id": "wf", "name": "WF",
          "entry": { "kind": "workflow", "main": "workflow.json" } }
        """, extra: [
            // sources must be an object keyed by name
            "workflow.json": """
            { "schemaVersion": 1, "sources": [], "view": { "type": "vstack" } }
            """,
        ])
        let report = WidgetValidator.validate(directory: dir)
        XCTAssertFalse(report.isValid)
        XCTAssertTrue(report.issues.contains { $0.file == "workflow.json" },
                      "expected workflow.json issue, got \(report.issues)")
    }

    func testValidatePathRejectsMissingPath() {
        XCTAssertThrowsError(
            try WidgetValidator.validate(
                path: workDir.appendingPathComponent("nope")
            )
        )
    }

    func testBundledWidgetsValidate() throws {
        // The repo's bundled widgets are the reference packages — they must
        // stay green under `barshelf validate`.
        let repoWidgets = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // BarShelfCLITests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("widgets", isDirectory: true)
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: repoWidgets.path),
            "bundled widgets directory not present"
        )
        let names = try FileManager.default.contentsOfDirectory(atPath: repoWidgets.path)
            .filter { name in
                FileManager.default.fileExists(
                    atPath: repoWidgets
                        .appendingPathComponent(name, isDirectory: true)
                        .appendingPathComponent("widget.json")
                        .path
                )
            }
            .sorted()
        XCTAssertGreaterThanOrEqual(names.count, 10)
        for name in names {
            let report = WidgetValidator.validate(
                directory: repoWidgets.appendingPathComponent(name, isDirectory: true)
            )
            XCTAssertTrue(report.isValid, "\(name): \(report.issues)")
        }
    }
}
