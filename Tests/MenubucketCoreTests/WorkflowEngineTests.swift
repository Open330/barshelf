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

    // MARK: - Persistence: storage read + store writes

    func testStorageSnapshotReadableAsRoot() throws {
        let def = try definition("""
        { "schemaVersion": 1, "sources": {},
          "view": { "type": "text", "id": "t", "text": "seen ${coalesce(storage.count, 0)} times" } }
        """)
        let output = try WorkflowEngine.evaluate(
            def, sources: [:], settings: .object([:]),
            storage: .object(["count": .number(7)]), nowMs: nowMs
        )
        XCTAssertEqual(output.viewTree.text, "seen 7 times")
    }

    func testStoreBlockProducesWritesWithTtl() throws {
        let def = try definition("""
        { "schemaVersion": 1, "sources": { "s": { "use": "exec" } },
          "view": { "type": "text", "text": "${string(sources.s.n)}" },
          "store": {
            "count":  { "value": "${add(coalesce(storage.count, 0), 1)}" },
            "cached": { "value": "${sources.s.n}", "ttlSec": 60 }
          } }
        """)
        let output = try WorkflowEngine.evaluate(
            def, sources: ["s": .object(["n": .number(42)])], settings: .object([:]),
            storage: .object(["count": .number(4)]), nowMs: nowMs
        )
        // Deterministic (sorted-key) order: "cached" then "count".
        XCTAssertEqual(output.writes.map(\.key), ["cached", "count"])
        let byKey = Dictionary(uniqueKeysWithValues: output.writes.map { ($0.key, $0) })
        XCTAssertEqual(byKey["count"]?.value, .number(5))   // incremented from prior snapshot
        XCTAssertNil(byKey["count"]?.ttlMs)
        XCTAssertEqual(byKey["cached"]?.value, .number(42)) // whole-string expr keeps number type
        XCTAssertEqual(byKey["cached"]?.ttlMs, 60_000)      // ttlSec → ms
    }

    // MARK: - Logic: conditions, comparison, arithmetic, string literals

    func testLogicComparisonAndArithmeticFunctions() throws {
        let def = try definition("""
        { "schemaVersion": 1, "sources": { "s": { "use": "exec" } },
          "view": { "type": "vstack", "children": [
            { "type": "text", "id": "if",   "text": "${if(eq(sources.s.status, 'ok'), 'good', 'bad')}" },
            { "type": "text", "id": "gt",   "text": "${string(gt(sources.s.n, 10))}" },
            { "type": "text", "id": "math", "text": "${string(add(mul(sources.s.n, 2), 1))}" },
            { "type": "text", "id": "and",  "text": "${string(and(true, gt(sources.s.n, 3)))}" },
            { "type": "text", "id": "def",  "text": "${default(sources.s.missing, 'fallback')}" },
            { "type": "text", "id": "has",  "text": "${string(contains(sources.s.status, 'o'))}" }
          ] } }
        """)
        let output = try WorkflowEngine.evaluate(
            def,
            sources: ["s": .object(["status": .string("ok"), "n": .number(21)])],
            settings: .object([:]), nowMs: nowMs
        )
        let texts = output.viewTree.children?.compactMap(\.text)
        XCTAssertEqual(texts, ["good", "true", "43", "true", "fallback", "true"])
    }

    func testArithmeticCoercesNumericStrings() throws {
        // CLI output often arrives as strings; add()/gt() should still work.
        let def = try definition("""
        { "schemaVersion": 1, "sources": { "s": { "use": "exec" } },
          "view": { "type": "text", "id": "t", "text": "${string(add(sources.s.a, sources.s.b))}" } }
        """)
        let output = try WorkflowEngine.evaluate(
            def, sources: ["s": .object(["a": .string("40"), "b": .string("2")])],
            settings: .object([:]), nowMs: nowMs
        )
        XCTAssertEqual(output.viewTree.text, "42")
    }

    // MARK: - Conditional switch node (view modes)

    func testSwitchSelectsMatchingCase() throws {
        let def = try definition("""
        { "schemaVersion": 1, "sources": {},
          "view": { "switch": "${settings.mode}",
            "cases": {
              "grid": { "type": "grid", "id": "g", "items": [] },
              "list": { "type": "list", "id": "l", "items": [] }
            },
            "default": { "type": "text", "text": "none" } } }
        """)
        let grid = try WorkflowEngine.evaluate(def, sources: [:], settings: .object(["mode": .string("grid")]))
        XCTAssertEqual(grid.viewTree.type, "grid")
        let list = try WorkflowEngine.evaluate(def, sources: [:], settings: .object(["mode": .string("list")]))
        XCTAssertEqual(list.viewTree.type, "list")
        let fallback = try WorkflowEngine.evaluate(def, sources: [:], settings: .object(["mode": .string("???")]))
        XCTAssertEqual(fallback.viewTree.text, "none")
    }

    func testSwitchDoesNotExpandUnmatchedBranch() throws {
        let def = try definition("""
        { "schemaVersion": 1, "sources": { "s": { "use": "exec" } },
          "view": { "switch": "on",
            "cases": {
              "on":  { "type": "text", "text": "on" },
              "off": { "type": "list", "items": { "forEach": "$.sources.s.items", "as": "x",
                        "template": { "type": "text", "text": "${x}" } } }
            } } }
        """)
        let output = try WorkflowEngine.evaluate(
            def, sources: ["s": .object(["items": .array([.string("a"), .string("b")])])],
            settings: .object([:])
        )
        XCTAssertEqual(output.viewTree.text, "on")
        XCTAssertEqual(output.expandedItemCount, 0) // the off-branch forEach never ran
    }

    func testBundledWorkflowSourcesResolveWithoutInterpolationErrors() throws {
        // Phase-1 interpolation of a source's `with` used to choke on shell
        // `${var}` syntax (it looks like `${expr}`). No bundled widget may throw.
        let widgetsDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("widgets")
        let dirs = try FileManager.default.contentsOfDirectory(
            at: widgetsDir, includingPropertiesForKeys: nil
        )
        var checked = 0
        for dir in dirs {
            let wf = dir.appendingPathComponent("workflow.json")
            guard FileManager.default.fileExists(atPath: wf.path) else { continue }
            let def = try WorkflowDefinition.decode(from: try Data(contentsOf: wf))
            XCTAssertNoThrow(
                try WorkflowEngine.resolvedSourceParams(def, settings: .object([:])),
                "resolvedSourceParams threw for \(dir.lastPathComponent)"
            )
            checked += 1
        }
        XCTAssertGreaterThan(checked, 5)
    }

    func testNumericPathSegmentIndexesArrays() throws {
        let def = try definition("""
        { "schemaVersion": 1, "sources": { "s": { "use": "exec" } },
          "view": { "type": "text", "id": "t", "text": "${string(sources.s.items.1.name)}" } }
        """)
        let output = try WorkflowEngine.evaluate(
            def,
            sources: ["s": .object(["items": .array([
                .object(["name": .string("a")]), .object(["name": .string("b")]),
            ])])],
            settings: .object([:])
        )
        XCTAssertEqual(output.viewTree.text, "b") // items[1].name
    }

    /// Flagship native widgets behave like real ones: clicking the whole card
    /// opens their companion app / page. Guards the declared root-level actions.
    func testWiredNativeWidgetsDeclareClickActions() throws {
        let widgetsDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("widgets")
        let expected: [String: String] = [
            "today": "openApp", "calendar": "openApp", "system": "openApp",
            "weather": "openApp", "now-playing": "openApp", "reminders": "openApp",
            "clock": "openURL", "battery-meter": "openURL", "network": "openURL",
            "stock": "openURL", "exchange": "openURL", "github-status": "openURL",
            "downloads-new": "revealFile",
        ]
        for (name, type) in expected {
            let wf = widgetsDir.appendingPathComponent(name).appendingPathComponent("workflow.json")
            let json = try JSONSerialization.jsonObject(with: try Data(contentsOf: wf))
            let types = Self.collectActionTypes(json)
            XCTAssertTrue(
                types.contains(type),
                "\(name) should declare a \(type) click action, found \(types)"
            )
        }
    }

    /// Recursively gathers every `action.type` declared anywhere in a view tree.
    private static func collectActionTypes(_ any: Any) -> Set<String> {
        var found: Set<String> = []
        if let dict = any as? [String: Any] {
            if let action = dict["action"] as? [String: Any],
               let type = action["type"] as? String {
                found.insert(type)
            }
            for value in dict.values { found.formUnion(collectActionTypes(value)) }
        } else if let array = any as? [Any] {
            for value in array { found.formUnion(collectActionTypes(value)) }
        }
        return found
    }
}

