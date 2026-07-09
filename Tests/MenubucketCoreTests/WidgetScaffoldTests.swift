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

    func testAppearanceWritesAuthorDefaults() throws {
        let (manifest, _) = try generate(.init(
            name: "Styled",
            source: .staticText("status"),
            display: .text,
            appearance: WidgetAppearance(
                accent: "green",
                density: .compact,
                cardStyle: .tinted,
                showHeader: false
            )
        ))
        XCTAssertEqual(manifest.appearance?.accent, "green")
        XCTAssertEqual(manifest.appearance?.density, .compact)
        XCTAssertEqual(manifest.appearance?.cardStyle, .tinted)
        XCTAssertEqual(manifest.appearance?.showHeader, false)
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

    func testHTTPJSONSourceDeclaresNetworkPermission() throws {
        let (manifest, workflow) = try generate(.init(
            name: "Status",
            source: .httpJSON(url: "https://api.example.com/status.json"),
            display: .value(valuePath: "status", caption: "API")
        ))
        XCTAssertEqual(manifest.permissions?.network, ["api.example.com"])

        let params = try WorkflowEngine.resolvedSourceParams(workflow, settings: .object([:]))
        XCTAssertEqual(params["data"]?.objectValue?["url"], .string("https://api.example.com/status.json"))

        let output = try WorkflowEngine.evaluate(
            workflow, sources: ["data": .object(["status": .string("ok")])], settings: .object([:])
        )
        let text = flatten(output.viewTree)
        XCTAssertTrue(text.contains("ok"))
        XCTAssertTrue(text.contains("API"))
    }

    func testStaticJSONSourceUsesLiteralValueSource() throws {
        let literal: JSONValue = .array([
            .object(["name": .string("Build"), "state": .string("${not.interpolated}")]),
        ])
        let (manifest, workflow) = try generate(.init(
            name: "Pasted",
            source: .staticJSON(literal),
            display: .list(field: "state")
        ))
        XCTAssertNil(manifest.permissions)

        let params = try WorkflowEngine.resolvedSourceParams(workflow, settings: .object([:]))
        XCTAssertEqual(params["data"], literal)

        let output = try WorkflowEngine.evaluate(
            workflow, sources: ["data": literal], settings: .object([:])
        )
        XCTAssertTrue(flatten(output.viewTree).contains("${not.interpolated}"))
    }

    func testEmptyNameAndCommandRejected() {
        XCTAssertThrowsError(try WidgetBuilderScaffold.files(for: .init(
            name: "  ", source: .staticText("x"), display: .text
        )))
        XCTAssertThrowsError(try WidgetBuilderScaffold.files(for: .init(
            name: "Bad", source: .command(argv: [], json: false), display: .text
        )))
    }

    // MARK: - Refine (filter / sort / limit) + row actions

    private let sampleRuns: JSONValue = .array([
        .object(["name": .string("a"), "status": .string("success"), "age": .number(5)]),
        .object(["name": .string("b"), "status": .string("running"), "age": .number(30)]),
        .object(["name": .string("c"), "status": .string("failed"), "age": .number(20)]),
        .object(["name": .string("d"), "status": .string("running"), "age": .number(10)]),
    ])

    /// Names rendered by a list body, in order.
    private func listNames(_ output: WorkflowEngine.Output) throws -> [String] {
        let list = try XCTUnwrap(firstNode(ofType: "list", in: output.viewTree))
        return list.items?.compactMap { $0.children?.first?.text } ?? []
    }

    func testRefineFilterSortLimitChainApplies() throws {
        let (_, workflow) = try generate(.init(
            name: "Runs",
            source: .command(argv: ["gh", "run", "list", "--json", "name,status"], json: true),
            display: .list(field: "name"),
            refine: .init(
                filter: .init(field: "status", isNot: true, value: .string("success")),
                sort: .init(field: "age", descending: true),
                limit: 2
            ),
            rowAction: .copy(field: "name")
        ))
        // The chained transforms are emitted.
        XCTAssertNotNil(workflow.transforms?["refined_filter"])
        XCTAssertNotNil(workflow.transforms?["refined_sort"])
        XCTAssertNotNil(workflow.transforms?["refined_limit"])

        let output = try WorkflowEngine.evaluate(
            workflow, sources: ["data": sampleRuns], settings: .object([:])
        )
        // success filtered out → {b:30, c:20, d:10}; sort age desc; limit 2 → [b, c].
        XCTAssertEqual(try listNames(output), ["b", "c"])
        XCTAssertEqual(output.expandedItemCount, 2)

        // Row action wired to copyText carrying the row's name.
        let firstRow = try XCTUnwrap(firstNode(ofType: "list", in: output.viewTree)?.items?.first)
        XCTAssertEqual(firstRow.action?.type, "copyText")
        XCTAssertEqual(firstRow.action?.value, "b")
    }

    func testRefineNumericFilterEquals() throws {
        let (_, workflow) = try generate(.init(
            name: "Runs",
            source: .command(argv: ["x"], json: true),
            display: .list(field: "name"),
            refine: .init(filter: .init(field: "age", value: .number(30)))
        ))
        let output = try WorkflowEngine.evaluate(
            workflow, sources: ["data": sampleRuns], settings: .object([:])
        )
        XCTAssertEqual(try listNames(output), ["b"]) // only age == 30
    }

    func testRefineOpenURLRowAction() throws {
        let (_, workflow) = try generate(.init(
            name: "Links",
            source: .command(argv: ["x"], json: true),
            display: .list(field: "name"),
            rowAction: .openURL(field: "url")
        ))
        let rows: JSONValue = .array([
            .object(["name": .string("home"), "url": .string("https://example.com")]),
        ])
        let output = try WorkflowEngine.evaluate(
            workflow, sources: ["data": rows], settings: .object([:])
        )
        let row = try XCTUnwrap(firstNode(ofType: "list", in: output.viewTree)?.items?.first)
        XCTAssertEqual(row.action?.type, "openURL")
        XCTAssertEqual(row.action?.url, "https://example.com")
    }

    func testNoRefineEmitsNoTransforms() throws {
        let (_, workflow) = try generate(.init(
            name: "Plain",
            source: .command(argv: ["x"], json: true),
            display: .list(field: "name")
        ))
        XCTAssertNil(workflow.transforms) // untouched path stays transform-free
    }

    // MARK: - New sources (shell / HTTP headers) + meter display

    func testShellCommandDerivesShellPermission() throws {
        let (manifest, workflow) = try generate(.init(
            name: "Script",
            source: .command(argv: ["/bin/sh", "-c", "echo '{\"n\":1}' | jq ."], json: true),
            display: .value(valuePath: "n", caption: nil)
        ))
        XCTAssertEqual(manifest.permissions?.exec?.first?.command, "/bin/sh")
        XCTAssertEqual(manifest.permissions?.exec?.first?.allowedArgs?.first,
                       ["-c", "echo '{\"n\":1}' | jq ."])
        XCTAssertEqual(workflow.sources["data"]?.use, "exec")
    }

    func testHTTPHeadersEmittedInSource() throws {
        let (manifest, workflow) = try generate(.init(
            name: "API",
            source: .httpJSON(
                url: "https://api.example.com/x.json",
                headers: ["Authorization": "Bearer t"]
            ),
            display: .value(valuePath: "status", caption: nil)
        ))
        XCTAssertEqual(manifest.permissions?.network, ["api.example.com"])
        let with = try XCTUnwrap(workflow.sources["data"]?.with?.objectValue)
        XCTAssertEqual(with["url"], .string("https://api.example.com/x.json"))
        XCTAssertEqual(with["headers"]?.objectValue?["Authorization"], .string("Bearer t"))
    }

    func testHTTPWithoutHeadersOmitsKey() throws {
        let (_, workflow) = try generate(.init(
            name: "API",
            source: .httpJSON(url: "https://a.example.com/x"),
            display: .text
        ))
        let with = try XCTUnwrap(workflow.sources["data"]?.with?.objectValue)
        XCTAssertNil(with["headers"])
    }

    func testMeterRendersProgressAndReadout() throws {
        let (_, workflow) = try generate(.init(
            name: "CPU",
            source: .command(argv: ["x"], json: true),
            display: .meter(valuePath: "pct", maxValue: 100, label: "CPU")
        ))
        let output = try WorkflowEngine.evaluate(
            workflow, sources: ["data": .object(["pct": .number(72)])], settings: .object([:])
        )
        let progress = try XCTUnwrap(firstNode(ofType: "progress", in: output.viewTree))
        XCTAssertEqual(progress.value ?? 0, 0.72, accuracy: 0.0001) // 72 / 100
        XCTAssertEqual(progress.style, "linear")
        let text = flatten(output.viewTree)
        XCTAssertTrue(text.contains("CPU"))   // label
        XCTAssertTrue(text.contains("72%"))   // readout
    }

    func testMeterScalesToCustomMax() throws {
        let (_, workflow) = try generate(.init(
            name: "RAM",
            source: .command(argv: ["x"], json: true),
            display: .meter(valuePath: "used", maxValue: 16, label: "RAM (GB)")
        ))
        let output = try WorkflowEngine.evaluate(
            workflow, sources: ["data": .object(["used": .number(4)])], settings: .object([:])
        )
        let progress = try XCTUnwrap(firstNode(ofType: "progress", in: output.viewTree))
        XCTAssertEqual(progress.value ?? 0, 0.25, accuracy: 0.0001) // 4 / 16, no % suffix
        XCTAssertFalse(flatten(output.viewTree).contains("%"))
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

    /// First node of `type` in a depth-first walk of children + list items.
    private func firstNode(ofType type: String, in node: UINode) -> UINode? {
        if node.type == type { return node }
        for child in (node.children ?? []) + (node.items ?? []) {
            if let found = firstNode(ofType: type, in: child) { return found }
        }
        return nil
    }
}
