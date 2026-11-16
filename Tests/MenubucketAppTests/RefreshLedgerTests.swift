import AppKit
import Combine
import XCTest
import MenubucketCore
@testable import MenubucketApp

@MainActor
final class RefreshLedgerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private var clock: Date!
    private var store: RefreshStatsStore!
    private var ledger: RefreshLedger!
    private var published: [[String: WidgetRefreshStats]] = []
    private var cancellables: Set<AnyCancellable> = []

    override func setUp() async throws {
        clock = t0
        store = RefreshStatsStore(persistDebounce: 0)
        ledger = makeLedger(store)
    }

    override func tearDown() async throws {
        cancellables.removeAll()
        published.removeAll()
    }

    /// A ledger on `store` whose clock is `clock`, with every publish of
    /// its model after the initial value recorded in `published`.
    private func makeLedger(_ store: RefreshStatsStore) -> RefreshLedger {
        let ledger = RefreshLedger(store: store, now: { [unowned self] in self.clock })
        cancellables.removeAll()
        published.removeAll()
        ledger.model.$stats.dropFirst()
            .sink { [unowned self] in self.published.append($0) }
            .store(in: &cancellables)
        return ledger
    }

    private func stats(_ id: String) -> WidgetRefreshStats? { ledger.model.stats[id] }

    // MARK: - Starting

    func testTheModelStartsWithWhatTheStoreAlreadyHolds() {
        store.recordFailure(widgetID: "a", error: "old", at: t0)
        let ledger = RefreshLedger(store: store)
        XCTAssertEqual(ledger.model.stats["a"]?.failureCount, 1)
        XCTAssertEqual(ledger.model.stats["a"]?.lastError, "old")
    }

    func testMarkingAStartReturnsTheClocksMoment() {
        XCTAssertEqual(ledger.markStarted(widgetID: "a"), t0)
        XCTAssertEqual(published.count, 0, "a start changes no stats")
        XCTAssertTrue(ledger.model.stats.isEmpty)
    }

    // MARK: - Outcomes

    func testASuccessRunsFromTheMarkedStartAndPublishesOnce() {
        ledger.markStarted(widgetID: "a")
        ledger.recordSuccess(widgetID: "a", completedAt: t0.addingTimeInterval(2))
        XCTAssertEqual(stats("a")?.successCount, 1)
        XCTAssertEqual(stats("a")?.failureCount, 0)
        XCTAssertEqual(stats("a")?.lastDurationMs, 2000)
        XCTAssertEqual(stats("a")?.lastRefreshAt, t0.addingTimeInterval(2))
        XCTAssertEqual(stats("a")?.lastSuccessAt, t0.addingTimeInterval(2))
        XCTAssertNil(stats("a")?.lastError)
        XCTAssertEqual(published.count, 1)
        XCTAssertEqual(published.last, store.all, "the model shows what the store holds")
    }

    func testAFailureKeepsItsMessageAndRunsFromTheMarkedStart() {
        ledger.markStarted(widgetID: "a")
        ledger.recordFailure(widgetID: "a", error: "boom", completedAt: t0.addingTimeInterval(0.5))
        XCTAssertEqual(stats("a")?.failureCount, 1)
        XCTAssertEqual(stats("a")?.successCount, 0)
        XCTAssertEqual(stats("a")?.lastError, "boom")
        XCTAssertEqual(stats("a")?.lastDurationMs, 500)
        XCTAssertNil(stats("a")?.lastSuccessAt)
        XCTAssertEqual(published.count, 1)
    }

    func testAnExplicitStartWinsOverTheMarkedOne() {
        ledger.markStarted(widgetID: "a")
        ledger.recordSuccess(
            widgetID: "a", startedAt: t0.addingTimeInterval(3), completedAt: t0.addingTimeInterval(4)
        )
        XCTAssertEqual(stats("a")?.lastDurationMs, 1000)

        ledger.markStarted(widgetID: "a")
        ledger.recordFailure(
            widgetID: "a", error: "x", startedAt: t0.addingTimeInterval(3), completedAt: t0.addingTimeInterval(5)
        )
        XCTAssertEqual(stats("a")?.lastDurationMs, 2000)
    }

    func testAnOutcomeWithoutAStartCountsWithoutADuration() {
        ledger.recordSuccess(widgetID: "a", completedAt: t0)
        ledger.recordFailure(widgetID: "b", error: "x", completedAt: t0)
        XCTAssertEqual(stats("a")?.successCount, 1)
        XCTAssertNil(stats("a")?.lastDurationMs)
        XCTAssertEqual(stats("b")?.failureCount, 1)
        XCTAssertNil(stats("b")?.lastDurationMs)
    }

    func testAnOutcomeUsesUpTheMarkedStart() {
        ledger.markStarted(widgetID: "a")
        ledger.recordSuccess(widgetID: "a", completedAt: t0.addingTimeInterval(1))
        ledger.recordSuccess(widgetID: "a", completedAt: t0.addingTimeInterval(9))
        XCTAssertEqual(stats("a")?.successCount, 2)
        XCTAssertEqual(stats("a")?.durationSampleCount, 1, "the second had no start of its own")
        XCTAssertEqual(stats("a")?.lastDurationMs, 1000)

        // Also when the outcome brought its own start.
        ledger.markStarted(widgetID: "a")
        ledger.recordFailure(widgetID: "a", error: "x", startedAt: t0, completedAt: t0.addingTimeInterval(1))
        ledger.recordFailure(widgetID: "a", error: "x", completedAt: t0.addingTimeInterval(9))
        XCTAssertEqual(stats("a")?.durationSampleCount, 2)
    }

    func testStartsAreKeptPerWidget() {
        ledger.markStarted(widgetID: "a")
        clock = t0.addingTimeInterval(10)
        ledger.markStarted(widgetID: "b")
        ledger.recordSuccess(widgetID: "b", completedAt: t0.addingTimeInterval(11))
        ledger.recordSuccess(widgetID: "a", completedAt: t0.addingTimeInterval(11))
        XCTAssertEqual(stats("a")?.lastDurationMs, 11_000)
        XCTAssertEqual(stats("b")?.lastDurationMs, 1000)
    }

    func testALaterMarkReplacesTheEarlierOne() {
        ledger.markStarted(widgetID: "a")
        clock = t0.addingTimeInterval(10)
        ledger.markStarted(widgetID: "a")
        ledger.recordSuccess(widgetID: "a", completedAt: t0.addingTimeInterval(11))
        XCTAssertEqual(stats("a")?.lastDurationMs, 1000)
    }

    // MARK: - Forgetting starts

    func testAForgottenStartGivesNoDurationAndRecordsNothing() {
        ledger.markStarted(widgetID: "a")
        ledger.markStarted(widgetID: "b")
        ledger.forgetStart(widgetID: "a")
        XCTAssertEqual(published.count, 0)
        XCTAssertTrue(store.all.isEmpty)

        ledger.recordSuccess(widgetID: "a", completedAt: t0.addingTimeInterval(1))
        ledger.recordSuccess(widgetID: "b", completedAt: t0.addingTimeInterval(1))
        XCTAssertNil(stats("a")?.lastDurationMs)
        XCTAssertEqual(stats("b")?.lastDurationMs, 1000)
    }

    func testStartsOfGoneWidgetsAreForgottenTheirStatsAreNot() {
        ledger.recordSuccess(widgetID: "gone", completedAt: t0)
        ledger.markStarted(widgetID: "gone")
        ledger.markStarted(widgetID: "live")
        published.removeAll()

        ledger.forgetStarts(notIn: ["live"])
        XCTAssertEqual(published.count, 0)
        XCTAssertEqual(stats("gone")?.successCount, 1, "stats go with `retain`")

        ledger.recordSuccess(widgetID: "gone", completedAt: t0.addingTimeInterval(1))
        ledger.recordSuccess(widgetID: "live", completedAt: t0.addingTimeInterval(1))
        XCTAssertEqual(stats("gone")?.durationSampleCount, 0)
        XCTAssertEqual(stats("live")?.lastDurationMs, 1000)
    }

    // MARK: - The stats

    func testRetainDropsTheStatsOfGoneWidgetsAndPublishes() {
        ledger.recordSuccess(widgetID: "gone", completedAt: t0)
        ledger.recordSuccess(widgetID: "live", completedAt: t0)
        published.removeAll()

        ledger.retain(widgetIDs: ["live"])
        XCTAssertNil(stats("gone"))
        XCTAssertEqual(stats("live")?.successCount, 1)
        XCTAssertEqual(published.count, 1)
        XCTAssertNil(store.stats(for: "gone"))
    }

    func testRetainLeavesAStartAlone() {
        ledger.markStarted(widgetID: "a")
        ledger.retain(widgetIDs: [])
        ledger.recordSuccess(widgetID: "a", completedAt: t0.addingTimeInterval(1))
        XCTAssertEqual(stats("a")?.lastDurationMs, 1000)
    }

    func testNothingIsPublishedWhenNothingChanged() {
        ledger.recordSuccess(widgetID: "a", completedAt: t0)
        published.removeAll()
        ledger.retain(widgetIDs: ["a", "b"])
        XCTAssertEqual(published.count, 0, "the Monitoring pane is not redrawn for nothing")
    }

    func testEveryOutcomePublishesInOrder() {
        ledger.recordSuccess(widgetID: "a", completedAt: t0)
        ledger.recordFailure(widgetID: "a", error: "x", completedAt: t0.addingTimeInterval(1))
        ledger.recordSuccess(widgetID: "b", completedAt: t0.addingTimeInterval(2))
        XCTAssertEqual(published.map { $0["a"]?.totalCount }, [1, 2, 2])
        XCTAssertEqual(published.map { $0["b"]?.totalCount }, [nil, nil, 1])
    }

    func testFlushWritesWhatTheThrottleIsHolding() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("refresh-ledger-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent(RefreshStatsStore.defaultFileName)
        // A throttle long enough that only a flush writes during the test.
        ledger = makeLedger(RefreshStatsStore(fileURL: fileURL, persistDebounce: 3600))
        ledger.recordSuccess(widgetID: "a", completedAt: t0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))

        ledger.flush()
        let reloaded = RefreshLedger(store: RefreshStatsStore(fileURL: fileURL, persistDebounce: 0))
        XCTAssertEqual(reloaded.model.stats["a"]?.successCount, 1)
    }
}

