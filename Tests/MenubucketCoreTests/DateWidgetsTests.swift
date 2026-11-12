import XCTest
@testable import MenubucketCore

/// Today, Clock, Local Time and Calendar read the date from `now()` instead of
/// `/bin/date`, whose C-locale names leaked English into Korean ("2026년 Nov").
/// The engine has no local-date function, so the widgets derive the zone
/// offset and the civil date with arithmetic; these tests hold that arithmetic
/// to Foundation's calendar in zones on both sides of UTC.
final class DateWidgetsTests: XCTestCase {
    private var savedZone: TimeZone!

    override func setUp() {
        super.setUp()
        savedZone = NSTimeZone.default
    }

    override func tearDown() {
        NSTimeZone.default = savedZone
        super.tearDown()
    }

    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func starter(_ name: String) throws -> (manifest: Manifest, workflow: WorkflowDefinition) {
        let dir = Self.root.appendingPathComponent("widgets/\(name)")
        return (
            try Manifest.decode(from: Data(contentsOf: dir.appendingPathComponent("widget.json"))),
            try WorkflowDefinition.decode(from: Data(contentsOf: dir.appendingPathComponent("workflow.json")))
        )
    }

    private func evaluate(
        _ name: String, at ms: Double, locale: String? = nil, size: String = "S",
        settings: [String: JSONValue] = [:]
    ) throws -> WorkflowEngine.Output {
        let (manifest, workflow) = try starter(name)
        let definition = locale.flatMap { manifest.localization(for: $0) }?.workflow(workflow) ?? workflow
        var widget: [String: JSONValue] = ["size": .string(size)]
        if let locale { widget["locale"] = .string(locale) }
        return try WorkflowEngine.evaluate(
            definition, sources: [:], settings: .object(settings), widget: .object(widget), nowMs: ms
        )
    }

    private func texts(_ node: UINode) -> [String] {
        [node.text].compactMap { $0 } + ((node.children ?? []) + (node.items ?? [])).flatMap(texts)
    }

    private static let english: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private static let zones = [
        "Asia/Seoul", "America/Los_Angeles", "Pacific/Honolulu", "Asia/Kolkata",
        "Pacific/Auckland", "Pacific/Chatham", "UTC", "America/St_Johns",
    ]

    /// A spread of instants: around midnight, month ends, leap days, a year end.
    private static let instants: [Double] = {
        var out: [Double] = []
        let base = 1_704_067_200_000.0 // 2024-01-01T00:00Z
        for step in 0..<180 {
            out.append(base + Double(step) * 5.3 * 86_400_000 + Double(step % 7) * 3_600_000)
        }
        out += [1_709_164_800_000, 1_709_251_199_000, 1_735_689_599_000, 1_735_689_600_000, 1_798_675_200_000]
        return out
    }()

    func testTodayMatchesTheCalendarInEveryZone() throws {
        let (_, workflow) = try starter("today")
        for zone in Self.zones {
            NSTimeZone.default = try XCTUnwrap(TimeZone(identifier: zone))
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = NSTimeZone.default
            for ms in Self.instants {
                let date = Date(timeIntervalSince1970: ms / 1000)
                let parts = calendar.dateComponents([.year, .month, .day, .weekday, .hour, .minute], from: date)
                let output = try WorkflowEngine.evaluate(
                    workflow, sources: [:], settings: .object([:]), widget: .object(["size": .string("L")]), nowMs: ms
                )
                let weekday = Self.english.standaloneWeekdaySymbols[parts.weekday! - 1]
                let month = Self.english.monthSymbols[parts.month! - 1]
                let expected = "\(weekday), \(month) \(parts.day!), \(parts.year!)"
                XCTAssertEqual(output.statusTooltip, expected, "\(zone) \(ms)")
                XCTAssertEqual(output.statusLabel, String(format: "%02d:%02d", parts.hour!, parts.minute!), "\(zone) \(ms)")
            }
        }
    }

    func testTodayReadsInKoreanWithoutEnglishNames() throws {
        NSTimeZone.default = try XCTUnwrap(TimeZone(identifier: "Asia/Seoul"))
        let ms = 1_794_441_600_000.0 // 2026-11-12 09:00 KST, a Thursday
        let korean = try evaluate("today", at: ms, locale: "ko", size: "M")
        XCTAssertEqual(korean.statusTooltip, "2026년 11월 12일 목요일")
        let shown = texts(korean.viewTree)
        XCTAssertTrue(shown.contains("목요일"), "\(shown)")
        XCTAssertTrue(shown.contains("2026년 11월"), "\(shown)")
        XCTAssertTrue(shown.contains("12"), "\(shown)")
        XCTAssertFalse(shown.joined().contains("Nov"), "\(shown)")
        XCTAssertFalse(shown.joined().contains("Thursday"), "\(shown)")

        let english = try evaluate("today", at: ms, size: "M")
        XCTAssertEqual(english.statusTooltip, "Thursday, November 12, 2026")
        XCTAssertTrue(texts(english.viewTree).contains("Nov 2026"))
        XCTAssertEqual(english.statusLabel, "09:00")
    }

