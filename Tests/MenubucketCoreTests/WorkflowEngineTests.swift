import XCTest
@testable import MenubucketCore

final class WorkflowEngineTests: XCTestCase {
    private func definition(_ json: String) throws -> WorkflowDefinition {
        try WorkflowDefinition.decode(from: Data(json.utf8))
    }

    private let nowMs: Double = 1_783_442_400_000

    func testSourceParamsInterpolateSettingsWithTypes() throws {
        let def = try definition("""
        { "schemaVersion": 1,
          "sources": { "files": { "use": "fs.directory",
            "with": { "path": "${settings.folder}", "limit": "${settings.limit}",
                      "label": "dir: ${settings.folder}!" } } },
          "view": { "type": "divider" } }
        """)
        let params = try WorkflowEngine.resolvedSourceParams(
            def,
            settings: .object(["folder": .string("~/Downloads"), "limit": .number(12)])
        )
        let with = try XCTUnwrap(params["files"]?.objectValue)
        XCTAssertEqual(with["path"], .string("~/Downloads"))
        XCTAssertEqual(with["limit"], .number(12)) // whole-string expr keeps type
        XCTAssertEqual(with["label"], .string("dir: ~/Downloads!")) // concat → string
    }

    func testTransformChainSortFilterLimit() throws {
        let def = try definition("""
        { "schemaVersion": 1,
          "sources": { "s": { "use": "exec" } },
          "transforms": {
            "kept":   { "use": "filter", "from": "$.sources.s.items", "with": { "field": "ext", "equals": "png" } },
            "sorted": { "use": "sort",   "from": "$.transforms.kept", "with": { "by": "size", "direction": "descending" } },
            "top":    { "use": "limit",  "from": "$.transforms.sorted", "with": { "count": 2 } }
          },
          "view": { "type": "list", "items": { "forEach": "$.transforms.top", "as": "f",
                    "template": { "type": "text", "id": "${f.name}", "text": "${f.name} (${f.size})" } } } }
        """)
        let items: JSONValue = .array([
            .object(["name": .string("a"), "ext": .string("png"), "size": .number(10)]),
            .object(["name": .string("b"), "ext": .string("txt"), "size": .number(99)]),
            .object(["name": .string("c"), "ext": .string("png"), "size": .number(30)]),
            .object(["name": .string("d"), "ext": .string("png"), "size": .number(20)]),
        ])
        let output = try WorkflowEngine.evaluate(
            def, sources: ["s": .object(["items": items])], settings: .object([:]), nowMs: nowMs
        )
        XCTAssertEqual(output.expandedItemCount, 2)
        let texts = output.viewTree.items?.compactMap(\.text)
        XCTAssertEqual(texts, ["c (30)", "d (20)"]) // filtered txt out, sorted desc, limit 2
        XCTAssertFalse(output.usedEmpty)
    }

    func testEmptyNodeSubstitutedWhenNoItems() throws {
        let def = try definition("""
        { "schemaVersion": 1,
          "sources": { "s": { "use": "exec" } },
          "view": { "type": "list", "items": { "forEach": "$.sources.s.items", "as": "f",
                    "template": { "type": "text", "text": "${f.name}" } } },
          "empty": { "type": "empty", "title": "No files", "subtitle": "none" },
          "status": { "tooltip": "${count(sources.s.items)} items" } }
        """)
        let output = try WorkflowEngine.evaluate(
            def, sources: ["s": .object(["items": .array([])])], settings: .object([:]), nowMs: nowMs
        )
        XCTAssertTrue(output.usedEmpty)
        XCTAssertEqual(output.viewTree.type, "empty")
        XCTAssertEqual(output.viewTree.title, "No files")
        XCTAssertEqual(output.statusTooltip, "0 items")
    }

    func testBuiltinFunctions() throws {
        let def = try definition("""
        { "schemaVersion": 1,
          "sources": { "s": { "use": "exec" } },
          "view": { "type": "vstack", "children": [
            { "type": "text", "id": "base",  "text": "${file.basename(settings.folder)}" },
            { "type": "text", "id": "ext",   "text": "${file.extension(settings.folder)}" },
            { "type": "text", "id": "rel",   "text": "${date.relative(settings.past)}" },
            { "type": "text", "id": "trunc", "text": "${text.truncate(settings.long, 4)}" },
            { "type": "text", "id": "coal",  "text": "${coalesce(settings.missing, settings.folder)}" }
          ] } }
        """)
        let output = try WorkflowEngine.evaluate(
            def,
            sources: ["s": .null],
            settings: .object([
                "folder": .string("/tmp/shots/image.png"),
                "past": .number(nowMs - 3 * 60_000),
                "long": .string("abcdefgh"),
                "missing": .null,
            ]),
            nowMs: nowMs
        )
        let texts = output.viewTree.children?.compactMap(\.text)
        XCTAssertEqual(texts, ["image.png", "png", "3m ago", "abcd…", "/tmp/shots/image.png"])
    }

