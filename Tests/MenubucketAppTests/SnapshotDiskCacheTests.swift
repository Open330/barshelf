import XCTest
import MenubucketCore
@testable import MenubucketApp

@MainActor
final class SnapshotDiskCacheTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapshot-cache-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func snapshot(_ id: String, _ text: String) -> WidgetSnapshot {
        WidgetSnapshot(
            widgetID: id, viewTree: UINode(type: "text", text: text),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000), statusLabel: text
        )
    }

    private func exists(_ cache: SnapshotDiskCache, _ id: String) -> Bool {
        cache.fileURL(for: id).map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }

    func testDefaultsAreTheShippedLocationAndWindow() {
        XCTAssertEqual(SnapshotDiskCache.defaultThrottleInterval, 30)
        XCTAssertEqual(
            SnapshotDiskCache.defaultDirectory.map { Array($0.pathComponents.suffix(3)) },
            ["Application Support", "barshelf", "cache"]
        )
    }

    func testFileNameKeepsLettersDigitsDotAndDashAndReplacesTheRest() {
        let cache = SnapshotDiskCache(directory: directory)
        XCTAssertEqual(
            cache.fileURL(for: "dev.test/a b:c-1"),
            directory.appendingPathComponent("dev.test_a_b_c-1.json")
        )
        XCTAssertNil(SnapshotDiskCache(directory: nil).fileURL(for: "dev.test"))
    }

    func testImmediateWriteRoundTripsThroughDisk() {
        let cache = SnapshotDiskCache(directory: directory)
        let written = snapshot("dev.test.round-trip", "42%")
        XCTAssertNil(cache.load(widgetID: written.widgetID))

        cache.writeNow(written)
        cache.waitForWrites()

        XCTAssertEqual(cache.load(widgetID: written.widgetID), written)
        // Same format the runtime has always read and written.
        let data = try? Data(contentsOf: directory.appendingPathComponent("dev.test.round-trip.json"))
        XCTAssertEqual(data.flatMap { try? WidgetSnapshot.deserialize($0) }, written)
    }

    func testThrottleHoldsTheWriteUntilTheWindowCloses() {
        let cache = SnapshotDiskCache(directory: directory)
        var released: [WidgetSnapshot] = []
        cache.onThrottledWrite = { released.append($0) }

        cache.writeThrottled(snapshot("dev.test.held", "one"))
        cache.waitForWrites()

        XCTAssertFalse(exists(cache, "dev.test.held"))
        XCTAssertTrue(released.isEmpty)
    }

    func testThrottleCoalescesToOneWriteOfTheLatestSnapshot() {
        let cache = SnapshotDiskCache(directory: directory, throttleInterval: 0.05)
        var released: [WidgetSnapshot] = []
        let windowClosed = expectation(description: "window closed")
        cache.onThrottledWrite = {
            released.append($0)
            windowClosed.fulfill() // a second release over-fulfills and fails
        }

        for text in ["one", "two", "three"] {
            cache.writeThrottled(snapshot("dev.test.coalesce", text))
        }
        wait(for: [windowClosed], timeout: 10)
        cache.waitForWrites()

        XCTAssertEqual(released.map(\.statusLabel), ["three"])
        XCTAssertEqual(cache.load(widgetID: "dev.test.coalesce")?.statusLabel, "three")
    }

    func testFlushWritesWhatIsHeldAndLeavesNothingScheduled() {
        let cache = SnapshotDiskCache(directory: directory)
        var released: [String] = []
        cache.onThrottledWrite = { released.append($0.widgetID) }
        cache.writeThrottled(snapshot("dev.test.flush-a", "old"))
        cache.writeThrottled(snapshot("dev.test.flush-a", "new"))
        cache.writeThrottled(snapshot("dev.test.flush-b", "b"))

        cache.flush() // synchronous: no wait needed

        XCTAssertEqual(cache.load(widgetID: "dev.test.flush-a")?.statusLabel, "new")
        XCTAssertEqual(cache.load(widgetID: "dev.test.flush-b")?.statusLabel, "b")
        XCTAssertEqual(released.sorted(), ["dev.test.flush-a", "dev.test.flush-b"])

        cache.flush()
        XCTAssertEqual(released.count, 2, "a second flush has nothing to write")
    }

    func testWriteNowDropsTheHeldSnapshotAndDoesNotReportIt() {
        let cache = SnapshotDiskCache(directory: directory)
        var released: [WidgetSnapshot] = []
        cache.onThrottledWrite = { released.append($0) }
        cache.writeThrottled(snapshot("dev.test.now", "held"))

        cache.writeNow(snapshot("dev.test.now", "now"))
        cache.flush() // nothing held any more, so this neither writes nor waits
        cache.waitForWrites()

        XCTAssertEqual(cache.load(widgetID: "dev.test.now")?.statusLabel, "now")
        XCTAssertTrue(released.isEmpty)
    }

    func testForgettingAWidgetCancelsItsPendingWriteAndRemovesItsFile() {
        let cache = SnapshotDiskCache(directory: directory)
        var released: [WidgetSnapshot] = []
        cache.onThrottledWrite = { released.append($0) }
        cache.writeNow(snapshot("dev.test.forget", "on disk"))
        cache.waitForWrites()
        XCTAssertTrue(exists(cache, "dev.test.forget"))
        cache.writeThrottled(snapshot("dev.test.forget", "held"))

        cache.forget(widgetID: "dev.test.forget")
        XCTAssertFalse(exists(cache, "dev.test.forget"))

        // The held snapshot went with the scheduled write: nothing is left
        // that could re-create the file.
        cache.flush()
        XCTAssertFalse(exists(cache, "dev.test.forget"))
        XCTAssertTrue(released.isEmpty)
    }

    func testCancelPendingKeepsTheFileButDropsTheHeldSnapshot() {
        let cache = SnapshotDiskCache(directory: directory)
        cache.writeNow(snapshot("dev.test.cancel", "redacted"))
        cache.waitForWrites()
        cache.writeThrottled(snapshot("dev.test.cancel", "live sensitive tree"))

        cache.cancelPending("dev.test.cancel")
        cache.flush()

        XCTAssertEqual(cache.load(widgetID: "dev.test.cancel")?.statusLabel, "redacted")
    }

    func testCancelPendingNotInKeepsLiveWidgetsOnly() {
        let cache = SnapshotDiskCache(directory: directory)
        cache.writeThrottled(snapshot("dev.test.live", "live"))
        cache.writeThrottled(snapshot("dev.test.removed", "removed"))

        cache.cancelPending(notIn: ["dev.test.live"])
        cache.flush()

        XCTAssertTrue(exists(cache, "dev.test.live"))
        XCTAssertFalse(exists(cache, "dev.test.removed"))
    }
}
