import XCTest
@testable import BarShelfKit
@testable import MenubucketCore

final class UsageCommandTests: XCTestCase {
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private func sampleLog() -> UsageLog {
        var log = UsageLog()
        log.record(.popupOpen, widgetID: nil, day: "2026-11-12", count: 4)
        log.record(.action, widgetID: "dev.a", day: "2026-11-12", count: 2)
        log.record(.menuBarCardOpen, widgetID: "dev.a", day: "2026-11-11")
        log.record(.view, widgetID: "dev.b--work", day: "2026-11-12", count: 5)
        log.record(.action, widgetID: "dev.gone", day: "2026-11-12")
        return log
    }

    func testTextListsUsedThenIdle() {
        let text = UsageCommand.render(
            log: sampleLog(),
            widgets: ["dev.a": "Alpha", "dev.b--work": "Beta", "dev.c": "Gamma"],
            days: 30, json: false, today: "2026-11-12", calendar: calendar
        )
        XCTAssertTrue(text.contains("shelf opened 4 times"), text)
        XCTAssertTrue(text.contains("3\t0\t2\t1\tAlpha (dev.a)"), text)
        XCTAssertTrue(text.contains("1\t0\t1\t0\tdev.gone (not installed)"), text)
        XCTAssertTrue(text.contains("0\t5\t0\t0\tBeta (dev.b--work)"), text)
        XCTAssertTrue(text.contains("not used in 30 days:\n  Gamma (dev.c)"), text)
        let alpha = text.range(of: "Alpha")!.lowerBound
        let beta = text.range(of: "Beta")!.lowerBound
        XCTAssertLessThan(alpha, beta, "used before only seen")
    }

    func testJSONIsTheSummary() throws {
        let text = UsageCommand.render(
            log: sampleLog(), widgets: ["dev.a": "Alpha", "dev.c": "Gamma"],
            days: 1, json: true, today: "2026-11-12", calendar: calendar
        )
        let summary = try JSONDecoder().decode(UsageSummary.self, from: Data(text.utf8))
        XCTAssertEqual(summary.days, 1)
        XCTAssertEqual(summary.from, "2026-11-12")
        XCTAssertEqual(summary.popupOpens, 4)
        XCTAssertEqual(summary.rows.first { $0.widgetID == "dev.a" }?.usage.actions, 2)
        XCTAssertEqual(summary.rows.first { $0.widgetID == "dev.a" }?.usage.menuBarCardOpens, 0, "yesterday is outside one day")
        XCTAssertEqual(summary.neverUsed.map(\.widgetID), ["dev.c"])
    }

    func testEmptyLogSaysSo() {
        let text = UsageCommand.render(log: UsageLog(), widgets: [:], days: 30, json: false, today: "2026-11-12", calendar: calendar)
        XCTAssertTrue(text.hasPrefix("nothing counted yet"), text)
    }

    func testBadArgumentsFail() {
        XCTAssertEqual(UsageCommand.run(arguments: ["--days", "0"]), 1)
        XCTAssertEqual(UsageCommand.run(arguments: ["--days"]), 1)
        XCTAssertEqual(UsageCommand.run(arguments: ["--bogus"]), 1)
    }

    func testInstanceIDsFollowTheDirectoryName() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("usage-cli-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        for (folder, id) in [("dev.a", "dev.a"), ("dev.a--work", "dev.a"), ("other-name", "dev.c")] {
            let widget = dir.appendingPathComponent(folder)
            try FileManager.default.createDirectory(at: widget, withIntermediateDirectories: true)
            let manifest = #"{"schemaVersion":1,"id":"\#(id)","name":"N \#(folder)","entry":{"kind":"workflow","main":"workflow.json"}}"#
            try Data(manifest.utf8).write(to: widget.appendingPathComponent("widget.json"))
            try Data(#"{"view":{"type":"text","text":"hi"}}"#.utf8).write(to: widget.appendingPathComponent("workflow.json"))
        }
        let names = UsageCommand.installedWidgets(in: dir)
        XCTAssertEqual(Set(names.keys), ["dev.a", "dev.a--work", "dev.c"], "\(names)")
    }

    /// The app makes a copy of a widget as a link to the original folder.
    func testCopiesMadeAsSymbolicLinksAreNamed() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("usage-cli-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let original = dir.appendingPathComponent("dev.a")
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        try Data(#"{"schemaVersion":1,"id":"dev.a","name":"Watch","entry":{"kind":"workflow","main":"workflow.json"}}"#.utf8)
            .write(to: original.appendingPathComponent("widget.json"))
        try FileManager.default.createSymbolicLink(
            at: dir.appendingPathComponent("dev.a--office"), withDestinationURL: original)

        let names = UsageCommand.installedWidgets(in: dir)
        XCTAssertEqual(names, ["dev.a": "Watch", "dev.a--office": "Watch"])
    }
}