final class StorageServiceSnapshotTests: XCTestCase {
    func testSnapshotExcludesExpiredEntries() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("barshelf-storage-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = StorageService(directory: dir)
        let now: Double = 1_000_000

        try store.set(widgetId: "w", key: "live", value: .string("a"), ttlMs: nil, nowMs: now)
        try store.set(widgetId: "w", key: "soon", value: .string("b"), ttlMs: 100, nowMs: now)

        let before = store.snapshot(widgetId: "w", nowMs: now + 50)
        XCTAssertEqual(before["live"], .string("a"))
        XCTAssertEqual(before["soon"], .string("b"))

        let after = store.snapshot(widgetId: "w", nowMs: now + 200)
        XCTAssertEqual(after["live"], .string("a"))
        XCTAssertNil(after["soon"]) // TTL elapsed → excluded from the snapshot
    }
}

final class FileSourceTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("barshelf-filesource-\(UUID().uuidString)")
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

        let missing = try FileSource.Params(from: .object(["path": .string("/nonexistent-barshelf-test")]))
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

/// The aas-meters gallery widget re-creates aas usage as native meter bars via
/// a hand-authored workflow (nested forEach + logic). Guard its expressions.
final class AasMetersWidgetTests: XCTestCase {
    private func allNodes(ofType type: String, in node: UINode) -> [UINode] {
        var out = node.type == type ? [node] : []
        for child in (node.children ?? []) + (node.items ?? []) {
            out += allNodes(ofType: type, in: child)
        }
        return out
    }

