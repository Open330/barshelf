import XCTest
@testable import MenubucketCore

/// Every builder preset must produce files that decode as a manifest +
/// workflow and evaluate through WorkflowEngine (the same path the app runs).
final class WidgetScaffoldTests: XCTestCase {
    private func generate(_ spec: WidgetBuilderScaffold.Spec) throws -> (Manifest, WorkflowDefinition) {
        let files = try WidgetBuilderScaffold.files(for: spec)
        let manifestData = Data(try XCTUnwrap(files["widget.json"]).utf8)
        let workflowData = Data(try XCTUnwrap(files["workflow.json"]).utf8)
        let manifest = try Manifest.decode(from: manifestData)
        let workflow = try WorkflowDefinition.decode(from: workflowData)
        return (manifest, workflow)
    }

    func testSlugSanitizesNames() {
        XCTAssertEqual(WidgetBuilderScaffold.slug(from: "My CI Status!"), "my-ci-status")
        XCTAssertEqual(WidgetBuilderScaffold.slug(from: "  spaced  out  "), "spaced-out")
        XCTAssertEqual(WidgetBuilderScaffold.slug(from: "@@@"), "widget")
        XCTAssertEqual(WidgetBuilderScaffold.slug(from: "kube-pods"), "kube-pods")
    }

    func testDerivedIDAndMetadata() throws {
        let (manifest, _) = try generate(.init(
            name: "Kube Pods",
            icon: "cube.box",
            group: "Ops",
            size: "L",
            refreshIntervalSec: 60,
            source: .staticText("hi"),
            display: .text
        ))
        XCTAssertEqual(manifest.id, "dev.barshelf.user.kube-pods")
        XCTAssertEqual(manifest.name, "Kube Pods")
        XCTAssertEqual(manifest.icon, "cube.box")
        XCTAssertEqual(manifest.bucket?.group, "Ops")
        XCTAssertEqual(manifest.bucket?.size, "L")
        XCTAssertEqual(manifest.entry.kind, "workflow")
        XCTAssertEqual(manifest.entry.main, "workflow.json")
        XCTAssertEqual(manifest.refresh?.interval, 60)
        XCTAssertEqual(manifest.refresh?.onOpen, true)
    }

    func testStaticTextWidgetEvaluates() throws {
        let (manifest, workflow) = try generate(.init(
            name: "Note", source: .staticText("remember to hydrate"), display: .text
        ))
        XCTAssertNil(manifest.permissions) // no I/O, no permissions
        let output = try WorkflowEngine.evaluate(workflow, sources: [:], settings: .object([:]))
        XCTAssertTrue(flatten(output.viewTree).contains("remember to hydrate"))
    }

    func testCommandListDeclaresExecPermissionAndEvaluates() throws {
        let (manifest, workflow) = try generate(.init(
            name: "Branches",
            source: .command(argv: ["git", "branch", "--format=%(refname:short)"], json: false),
            display: .text
        ))
        // First-run approval gate: the command must be in the allowlist.
        let exec = try XCTUnwrap(manifest.permissions?.exec?.first)
        XCTAssertEqual(exec.command, "git")
        XCTAssertEqual(exec.allowedArgs, [["branch", "--format=%(refname:short)"]])
        XCTAssertTrue(ExecAllowlist.permits(
            command: ["git", "branch", "--format=%(refname:short)"],
            permissions: manifest.permissions?.exec
        ))
        // text display over a string source.
        let output = try WorkflowEngine.evaluate(
            workflow, sources: ["data": .string("main\ndev")], settings: .object([:])
        )
        XCTAssertTrue(flatten(output.viewTree).contains("main\ndev"))
    }

