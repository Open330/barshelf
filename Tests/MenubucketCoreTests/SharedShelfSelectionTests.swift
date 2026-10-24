import XCTest
@testable import MenubucketCore

/// What a desktop widget shows of the items a user picked, and how it tells
/// an unanswered refresh from an answered one.
final class SharedShelfSelectionTests: XCTestCase {
    private var container: URL!
    private let id = "dev.barshelf.aas-usage"
    private let asked = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        container = FileManager.default.temporaryDirectory
            .appendingPathComponent("shared-shelf-selection-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: container)
    }

    private func part(_ key: String, group: Bool = false) -> SharedShelf.Part {
        SharedShelf.Part(key: key, title: key, node: UINode(type: "text", text: key), containsParts: group ? true : nil)
    }

    // MARK: Picked parts

    func testNothingPickedShowsTheWidgetsOwnItemsWithoutGroups() {
        let parts = [part("Codex", group: true), part("Codex/a"), part("Codex/b")]
        XCTAssertEqual(SharedShelf.selection(keys: [], from: parts), .automatic([parts[1], parts[2]]))
    }

    func testPickedPartsKeepThePickedOrder() {
        let parts = [part("a"), part("b"), part("c")]
        XCTAssertEqual(SharedShelf.selection(keys: ["c", "a"], from: parts), .picked([parts[2], parts[0]]))
    }

    /// One of two picks is gone: the other alone, and nothing added for it.
    func testAGonePickIsLeftOutNotReplaced() {
        let parts = [part("a"), part("b"), part("c")]
        XCTAssertEqual(SharedShelf.selection(keys: ["gone", "b"], from: parts), .picked([parts[1]]))
    }

    /// A was picked, A disappeared, B remains: the widget must say A is
    /// missing — never fall back to showing B, which nobody picked.
    func testEveryPickGoneIsReportedNeverReplacedByOtherItems() {
        let parts = [part("b")]
        XCTAssertEqual(SharedShelf.selection(keys: ["a"], from: parts), .missing(keys: ["a"]))
        XCTAssertEqual(SharedShelf.selection(keys: ["a", "c"], from: []), .missing(keys: ["a", "c"]))
    }

    func testAMissingPartIsNamedFromItsKey() {
        XCTAssertEqual(SharedShelf.title(ofMissingPartKey: "Codex/chatgpt@codex"), "chatgpt@codex")
        XCTAssertEqual(SharedShelf.title(ofMissingPartKey: "Codex/chatgpt@codex#2"), "chatgpt@codex")
        XCTAssertEqual(SharedShelf.title(ofMissingPartKey: "id:cpu"), "cpu")
        XCTAssertEqual(SharedShelf.title(ofMissingPartKey: "Files/#"), "#")
        XCTAssertEqual(SharedShelf.title(ofMissingPartKey: "plain"), "plain")
    }

    // MARK: Refresh requests