/// The runtime keeps its books in the ledger: what it reports shows up in
/// `refreshStats`. Requires a disposable Foundation home, like
/// `FeedbackChannelTests`.
@MainActor
final class RefreshLedgerRuntimeTests: XCTestCase {
    func testWhatTheRuntimeReportsReachesTheMonitoringModel() throws {
        guard let home = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"],
              home.contains("barshelf-quality-home-"),
              WidgetRuntime.applicationSupportDirectory.resolvingSymlinksInPath().path.hasPrefix(
                URL(fileURLWithPath: home).resolvingSymlinksInPath().path + "/") else {
            throw XCTSkip("requires a disposable barshelf-quality-home-* Foundation home")
        }
        _ = NSApplication.shared
        let root = WidgetRuntime.applicationSupportDirectory
        let id = "dev.test.ledger-\(UUID().uuidString.prefix(8).lowercased())"
        let directory = root.appendingPathComponent("widgets/\(id)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        // Never approved, so no refresh of its own adds to the counts.
        let manifest = Manifest(
            schemaVersion: 1, id: id, name: "Ledger",
            entry: .init(kind: "workflow", main: "workflow.json"),
            permissions: .init(exec: [.init(command: "/bin/sh")])
        )
        try JSONEncoder().encode(manifest).write(to: directory.appendingPathComponent("widget.json"))
        try Data(#"{"schemaVersion":1,"sources":{},"view":{"type":"text","text":"ready"}}"#.utf8)
            .write(to: directory.appendingPathComponent("workflow.json"))

        // Stats of a widget that is not installed: gone at the first scan.
        let store = RefreshStatsStore(persistDebounce: 0)
        store.recordSuccess(widgetID: "dev.test.ledger-not-installed")
        let runtime = WidgetRuntime(
            appPrefs: AppPrefs(fileURL: root.appendingPathComponent("ledger-app-prefs-\(id).json")),
            refreshStatsStore: store,
            permissionStore: PermissionStore(fileURL: root.appendingPathComponent("ledger-permissions-\(id).json"))
        )
        runtime.loadWidgets()
        XCTAssertNotNil(runtime.widgets.first { $0.id == id })
        XCTAssertNil(runtime.refreshStats.stats["dev.test.ledger-not-installed"])
        XCTAssertNil(runtime.refreshStats.stats[id])

        runtime.scriptLoadDidComplete(widgetID: id, rendered: false, error: "boom")
        XCTAssertEqual(runtime.refreshStats.stats[id]?.failureCount, 1)
        XCTAssertEqual(runtime.refreshStats.stats[id]?.lastError, "boom")
        XCTAssertEqual(store.stats(for: id)?.failureCount, 1, "in the store the runtime was given")

        runtime.scriptLoadDidComplete(widgetID: id, rendered: false, error: nil)
        XCTAssertEqual(runtime.refreshStats.stats[id]?.successCount, 1)
        XCTAssertNil(runtime.refreshStats.stats[id]?.lastError)

        try FileManager.default.removeItem(at: directory)
        runtime.loadWidgets()
        XCTAssertNil(runtime.refreshStats.stats[id], "a removed widget's stats go at the rescan")
    }
}
