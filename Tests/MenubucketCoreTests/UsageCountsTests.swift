import XCTest
@testable import MenubucketCore

final class UsageCountsTests: XCTestCase {
    private var tempDir: URL!
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Seoul")!
        return c
    }()

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func date(_ key: String) -> Date { UsageDay.date(key, calendar: calendar)! }

    func testDayKeyUsesTheCalendarTimeZone() {
        // 23:30 UTC on Nov 11 is already Nov 12 in Seoul.
        let utc = ISO8601DateFormatter().date(from: "2026-11-11T23:30:00Z")!
        XCTAssertEqual(UsageDay.key(utc, calendar: calendar), "2026-11-12")
    }

    func testRecordCountsPerDayAndWidget() {
        var log = UsageLog()
        log.record(.popupOpen, widgetID: nil, day: "2026-11-12")
        log.record(.popupOpen, widgetID: "ignored", day: "2026-11-12")
        log.record(.view, widgetID: "a", day: "2026-11-12", count: 3)
        log.record(.action, widgetID: "a", day: "2026-11-12")
        log.record(.menuBarClick, widgetID: "b", day: "2026-11-11")
        log.record(.menuBarCardOpen, widgetID: "b", day: "2026-11-11")
        log.record(.action, widgetID: nil, day: "2026-11-11")
        log.record(.action, widgetID: "", day: "2026-11-11")

        XCTAssertEqual(log.since, "2026-11-11")
        XCTAssertEqual(log.days["2026-11-12"]?.popupOpens, 2)
        XCTAssertEqual(log.days["2026-11-12"]?.widgets["a"], WidgetUsage(views: 3, actions: 1))
        XCTAssertEqual(log.days["2026-11-11"]?.widgets["b"], WidgetUsage(menuBarClicks: 1, menuBarCardOpens: 1))
        XCTAssertEqual(log.days["2026-11-11"]?.widgets.count, 1)
    }

    func testWidgetsPerDayAreCapped() {
        var log = UsageLog()
        for i in 0..<(UsageLog.maxWidgetsPerDay + 20) {
            log.record(.view, widgetID: "w\(i)", day: "2026-11-12")
        }
        XCTAssertEqual(log.days["2026-11-12"]?.widgets.count, UsageLog.maxWidgetsPerDay)
        // An id already counted that day keeps counting.
        log.record(.action, widgetID: "w0", day: "2026-11-12")
        XCTAssertEqual(log.days["2026-11-12"]?.widgets["w0"]?.actions, 1)
    }

    func testPruneKeepsTheLastNinetyDays() {
        var log = UsageLog()
        log.record(.popupOpen, widgetID: nil, day: "2026-08-14") // 91 days before Nov 12
        log.record(.popupOpen, widgetID: nil, day: "2026-08-15") // the 90th day
        log.record(.popupOpen, widgetID: nil, day: "2026-11-12")
        log.prune(today: "2026-11-12", calendar: calendar)
        XCTAssertEqual(Set(log.days.keys), ["2026-08-15", "2026-11-12"])
        XCTAssertEqual(log.since, "2026-08-15")
    }

    func testSummaryWindowOrderAndNeverUsed() {
        var log = UsageLog()
        log.record(.popupOpen, widgetID: nil, day: "2026-10-01") // outside 30 days
        log.record(.action, widgetID: "old", day: "2026-10-01")
        log.record(.popupOpen, widgetID: nil, day: "2026-11-10")
        log.record(.popupOpen, widgetID: nil, day: "2026-11-12")
        log.record(.view, widgetID: "seen", day: "2026-11-12", count: 9)
        log.record(.action, widgetID: "used", day: "2026-11-10", count: 2)
        log.record(.menuBarCardOpen, widgetID: "used", day: "2026-11-12")
        log.record(.action, widgetID: "removed", day: "2026-11-12")

        let summary = log.summary(days: 30, today: "2026-11-12", calendar: calendar,
                                  known: ["used", "seen", "idle", "old"])
        XCTAssertEqual(summary.from, "2026-10-14")
        XCTAssertEqual(summary.to, "2026-11-12")
        XCTAssertEqual(summary.popupOpens, 2)
        XCTAssertEqual(summary.activeDays, 2)
        XCTAssertEqual(summary.rows.map(\.widgetID), ["used", "removed", "seen", "idle", "old"])
        XCTAssertEqual(summary.rows.first?.usage, WidgetUsage(actions: 2, menuBarCardOpens: 1))
        XCTAssertEqual(summary.rows.first { $0.widgetID == "removed" }?.installed, false)
        XCTAssertEqual(summary.rows.first { $0.widgetID == "seen" }?.onlySeen, true)
        XCTAssertEqual(summary.neverUsed.map(\.widgetID), ["idle", "old"])
    }

    func testSummaryStartsNoEarlierThanCounting() {
        var log = UsageLog()
        log.record(.popupOpen, widgetID: nil, day: "2026-11-11")
        let summary = log.summary(days: 30, today: "2026-11-12", calendar: calendar)
        XCTAssertEqual(summary.from, "2026-11-11")
    }

    func testStoreFlushesLoadsAndClears() throws {
        let url = tempDir.appendingPathComponent("usage.json")
        let today = date("2026-11-12")
        let store = UsageStore(fileURL: url, calendar: calendar, writeDelay: 3600, now: { today })
        store.record(.popupOpen)
        store.record(.action, widgetID: "a")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "writes wait for the batch")
        store.flush()

        let reloaded = UsageStore(fileURL: url, calendar: calendar, now: { today })
        XCTAssertEqual(reloaded.snapshot().days["2026-11-12"]?.popupOpens, 1)
        XCTAssertEqual(reloaded.summary(known: ["a"]).rows.first?.usage.actions, 1)

        reloaded.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(reloaded.snapshot(), UsageLog())
        reloaded.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "nothing new to write after clearing")
    }

    func testBatchedWriteHappensOnItsOwn() {
        let url = tempDir.appendingPathComponent("usage.json")
        let store = UsageStore(fileURL: url, calendar: calendar, writeDelay: 0.05)
        store.record(.popupOpen)
        // Polls instead of looking once at 0.5 s, which a busy runner can miss.
        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: url.path), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "the batched write happens without a flush")
    }

    func testDamagedFileLoadsEmpty() throws {
        let url = tempDir.appendingPathComponent("usage.json")
        try Data("not json".utf8).write(to: url)
        XCTAssertEqual(UsageStore.load(from: url), UsageLog())
        try Data(#"{"days":{"2026-11-12":{"popupOpens":"x","widgets":{"a":{"views":2}}}}}"#.utf8).write(to: url)
        let log = UsageStore.load(from: url)
        XCTAssertEqual(log.days["2026-11-12"]?.popupOpens, 0)
        XCTAssertEqual(log.days["2026-11-12"]?.widgets["a"]?.views, 2)
    }

    func testSummaryJSONCarriesTheFlags() throws {
        var log = UsageLog()
        log.record(.view, widgetID: "a", day: "2026-11-12")
        let summary = log.summary(days: 7, today: "2026-11-12", calendar: calendar, known: ["a", "b"])
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(summary)) as? [String: Any]
        let rows = json?["rows"] as? [[String: Any]]
        XCTAssertEqual(rows?.first?["widgetId"] as? String, "a")
        XCTAssertEqual(rows?.first?["onlySeen"] as? Bool, true)
        XCTAssertEqual(rows?.last?["neverUsed"] as? Bool, true)
        XCTAssertEqual(try JSONDecoder().decode(UsageSummary.self, from: JSONEncoder().encode(summary)), summary)
    }

    func testPreferenceDefaultsOnAndDecodesMissing() throws {
        XCTAssertTrue(AppPreferences().usageCountsEnabled)
        let decoded = try JSONDecoder().decode(AppPreferences.self, from: Data("{}".utf8))
        XCTAssertTrue(decoded.usageCountsEnabled)
        let off = try JSONDecoder().decode(AppPreferences.self, from: Data(#"{"usageCountsEnabled":false}"#.utf8))
        XCTAssertFalse(off.usageCountsEnabled)
    }
}