    func testAasMetersRendersHealthColoredBars() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = packageRoot.appendingPathComponent("widgets/aas-meters/workflow.json")
        let def = try WorkflowDefinition.decode(from: try Data(contentsOf: url))

        let payload: JSONValue = .object(["accounts": .array([
            .object([
                "provider": .string("anthropic"), "name": .string("work"),
                "meters": .array([
                    .object(["label": .string("5h"), "usedPct": .number(82)]),
                    .object(["label": .string("weekly"), "usedPct": .number(95)]),
                ]),
            ]),
            .object([
                "provider": .string("openai"), "name": .string("personal"),
                "meters": .array([]),
            ]),
        ])])

        let output = try WorkflowEngine.evaluate(
            def, sources: ["data": payload], settings: .object([:])
        )
        // 2 accounts expanded + 2 meters (first) + 0 (second) = 4.
        XCTAssertEqual(output.expandedItemCount, 4)
        XCTAssertFalse(output.usedEmpty)

        let bars = allNodes(ofType: "progress", in: output.viewTree)
        XCTAssertEqual(bars.count, 2)
        XCTAssertEqual(bars[0].value ?? 0, 0.82, accuracy: 0.0001)
        XCTAssertEqual(bars[0].tint, "warning") // 82% → warning
        XCTAssertEqual(bars[1].value ?? 0, 0.95, accuracy: 0.0001)
        XCTAssertEqual(bars[1].tint, "danger")  // 95% → danger

        let text = flattenText(output.viewTree)
        XCTAssertTrue(text.contains("work"))
        XCTAssertTrue(text.contains("anthropic"))
        XCTAssertTrue(text.contains("82%"))
        XCTAssertTrue(text.contains("95%"))
    }

    func testAasMetersEmptyState() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = packageRoot.appendingPathComponent("widgets/aas-meters/workflow.json")
        let def = try WorkflowDefinition.decode(from: try Data(contentsOf: url))
        let output = try WorkflowEngine.evaluate(
            def, sources: ["data": .object(["accounts": .array([])])], settings: .object([:])
        )
        XCTAssertTrue(output.usedEmpty)
        XCTAssertEqual(output.viewTree.type, "empty")
    }

    private func flattenText(_ node: UINode) -> String {
        var out = node.text ?? ""
        for child in (node.children ?? []) + (node.items ?? []) {
            out += "\n" + flattenText(child)
        }
        return out
    }
}