    func testCommandJSONListRendersRows() throws {
        let (_, workflow) = try generate(.init(
            name: "Docker",
            source: .command(argv: ["docker", "ps", "--format", "json"], json: true),
            display: .list(field: "name")
        ))
        let rows: JSONValue = .array([
            .object(["name": .string("api")]),
            .object(["name": .string("db")]),
        ])
        let output = try WorkflowEngine.evaluate(
            workflow, sources: ["data": rows], settings: .object([:])
        )
        XCTAssertEqual(output.expandedItemCount, 2)
        let text = flatten(output.viewTree)
        XCTAssertTrue(text.contains("api"))
        XCTAssertTrue(text.contains("db"))
    }

    func testCommandJSONTableMapsColumns() throws {
        let (_, workflow) = try generate(.init(
            name: "Usage",
            source: .command(argv: ["aas", "usage", "--json"], json: true),
            display: .table(columns: [
                .init(title: "Account", field: "name"),
                .init(title: "Plan", field: "plan"),
            ])
        ))
        let rows: JSONValue = .array([
            .object(["name": .string("work"), "plan": .string("max")]),
        ])
        let output = try WorkflowEngine.evaluate(
            workflow, sources: ["data": rows], settings: .object([:])
        )
        let text = flatten(output.viewTree)
        XCTAssertTrue(text.contains("work"))
        XCTAssertTrue(text.contains("max"))
    }

    func testValueDisplayReadsObjectPath() throws {
        let (_, workflow) = try generate(.init(
            name: "Rate",
            source: .command(argv: ["fx"], json: true),
            display: .value(valuePath: "krw", caption: "USD→KRW")
        ))
        let output = try WorkflowEngine.evaluate(
            workflow, sources: ["data": .object(["krw": .number(1387)])], settings: .object([:])
        )
        let text = flatten(output.viewTree)
        XCTAssertTrue(text.contains("1387"))
        XCTAssertTrue(text.contains("USD→KRW"))
    }

    func testFolderSourceHasSettingAndFileTemplate() throws {
        let (manifest, workflow) = try generate(.init(
            name: "Shots",
            source: .folder(path: "~/Pictures/Screenshots", limit: 12),
            display: .list(field: nil)
        ))
        // Folder path is a user-editable setting.
        XCTAssertEqual(manifest.settings?.first?.key, "folder")
        XCTAssertEqual(manifest.settings?.first?.type, "directory")
        XCTAssertEqual(manifest.permissions?.readPaths, ["~/Pictures/Screenshots"])

        let params = try WorkflowEngine.resolvedSourceParams(
            workflow, settings: .object(["folder": .string("/tmp")])
        )
        XCTAssertEqual(params["files"]?.objectValue?["path"], .string("/tmp"))
        XCTAssertEqual(params["files"]?.objectValue?["watch"], .bool(true))

        let items: JSONValue = .object(["items": .array([
            .object([
                "path": .string("/tmp/a.png"), "name": .string("a.png"),
                "modifiedAt": .number(0), "isDirectory": .bool(false),
            ]),
        ])])
        let output = try WorkflowEngine.evaluate(
            workflow, sources: ["files": items], settings: .object(["folder": .string("/tmp")])
        )
        let row = try XCTUnwrap(output.viewTree.children?.compactMap { node -> UINode? in
            node.type == "vstack" ? node : nil
        }.first?.children?.first { $0.type == "list" }?.items?.first)
        XCTAssertEqual(row.drag?.filePath, "/tmp/a.png")
        XCTAssertEqual(row.action?.path, "/tmp/a.png")
    }

    func testEmptyNameAndCommandRejected() {
        XCTAssertThrowsError(try WidgetBuilderScaffold.files(for: .init(
            name: "  ", source: .staticText("x"), display: .text
        )))
        XCTAssertThrowsError(try WidgetBuilderScaffold.files(for: .init(
            name: "Bad", source: .command(argv: [], json: false), display: .text
        )))
    }

    // MARK: - Helpers

    /// Concatenates all `text` fields in a view tree for content assertions.
    private func flatten(_ node: UINode) -> String {
        var out = node.text ?? ""
        for child in (node.children ?? []) + (node.items ?? []) {
            out += "\n" + flatten(child)
        }
        return out
    }
}
