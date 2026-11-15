import AppKit
import Combine
import XCTest
import MenubucketCore
@testable import MenubucketApp

/// Stands in for the timer: records what was scheduled and stopped, and
/// fires the tick when a test says so.
@MainActor
private final class FakeTicker {
    private(set) var intervals: [TimeInterval] = []
    private(set) var stopped = 0
    private var tick: (@MainActor @Sendable () -> Void)?

    var schedule: MenuBarSyncDriver.TickerScheduler {
        { [unowned self] interval, tick in
            self.intervals.append(interval)
            self.tick = tick
            return AnyCancellable { self.stopped += 1 }
        }
    }

    func fire() { tick?() }
}

/// The reads the promoter is given, for one widget on the bar or none.
@MainActor
private final class HookSource: MenuBarPromoterSource {
    var widgets: [LoadedWidget] = []
    var snapshots: [String: WidgetSnapshot] = [:]
    var placements: [String: MenuBarPlacement] = [:]
    var globalMenuBarPresentation: MenuBarPresentation?
    var sensitiveWidgetIDs: Set<String> = []

    func isDisabled(_ widgetID: String) -> Bool { false }
    func permissionStatus(for manifest: Manifest) -> PermissionStore.Status { .approved }
    func menuBarPlacement(for widget: LoadedWidget) -> MenuBarPlacement {
        placements[widget.id] ?? MenuBarPlacement(enabled: false)
    }
    func readingIsStale(_ widget: LoadedWidget, updatedAt: Date?, now: Date) -> Bool { false }
}