/// The recent-files-grid widget renders files as a stashbar-style tile grid.
final class GridWidgetTests: XCTestCase {
    private func firstNode(ofType type: String, in node: UINode) -> UINode? {
        if node.type == type { return node }
        for child in (node.children ?? []) + (node.items ?? []) {
            if let found = firstNode(ofType: type, in: child) { return found }
        }
        return nil
    }

    func testRecentFilesGridProducesTappableDraggableTiles() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("barshelf-grid-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["a.png", "b.pdf", "c.txt"] {
            try Data(name.utf8).write(to: dir.appendingPathComponent(name))
        }

        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = packageRoot.appendingPathComponent("widgets/recent-files-grid/workflow.json")
        let def = try WorkflowDefinition.decode(from: try Data(contentsOf: url))

        let settings: JSONValue = .object(["folder": .string(dir.path), "limit": .number(24)])
        let params = try WorkflowEngine.resolvedSourceParams(def, settings: settings)
        let listing = try FileSource.list(try FileSource.Params(from: try XCTUnwrap(params["files"])))

        // Default view mode (no setting) falls through to the grid branch.
        let output = try WorkflowEngine.evaluate(
            def, sources: ["files": listing], settings: settings
        )
        let grid = try XCTUnwrap(firstNode(ofType: "grid", in: output.viewTree))
        XCTAssertEqual(grid.items?.count, 3)                     // one tile per file
        let tile = try XCTUnwrap(grid.items?.first)
        XCTAssertNotNil(tile.drag?.filePath)                     // drag-out
        XCTAssertEqual(tile.action?.type, "openFile")           // click opens
        XCTAssertEqual(tile.children?.first?.source?.kind, "fileThumbnail")
        XCTAssertNotNil(tile.children?.last?.text)               // file name label

        // viewMode "List" switches to a row list (no grid node present).
        let listSettings: JSONValue = .object([
            "folder": .string(dir.path), "limit": .number(24), "viewMode": .string("List"),
        ])
        let listOut = try WorkflowEngine.evaluate(
            def, sources: ["files": listing], settings: listSettings
        )
        XCTAssertNil(firstNode(ofType: "grid", in: listOut.viewTree))
        let list = try XCTUnwrap(firstNode(ofType: "list", in: listOut.viewTree))
        XCTAssertEqual(list.items?.count, 3)
        XCTAssertEqual(list.items?.first?.action?.type, "openFile")
    }

    func testGridIsAKnownNodeType() {
        XCTAssertTrue(UINode(type: "grid").isKnownType)
        XCTAssertEqual(UINode(type: "grid", columns: 4).columns, 4)
    }
}

/// The Today widget renders a different native-style layout per widget size,
/// driven by a `switch` on ${widget.size}.
final class TodayWidgetTests: XCTestCase {
    private func todayDef() throws -> WorkflowDefinition {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = packageRoot.appendingPathComponent("widgets/today/workflow.json")
        return try WorkflowDefinition.decode(from: try Data(contentsOf: url))
    }

    private let sample: JSONValue = .object([
        "weekday": .string("Wednesday"), "month": .string("Jul"),
        "day": .string("09"), "time": .string("17:45"), "year": .string("2026"),
    ])

    private func render(size: String) throws -> UINode {
        try WorkflowEngine.evaluate(
            try todayDef(), sources: ["data": sample], settings: .object([:]),
            widget: .object(["size": .string(size)])
        ).viewTree
    }

    func testSmallLayoutShowsBigDayNumber() throws {
        let tree = try render(size: "S")               // small → default branch
        XCTAssertEqual(tree.type, "vstack")
        XCTAssertEqual(tree.children?[1].text, "09")
        XCTAssertEqual(tree.children?[1].size, 46)      // large day number
    }

