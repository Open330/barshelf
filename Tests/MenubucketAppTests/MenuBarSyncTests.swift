import AppKit
import XCTest
import MenubucketCore
@testable import MenubucketApp

/// What `WidgetRuntime.syncMenuBar` decides, pinned before it is split up.
///
/// Requires a disposable Foundation home: never starts a live runtime against
/// the user's installed widgets. Run with CFFIXED_USER_HOME.
@MainActor
final class MenuBarSyncTests: XCTestCase {
    /// A fixed clock for the syncs under test; nothing here waits for time.
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)

    // MARK: - Order and cap

    func testCandidatesAreOrderedByKeyThenNameThenWidgetOrderAndCappedAtFive() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let bravo = try fixture.addWidget("a", name: "Bravo", reading: 1)
        let alpha = try fixture.addWidget("b", name: "Alpha", reading: 1)
        let delta = try fixture.addWidget("c", name: "delta", reading: 1)
        let charlie = try fixture.addWidget("d", name: "Charlie", reading: 1)
        // Directory order and id order disagree, so the tie is seen to follow
        // the runtime's own widget order and nothing else.
        let sameOne = try fixture.addWidget("e", name: "Same", reading: 1, idSuffix: "zz")
        let sameTwo = try fixture.addWidget("f", name: "Same", reading: 1, idSuffix: "aa")
        let zulu = try fixture.addWidget("g", name: "Zulu", reading: 1)
        let runtime = try fixture.makeRuntime()

        runtime.prefs.setMenuBarPlacements([
            bravo: .init(enabled: true, order: 2),
            alpha: .init(enabled: true, order: 1),
            delta: .init(enabled: true),
            charlie: .init(enabled: true),
            sameOne: .init(enabled: true),
            sameTwo: .init(enabled: true),
            zulu: .init(enabled: true),
        ])
        runtime.syncMenuBar(now: t0)

        let widgetOrder = runtime.widgets.map(\.id)
        let firstSame = try XCTUnwrap([sameOne, sameTwo].min {
            widgetOrder.firstIndex(of: $0)! < widgetOrder.firstIndex(of: $1)!
        })
        XCTAssertEqual(
            runtime.ownedMenuBarEntries.map(\.widgetID),
            [alpha, bravo, charlie, delta, firstSame],
            "explicit keys first, then names without regard to case, then the widget list's order"
        )
        XCTAssertEqual(runtime.ownedMenuBarEntries.count, MenuBarPolicy.maxEntries)
        XCTAssertEqual(runtime.menuBarWidgetIDs, [alpha, bravo, charlie, delta, firstSame])
    }

    func testDormantItemStillHoldsOneOfTheFiveSlotsAndItsPlaceInTheStrip() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let hidden = try fixture.addWidget("a", name: "Hidden", reading: 10)
        let shown = try (1...4).map { try fixture.addWidget("b\($0)", name: "Shown \($0)", reading: 10) }
        let sixth = try fixture.addWidget("c", name: "Sixth", reading: 10)
        let runtime = try fixture.makeRuntime()

        var placements: [String: MenuBarPlacement?] = [
            hidden: .init(enabled: true, order: 1, presentation: .init(showWhen: 80)),
            sixth: .init(enabled: true, order: 6),
        ]
        for (index, id) in shown.enumerated() {
            placements[id] = .init(enabled: true, order: Double(index + 2))
        }
        runtime.prefs.setMenuBarPlacements(placements)
        runtime.syncMenuBar(now: t0)

        XCTAssertEqual(runtime.dormantMenuBarWidgetIDs, [hidden])
        XCTAssertEqual(runtime.ownedMenuBarEntries.map(\.widgetID), [hidden] + shown,
                       "the cap counts the hidden item")
        XCTAssertFalse(runtime.menuBarWidgetIDs.contains(sixth),
                       "a hidden item does not free its slot for the sixth")
        XCTAssertEqual(runtime.menuBarStripOrder, [hidden] + shown,
                       "a hidden item keeps its place in the strip order")
        XCTAssertEqual(runtime.menuBar.entries.map(\.widgetID), shown)
    }

    // MARK: - Disabled widgets

    func testDisabledWidgetIsNoCandidateAndLosesItsChartHistoryAndShowWhenStamp() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let charted = try fixture.addWidget("a", name: "Charted", reading: nil)
        let limited = try fixture.addWidget("b", name: "Limited", reading: 90)
        // A history from "the last run", and the placement that lets a widget
        // with no render yet keep it through the launch sync.
        let chartFile = MenuBarChartRecorder.defaultFileURL
        try MenuBarChartHistoryStore.save(
            [charted: MenuBarChartHistory(series: "cpu", scale: 100, values: [1, 2, 3])], to: chartFile
        )
        defer { try? FileManager.default.removeItem(at: chartFile) }
        WidgetPrefs().setMenuBarPlacement(.init(enabled: true), for: charted)
        let runtime = try fixture.makeRuntime(expectingOwned: [charted])
        XCTAssertEqual(runtime.menuBarHistory[charted]?.values, [1, 2, 3])

        let met = MenuBarPlacement(enabled: true, presentation: .init(showWhen: 80))
        let unmet = MenuBarPlacement(enabled: true, presentation: .init(showWhen: 95))
        runtime.prefs.setMenuBarPlacement(met, for: limited)
        runtime.syncMenuBar(now: t0)
        XCTAssertEqual(runtime.menuBarWidgetIDs, [charted, limited])
        XCTAssertEqual(runtime.dormantMenuBarWidgetIDs, [])

        runtime.prefs.setDisabled(charted, true)
        runtime.prefs.setDisabled(limited, true)
        runtime.syncMenuBar(now: t0.addingTimeInterval(1))
        XCTAssertEqual(runtime.ownedMenuBarEntries, [], "a disabled widget is not on the bar, placement or not")
        XCTAssertEqual(runtime.menuBar.entries, [])
        XCTAssertNil(runtime.menuBarHistory[charted], "its chart history goes")

        // Back with a reading that no longer qualifies, a second after one
        // that did: only a forgotten stamp hides it at once.
        runtime.prefs.setMenuBarPlacement(unmet, for: limited)
        runtime.prefs.setDisabled(limited, false)
        runtime.syncMenuBar(now: t0.addingTimeInterval(2))
        XCTAssertEqual(runtime.menuBarWidgetIDs, [limited])
        XCTAssertEqual(runtime.dormantMenuBarWidgetIDs, [limited], "its show-when stamp went with it")
    }

    // MARK: - No reading yet

    func testPromotedWidgetWithNoSnapshotIsOwnedStaleNotDormantAndRefreshedOnPromotion() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let id = try fixture.addWidget("a", name: "Unrendered", reading: nil)
        let runtime = try fixture.makeRuntime()
        XCTAssertNil(runtime.snapshots[id]?.updatedAt)
        XCTAssertNotEqual(runtime.snapshots[id]?.isLoading, true, "loading the widget did not refresh it")

        runtime.prefs.setMenuBarPlacement(.init(enabled: true, presentation: .init(showWhen: 80)), for: id)
        runtime.syncMenuBar(now: t0)

        let entry = try XCTUnwrap(runtime.ownedMenuBarEntries.first)
        XCTAssertEqual(runtime.ownedMenuBarEntries.map(\.widgetID), [id])
        XCTAssertTrue(entry.isStale, "never rendered is stale")
        XCTAssertEqual(runtime.dormantMenuBarWidgetIDs, [], "nothing to judge yet, so nothing to hide")
        XCTAssertEqual(runtime.menuBar.entries.map(\.widgetID), [id])
        XCTAssertEqual(runtime.snapshots[id]?.isLoading, true, "promotion started its first refresh")
    }

    func testEntryStalenessIsJudgedAtTheSyncsClock() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let id = try fixture.addWidget("a", name: "Ticking", reading: 1,
                                       refresh: .init(interval: 10, staleAfterSec: 3600))
        let runtime = try fixture.makeRuntime()
        let updatedAt = try XCTUnwrap(runtime.snapshots[id]?.updatedAt)
        runtime.prefs.setMenuBarPlacement(.init(enabled: true), for: id)

        runtime.syncMenuBar(now: updatedAt.addingTimeInterval(59))
        XCTAssertEqual(runtime.ownedMenuBarEntries.first?.isStale, false)
        runtime.syncMenuBar(now: updatedAt.addingTimeInterval(3600))
        XCTAssertEqual(runtime.ownedMenuBarEntries.first?.isStale, true)
        XCTAssertEqual(runtime.menuBar.entries.first?.isStale, true)
    }

    // MARK: - Show-when hold

    func testShowWhenHoldStampsEveryQualifyingSyncAndReleasesAfterSixtySeconds() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let id = try fixture.addWidget("a", name: "Limited", reading: 90)
        let runtime = try fixture.makeRuntime()
        let met = MenuBarPlacement(enabled: true, presentation: .init(showWhen: 80))
        let unmet = MenuBarPlacement(enabled: true, presentation: .init(showWhen: 95))
        func sync(_ placement: MenuBarPlacement, at seconds: TimeInterval) -> Bool {
            runtime.prefs.setMenuBarPlacement(placement, for: id)
            runtime.syncMenuBar(now: t0.addingTimeInterval(seconds))
            XCTAssertEqual(runtime.menuBarWidgetIDs, placement.enabled ? [id] : [])
            return runtime.dormantMenuBarWidgetIDs.contains(id)
        }

        XCTAssertTrue(sync(unmet, at: 0), "never qualified: hidden at once")
        XCTAssertFalse(sync(met, at: 0))
        XCTAssertFalse(sync(met, at: 50), "still qualifying: stamped again")
        XCTAssertFalse(sync(unmet, at: 109.9), "59.9 s after the last qualifying sync, not the first")
        XCTAssertTrue(sync(unmet, at: 110), "at exactly 60 s the hold is over")
        XCTAssertTrue(sync(unmet, at: 171))
        XCTAssertFalse(sync(unmet, at: 109.9), "hiding it did not clear the stamp")

        // Off the bar and back: the stamp of an id no longer owned is gone,
        // so a time the old stamp would still have covered hides it.
        XCTAssertFalse(sync(.init(enabled: false), at: 111))
        XCTAssertTrue(sync(unmet, at: 60))
    }

    func testStoreReceivesOwnedEntriesMinusTheDormantOnes() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let hidden = try fixture.addWidget("a", name: "Hidden", reading: 10)
        let shown = try fixture.addWidget("b", name: "Shown", reading: 10)
        let held = try fixture.addWidget("c", name: "Held", reading: 90)
        let runtime = try fixture.makeRuntime()

        runtime.prefs.setMenuBarPlacements([
            hidden: .init(enabled: true, order: 1, presentation: .init(showWhen: 80)),
            shown: .init(enabled: true, order: 2),
            held: .init(enabled: true, order: 3, presentation: .init(showWhen: 80)),
        ])
        runtime.syncMenuBar(now: t0)
        XCTAssertEqual(runtime.ownedMenuBarEntries.map(\.widgetID), [hidden, shown, held])
        XCTAssertEqual(runtime.menuBar.entries.map(\.widgetID), [shown, held])
        XCTAssertEqual(runtime.menuBar.entries,
                       runtime.ownedMenuBarEntries.filter { !runtime.dormantMenuBarWidgetIDs.contains($0.widgetID) })

        // Within its hold an item that stopped qualifying is still drawn.
        runtime.prefs.setMenuBarPlacement(
            .init(enabled: true, order: 3, presentation: .init(showWhen: 95)), for: held
        )
        runtime.syncMenuBar(now: t0.addingTimeInterval(59))
        XCTAssertEqual(runtime.menuBar.entries.map(\.widgetID), [shown, held])
        runtime.syncMenuBar(now: t0.addingTimeInterval(61))
        XCTAssertEqual(runtime.ownedMenuBarEntries.map(\.widgetID), [hidden, shown, held])
        XCTAssertEqual(runtime.menuBar.entries.map(\.widgetID), [shown])
    }

    // MARK: - Scheduler

    /// The scheduler's promoted set is private; a promoted widget with an
    /// interval owns an interval timer while the popup is closed, and an
    /// unpromoted one that does not run in the background owns none.
    func testSchedulerIsToldOwnedAndDockWidgetsOnlyWhenTheOwnedSetChanges() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let hourly = Manifest.Refresh(interval: 3600, staleAfterSec: 3600)
        let first = try fixture.addWidget("a", name: "First", reading: 1, refresh: hourly)
        let second = try fixture.addWidget("b", name: "Second", reading: 1, refresh: hourly)
        let docked = try fixture.addWidget("c", name: "Docked", reading: 1, refresh: hourly)
        let runtime = try fixture.makeRuntime()
        var polled: Set<String> { runtime.scheduler.activeIntervalWidgetIDs.intersection(fixture.ids) }
        XCTAssertFalse(runtime.scheduler.popupIsOpen)
        XCTAssertEqual(polled, [])

        runtime.prefs.setMenuBarPlacement(.init(enabled: true), for: first)
        runtime.syncMenuBar(now: t0)
        XCTAssertEqual(polled, [first])

        // Emptied behind the runtime's back: a sync that owns the same ids
        // does not tell the scheduler again.
        runtime.scheduler.setMenuBarWidgetIDs([])
        XCTAssertEqual(polled, [])
        runtime.syncMenuBar(now: t0.addingTimeInterval(1))
        XCTAssertEqual(runtime.menuBarWidgetIDs, [first])
        XCTAssertEqual(polled, [], "an unchanged owned set is not re-sent")

        runtime.setDockWidgetIDs([docked])
        XCTAssertEqual(polled, [first, docked])
        runtime.scheduler.setMenuBarWidgetIDs([])
        XCTAssertEqual(polled, [])
        runtime.prefs.setMenuBarPlacement(.init(enabled: true), for: second)
        runtime.syncMenuBar(now: t0.addingTimeInterval(2))
        XCTAssertEqual(polled, [first, second, docked], "a changed owned set is sent with the dock's widgets")

        runtime.scheduler.setMenuBarWidgetIDs([])
        runtime.prefs.setMenuBarPlacement(nil, for: first)
        runtime.syncMenuBar(now: t0.addingTimeInterval(3))
        XCTAssertEqual(polled, [second, docked], "losing an id is a change too")
    }

    // MARK: - Refresh on promotion

    func testOnlyNewlyOwnedWidgetsStaleByTheCardRuleAreRefreshed() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        // No `staleAfterSec`: stale at every trigger by the card rule, though
        // the menu bar's own rule would call a reading this recent current.
        let always = try fixture.addWidget("a", name: "Always stale", reading: 1, refresh: .init())
        let later = try fixture.addWidget("b", name: "Later", reading: 1, refresh: .init())
        let fresh = try fixture.addWidget("c", name: "Fresh", reading: 1)
        let runtime = try fixture.makeRuntime()
        func isLoading(_ id: String) -> Bool { runtime.snapshots[id]?.isLoading == true }
        XCTAssertFalse(isLoading(always) || isLoading(later) || isLoading(fresh))

        runtime.prefs.setMenuBarPlacement(.init(enabled: true), for: always)
        runtime.syncMenuBar(now: t0)
        XCTAssertTrue(isLoading(always), "newly owned and stale: refreshed")
        let renderedBefore = runtime.snapshots[always]?.updatedAt
        let deadline = Date().addingTimeInterval(10)
        while isLoading(always), Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(isLoading(always))
        XCTAssertNil(runtime.snapshots[always]?.error)
        XCTAssertNotEqual(runtime.snapshots[always]?.updatedAt, renderedBefore, "the refresh ran once")
        let renderedAt = runtime.snapshots[always]?.updatedAt

        // Still stale by the card rule and idle, but no longer newly owned.
        runtime.syncMenuBar(now: t0.addingTimeInterval(1))
        XCTAssertFalse(isLoading(always), "a sync that owns the same ids refreshes nothing")

        runtime.prefs.setMenuBarPlacements([later: .init(enabled: true), fresh: .init(enabled: true)])
        runtime.syncMenuBar(now: t0.addingTimeInterval(2))
        XCTAssertEqual(runtime.menuBarWidgetIDs, [always, later, fresh])
        XCTAssertTrue(isLoading(later), "newly owned and stale: refreshed")
        XCTAssertFalse(isLoading(fresh), "newly owned but within its staleAfterSec: left alone")
        XCTAssertFalse(isLoading(always), "already owned: left alone though stale")
        XCTAssertEqual(runtime.snapshots[always]?.updatedAt, renderedAt)

        // The control: an automatic refresh of the idle widget was possible
        // all along, so the syncs above did not ask for one.
        runtime.refresh(widgetID: always, manual: false)
        XCTAssertTrue(isLoading(always))
    }

    // MARK: - Fixture

    /// Widgets in the disposable home, each a source-less workflow with an
    /// optional cached reading, and the runtime that loads them.
    @MainActor
    private final class Fixture {
        let root: URL
        private let tag = UUID().uuidString.lowercased()
        private var manifests: [Manifest] = []
        private var files: [URL] = []
        private var runtime: WidgetRuntime?
        var ids: Set<String> { Set(manifests.map(\.id)) }

        init() throws {
            guard let home = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"],
                  home.contains("barshelf-quality-home-"),
                  WidgetRuntime.applicationSupportDirectory.resolvingSymlinksInPath().path.hasPrefix(
                    URL(fileURLWithPath: home).resolvingSymlinksInPath().path + "/") else {
                throw XCTSkip("run with CFFIXED_USER_HOME set to a disposable barshelf-quality-home-* directory")
            }
            _ = NSApplication.shared
            root = WidgetRuntime.applicationSupportDirectory
        }

        /// `reading` is the cached snapshot's one percentage, rendered just
        /// now; nil leaves the widget with no snapshot at all. By default a
        /// cached reading stays fresh for an hour, so promoting the widget
        /// starts no refresh.
        func addWidget(
            _ directory: String, name: String, reading: Double?,
            refresh: Manifest.Refresh = .init(staleAfterSec: 3600), idSuffix: String? = nil
        ) throws -> String {
            let id = "dev.test.mbsync.\(tag).\(idSuffix ?? directory)"
            let fixture = root.appendingPathComponent("widgets/mbsync-\(tag)-\(directory)")
            try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
            files.append(fixture)
            let manifest = Manifest(schemaVersion: 1, id: id, name: name,
                                    entry: .init(kind: "workflow", main: "workflow.json"),
                                    refresh: refresh, statusItem: .init(mode: "text"),
                                    permissions: .init(storage: .init()))
            try JSONEncoder().encode(manifest).write(to: fixture.appendingPathComponent("widget.json"))
            try Data(#"{"schemaVersion":1,"sources":{},"view":{"type":"text","text":"rendered"}}"#.utf8)
                .write(to: fixture.appendingPathComponent("workflow.json"))
            if let reading {
                let cache = root.appendingPathComponent("cache/\(id).json")
                try FileManager.default.createDirectory(
                    at: cache.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                try WidgetSnapshot(
                    widgetID: id, viewTree: UINode(type: "text", text: "cached"), updatedAt: Date(),
                    statusMetrics: [StatusMetric(id: "load", label: "Load", number: reading, format: "percent")]
                ).serialized().write(to: cache)
                files.append(cache)
            }
            manifests.append(manifest)
            return id
        }

        /// A runtime that has loaded the fixture's widgets, approved, with
        /// nothing on the menu bar but `expectingOwned`.
        func makeRuntime(expectingOwned: Set<String> = []) throws -> WidgetRuntime {
            let permissionsFile = root.appendingPathComponent("mbsync-permissions-\(tag).json")
            let appPrefsFile = root.appendingPathComponent("mbsync-app-prefs-\(tag).json")
            files += [permissionsFile, appPrefsFile]
            let permissions = PermissionStore(fileURL: permissionsFile)
            manifests.forEach { permissions.approve($0) }
            let runtime = WidgetRuntime(appPrefs: AppPrefs(fileURL: appPrefsFile), permissionStore: permissions)
            self.runtime = runtime
            XCTAssertTrue(ids.isSubset(of: Set(runtime.widgets.map(\.id))))
            // Whatever another test left promoted in this home would take
            // slots here.
            let strangers = runtime.menuBarWidgetIDs.subtracting(ids)
            if !strangers.isEmpty {
                runtime.prefs.setMenuBarPlacements(
                    Dictionary(uniqueKeysWithValues: strangers.map { ($0, MenuBarPlacement?.none) })
                )
                runtime.syncMenuBar()
            }
            XCTAssertEqual(runtime.menuBarWidgetIDs, expectingOwned)
            return runtime
        }

        func cleanUp() {
            let prefs = runtime?.prefs ?? WidgetPrefs()
            prefs.setMenuBarPlacements(Dictionary(uniqueKeysWithValues: ids.map { ($0, MenuBarPlacement?.none) }))
            ids.forEach { prefs.setDisabled($0, false) }
            runtime?.setDockWidgetIDs([])
            runtime?.syncMenuBar()
            files.forEach { try? FileManager.default.removeItem(at: $0) }
        }
    }
}