@MainActor
final class MenuBarSyncDriverTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)
    private var directory: URL!
    private var source: HookSource!
    private var ticker: FakeTicker!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("menubar-sync-driver-\(UUID().uuidString)", isDirectory: true)
        source = HookSource()
        ticker = FakeTicker()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Shipped timing

    func testShippedTimingIsAFifteenSecondTickAndAThirtyMillisecondBatch() {
        XCTAssertEqual(MenuBarSyncDriver.defaultStalenessInterval, 15)
        XCTAssertEqual(MenuBarUpdateBatch.defaultDelay, .milliseconds(30))
    }

    func testTheShippedTickRepeatsAndMaySlipByAThirdOfItsInterval() {
        // An hour: scheduled for real, and gone long before it could fire.
        let timer = MenuBarSyncDriver.stalenessTimer(interval: 3600) {}
        defer { timer.invalidate() }
        XCTAssertTrue(timer.isValid)
        XCTAssertEqual(timer.timeInterval, 3600)
        XCTAssertEqual(timer.tolerance, 1200)
    }

    // MARK: - Staleness tick

    func testTheTickStartsOnlyWithOwnedEntriesAndOnlyOnce() {
        let driver = MenuBarSyncDriver(stalenessInterval: 7, scheduleTicker: ticker.schedule)

        driver.updateTicker(hasOwnedEntries: false)
        XCTAssertFalse(driver.isTicking)
        XCTAssertEqual(ticker.intervals, [])

        driver.updateTicker(hasOwnedEntries: true)
        XCTAssertTrue(driver.isTicking)
        XCTAssertEqual(ticker.intervals, [7], "at the injected interval")

        driver.updateTicker(hasOwnedEntries: true)
        XCTAssertEqual(ticker.intervals, [7], "one is running: not started again")
        XCTAssertEqual(ticker.stopped, 0)
    }

    func testTheTickStopsWhenNothingIsOwnedAndStartsAgainLater() {
        let driver = MenuBarSyncDriver(stalenessInterval: 7, scheduleTicker: ticker.schedule)
        driver.updateTicker(hasOwnedEntries: true)

        driver.updateTicker(hasOwnedEntries: false)
        XCTAssertFalse(driver.isTicking)
        XCTAssertEqual(ticker.stopped, 1)
        driver.updateTicker(hasOwnedEntries: false)
        XCTAssertEqual(ticker.stopped, 1, "nothing running: nothing to stop")

        driver.updateTicker(hasOwnedEntries: true)
        XCTAssertTrue(driver.isTicking)
        XCTAssertEqual(ticker.intervals, [7, 7])
    }

    func testStoppingTheTickLeavesTheNextUpdateFreeToStartIt() {
        let driver = MenuBarSyncDriver(scheduleTicker: ticker.schedule)
        driver.updateTicker(hasOwnedEntries: true)

        driver.stopTicker()
        XCTAssertFalse(driver.isTicking)
        XCTAssertEqual(ticker.stopped, 1)

        driver.updateTicker(hasOwnedEntries: true)
        XCTAssertTrue(driver.isTicking)
        XCTAssertEqual(ticker.intervals.count, 2)
    }

    func testEachTickAsksForASync() {
        let driver = MenuBarSyncDriver(scheduleTicker: ticker.schedule)
        var syncs = 0
        driver.onSyncNeeded = { syncs += 1 }
        driver.updateTicker(hasOwnedEntries: true)

        ticker.fire()
        ticker.fire()
        XCTAssertEqual(syncs, 2)
        XCTAssertFalse(driver.hasPendingSync, "a tick syncs at once, not through the batch")
    }

    func testAReleasedDriverStopsItsTick() {
        var driver: MenuBarSyncDriver? = MenuBarSyncDriver(scheduleTicker: ticker.schedule)
        driver?.updateTicker(hasOwnedEntries: true)
        driver = nil
        XCTAssertEqual(ticker.stopped, 1)
        ticker.fire()
    }

    // MARK: - Batch

    func testRequestsShareOneBatchedSyncAndTheNextRequestStartsAnother() async {
        let driver = MenuBarSyncDriver(batchDelay: .milliseconds(1), scheduleTicker: ticker.schedule)
        var syncs = 0
        var ran = expectation(description: "the batched sync")
        driver.onSyncNeeded = {
            syncs += 1
            ran.fulfill()
        }

        XCTAssertFalse(driver.hasPendingSync)
        for _ in 0..<100 { driver.requestSync() }
        XCTAssertTrue(driver.hasPendingSync)
        XCTAssertEqual(syncs, 0, "never inline")
        await fulfillment(of: [ran], timeout: 10)
        XCTAssertEqual(syncs, 1)
        XCTAssertFalse(driver.hasPendingSync)

        ran = expectation(description: "the next batched sync")
        driver.requestSync()
        await fulfillment(of: [ran], timeout: 10)
        XCTAssertEqual(syncs, 2)
    }

    func testACancelledBatchNeverSyncs() async {
        let driver = MenuBarSyncDriver(batchDelay: .milliseconds(1), scheduleTicker: ticker.schedule)
        let ran = expectation(description: "a superseded batch must not run")
        ran.isInverted = true
        driver.onSyncNeeded = { ran.fulfill() }

        driver.requestSync()
        driver.cancelPendingSync()
        XCTAssertFalse(driver.hasPendingSync)
        await fulfillment(of: [ran], timeout: 0.1)
    }

    // MARK: - Promoter: sync settles the batch and the tick

    private let charted = MenuBarPlacement(enabled: true, separate: true, presentation: .init(chart: .line))

    /// A promoter on the stub source and the fake ticker. The batch delay is
    /// an hour: these tests look at whether a sync is queued, not at it
    /// running.
    private func makePromoter() -> MenuBarPromoter {
        let promoter = MenuBarPromoter(
            chartRecorder: MenuBarChartRecorder(
                fileURL: directory.appendingPathComponent("menu-bar-charts.json"), saveInterval: 3600
            ),
            syncDriver: MenuBarSyncDriver(batchDelay: .seconds(3600), scheduleTicker: ticker.schedule),
            isSymbolName: { _ in false }
        )
        promoter.source = source
        return promoter
    }

    private func snapshot(_ id: String, reading: Double, at updatedAt: Date) -> WidgetSnapshot {
        WidgetSnapshot(
            widgetID: id, viewTree: UINode(type: "text", text: "rendered"), updatedAt: updatedAt,
            statusMetrics: [StatusMetric(id: "load", label: "Load", number: reading, format: "percent")]
        )
    }

    /// Adds a widget with a reading of 10 at `t0`; on the bar with a chart
    /// unless `placement` says otherwise.
    private func add(_ id: String, placement: MenuBarPlacement? = nil) {
        source.widgets.append(LoadedWidget(
            manifest: Manifest(
                schemaVersion: 1, id: id, name: id,
                entry: .init(kind: "workflow", main: "workflow.json"),
                statusItem: .init(mode: "text")
            ),
            directory: directory
        ))
        source.placements[id] = placement ?? charted
        source.snapshots[id] = snapshot(id, reading: 10, at: t0)
    }

    /// Stores `next` as the widget's snapshot the way the runtime does, and
    /// tells the promoter.
    private func change(_ promoter: MenuBarPromoter, _ id: String, to next: WidgetSnapshot) {
        let previous = source.snapshots[id]
        source.snapshots[id] = next
        promoter.snapshotChanged(id: id, from: previous, to: next)
    }

    func testASyncStartsTheTickWhileSomethingIsOwnedAndStopsItWhenNothingIs() {
        let promoter = makePromoter()
        promoter.sync(now: t0)
        XCTAssertFalse(promoter.isStalenessTicking, "nothing owned")

        add("w")
        promoter.sync(now: t0)
        XCTAssertTrue(promoter.isStalenessTicking)
        promoter.sync(now: t0.addingTimeInterval(1))
        XCTAssertEqual(ticker.intervals.count, 1, "already running")

        source.placements["w"] = MenuBarPlacement(enabled: false)
        promoter.sync(now: t0.addingTimeInterval(2))
        XCTAssertFalse(promoter.isStalenessTicking)
        XCTAssertEqual(ticker.stopped, 1)
    }

    func testADormantItemKeepsTheTickRunning() {
        let promoter = makePromoter()
        add("w", placement: MenuBarPlacement(enabled: true, presentation: .init(showWhen: 80)))
        promoter.sync(now: t0)
        XCTAssertEqual(promoter.dormantWidgetIDs, ["w"])
        XCTAssertEqual(promoter.menuBar.entries, [])
        XCTAssertTrue(promoter.isStalenessTicking, "owned, though not drawn")
    }

    func testAStoppedTickStaysStoppedUntilTheNextSync() {
        let promoter = makePromoter()
        add("w")
        promoter.sync(now: t0)

        promoter.stopStalenessTicker()
        XCTAssertFalse(promoter.isStalenessTicking)

        promoter.sync(now: t0.addingTimeInterval(1))
        XCTAssertTrue(promoter.isStalenessTicking)
    }

    func testTheTickAndTheBatchGoThroughTheRuntimeNotStraightToASync() {
        let promoter = makePromoter()
        var asked = 0
        promoter.onSyncNeeded = { asked += 1 }
        add("w")
        promoter.sync(now: t0)
        let drawn = promoter.menuBar.entries

        source.snapshots["w"] = snapshot("w", reading: 55, at: t0.addingTimeInterval(1))
        ticker.fire()
        XCTAssertEqual(asked, 1)
        XCTAssertEqual(promoter.menuBar.entries, drawn, "the promoter did not sync by itself")
    }

    func testAnImmediateSyncDropsTheQueuedOne() {
        let promoter = makePromoter()
        add("w")
        promoter.sync(now: t0)
        change(promoter, "w", to: snapshot("w", reading: 20, at: t0.addingTimeInterval(1)))
        XCTAssertTrue(promoter.hasPendingSync)

        promoter.sync(now: t0.addingTimeInterval(1))
        XCTAssertFalse(promoter.hasPendingSync)
    }

    // MARK: - Promoter: snapshot hook

    func testALoadingOnlyChangeAsksForNothing() {
        let promoter = makePromoter()
        add("w")
        promoter.sync(now: t0)

        var loading = snapshot("w", reading: 10, at: t0)
        loading.isLoading = true
        loading.viewTree = UINode(type: "text", text: "another card layout")
        change(promoter, "w", to: loading)

        XCTAssertFalse(promoter.hasPendingSync)
        promoter.sync(now: t0.addingTimeInterval(1))
        XCTAssertNil(promoter.chartHistories["w"], "and marks no point for the chart")
    }

    func testAnErrorChangeAsksForASyncButIsNotANewMeasurement() {
        let promoter = makePromoter()
        add("w")
        promoter.sync(now: t0)

        var failed = snapshot("w", reading: 10, at: t0)
        failed.error = "Unavailable"
        change(promoter, "w", to: failed)

        XCTAssertTrue(promoter.hasPendingSync)
        promoter.sync(now: t0.addingTimeInterval(1))
        XCTAssertNil(promoter.chartHistories["w"], "the same reading again is not a point")
    }

    func testANewReadingAsksForASyncAndMarksAPointForTheChart() {
        let promoter = makePromoter()
        add("w")
        promoter.sync(now: t0)

        change(promoter, "w", to: snapshot("w", reading: 20, at: t0.addingTimeInterval(1)))

        XCTAssertTrue(promoter.hasPendingSync)
        XCTAssertNil(promoter.chartHistories["w"], "taken at the sync, not before")
        promoter.sync(now: t0.addingTimeInterval(1))
        XCTAssertEqual(promoter.chartHistories["w"]?.values, [20])
    }

    func testAChangedMetricOrLabelAtTheSameTimeIsANewMeasurementToo() {
        let original = snapshot("w", reading: 10, at: t0)
        var relabelled = original
        relabelled.statusLabel = "11%"
        var failed = original
        failed.error = "Unavailable"
        var tinted = original
        tinted.statusTint = "red"

        XCTAssertTrue(MenuBarPromoter.snapshotIsNewMeasurement(
            from: original, to: snapshot("w", reading: 11, at: t0)))
        XCTAssertTrue(MenuBarPromoter.snapshotIsNewMeasurement(from: original, to: relabelled))
        XCTAssertTrue(MenuBarPromoter.snapshotIsNewMeasurement(from: nil, to: original))
        XCTAssertFalse(MenuBarPromoter.snapshotIsNewMeasurement(from: original, to: failed))
        XCTAssertFalse(MenuBarPromoter.snapshotIsNewMeasurement(from: original, to: tinted))
        XCTAssertTrue(MenuBarPromoter.snapshotAffectsMenuBar(from: original, to: tinted))
    }

    func testAWidgetTheMenuBarDoesNotOwnAsksForNothing() {
        let promoter = makePromoter()
        add("owned")
        add("off", placement: MenuBarPlacement(enabled: false))
        promoter.sync(now: t0)

        change(promoter, "off", to: snapshot("off", reading: 20, at: t0.addingTimeInterval(1)))
        XCTAssertFalse(promoter.hasPendingSync)

        // Not marked either: put on the bar afterwards, its first sync has
        // no reading waiting to become a point.
        source.placements["off"] = charted
        promoter.sync(now: t0.addingTimeInterval(2))
        XCTAssertNil(promoter.chartHistories["off"])
    }

    func testTheRuntimesOldNameForTheDecisionStillAnswersTheSame() {
        let original = snapshot("w", reading: 10, at: t0)
        var loading = original
        loading.isLoading = true
        var failed = original
        failed.error = "Unavailable"
        for next in [loading, failed, snapshot("w", reading: 11, at: t0)] {
            XCTAssertEqual(
                WidgetRuntime.menuBarStateChanged(from: original, to: next),
                MenuBarPromoter.snapshotAffectsMenuBar(from: original, to: next)
            )
        }
        XCTAssertTrue(WidgetRuntime.menuBarStateChanged(from: nil, to: original))
    }
}