    func testMediumLayoutIsSideBySide() throws {
        let tree = try render(size: "M")
        XCTAssertEqual(tree.type, "hstack")
        XCTAssertEqual(tree.children?.first?.children?[1].size, 40) // day number
    }

    func testLargeLayoutHasLargestNumber() throws {
        let tree = try render(size: "L")
        XCTAssertEqual(tree.type, "vstack")
        let day = tree.children?[1].children?.first
        XCTAssertEqual(day?.text, "09")
        XCTAssertEqual(day?.size, 64)                   // largest day number
    }
}

/// The Battery widget renders a level-colored meter + glyph from a shell source.
final class BatteryWidgetTests: XCTestCase {
    private func batteryDef() throws -> WorkflowDefinition {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = packageRoot.appendingPathComponent("widgets/battery-meter/workflow.json")
        return try WorkflowDefinition.decode(from: try Data(contentsOf: url))
    }

    private func firstNode(ofType type: String, in node: UINode) -> UINode? {
        if node.type == type { return node }
        for child in (node.children ?? []) + (node.items ?? []) {
            if let found = firstNode(ofType: type, in: child) { return found }
        }
        return nil
    }

    private func render(pct: Double, state: String) throws -> UINode {
        try WorkflowEngine.evaluate(
            try batteryDef(),
            sources: ["data": .object(["pct": .number(pct), "state": .string(state)])],
            settings: .object([:])
        ).viewTree
    }

    func testHealthyBatteryIsGreen() throws {
        let tree = try render(pct: 80, state: "charging")
        XCTAssertEqual(tree.children?[1].text, "80%")
        let meter = try XCTUnwrap(firstNode(ofType: "progress", in: tree))
        XCTAssertEqual(meter.value ?? 0, 0.8, accuracy: 0.0001)
        XCTAssertEqual(meter.tint, "good")
        XCTAssertEqual(firstNode(ofType: "image", in: tree)?.source?.name, "battery.100percent")
    }

    func testLowBatteryIsRed() throws {
        let tree = try render(pct: 5, state: "discharging")
        let meter = try XCTUnwrap(firstNode(ofType: "progress", in: tree))
        XCTAssertEqual(meter.tint, "danger")
        XCTAssertEqual(firstNode(ofType: "image", in: tree)?.source?.name, "battery.25percent")
    }
}

/// End-to-end checks for the native clock / system / weather widgets.
final class NativeWidgetsTests: XCTestCase {
    private func def(_ name: String) throws -> WorkflowDefinition {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try WorkflowDefinition.decode(
            from: try Data(contentsOf: root.appendingPathComponent("widgets/\(name)/workflow.json"))
        )
    }

    private func allNodes(ofType type: String, in node: UINode) -> [UINode] {
        var out = node.type == type ? [node] : []
        for child in (node.children ?? []) + (node.items ?? []) {
            out += allNodes(ofType: type, in: child)
        }
        return out
    }

    private func flat(_ node: UINode) -> String {
        (node.text ?? "") + ((node.children ?? []) + (node.items ?? [])).map(flat).joined(separator: "\n")
    }

    func testClockShowsBigTime() throws {
        let out = try WorkflowEngine.evaluate(
            try def("clock"),
            sources: ["data": .object([
                "h": .string("20"), "m": .string("53"), "s": .string("26"), "date": .string("Thu Jul 09"),
            ])],
            settings: .object([:])
        )
        let timeRow = out.viewTree.children?[1]
        XCTAssertEqual(timeRow?.children?.first?.text, "20:53")
        XCTAssertEqual(timeRow?.children?.first?.size, 44)
        XCTAssertEqual(timeRow?.children?.last?.text, "26")
    }

    func testSystemMetersHealthColors() throws {
        let out = try WorkflowEngine.evaluate(
            try def("system"),
            sources: ["data": .object(["disk": .number(92), "cpu": .number(30), "mem": .number(50)])],
            settings: .object([:])
        )
        let bars = allNodes(ofType: "progress", in: out.viewTree)
        XCTAssertEqual(bars.count, 3)                               // CPU, Memory, Disk
        XCTAssertEqual(bars[0].value ?? 0, 0.30, accuracy: 0.0001)  // CPU
        XCTAssertEqual(bars[0].tint, "good")
        XCTAssertEqual(bars[2].value ?? 0, 0.92, accuracy: 0.0001)  // Disk
        XCTAssertEqual(bars[2].tint, "danger")
    }

