import XCTest
import MenubucketCore
@testable import MenubucketApp

/// Exercises the pure page layout used by `WidgetRuntime.pages`: bucket
/// overrides win over the manifest, disabled widgets vanish, empty groups
/// disappear, and both members and pages keep a stable order.
final class WidgetPagesTests: XCTestCase {
    func testInitialPageMaterializationIsBoundedAndVisitedPagesSurviveFarJumps() {
        let ids = (0..<20).map { "page-\($0)" }
        func mounted(_ selected: Int, visited: Set<String> = []) -> [String] {
            ids.enumerated().compactMap { index, id in
                RootView.shouldMaterializePage(
                    at: index, selectedIndex: selected, pageID: id, visited: visited
                ) ? id : nil
            }
        }
        XCTAssertEqual(mounted(0), ["page-0", "page-1"])
        XCTAssertEqual(mounted(10), ["page-9", "page-10", "page-11"])
        XCTAssertEqual(mounted(19), ["page-18", "page-19"])
        // Preserve the old page during a keyboard jump and keep its scroll
        // position when returning, without mounting the intervening pages.
        XCTAssertEqual(mounted(10, visited: ["page-0", "page-1"]),
                       ["page-0", "page-1", "page-9", "page-10", "page-11"])
    }

    func testDistantNavigationDoesNotAnimateAcrossUnbuiltPages() {
        let pager = PagerState()
        pager.jump(to: 9, pageCount: 20)
        XCTAssertFalse(pager.animatesPageTransition)
        pager.step(1, pageCount: 20)
        XCTAssertTrue(pager.animatesPageTransition)
        pager.jump(to: 0, pageCount: 20)
        XCTAssertFalse(pager.animatesPageTransition)
        pager.beginSwipe()
        XCTAssertTrue(pager.animatesPageTransition)
    }

    func testRepeatedNavigationDoesNotPublishAnUnchangedSelection() {
        let pager = PagerState()
        var selections: [Int] = []
        let subscription = pager.$index.dropFirst().sink { selections.append($0) }

        pager.clamp(to: 0)
        pager.clamp(to: 3)
        pager.step(-1, pageCount: 3)
        pager.jump(to: 0, pageCount: 3)
        XCTAssertTrue(selections.isEmpty)

        pager.step(1, pageCount: 3)
        pager.jump(to: 1, pageCount: 3)
        pager.clamp(to: 3)
        pager.jump(to: 2, pageCount: 3)
        pager.step(1, pageCount: 3)
        pager.clamp(to: 1)
        pager.clamp(to: 0)
        XCTAssertEqual(selections, [1, 2, 0])
        withExtendedLifetime(subscription) {}
    }

    private func widget(_ id: String, group: String?, order: Int?) -> LoadedWidget {
        LoadedWidget(
            manifest: Manifest(
                schemaVersion: 1,
                id: id,
                name: id,
                bucket: Manifest.Bucket(group: group, order: order),
                entry: Manifest.Entry(kind: "exec")
            ),
            directory: URL(fileURLWithPath: "/tmp/\(id)")
        )
    }

    func testOverridesRegroupAndReorder() {
        let widgets = [
            widget("a", group: "General", order: 0),
            widget("b", group: "General", order: 1),
            widget("c", group: "Ops", order: 0),
        ]
        // Move "a" into Ops and push it after "c" via an order override.
        let overrideGroup = ["a": "Ops"]
        let overrideOrder: [String: Double] = ["a": 5]

        let pages = WidgetRuntime.computePages(
            widgets,
            group: { overrideGroup[$0.id] ?? $0.group },
            order: { overrideOrder[$0.id] ?? Double($0.order) },
            isDisabled: { _ in false }
        )

        // Ops sorts first: its first member ("c", order 0) precedes General's
        // first member ("b", order 1). "a" lands after "c" via its order override.
        XCTAssertEqual(pages.map(\.group), ["Ops", "General"])
        XCTAssertEqual(pages[0].widgets.map(\.id), ["c", "a"])
        XCTAssertEqual(pages[1].widgets.map(\.id), ["b"])
    }

    func testDisabledWidgetLeavesEmptyGroupOut() {
        let widgets = [
            widget("a", group: "General", order: 0),
            widget("solo", group: "Solo", order: 0),
        ]

        let pages = WidgetRuntime.computePages(
            widgets,
            group: { $0.group },
            order: { Double($0.order) },
            isDisabled: { $0.id == "solo" }
        )

        XCTAssertEqual(pages.map(\.group), ["General"])
    }