/// The runtime's end of the driver: a batched sync comes back through
/// `WidgetRuntime.syncMenuBar`.
///
/// Requires a disposable Foundation home: never starts a live runtime against
/// the user's installed widgets. Run with CFFIXED_USER_HOME.
@MainActor
final class MenuBarSyncDriverRuntimeTests: XCTestCase {
    func testASnapshotOfAnOwnedWidgetReachesTheMenuBarThroughTheBatchWithNobodyAskingForASync() async throws {
        guard let home = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"],
              home.contains("barshelf-quality-home-"),
              WidgetRuntime.applicationSupportDirectory.resolvingSymlinksInPath().path.hasPrefix(
                URL(fileURLWithPath: home).resolvingSymlinksInPath().path + "/") else {
            throw XCTSkip("run with CFFIXED_USER_HOME set to a disposable barshelf-quality-home-* directory")
        }
        _ = NSApplication.shared
        let root = WidgetRuntime.applicationSupportDirectory
        let tag = UUID().uuidString.lowercased()
        let id = "dev.test.mbdriver.\(tag)"
        let widgetDirectory = root.appendingPathComponent("widgets/mbdriver-\(tag)")
        let cache = root.appendingPathComponent("cache/\(id).json")
        let permissionsFile = root.appendingPathComponent("mbdriver-permissions-\(tag).json")
        let appPrefsFile = root.appendingPathComponent("mbdriver-app-prefs-\(tag).json")
        var runtime: WidgetRuntime?
        defer {
            let prefs = runtime?.prefs ?? WidgetPrefs()
            prefs.setMenuBarPlacements([id: MenuBarPlacement?.none])
            for file in [widgetDirectory, cache, permissionsFile, appPrefsFile] {
                try? FileManager.default.removeItem(at: file)
            }
        }

        func reading(_ value: Double) -> WidgetSnapshot {
            WidgetSnapshot(
                widgetID: id, viewTree: UINode(type: "text", text: "cached"), updatedAt: Date(),
                statusMetrics: [StatusMetric(id: "load", label: "Load", number: value, format: "percent")]
            )
        }
        let manifest = Manifest(schemaVersion: 1, id: id, name: "Driver",
                                entry: .init(kind: "workflow", main: "workflow.json"),
                                refresh: .init(staleAfterSec: 3600), statusItem: .init(mode: "text"),
                                permissions: .init(storage: .init()))
        try FileManager.default.createDirectory(at: widgetDirectory, withIntermediateDirectories: true)
        try JSONEncoder().encode(manifest).write(to: widgetDirectory.appendingPathComponent("widget.json"))
        try Data(#"{"schemaVersion":1,"sources":{},"view":{"type":"text","text":"rendered"}}"#.utf8)
            .write(to: widgetDirectory.appendingPathComponent("workflow.json"))
        try FileManager.default.createDirectory(
            at: cache.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try reading(10).serialized().write(to: cache)

        let permissions = PermissionStore(fileURL: permissionsFile)
        permissions.approve(manifest)
        let made = WidgetRuntime(appPrefs: AppPrefs(fileURL: appPrefsFile), permissionStore: permissions)
        runtime = made
        let widget = try XCTUnwrap(made.widgets.first { $0.id == id })
        made.prefs.setMenuBarPlacements([id: MenuBarPlacement(enabled: true, order: -1)])
        made.syncMenuBar()
        // A new runtime syncs once more by itself, a run loop turn after it
        // is made (its preferences subscription). Let that pass, so the
        // sync seen below can only be the batch's.
        let settled = expectation(description: "the runtime's own first syncs are over")
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100)) { settled.fulfill() }
        await fulfillment(of: [settled], timeout: 10)
        let before = try XCTUnwrap(made.menuBar.entries.first { $0.widgetID == id })

        // The one public way to hand the runtime a snapshot directly; it
        // does not sync by itself.
        made.stagePreview(widgets: [widget], renders: [reading(55)])
        XCTAssertEqual(made.menuBar.entries.first { $0.widgetID == id }, before, "not inline")

        let synced = expectation(description: "the batched sync redraws the item")
        let watching = made.menuBar.$entries.dropFirst().sink { entries in
            if let entry = entries.first(where: { $0.widgetID == id }), entry != before { synced.fulfill() }
        }
        await fulfillment(of: [synced], timeout: 10)
        watching.cancel()
    }
}
