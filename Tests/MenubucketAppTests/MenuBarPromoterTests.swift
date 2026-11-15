import XCTest
import MenubucketCore
@testable import MenubucketApp

/// Stands in for the runtime: only the reads the promoter is given.
@MainActor
private final class StubSource: MenuBarPromoterSource {
    var widgets: [LoadedWidget] = []
    var snapshots: [String: WidgetSnapshot] = [:]
    var disabled: Set<String> = []
    /// By manifest id; anything not listed is approved.
    var statuses: [String: PermissionStore.Status] = [:]
    /// By widget id; anything not listed is off the bar.
    var placements: [String: MenuBarPlacement] = [:]
    var globalMenuBarPresentation: MenuBarPresentation?
    var stale: Set<String> = []
    /// The clock each staleness question was asked at.
    var staleAskedAt: [Date] = []
    var sensitiveWidgetIDs: Set<String> = []

    func isDisabled(_ widgetID: String) -> Bool { disabled.contains(widgetID) }
    func permissionStatus(for manifest: Manifest) -> PermissionStore.Status { statuses[manifest.id] ?? .approved }
    func menuBarPlacement(for widget: LoadedWidget) -> MenuBarPlacement {
        placements[widget.id] ?? MenuBarPlacement(enabled: false)
    }
    func readingIsStale(_ widget: LoadedWidget, updatedAt: Date?, now: Date) -> Bool {
        staleAskedAt.append(now)
        return stale.contains(widget.id)
    }
}