    func testAKeptPageStaysWhileEmptyInItsPlace() {
        let widgets = [
            widget("a", group: "General", order: 0),
            widget("off", group: "Later", order: 0),
        ]
        let order = ["General": 0.0, "Ideas": 1, "Later": 2]
        let pages = WidgetRuntime.computePages(
            widgets,
            group: { $0.group },
            order: { Double($0.order) },
            isDisabled: { $0.id == "off" },
            groupSort: { order[$0] ?? .greatestFiniteMagnitude },
            keptPages: ["Ideas", "Later"]
        )
        // A made page with nothing in it, and one whose widgets are all off,
        // both stay as empty pages; nothing else changes.
        XCTAssertEqual(pages.map(\.group), ["General", "Ideas", "Later"])
        XCTAssertEqual(pages.map(\.widgets.count), [1, 0, 0])
    }

    func testARenamedDefaultPageKeepsItsPlace() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("renamed-pages-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let prefs = WidgetPrefs(fileURL: url)
        prefs.setGroupsOrder(["System", "Demo", "Files"])
        // A widget still on Demo (an old copy, or the user's own override): no change.
        XCTAssertFalse(prefs.migrateRenamedPages(inUse: ["System", "Demo", "Files"]))
        XCTAssertTrue(prefs.migrateRenamedPages(inUse: ["System", "Everyday", "Files"]))
        XCTAssertEqual(prefs.groupSortKey("Everyday"), 1)
        XCTAssertNil(prefs.groupSortKey("Demo"))
        XCTAssertFalse(prefs.migrateRenamedPages(inUse: ["System", "Everyday", "Files"]))

        // Everyday already placed by the user wins; Demo's key just goes.
        prefs.setGroupsOrder(["Everyday", "System", "Demo"])
        prefs.migrateRenamedPages(inUse: ["Everyday", "System"])
        XCTAssertEqual(prefs.groupSortKey("Everyday"), 0)
        XCTAssertNil(prefs.groupSortKey("Demo"))
    }

    func testKeptPagesPersistAndUndoWithTheLayout() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kept-pages-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let prefs = WidgetPrefs(fileURL: url)
        let before = prefs.layoutState
        prefs.setKeptPages(["Ideas", "Ideas", "", "Later"])
        XCTAssertEqual(prefs.keptPages, ["Ideas", "Later"])
        XCTAssertEqual(WidgetPrefs(fileURL: url).keptPages, ["Ideas", "Later"])
        prefs.restoreLayout(before)
        XCTAssertEqual(prefs.keptPages, [])
    }

    func testVisibleWidgetIDsContainSelectedPageAndOnlyDisplayedEnabledPins() {
        let pages = [
            WidgetPage(group: "First", widgets: [
                widget("a", group: "First", order: 0),
                widget("pinned-1", group: "First", order: 1),
            ]),
            WidgetPage(group: "Third", widgets: [
                widget("reminders", group: "Third", order: 0),
                widget("pinned-2", group: "Third", order: 1),
                widget("pinned-hidden", group: "Third", order: 2),
            ]),
        ]

        XCTAssertEqual(
            RootView.visibleWidgetIDs(
                pages: pages, index: 0,
                pinnedIDs: ["disabled", "pinned-1", "pinned-2", "pinned-hidden"]
            ),
            ["a", "pinned-1", "pinned-2"]
        )
        XCTAssertEqual(
            RootView.visibleWidgetIDs(
                pages: pages, index: 1,
                pinnedIDs: ["disabled", "pinned-1", "pinned-2", "pinned-hidden"]
            ),
            // The overflow pin still runs while its regular card is on the
            // selected page, even though it is absent from the pinned strip.
            ["reminders", "pinned-1", "pinned-2", "pinned-hidden"]
        )
    }

    func testOnlySelectedPagerPageKeepsContentWorkActive() {
        XCTAssertTrue(RootView.pageContentIsActive(
            pageID: "Agents", selectedPageID: "Agents"
        ))
        XCTAssertFalse(RootView.pageContentIsActive(
            pageID: "Files", selectedPageID: "Agents"
        ))
    }

    func testOpeningSearchCancelsAnInProgressPagerSwipe() {
        let pager = PagerState()
        pager.beginSwipe()
        pager.updateSwipe(totalDeltaX: -90, pageCount: 3)
        XCTAssertTrue(pager.isSwiping)
        XCTAssertEqual(pager.dragOffset, -90)

        pager.setSearchPresented(true)
        XCTAssertTrue(pager.searchIsPresented)
        XCTAssertFalse(pager.isSwiping)
        XCTAssertEqual(pager.dragOffset, 0)
    }

    func testInstanceDirectorySuffixCreatesIndependentDisplayIdentity() {
        let manifest = Manifest(
            schemaVersion: 1,
            id: "dev.barshelf.muxa-watch",
            name: "muxa Watch",
            entry: Manifest.Entry(kind: "script")
        )
        let instanceID = WidgetRuntime.instanceID(
            manifestID: manifest.id,
            directoryName: "dev.barshelf.muxa-watch--jiun-mbp"
        )
        let widget = LoadedWidget(
            manifest: manifest,
            directory: URL(fileURLWithPath: "/tmp/\(instanceID)"),
            instanceID: instanceID
        )

        XCTAssertEqual(widget.id, "dev.barshelf.muxa-watch--jiun-mbp")
        XCTAssertEqual(widget.displayName, "muxa Watch · jiun-mbp")
        XCTAssertEqual(
            WidgetRuntime.instanceID(
                manifestID: manifest.id,
                directoryName: "muxa-watch"
            ),
            manifest.id
        )
        XCTAssertEqual(WidgetRuntime.normalizedInstanceLabel(" Jiun MBP "), "jiun-mbp")
    }

    func testDiscoveryLoadsCanonicalWidgetAndSymlinkedInstances() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("widget-instances-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let manifestID = "dev.barshelf.muxa-watch"
        let canonical = root.appendingPathComponent(manifestID)
        try FileManager.default.createDirectory(
            at: canonical, withIntermediateDirectories: true
        )
        let manifest = """
        {
          "schemaVersion": 1,
          "id": "\(manifestID)",
          "name": "muxa Watch",
          "entry": { "kind": "script" }
        }
        """
        try Data(manifest.utf8).write(
            to: canonical.appendingPathComponent("widget.json")
        )
        for label in ["jiun-mbp", "jiun-mini", "rtzr"] {
            try FileManager.default.createSymbolicLink(
                at: root.appendingPathComponent("\(manifestID)--\(label)"),
                withDestinationURL: canonical
            )
        }

        let widgets = WidgetRuntime.discoverWidgets(in: [root])

        XCTAssertEqual(
            Set(widgets.map(\.id)),
            Set([
                manifestID,
                "\(manifestID)--jiun-mbp",
                "\(manifestID)--jiun-mini",
                "\(manifestID)--rtzr",
            ])
        )
    }

    func testRuntimeDiscoveryRejectsUnsupportedManifestSchemaVersion() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("widget-version-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let supported = root.appendingPathComponent("supported", isDirectory: true)
        let unsupported = root.appendingPathComponent("unsupported", isDirectory: true)
        try FileManager.default.createDirectory(
            at: supported, withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: unsupported, withIntermediateDirectories: true
        )
        try Data("""
        { "schemaVersion": 1, "id": "supported", "name": "Supported",
          "entry": { "kind": "exec" } }
        """.utf8).write(to: supported.appendingPathComponent("widget.json"))
        try Data("""
        { "schemaVersion": 2, "id": "unsupported", "name": "Unsupported",
          "entry": { "kind": "exec" } }
        """.utf8).write(to: unsupported.appendingPathComponent("widget.json"))

        let widgets = WidgetRuntime.discoverWidgets(in: [root])

        XCTAssertEqual(widgets.map(\.id), ["supported"])
    }
}