    func testErrorsAreSpecific() throws {
        let cyclic = try definition("""
        { "schemaVersion": 1, "sources": {},
          "transforms": { "a": { "use": "assign", "from": "$.transforms.b" },
                          "b": { "use": "assign", "from": "$.transforms.a" } },
          "view": { "type": "text", "text": "${transforms.a}" } }
        """)
        XCTAssertThrowsError(
            try WorkflowEngine.evaluate(cyclic, sources: [:], settings: .object([:]))
        ) { error in
            guard case WorkflowError.transformCycle = error else {
                return XCTFail("expected transformCycle, got \(error)")
            }
        }

        let badFunction = try definition("""
        { "schemaVersion": 1, "sources": {},
          "view": { "type": "text", "text": "${eval(settings.x)}" } }
        """)
        XCTAssertThrowsError(
            try WorkflowEngine.evaluate(badFunction, sources: [:], settings: .object([:]))
        ) { error in
            guard case WorkflowError.unknownFunction("eval") = error else {
                return XCTFail("expected unknownFunction, got \(error)")
            }
        }
    }

    // MARK: - Hardening: numeric overflow must not trap the host

    func testTruncateLimitOutOfIntRangeDoesNotCrash() throws {
        // `Double("1e400")` is +∞ and `1e19` is a representable Double that
        // exceeds Int.max — both used to trap in `Int(_:)`.
        for literal in ["1e400", "1e19", "-1e400"] {
            let def = try definition("""
            { "schemaVersion": 1, "sources": {},
              "view": { "type": "text", "id": "t", "text": "${text.truncate(settings.s, \(literal))}" } }
            """)
            let output = try WorkflowEngine.evaluate(
                def, sources: [:], settings: .object(["s": .string("hello")]), nowMs: nowMs
            )
            // A non-positive/huge limit leaves the string untouched.
            XCTAssertEqual(output.viewTree.text, "hello", "literal \(literal)")
        }
    }

    func testLimitTransformCountOutOfIntRangeDoesNotCrash() throws {
        let def = try definition("""
        { "schemaVersion": 1,
          "sources": { "s": { "use": "exec" } },
          "transforms": { "top": { "use": "limit", "from": "$.sources.s.items", "with": { "count": "${1e19}" } } },
          "view": { "type": "list", "items": { "forEach": "$.transforms.top", "as": "f",
                    "template": { "type": "text", "text": "${f.n}" } } } }
        """)
        let items: JSONValue = .array([.object(["n": .string("a")]), .object(["n": .string("b")])])
        let output = try WorkflowEngine.evaluate(
            def, sources: ["s": .object(["items": items])], settings: .object([:]), nowMs: nowMs
        )
        XCTAssertEqual(output.expandedItemCount, 2) // clamped to Int.max → keeps all
    }

    func testDateRelativeWithHugeNegativeDoesNotCrash() throws {
        let def = try definition("""
        { "schemaVersion": 1, "sources": {},
          "view": { "type": "text", "id": "t", "text": "${date.relative(-1e300)}" } }
        """)
        let output = try WorkflowEngine.evaluate(
            def, sources: [:], settings: .object([:]), nowMs: nowMs
        )
        XCTAssertNotNil(output.viewTree.text) // finite string, no trap
    }

    func testDeeplyNestedExpressionThrowsInsteadOfOverflow() throws {
        // 400 levels of nesting exceeds maxDepth (256) → thrown error, not crash.
        let expr = String(repeating: "count(", count: 400) + "settings.x"
            + String(repeating: ")", count: 400)
        let def = try definition("""
        { "schemaVersion": 1, "sources": {},
          "view": { "type": "text", "id": "t", "text": "${\(expr)}" } }
        """)
        XCTAssertThrowsError(
            try WorkflowEngine.evaluate(def, sources: [:], settings: .object(["x": .array([])]), nowMs: nowMs)
        ) { error in
            guard case WorkflowError.badExpression = error else {
                return XCTFail("expected badExpression for over-deep nesting, got \(error)")
            }
        }
    }