@MainActor
final class MenuBarPromoterTests: XCTestCase {
    /// A fixed clock for the syncs under test; nothing here waits for time.
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)
    private var directory: URL!
    private var chartFile: URL!
    private var source: StubSource!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("menubar-promoter-\(UUID().uuidString)", isDirectory: true)
        chartFile = directory.appendingPathComponent("menu-bar-charts.json")
        source = StubSource()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A promoter on the stub and the temp chart file. The save interval is
    /// an hour: no test waits for the timer.
    private func makePromoter(
        hold: TimeInterval = 60, attached: Bool = true
    ) -> MenuBarPromoter {
        let promoter = MenuBarPromoter(
            chartRecorder: MenuBarChartRecorder(fileURL: chartFile, saveInterval: 3600),
            showWhenHold: MenuBarShowWhenHold(hold: hold),
            isSymbolName: { $0 == "known.symbol" }
        )
        if attached { promoter.source = source }
        return promoter
    }

    /// Adds a widget to the source, with a reading if `reading` is given.
    @discardableResult
    private func add(
        _ id: String, name: String? = nil, reading: Double? = 10,
        placement: MenuBarPlacement? = MenuBarPlacement(enabled: true), icon: String? = nil
    ) -> String {
        source.widgets.append(LoadedWidget(
            manifest: Manifest(
                schemaVersion: 1, id: id, name: name ?? id, icon: icon,
                entry: .init(kind: "workflow", main: "workflow.json"),
                statusItem: .init(mode: "text")
            ),
            directory: directory
        ))
        source.placements[id] = placement
        if let reading { setReading(id, reading) }
        return id
    }

    private func setReading(_ id: String, _ reading: Double, at updatedAt: Date? = nil) {
        source.snapshots[id] = WidgetSnapshot(
            widgetID: id, viewTree: UINode(type: "text", text: "rendered"), updatedAt: updatedAt ?? t0,
            statusMetrics: [StatusMetric(id: "load", label: "Load", number: reading, format: "percent")]
        )
    }

    private let charted = MenuBarPlacement(enabled: true, separate: true, presentation: .init(chart: .line))

    private func savedHistories() -> [String: MenuBarChartHistory] {
        MenuBarChartHistoryStore.load(from: chartFile)
    }

    // MARK: - Without a runtime

    func testWithNoSourceASyncOwnsNothingAndSavesNothing() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try MenuBarChartHistoryStore.save(
            ["old": MenuBarChartHistory(series: "cpu", scale: 100, values: [1, 2])], to: chartFile
        )
        let promoter = makePromoter(attached: false)
        add("a")

        let result = promoter.sync(now: t0)

        XCTAssertEqual(result, MenuBarSyncResult(
            ownedWidgetIDs: [], newlyOwnedWidgetIDs: [], ownedSetChanged: false, intervalOverrides: [:]
        ))
        XCTAssertEqual(promoter.ownedEntries, [])
        XCTAssertEqual(promoter.menuBar.entries, [])
        // Nobody to ask what is sensitive: the file is left as it was rather
        // than rewritten as empty.
        promoter.saveCharts()
        XCTAssertEqual(savedHistories()["old"]?.values, [1, 2])
    }

    // MARK: - Candidates, order and cap

    func testOnlyEnabledApprovedPlacedWidgetsAreCandidates() {
        let promoter = makePromoter()
        add("on")
        add("off", placement: MenuBarPlacement(enabled: false))
        add("disabled")
        add("pending")
        add("denied")
        source.disabled = ["disabled"]
        source.statuses = ["pending": .pending, "denied": .denied]

        let result = promoter.sync(now: t0)

        XCTAssertEqual(promoter.ownedEntries.map(\.widgetID), ["on"])
        XCTAssertEqual(promoter.ownedWidgetIDs, ["on"])
        XCTAssertEqual(result.ownedWidgetIDs, ["on"])
        XCTAssertEqual(promoter.menuBar.entries.map(\.widgetID), ["on"])
    }

    func testCandidatesAreOrderedByKeyThenNameThenSourceOrderAndCapped() {
        let promoter = makePromoter()
        add("bravo", name: "Bravo", placement: .init(enabled: true, order: 2))
        add("alpha", name: "Alpha", placement: .init(enabled: true, order: 1))
        add("delta", name: "delta")
        add("charlie", name: "Charlie")
        add("same.z", name: "Same")
        add("same.a", name: "Same")
        add("zulu", name: "Zulu")

        let result = promoter.sync(now: t0)

        XCTAssertEqual(promoter.ownedEntries.map(\.widgetID), ["alpha", "bravo", "charlie", "delta", "same.z"])
        XCTAssertEqual(promoter.ownedEntries.count, MenuBarPolicy.maxEntries)
        XCTAssertEqual(result.ownedWidgetIDs, ["alpha", "bravo", "charlie", "delta", "same.z"])
    }

    func testIntervalOverridesCoverEveryCandidateEvenPastTheCap() {
        let promoter = makePromoter()
        for index in 1...5 {
            add("w\(index)", placement: .init(enabled: true, order: Double(index), interval: Double(index)))
        }
        add("sixth", placement: .init(enabled: true, order: 6, interval: 30))
        add("plain", placement: .init(enabled: true, order: 7))
        add("off", placement: .init(enabled: false, interval: 2))

        let result = promoter.sync(now: t0)

        XCTAssertFalse(result.ownedWidgetIDs.contains("sixth"))
        XCTAssertEqual(result.intervalOverrides, ["w1": 1, "w2": 2, "w3": 3, "w4": 4, "w5": 5, "sixth": 30])
    }

    // MARK: - What the runtime is told

    func testResultNamesNewlyOwnedWidgetsAndWhetherTheOwnedSetChanged() {
        let promoter = makePromoter()
        add("first")
        add("second", placement: MenuBarPlacement(enabled: false))

        var result = promoter.sync(now: t0)
        XCTAssertEqual(result.newlyOwnedWidgetIDs, ["first"])
        XCTAssertTrue(result.ownedSetChanged)

        result = promoter.sync(now: t0.addingTimeInterval(1))
        XCTAssertEqual(result.ownedWidgetIDs, ["first"])
        XCTAssertEqual(result.newlyOwnedWidgetIDs, [])
        XCTAssertFalse(result.ownedSetChanged, "the same ids again is no change")

        source.placements["second"] = MenuBarPlacement(enabled: true)
        result = promoter.sync(now: t0.addingTimeInterval(2))
        XCTAssertEqual(result.ownedWidgetIDs, ["first", "second"])
        XCTAssertEqual(result.newlyOwnedWidgetIDs, ["second"])
        XCTAssertTrue(result.ownedSetChanged)

        source.placements["first"] = MenuBarPlacement(enabled: false)
        result = promoter.sync(now: t0.addingTimeInterval(3))
        XCTAssertEqual(result.ownedWidgetIDs, ["second"])
        XCTAssertEqual(result.newlyOwnedWidgetIDs, [])
        XCTAssertTrue(result.ownedSetChanged, "losing an id is a change too")
    }

    func testADormantWidgetIsStillOwnedAndNewlyOwned() {
        let promoter = makePromoter()
        add("hidden", reading: 10, placement: .init(enabled: true, presentation: .init(showWhen: 80)))

        let result = promoter.sync(now: t0)

        XCTAssertEqual(promoter.dormantWidgetIDs, ["hidden"])
        XCTAssertEqual(result.ownedWidgetIDs, ["hidden"], "it keeps polling, so it can come back")
        XCTAssertEqual(result.newlyOwnedWidgetIDs, ["hidden"])
        XCTAssertEqual(promoter.menuBar.entries, [])
    }

    // MARK: - How an entry is built

    func testStalenessIsAskedOfTheSourceAtTheSyncsClock() {
        let promoter = makePromoter()
        add("fresh")
        add("old")
        source.stale = ["old"]
        let now = t0.addingTimeInterval(42)

        promoter.sync(now: now)

        XCTAssertEqual(source.staleAskedAt, [now, now])
        XCTAssertEqual(promoter.ownedEntries.first { $0.widgetID == "fresh" }?.isStale, false)
        XCTAssertEqual(promoter.ownedEntries.first { $0.widgetID == "old" }?.isStale, true)
    }

    func testAFailedRefreshBecomesTheExplainedTooltipElseTheWidgetsOwn() {
        let promoter = makePromoter()
        add("failed")
        add("fine")
        source.snapshots["failed"]?.error = "command not found: gh"
        source.snapshots["failed"]?.statusTooltip = "ignored"
        source.snapshots["fine"]?.statusTooltip = "its own"

        promoter.sync(now: t0)

        XCTAssertEqual(promoter.ownedEntries.first { $0.widgetID == "failed" }?.tooltip,
                       WidgetRuntime.errorTooltip("command not found: gh"))
        XCTAssertEqual(promoter.ownedEntries.first { $0.widgetID == "fine" }?.tooltip, "its own")
    }

    func testEntriesMatchTheSharedBuilderWithTheInjectedSymbolLookupAndTheAppWideStyle() {
        let promoter = makePromoter()
        let global = MenuBarPresentation(showWhen: 5)
        source.globalMenuBarPresentation = global
        let placement = MenuBarPlacement(enabled: true)
        for (id, icon) in [("symbol", "known.symbol"), ("other", "unknown.symbol")] {
            add(id, placement: placement, icon: icon)
        }

        promoter.sync(now: t0)

        for widget in source.widgets {
            let expected = MenuBarPolicy.buildEntry(MenuBarEntryInputs(
                widgetID: widget.id, name: widget.displayName, manifestIcon: widget.manifest.icon,
                statusItem: widget.manifest.statusItem, placement: placement, globalPresentation: global,
                snapshot: source.snapshots[widget.id], isStale: false, tooltip: nil,
                isSymbolName: { $0 == "known.symbol" }
            )).entry
            XCTAssertEqual(promoter.ownedEntries.first { $0.widgetID == widget.id }, expected)
        }
        XCTAssertNotEqual(
            promoter.ownedEntries.first { $0.widgetID == "symbol" }?.iconSymbol,
            promoter.ownedEntries.first { $0.widgetID == "other" }?.iconSymbol,
            "the injected lookup, not AppKit's, decided what is a symbol"
        )
    }

    // MARK: - Show-when hold

    func testStoreGetsOwnedEntriesMinusTheDormantOnesWhichKeepTheirSlot() {
        let promoter = makePromoter()
        add("hidden", reading: 10, placement: .init(enabled: true, order: 1, presentation: .init(showWhen: 80)))
        for index in 2...5 { add("shown\(index)", placement: .init(enabled: true, order: Double(index))) }
        add("sixth", placement: .init(enabled: true, order: 6))

        promoter.sync(now: t0)

        XCTAssertEqual(promoter.dormantWidgetIDs, ["hidden"])
        XCTAssertEqual(promoter.ownedEntries.map(\.widgetID), ["hidden", "shown2", "shown3", "shown4", "shown5"])
        XCTAssertEqual(promoter.menuBar.entries.map(\.widgetID), ["shown2", "shown3", "shown4", "shown5"])
        XCTAssertEqual(promoter.menuBar.entries,
                       promoter.ownedEntries.filter { !promoter.dormantWidgetIDs.contains($0.widgetID) })
    }

    func testAnItemStaysForTheInjectedHoldAfterItLastQualified() {
        let promoter = makePromoter(hold: 10)
        add("w", reading: 90, placement: .init(enabled: true, presentation: .init(showWhen: 80)))
        func dormant(reading: Double, at seconds: TimeInterval) -> Bool {
            setReading("w", reading)
            promoter.sync(now: t0.addingTimeInterval(seconds))
            return promoter.dormantWidgetIDs.contains("w")
        }

        XCTAssertFalse(dormant(reading: 90, at: 0))
        XCTAssertFalse(dormant(reading: 90, at: 5), "still qualifying: stamped again")
        XCTAssertFalse(dormant(reading: 10, at: 14.9), "within the hold of the last qualifying sync")
        XCTAssertEqual(promoter.menuBar.entries.map(\.widgetID), ["w"])
        XCTAssertTrue(dormant(reading: 10, at: 15), "at exactly the hold it is over")
        XCTAssertEqual(promoter.menuBar.entries, [])

        // Off the bar and back: the stamp went with it.
        source.placements["w"] = MenuBarPlacement(enabled: false)
        promoter.sync(now: t0.addingTimeInterval(16))
        source.placements["w"] = .init(enabled: true, presentation: .init(showWhen: 80))
        XCTAssertTrue(dormant(reading: 10, at: 6), "a time the old stamp would have covered")
    }

    func testAWidgetWithNoReadingIsNotDormant() {
        let promoter = makePromoter()
        add("w", reading: nil, placement: .init(enabled: true, presentation: .init(showWhen: 80)))

        promoter.sync(now: t0)

        XCTAssertEqual(promoter.dormantWidgetIDs, [])
        XCTAssertEqual(promoter.menuBar.entries.map(\.widgetID), ["w"])
    }

    // MARK: - Charts

    func testAPointIsTakenOnlyFromAWidgetMarkedPending() {
        let promoter = makePromoter()
        add("w", reading: 10, placement: charted)

        promoter.sync(now: t0)
        XCTAssertNil(promoter.chartHistories["w"], "a sync with no new reading records nothing")

        promoter.markPending("w")
        promoter.sync(now: t0)
        XCTAssertEqual(promoter.chartHistories["w"]?.values, [10])
        XCTAssertEqual(promoter.ownedEntries.first?.history, [10])
        XCTAssertEqual(promoter.menuBar.entries.first?.history, [10])

        // The mark is spent: a re-sync for any other reason adds nothing.
        setReading("w", 99)
        let recorded = promoter.chartHistories
        promoter.sync(now: t0.addingTimeInterval(1))
        XCTAssertEqual(promoter.chartHistories, recorded)
    }

    func testAnItemWithNoChartRecordsNothingAndItsPendingMarkIsDropped() {
        let promoter = makePromoter()
        add("w", reading: 10)

        promoter.markPending("w")
        promoter.sync(now: t0)
        XCTAssertEqual(promoter.chartHistories, [:])

        // Charting turned on later: the old mark is not waiting for it.
        source.placements["w"] = charted
        promoter.sync(now: t0.addingTimeInterval(1))
        XCTAssertNil(promoter.chartHistories["w"])
    }

    func testHistoryGoesWhenTheItemLeavesTheBarIsDisabledOrStopsCharting() {
        let promoter = makePromoter()
        let ids = ["left", "disabled", "unapproved", "plain", "kept"]
        for id in ids {
            add(id, reading: 10, placement: charted)
            promoter.markPending(id)
        }
        promoter.sync(now: t0)
        XCTAssertEqual(Set(promoter.chartHistories.keys), Set(ids))

        source.placements["left"] = MenuBarPlacement(enabled: false)
        source.disabled = ["disabled"]
        source.statuses = ["unapproved": .pending]
        source.placements["plain"] = MenuBarPlacement(enabled: true, separate: true)
        promoter.sync(now: t0.addingTimeInterval(1))

        XCTAssertEqual(Set(promoter.chartHistories.keys), ["kept"])
    }

    func testRestoredHistoryWaitsForTheFirstRenderOfACandidate() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let saved = MenuBarChartHistory(series: "cpu", scale: 100, values: [1, 2, 3])
        try MenuBarChartHistoryStore.save(["unrendered": saved, "rendered": saved, "gone": saved], to: chartFile)
        let promoter = makePromoter()
        // Neither asks for a chart by placement: only the first render can.
        add("unrendered", reading: nil)
        add("rendered", reading: 10)

        // Before the restore, as at launch: nothing to prune or lose.
        promoter.sync(now: t0)
        XCTAssertEqual(promoter.chartHistories, [:])
        promoter.restoreCharts()
        XCTAssertEqual(Set(promoter.chartHistories.keys), ["unrendered", "rendered", "gone"])

        promoter.sync(now: t0.addingTimeInterval(1))
        XCTAssertEqual(promoter.chartHistories, ["unrendered": saved],
                       "kept for the candidate with no render yet; judged for the rest")

        setReading("unrendered", 10)
        promoter.sync(now: t0.addingTimeInterval(2))
        XCTAssertEqual(promoter.chartHistories, [:], "rendered without asking for a chart: judged now")
    }

    // MARK: - Saving

    func testSaveLeavesOutWhatTheSourceCallsSensitive() {
        let promoter = makePromoter()
        for id in ["plain", "secret"] {
            add(id, reading: 10, placement: charted)
            promoter.markPending(id)
        }
        promoter.sync(now: t0)

        promoter.saveCharts()
        XCTAssertEqual(Set(savedHistories().keys), ["plain", "secret"])

        // Turned sensitive: asked again at the save, and rewritten without it.
        source.sensitiveWidgetIDs = ["secret"]
        promoter.saveCharts()
        XCTAssertEqual(Set(savedHistories().keys), ["plain"])
        XCTAssertEqual(Set(promoter.chartHistories.keys), ["plain", "secret"], "still drawn, only not on disk")
    }

    func testASyncThatEmptiesTheHistoriesClearsTheFile() {
        let promoter = makePromoter()
        add("w", reading: 10, placement: charted)
        promoter.markPending("w")
        promoter.sync(now: t0)
        promoter.saveCharts()
        XCTAssertEqual(Set(savedHistories().keys), ["w"])

        source.placements["w"] = MenuBarPlacement(enabled: false)
        promoter.sync(now: t0.addingTimeInterval(1))

        XCTAssertFalse(FileManager.default.fileExists(atPath: chartFile.path))
    }

    // MARK: - Defaults

    func testDefaultsAreAStoreOfItsOwnTheSixtySecondHoldAndAppKitsSymbols() {
        let promoter = MenuBarPromoter(chartRecorder: MenuBarChartRecorder(fileURL: chartFile))
        XCTAssertEqual(promoter.menuBar.entries, [])
        XCTAssertEqual(MenuBarShowWhenHold().hold, 60)
        XCTAssertTrue(MenuBarPromoter.defaultIsSymbolName("gauge"))
        XCTAssertFalse(MenuBarPromoter.defaultIsSymbolName("no.such.symbol.here"))
    }
}