final class ScriptRefreshCoalescerTests: XCTestCase {
    func testOverlappingGenerationIsRejectedUntilMatchingCompletion() {
        var coalescer = ScriptRefreshCoalescer()

        XCTAssertTrue(coalescer.begin(widgetID: "muxa", generation: "first"))
        XCTAssertFalse(coalescer.begin(widgetID: "muxa", generation: "overlap"))
        XCTAssertTrue(coalescer.markRendered(widgetID: "muxa", generation: "first"))
        XCTAssertEqual(coalescer.finish(widgetID: "muxa", generation: "first"), true)
        XCTAssertTrue(coalescer.begin(widgetID: "muxa", generation: "second"))
    }

    func testStaleCompletionCannotReleaseNewGeneration() {
        var coalescer = ScriptRefreshCoalescer()

        XCTAssertTrue(coalescer.begin(widgetID: "muxa", generation: "first"))
        XCTAssertEqual(coalescer.finish(widgetID: "muxa", generation: "first"), false)
        XCTAssertTrue(coalescer.begin(widgetID: "muxa", generation: "second"))

        XCTAssertNil(coalescer.finish(widgetID: "muxa", generation: "first"))
        XCTAssertFalse(coalescer.begin(widgetID: "muxa", generation: "third"))
        XCTAssertEqual(coalescer.finish(widgetID: "muxa", generation: "second"), false)
    }

    func testCallbackGateRejectsQueuedCallbacksAfterDisableAndReenable() {
        let gate = ScriptCallbackGate()
        let oldToken = gate.token(for: "muxa")
        gate.invalidate(widgetID: "muxa")

        XCTAssertFalse(gate.accepts(widgetID: "muxa", token: oldToken))
        XCTAssertTrue(gate.accepts(widgetID: "muxa", token: gate.token(for: "muxa")))
    }
}