    func testWeatherMapsCodeToConditionAndIcon() throws {
        let out = try WorkflowEngine.evaluate(
            try def("weather"),
            sources: ["data": .object([
                "current": .object(["temperature_2m": .number(24.4), "weather_code": .number(51)]),
            ])],
            settings: .object(["place": .string("Seoul"), "lat": .string("37.57"), "lon": .string("126.98")])
        )
        let text = flat(out.viewTree)
        XCTAssertTrue(text.contains("24°"))          // rounded temperature
        XCTAssertTrue(text.contains("Rain"))          // code 51 → Rain
        XCTAssertEqual(allNodes(ofType: "image", in: out.viewTree).first?.source?.name, "cloud.rain.fill")
    }

    func testWeatherClearIcon() throws {
        let out = try WorkflowEngine.evaluate(
            try def("weather"),
            sources: ["data": .object([
                "current": .object(["temperature_2m": .number(18), "weather_code": .number(0)]),
            ])],
            settings: .object(["place": .string("X"), "lat": .string("0"), "lon": .string("0")])
        )
        XCTAssertEqual(allNodes(ofType: "image", in: out.viewTree).first?.source?.name, "sun.max.fill")
        XCTAssertTrue(flat(out.viewTree).contains("Clear"))
    }

    func testCalendarGridHighlightsToday() throws {
        let cells: [JSONValue] = Array(repeating: .number(0), count: 3)
            + (1...31).map { JSONValue.number(Double($0)) }
        let out = try WorkflowEngine.evaluate(
            try def("calendar"),
            sources: ["data": .object([
                "today": .number(9), "month": .string("July"), "cells": .array(cells),
            ])],
            settings: .object([:])
        )
        let grids = allNodes(ofType: "grid", in: out.viewTree)
        XCTAssertEqual(grids.count, 2)                 // weekday header + day cells
        let dayGrid = grids[1]
        XCTAssertEqual(dayGrid.columns, 7)
        XCTAssertEqual(dayGrid.items?.count, 34)       // 3 leading blanks + 31 days
        XCTAssertEqual(dayGrid.items?.first?.text, "") // blank cell
        let nine = dayGrid.items?.first { $0.text == "9" }
        XCTAssertEqual(nine?.fill, "accent")           // today gets a filled circle
        XCTAssertEqual(nine?.role, "title")            // and bold
        XCTAssertEqual(dayGrid.items?.first { $0.text == "10" }?.fill, "") // others: no circle
    }

    func testExchangeShowsRate() throws {
        let out = try WorkflowEngine.evaluate(
            try def("exchange"),
            sources: ["data": .object(["rates": .object(["KRW": .number(1506.3)])])],
            settings: .object([:])
        )
        XCTAssertTrue(flat(out.viewTree).contains("₩1506"))
    }

    func testNetworkShowsIP() throws {
        let out = try WorkflowEngine.evaluate(
            try def("network"),
            sources: ["data": .object(["ip": .string("172.30.0.5")])],
            settings: .object([:])
        )
        XCTAssertTrue(flat(out.viewTree).contains("172.30.0.5"))
    }

    func testSystemHasThreeMeters() throws {
        let out = try WorkflowEngine.evaluate(
            try def("system"),
            sources: ["data": .object(["disk": .number(50), "cpu": .number(20), "mem": .number(70)])],
            settings: .object([:])
        )
        XCTAssertEqual(allNodes(ofType: "progress", in: out.viewTree).count, 3) // CPU, Memory, Disk
    }