    func testDateWidgetsRunNothing() throws {
        for name in ["today", "clock", "local-time", "calendar"] {
            let (manifest, workflow) = try starter(name)
            XCTAssertTrue(workflow.sources.isEmpty, name)
            XCTAssertFalse(PermissionStore.requiresApproval(for: manifest), name)
        }
    }

    func testClockFollowsTheHourFormatAndLanguage() throws {
        NSTimeZone.default = try XCTUnwrap(TimeZone(identifier: "Asia/Seoul"))
        let ms = 1_794_473_400_000.0 // 2026-11-12 17:50 KST
        let plain = try evaluate("clock", at: ms)
        XCTAssertEqual(plain.statusLabel, "17:50")
        XCTAssertEqual(plain.viewTree.children?.first?.children?.first?.text, "17:50")
        XCTAssertEqual(plain.statusTooltip, "Thursday, November 12")

        let twelve = try evaluate("clock", at: ms, settings: ["hourFormat": .string("12")])
        XCTAssertEqual(twelve.statusLabel, "5:50 PM")
        let korean = try evaluate("clock", at: ms, locale: "ko", settings: ["hourFormat": .string("12")])
        XCTAssertEqual(korean.statusLabel, "오후 5:50")
        XCTAssertEqual(korean.statusTooltip, "11월 12일 목요일")
        let midnight = try evaluate("clock", at: 1_794_409_500_000, settings: ["hourFormat": .string("12")]) // 00:05 KST
        XCTAssertEqual(midnight.statusLabel, "12:05 AM")
    }

    func testLocalTimeFitsAndSaysTheDate() throws {
        NSTimeZone.default = try XCTUnwrap(TimeZone(identifier: "Asia/Seoul"))
        let output = try evaluate("local-time", at: 1_794_449_160_000, locale: "ko") // 11:06 KST
        let shown = texts(output.viewTree)
        XCTAssertEqual(shown, ["11:06", "11월 12일 목요일"])
        XCTAssertEqual(output.viewTree.type, "vstack", "no boxed card")
        XCTAssertEqual(output.statusLabel, "11:06")
        XCTAssertEqual(try evaluate("local-time", at: 1_794_449_160_000).viewTree.children?.last?.text, "Thursday, Nov 12")
    }

    private func dayGrid(_ output: WorkflowEngine.Output) -> UINode? {
        (output.viewTree.children ?? []).last { $0.type == "grid" }
    }

    func testCalendarGridMatchesTheMonthInEveryZone() throws {
        for zone in ["Asia/Seoul", "America/Los_Angeles", "Pacific/Chatham"] {
            NSTimeZone.default = try XCTUnwrap(TimeZone(identifier: zone))
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = NSTimeZone.default
            for ms in Self.instants.prefix(60) {
                let date = Date(timeIntervalSince1970: ms / 1000)
                let parts = calendar.dateComponents([.year, .month, .day], from: date)
                let first = calendar.date(from: DateComponents(year: parts.year, month: parts.month, day: 1))!
                let leading = calendar.component(.weekday, from: first) - 1
                let length = calendar.range(of: .day, in: .month, for: date)!.count
                let output = try evaluate("calendar", at: ms)
                let items = try XCTUnwrap(dayGrid(output)?.items, zone)
                XCTAssertEqual(items.count, leading + length, "\(zone) \(ms)")
                XCTAssertEqual(items.prefix(leading).allSatisfy { $0.text == "" }, true, "\(zone) \(ms)")
                XCTAssertEqual(items.last?.text, String(length), "\(zone) \(ms)")
                let today = items.first { $0.text == String(parts.day!) }
                XCTAssertEqual(today?.fill, "accent", "\(zone) \(ms)")
                XCTAssertEqual(today?.role, "title", "\(zone) \(ms)")
                XCTAssertEqual(items.filter { $0.fill == "accent" }.count, 1, "\(zone) \(ms)")
            }
        }
    }

    func testCalendarTitleHasTheYearInBothLanguages() throws {
        NSTimeZone.default = try XCTUnwrap(TimeZone(identifier: "Asia/Seoul"))
        let ms = 1_794_441_600_000.0
        XCTAssertEqual(try evaluate("calendar", at: ms).viewTree.children?.first?.text, "November 2026")
        let korean = try evaluate("calendar", at: ms, locale: "ko")
        XCTAssertEqual(korean.viewTree.children?.first?.text, "2026년 11월")
        XCTAssertEqual(korean.statusTooltip, "11월 12일 목요일")
        let header = texts(korean.viewTree)
        for day in ["일", "월", "화", "수", "목", "금", "토"] { XCTAssertTrue(header.contains(day), day) }
    }
}
