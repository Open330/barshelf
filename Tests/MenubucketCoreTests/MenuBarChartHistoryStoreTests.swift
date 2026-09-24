import Foundation
import XCTest

@testable import MenubucketCore

final class MenuBarChartHistoryStoreTests: XCTestCase {
    private var url: URL!

    override func setUpWithError() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("charts-\(UUID().uuidString)").appendingPathComponent("menu-bar-charts.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    func testAQuickRelaunchKeepsTheGraph() throws {
        var history = MenuBarChartHistory(series: "cpu", scale: 100, values: [10, 20, 30], lastAt: 12345)
        history.pending = 99
        let saved = Date(timeIntervalSince1970: 1_000_000)
        try MenuBarChartHistoryStore.save(["w": history], to: url, at: saved)
        let loaded = MenuBarChartHistoryStore.load(from: url, now: saved.addingTimeInterval(60))
        XCTAssertEqual(loaded["w"]?.values, [10, 20, 30, 99], "the unfinished step's peak is kept")
        XCTAssertEqual(loaded["w"]?.scale, 100)
        XCTAssertNil(loaded["w"]?.lastAt, "the old run's clock means nothing now")
        XCTAssertNil(loaded["w"]?.pending)
    }

    func testALongAbsenceStartsAfresh() throws {
        let saved = Date(timeIntervalSince1970: 1_000_000)
        try MenuBarChartHistoryStore.save(["w": .init(series: "cpu", scale: 100, values: [1])], to: url, at: saved)
        XCTAssertFalse(MenuBarChartHistoryStore.load(from: url, now: saved.addingTimeInterval(45)).isEmpty,
                       "an update's relaunch is bridged")
        XCTAssertTrue(MenuBarChartHistoryStore.load(from: url, now: saved.addingTimeInterval(2 * 60)).isEmpty,
                      "a gap longer than a graph's own window is not drawn as a line")
        XCTAssertTrue(MenuBarChartHistoryStore.load(from: url, now: saved.addingTimeInterval(-5)).isEmpty,
                      "a clock that went backwards is not trusted")
    }

    func testNothingToKeepRemovesTheFileAndJunkIsIgnored() throws {
        try MenuBarChartHistoryStore.save(["w": .init(series: "cpu", scale: 100, values: [1])], to: url)
        try MenuBarChartHistoryStore.save([:], to: url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        XCTAssertTrue(MenuBarChartHistoryStore.load(from: url).isEmpty)
    }
}