    func testForEachScopeAndDragActionInterpolation() throws {
        let def = try definition("""
        { "schemaVersion": 1,
          "sources": { "s": { "use": "exec" } },
          "view": { "type": "list", "items": { "forEach": "$.sources.s.items", "as": "f",
            "template": { "type": "hstack", "id": "file-${f.path}",
                          "drag": { "filePath": "${f.path}" },
                          "action": { "type": "openFile", "path": "${f.path}" },
                          "children": [ { "type": "text", "text": "${f.name}" } ] } } } }
        """)
        let output = try WorkflowEngine.evaluate(
            def,
            sources: ["s": .object(["items": .array([
                .object(["path": .string("/tmp/a.txt"), "name": .string("a.txt")]),
            ])])],
            settings: .object([:]),
            nowMs: nowMs
        )
        let row = try XCTUnwrap(output.viewTree.items?.first)
        XCTAssertEqual(row.id, "file-/tmp/a.txt")
        XCTAssertEqual(row.drag?.filePath, "/tmp/a.txt")
        XCTAssertEqual(row.action?.path, "/tmp/a.txt")
    }
}

final class FileSourceTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mb-filesource-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, age) in [("old.txt", 300.0), ("mid.png", 200.0), ("new.pdf", 100.0), (".hidden", 50.0)] {
            let url = dir.appendingPathComponent(name)
            try Data(name.utf8).write(to: url)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSinceNow: -age)], ofItemAtPath: url.path
            )
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testListSortsFiltersAndLimits() throws {
        let params = try FileSource.Params(from: .object([
            "path": .string(dir.path),
            "sortBy": .string("modifiedAt"),
            "sortDirection": .string("descending"),
            "limit": .number(2),
        ]))
        let result = try FileSource.list(params)
        let names = result.objectValue?["items"]?.arrayValue?
            .compactMap { $0.objectValue?["name"]?.stringValue }
        XCTAssertEqual(names, ["new.pdf", "mid.png"]) // hidden skipped, newest first, limit 2
        let first = result.objectValue?["items"]?.arrayValue?.first?.objectValue
        XCTAssertEqual(first?["ext"], .string("pdf"))
        XCTAssertEqual(first?["isDirectory"], .bool(false))
        XCTAssertNotNil(first?["modifiedAt"]?.numberValue)
    }

    func testTildeExpansionAndMissingDirectoryError() throws {
        let params = try FileSource.Params(from: .object(["path": .string("~/")]))
        XCTAssertFalse(params.path.hasPrefix("~"))

        let missing = try FileSource.Params(from: .object(["path": .string("/nonexistent-mb-test")]))
        XCTAssertThrowsError(try FileSource.list(missing))
    }

    func testLimitOutOfIntRangeDoesNotCrash() throws {
        // `1e19` is a representable Double above Int.max; `Int(_:)` would trap.
        let params = try FileSource.Params(from: .object([
            "path": .string(dir.path),
            "limit": .number(1e19),
        ]))
        XCTAssertEqual(params.limit, Int.max) // clamped, not trapped
        let result = try FileSource.list(params)
        XCTAssertNotNil(result.objectValue?["items"]?.arrayValue)
    }

    func testRecentFilesWorkflowEndToEnd() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let workflowURL = packageRoot.appendingPathComponent("widgets/recent-files/workflow.json")
        let def = try WorkflowDefinition.decode(from: try Data(contentsOf: workflowURL))

        let settings: JSONValue = .object(["folder": .string(dir.path), "limit": .number(12)])
        let params = try WorkflowEngine.resolvedSourceParams(def, settings: settings)
        let fsParams = try FileSource.Params(from: try XCTUnwrap(params["files"]))
        XCTAssertTrue(fsParams.watch)
        let listing = try FileSource.list(fsParams)

        let output = try WorkflowEngine.evaluate(
            def, sources: ["files": listing], settings: settings
        )
        XCTAssertEqual(output.expandedItemCount, 3)
        XCTAssertEqual(output.statusTooltip, "Recent files: 3 items")
        XCTAssertEqual(output.viewTree.type, "vstack")
        // Row template resolved: thumbnail source + drag + reveal action.
        let list = output.viewTree.children?.first { $0.type == "list" }
        let row = try XCTUnwrap(list?.items?.first)
        XCTAssertEqual(row.children?.first?.source?.kind, "fileThumbnail")
        XCTAssertNotNil(row.children?.first?.source?.modifiedAt)
        XCTAssertNotNil(row.drag)
    }
}
