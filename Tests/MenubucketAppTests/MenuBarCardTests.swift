@testable import MenubucketApp
import MenubucketCore
import XCTest

final class MenuBarCardTests: XCTestCase {
    private func widget(statusItem: String = #"{"mode": "text"}"#) throws -> LoadedWidget {
        let json = """
        {"schemaVersion": 1, "id": "test.card", "name": "Card", "version": "1.0.0",
         "entry": {"kind": "workflow", "main": "workflow.json"}, "statusItem": \(statusItem)}
        """
        return LoadedWidget(
            manifest: try Manifest.decode(from: Data(json.utf8)),
            directory: FileManager.default.temporaryDirectory
        )
    }

    func testHistoryKeepsTheLatestReadingsAndDropsRemovedWidgets() {
        let history = ReadingHistory()
        for value in 0..<(ReadingHistory.limit + 5) { history.record("a", Double(value)) }
        history.record("b", 1)
        XCTAssertEqual(history.values["a"]?.count, ReadingHistory.limit)
        XCTAssertEqual(history.values["a"]?.last, Double(ReadingHistory.limit + 4))
        history.retain(["a"])
        XCTAssertNil(history.values["b"])
    }

    func testTheReadingIsTheFirstMetricWithANumber() {
        var snapshot = WidgetSnapshot(widgetID: "a")
        snapshot.statusMetrics = [StatusMetric(label: "Load", value: "busy"), StatusMetric(label: "CPU", value: "23%", number: 23)]
        XCTAssertEqual(ReadingHistory.reading(of: snapshot), 23)
    }

    func testHeroLeadsWithTheMenuBarReadingUnlessTheWidgetOptsOut() throws {
        var snapshot = WidgetSnapshot(widgetID: "test.card")
        snapshot.statusMetrics = [StatusMetric(label: "CPU", value: "23%", number: 23, format: "percent", tint: "warning")]
        let hero = try XCTUnwrap(MenuBarCardHero.Content(widget: try widget(), snapshot: snapshot, history: [1, 2, 3]))
        XCTAssertEqual(hero.label, "CPU")
        XCTAssertEqual(hero.value, "23%")
        XCTAssertEqual(hero.tint, "warning")
        XCTAssertTrue(hero.isPercent)

        let optedOut = try widget(statusItem: #"{"mode": "text", "popoverHero": false}"#)
        XCTAssertNil(MenuBarCardHero.Content(widget: optedOut, snapshot: snapshot, history: []))

        XCTAssertNil(MenuBarCardHero.Content(widget: try widget(), snapshot: WidgetSnapshot(widgetID: "x"), history: []),
                     "nothing for the menu bar, nothing to lead with")

        var labelOnly = WidgetSnapshot(widgetID: "test.card")
        labelOnly.statusLabel = "1:42"
        XCTAssertEqual(MenuBarCardHero.Content(widget: try widget(), snapshot: labelOnly, history: [])?.value, "1:42")
    }

    func testTheCardsHiddenActionGetsANamedButtonOnlyWhenItsNameIsClear() {
        XCTAssertNotNil(PrimaryActionTitle.title(for: NodeAction(type: "openURL", url: "https://example.com")))
        XCTAssertNotNil(PrimaryActionTitle.title(for: NodeAction(type: "revealFile", path: "/tmp")))
        XCTAssertNil(PrimaryActionTitle.title(for: NodeAction(type: "copyText", value: "x")))
        XCTAssertNil(PrimaryActionTitle.title(for: NodeAction(type: "run")))
        XCTAssertEqual(PrimaryActionTitle.appName("Some App"), "Some App")
    }
}
