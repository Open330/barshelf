import XCTest
import MenubucketCore
@testable import MenubucketApp

/// Exercises the pure page layout used by `WidgetRuntime.pages`: bucket
/// overrides win over the manifest, disabled widgets vanish, empty groups
/// disappear, and both members and pages keep a stable order.
final class WidgetPagesTests: XCTestCase {
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