    func testStockPriceChangeAndColor() throws {
        let out = try WorkflowEngine.evaluate(
            try def("stock"),
            sources: ["data": .object(["chart": .object(["result": .array([
                .object(["meta": .object([
                    "symbol": .string("AAPL"),
                    "regularMarketPrice": .number(313.39),
                    "chartPreviousClose": .number(310.66),
                ])]),
            ])])])],
            settings: .object(["symbol": .string("AAPL")])
        )
        let text = flat(out.viewTree)
        XCTAssertTrue(text.contains("313.39"))  // price via result.0.meta (array index)
        XCTAssertTrue(text.contains("AAPL"))
        XCTAssertTrue(text.contains("▲"))        // up
        XCTAssertEqual(out.viewTree.children?.last?.foreground, "good") // green
    }

    func testNowPlayingShowsTrack() throws {
        let out = try WorkflowEngine.evaluate(
            try def("now-playing"),
            sources: ["data": .object(["track": .string("Bohemian Rhapsody - Queen")])],
            settings: .object([:])
        )
        XCTAssertTrue(flat(out.viewTree).contains("Bohemian Rhapsody - Queen"))
    }

    func testRemindersShowsOpenCount() throws {
        let out = try WorkflowEngine.evaluate(
            try def("reminders"),
            sources: ["data": .object(["count": .number(3)])],
            settings: .object([:])
        )
        XCTAssertTrue(flat(out.viewTree).contains("3"))
    }
}

/// End-to-end evaluation of the shipped persistence example widgets, so the
/// hand-authored nested expressions can't silently rot.
final class PersistenceWidgetTests: XCTestCase {
    private let nowMs: Double = 1_783_442_400_000

    private func widgetWorkflow(_ name: String) throws -> WorkflowDefinition {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = packageRoot.appendingPathComponent("widgets/\(name)/workflow.json")
        return try WorkflowDefinition.decode(from: try Data(contentsOf: url))
    }

    func testVisitCounterIncrementsAndPersists() throws {
        let def = try widgetWorkflow("visit-counter")
        let firstAt = nowMs - 3 * 60_000
        let output = try WorkflowEngine.evaluate(
            def, sources: [:], settings: .object([:]),
            storage: .object([
                "count": .number(2),
                "firstAt": .number(firstAt),
                "lastAt": .number(nowMs - 60_000),
            ]),
            nowMs: nowMs
        )
        // The running count renders as prior + 1.
        let valueNode = output.viewTree.children?[1].children?.first
        XCTAssertEqual(valueNode?.text, "3")
        XCTAssertEqual(output.statusLabel, "3")

        let byKey = Dictionary(uniqueKeysWithValues: output.writes.map { ($0.key, $0.value) })
        XCTAssertEqual(byKey["count"], .number(3))
        XCTAssertEqual(byKey["firstAt"], .number(firstAt)) // preserved across visits
        XCTAssertEqual(byKey["lastAt"], .number(nowMs))     // stamped now
    }

    func testDownloadsNewShowsSignedDelta() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("barshelf-downloads-new-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["a.txt", "b.txt", "c.txt", "d.txt", "e.txt"] {
            try Data(name.utf8).write(to: dir.appendingPathComponent(name))
        }

        let def = try widgetWorkflow("downloads-new")
        let settings: JSONValue = .object(["folder": .string(dir.path)])
        let params = try WorkflowEngine.resolvedSourceParams(def, settings: settings)
        let listing = try FileSource.list(try FileSource.Params(from: try XCTUnwrap(params["files"])))

        // 5 files now, 3 at the last check → +2.
        let output = try WorkflowEngine.evaluate(
            def, sources: ["files": listing], settings: settings,
            storage: .object(["count": .number(3)]), nowMs: nowMs
        )
        let deltaNode = output.viewTree.children?[1]
        XCTAssertEqual(deltaNode?.text, "+2 since last check")
        XCTAssertEqual(deltaNode?.foreground, "good")
        XCTAssertEqual(output.writes.first(where: { $0.key == "count" })?.value, .number(5))

        // First-ever check (no stored count) → no change, neutral tint.
        let firstRun = try WorkflowEngine.evaluate(
            def, sources: ["files": listing], settings: settings,
            storage: .object([:]), nowMs: nowMs
        )
        XCTAssertEqual(firstRun.viewTree.children?[1].text, "+0 since last check")
        XCTAssertEqual(firstRun.viewTree.children?[1].foreground, "secondary")
    }
}
