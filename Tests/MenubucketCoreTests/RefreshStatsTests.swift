import XCTest
@testable import MenubucketCore

final class RefreshStatsTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("refresh-stats-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testRecordsSuccessFailureAndDurations() {
        let store = RefreshStatsStore(persistDebounce: 0)
        let first = Date(timeIntervalSince1970: 100)
        let second = Date(timeIntervalSince1970: 200)

        store.recordSuccess(widgetID: "w", durationMs: 20, at: first)
        store.recordFailure(widgetID: "w", error: "boom", durationMs: 40, at: second)

        let stats = store.stats(for: "w")
        XCTAssertEqual(stats?.successCount, 1)
        XCTAssertEqual(stats?.failureCount, 1)
        XCTAssertEqual(stats?.lastSuccessAt, first)
        XCTAssertEqual(stats?.lastRefreshAt, second)
        XCTAssertEqual(stats?.lastError, "boom")
        XCTAssertEqual(stats?.lastDurationMs, 40)
        XCTAssertEqual(stats?.averageDurationMs, 30)
        XCTAssertEqual(stats?.lastOutcomeWasSuccess, false)
    }

    func testSuccessClearsLastError() {
        let store = RefreshStatsStore(persistDebounce: 0)

        store.recordFailure(widgetID: "w", error: nil)
        store.recordSuccess(widgetID: "w")

        let stats = store.stats(for: "w")
        XCTAssertEqual(stats?.failureCount, 1)
        XCTAssertEqual(stats?.successCount, 1)
        XCTAssertNil(stats?.lastError)
        XCTAssertEqual(stats?.lastOutcomeWasSuccess, true)
    }

    func testPersistsAndRetainsStats() {
        let fileURL = tempDir.appendingPathComponent("refresh-stats.json")
        let store = RefreshStatsStore(fileURL: fileURL, persistDebounce: 0)

        store.recordSuccess(widgetID: "keep", durationMs: 10)
        store.recordFailure(widgetID: "drop", error: "gone")
        store.retain(widgetIDs: ["keep"])

        let reloaded = RefreshStatsStore(fileURL: fileURL, persistDebounce: 0)
        XCTAssertNotNil(reloaded.stats(for: "keep"))
        XCTAssertNil(reloaded.stats(for: "drop"))
    }
}