    private func writeSnapshot(at date: Date) throws {
        try SharedShelf.writeSnapshot(SharedShelf.Snapshot(widgetID: id, name: "Usage"), to: container)
        let url = container
            .appendingPathComponent(SharedShelf.snapshotsDirectoryName, isDirectory: true)
            .appendingPathComponent(id + ".json")
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    func testNeverAskedIsNoState() {
        XCTAssertEqual(SharedShelf.refreshRequestState(widgetID: id, in: container, now: asked), .none)
    }

    func testAnUnansweredRequestIsReportedAfterItLapses() throws {
        try writeSnapshot(at: asked.addingTimeInterval(-600))
        try SharedShelf.requestRefresh(widgetID: id, in: container, now: asked)

        XCTAssertEqual(SharedShelf.refreshRequestState(widgetID: id, in: container, now: asked.addingTimeInterval(10)), .pending(since: asked))
        let lapse = asked.addingTimeInterval(SharedShelf.refreshRequestLifetime)
        XCTAssertEqual(SharedShelf.refreshRequestState(widgetID: id, in: container, now: lapse), .unanswered(since: asked))
        // The extension drops lapsed requests when it lists them; the answer
        // is still known to be missing.
        _ = SharedShelf.pendingRefreshRequests(in: container, now: lapse)
        XCTAssertEqual(SharedShelf.refreshRequestState(widgetID: id, in: container, now: lapse), .unanswered(since: asked))
    }

    /// BarShelf gave up on the request (cleared it) without writing anything.
    func testARequestClearedWithoutAWriteIsUnanswered() throws {
        try writeSnapshot(at: asked.addingTimeInterval(-600))
        try SharedShelf.requestRefresh(widgetID: id, in: container, now: asked)
        SharedShelf.clearRefreshRequest(widgetID: id, in: container)
        XCTAssertEqual(SharedShelf.refreshRequestState(widgetID: id, in: container, now: asked.addingTimeInterval(5)), .unanswered(since: asked))
    }

    /// A write after the request — a new reading or the error it got — is
    /// the answer, before or after the request lapses.
    func testAWriteAfterTheRequestAnswersIt() throws {
        try SharedShelf.requestRefresh(widgetID: id, in: container, now: asked)
        try writeSnapshot(at: asked.addingTimeInterval(3))
        SharedShelf.clearRefreshRequest(widgetID: id, in: container)
        XCTAssertEqual(SharedShelf.refreshRequestState(widgetID: id, in: container, now: asked.addingTimeInterval(5)), .none)
        XCTAssertEqual(SharedShelf.refreshRequestState(widgetID: id, in: container, now: asked.addingTimeInterval(3600)), .none)
    }

    func testANoAnswerWithoutAnySnapshotIsStillReported() throws {
        try SharedShelf.requestRefresh(widgetID: id, in: container, now: asked)
        let lapse = asked.addingTimeInterval(SharedShelf.refreshRequestLifetime + 1)
        XCTAssertEqual(SharedShelf.refreshRequestState(widgetID: id, in: container, now: lapse), .unanswered(since: asked))
    }

    func testAskingAgainIsPendingAgain() throws {
        try writeSnapshot(at: asked.addingTimeInterval(-600))
        try SharedShelf.requestRefresh(widgetID: id, in: container, now: asked)
        let again = asked.addingTimeInterval(300)
        try SharedShelf.requestRefresh(widgetID: id, in: container, now: again)
        XCTAssertEqual(SharedShelf.refreshRequestState(widgetID: id, in: container, now: again.addingTimeInterval(1)), .pending(since: again))
    }

    /// Asked at .9 of a second: a snapshot written at .1 of that same second
    /// came before the ask and is not its answer; one at .95 is.
    func testWithinOneSecondOnlyAWriteAfterTheAskAnswersIt() throws {
        let ask = asked.addingTimeInterval(0.9)
        try writeSnapshot(at: asked.addingTimeInterval(0.1))
        try SharedShelf.requestRefresh(widgetID: id, in: container, now: ask)
        XCTAssertEqual(SharedShelf.refreshRequestState(widgetID: id, in: container, now: ask.addingTimeInterval(1)), .pending(since: asked))
        guard case let .unanswered(since) = SharedShelf.refreshRequestState(
            widgetID: id, in: container, now: ask.addingTimeInterval(SharedShelf.refreshRequestLifetime)
        ) else { return XCTFail("a lapsed request with only an older write is unanswered") }
        XCTAssertEqual(since.timeIntervalSince1970, ask.timeIntervalSince1970, accuracy: 0.001)

        try writeSnapshot(at: asked.addingTimeInterval(0.95))
        XCTAssertEqual(SharedShelf.refreshRequestState(widgetID: id, in: container, now: ask.addingTimeInterval(1)), .none)
    }

    /// A request without the precise record (an extension from before it)
    /// is only known to the second, so only a write after that second answers.
    func testARequestWithoutAnAskRecordNeedsAWriteAfterItsSecond() throws {
        try SharedShelf.requestRefresh(widgetID: id, in: container, now: asked.addingTimeInterval(0.9))
        try FileManager.default.removeItem(at: container
            .appendingPathComponent(SharedShelf.askedDirectoryName, isDirectory: true)
            .appendingPathComponent(id + ".json"))
        try writeSnapshot(at: asked.addingTimeInterval(0.95))
        XCTAssertEqual(SharedShelf.refreshRequestState(widgetID: id, in: container, now: asked.addingTimeInterval(2)), .pending(since: asked))
        try writeSnapshot(at: asked.addingTimeInterval(1))
        XCTAssertEqual(SharedShelf.refreshRequestState(widgetID: id, in: container, now: asked.addingTimeInterval(2)), .none)
    }

    func testPruningDropsAskRecordsOfRemovedWidgetsOnly() throws {
        try SharedShelf.requestRefresh(widgetID: id, in: container, now: asked)
        try SharedShelf.requestRefresh(widgetID: "dev.barshelf.removed", in: container, now: asked)
        SharedShelf.pruneSnapshots(keeping: [id], in: container)
        let records = try FileManager.default.contentsOfDirectory(atPath: container
            .appendingPathComponent(SharedShelf.askedDirectoryName, isDirectory: true).path)
        XCTAssertEqual(records, [id + ".json"])
        XCTAssertEqual(SharedShelf.refreshRequestState(widgetID: id, in: container, now: asked.addingTimeInterval(1)), .pending(since: asked))
    }

    /// The record that outlives the request sits apart from the request files
    /// BarShelf reads, so the app's handling of requests is unchanged.
    func testTheAskedRecordIsNotARequest() throws {
        try SharedShelf.requestRefresh(widgetID: id, in: container, now: asked)
        SharedShelf.clearRefreshRequest(widgetID: id, in: container)
        XCTAssertTrue(SharedShelf.pendingRefreshRequests(in: container, now: asked).isEmpty)
    }
}
