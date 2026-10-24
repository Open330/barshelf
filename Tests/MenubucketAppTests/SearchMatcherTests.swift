import XCTest
import MenubucketCore
@testable import MenubucketApp

final class SearchMatcherTests: XCTestCase {
    func testEveryWordMustAppearInAnyOrder() {
        XCTAssertTrue(SearchMatcher("cpu temp").matches("Temperature · CPU"))
        XCTAssertFalse(SearchMatcher("cpu fan").matches("Temperature · CPU"))
    }

    func testCaseAccentsAndWidthAreIgnored() {
        XCTAssertTrue(SearchMatcher("cafe").matches("Café hours"))
        XCTAssertTrue(SearchMatcher("ＢＡＴＴＥＲＹ").matches("Battery"))
        XCTAssertTrue(SearchMatcher("battery").matches("BATTERY 82%"))
    }

    /// A widget shown by its Korean name is still found by its English one.
    func testWordsCanComeFromEitherName() {
        XCTAssertTrue(SearchMatcher("weather").matches("날씨", "Weather"))
        XCTAssertTrue(SearchMatcher("날씨").matches("날씨", "Weather"))
        XCTAssertFalse(SearchMatcher("battery").matches("날씨", "Weather"))
    }

    func testBlankQueriesMatchNothing() {
        XCTAssertTrue(SearchMatcher("   ").isEmpty)
        XCTAssertFalse(SearchMatcher("").matches("anything"))
        XCTAssertFalse(SearchMatcher("x").matches(nil))
    }

    @MainActor
    func testOverlayMatchesWidgetNameAndReadingTogetherWithoutUnrelatedRows() {
        let manifest = Manifest(schemaVersion: 1, id: "dev.test.weather-search", name: "Weather",
                                entry: .init(kind: "workflow"))
        let widget = LoadedWidget(manifest: manifest, directory: URL(fileURLWithPath: "/unused"))
        let action = NodeAction(type: "copyText", value: "Seoul")
        let tree = UINode(type: "stack", children: [
            UINode(type: "text", text: "Seoul 20°C", action: action),
            UINode(type: "text", text: "Busan 22°C")
        ])
        let pages = [WidgetPage(group: "Empty", widgets: []), WidgetPage(group: "Travel", widgets: [widget])]
        let snapshots = [widget.id: WidgetSnapshot(widgetID: widget.id, viewTree: tree)]
        let hits = SearchOverlay.searchHits(query: "weather seoul", pages: pages, snapshots: snapshots)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.text, "Seoul 20°C")
        XCTAssertEqual(hits.first?.pageIndex, 1)
        XCTAssertEqual(hits.first?.widgetID, widget.id)
        XCTAssertEqual(hits.first?.action, action)
        XCTAssertTrue(SearchOverlay.searchHits(query: "weather tokyo", pages: pages, snapshots: snapshots).isEmpty)
        let names = SearchOverlay.searchHits(query: "weather", pages: pages, snapshots: snapshots)
        XCTAssertEqual(names.count, 1, "matching a widget name must not turn every unrelated reading into a hit")
        XCTAssertNil(names.first?.action)
    }

    /// Measured live on 0.7.5 shown in English: "시스템" found nothing, though
    /// the System widget carries that name, and one reading listed twice
    /// came back as two results.
    @MainActor
    func testOtherLanguageNamesMatchAndRepeatedReadingsAreOneResult() {
        let manifest = Manifest(schemaVersion: 1, id: "dev.test.system-search", name: "System",
                                entry: .init(kind: "workflow"),
                                localizations: WidgetLocalizations(["ko": ["System": "시스템"]]))
        let widget = LoadedWidget(manifest: manifest, directory: URL(fileURLWithPath: "/unused"))
        let tree = UINode(type: "stack", children: [
            UINode(type: "text", text: "CPU 19%"),
            UINode(type: "text", text: "CPU 19%"),
        ])
        let pages = [WidgetPage(group: "System", widgets: [widget])]
        let snapshots = [widget.id: WidgetSnapshot(widgetID: widget.id, viewTree: tree)]
        let byKoreanName = SearchOverlay.searchHits(query: "시스템", pages: pages, snapshots: snapshots)
        XCTAssertEqual(byKoreanName.map(\.widgetID), [widget.id])
        XCTAssertEqual(SearchOverlay.searchHits(query: "시스템 cpu", pages: pages, snapshots: snapshots).count, 1)
        XCTAssertEqual(SearchOverlay.searchHits(query: "cpu", pages: pages, snapshots: snapshots).count, 1)
    }
}
