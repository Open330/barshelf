import Foundation
import XCTest

@testable import MenubucketCore

/// The app-wide menu bar style: where it ranks, what it may carry, and how
/// it survives on disk.
final class MenuBarGlobalStyleTests: XCTestCase {
    func testGlobalRanksBelowTheItemAndAboveTheWidget() {
        let resolved = MenuBarPolicy.resolvedPresentation(
            user: MenuBarPresentation(alignment: .leading),
            global: MenuBarPresentation(width: .fit, alignment: .center, size: .small),
            live: MenuBarPresentation(width: .fixed, size: .large, numberAlignment: .left),
            manifest: MenuBarPresentation(digits: 3)
        )
        XCTAssertEqual(resolved.alignment, .leading, "the item's own choice wins")
        XCTAssertEqual(resolved.width, .fit, "the app-wide choice beats the render's")
        XCTAssertEqual(resolved.size, .small)
        XCTAssertEqual(resolved.numberAlignment, .left, "what global leaves open still comes from the widget")
        XCTAssertEqual(resolved.digits, 3)
    }

    func testGlobalCarriesOnlyStyle() {
        let style = MenuBarPolicy.globalStyle(MenuBarPresentation(
            showValues: false, showUnits: false, precision: 2, color: "monochrome",
            metricOrder: ["a"], metricOverrides: ["a": MenuBarMetricOverride(hidden: true)],
            weight: .bold
        ))
        XCTAssertEqual(style, MenuBarPresentation(showUnits: false, color: "monochrome", weight: .bold))
        XCTAssertNil(MenuBarPolicy.globalStyle(MenuBarPresentation(precision: 1)),
                     "nothing left means no global layer at all")

        let resolved = MenuBarPolicy.resolvedPresentation(
            user: nil, global: MenuBarPresentation(precision: 3), live: MenuBarPresentation(precision: 0), manifest: nil
        )
        XCTAssertEqual(resolved.precision, 0, "a sensor's whole degrees are not the app's to change")
    }

    func testClearingKeepsWhatIsNotStyle() {
        let cleared = MenuBarPolicy.clearingGlobalStyle(MenuBarPresentation(
            precision: 1, color: "accent", metricOrder: ["b", "a"], width: .fixed, digits: 3
        ))
        XCTAssertEqual(cleared, MenuBarPresentation(precision: 1, metricOrder: ["b", "a"]))
        XCTAssertNil(MenuBarPolicy.clearingGlobalStyle(MenuBarPresentation(width: .fit, size: .large)))
    }

    func testPreferencesRoundTripAndStayLenient() throws {
        let prefs = AppPreferences(menuBarPresentation: MenuBarPresentation(precision: 2, width: .fit))
        XCTAssertEqual(prefs.menuBarPresentation, MenuBarPresentation(width: .fit), "precision is dropped on the way in")
        let data = try JSONEncoder().encode(prefs)
        XCTAssertEqual(try JSONDecoder().decode(AppPreferences.self, from: data), prefs)

        let broken = Data(#"{"menuBarSymbol":"gauge","menuBarPresentation":[1,2]}"#.utf8)
        let decoded = try JSONDecoder().decode(AppPreferences.self, from: broken)
        XCTAssertEqual(decoded.menuBarSymbol, "gauge", "a bad block does not cost the rest")
        XCTAssertNil(decoded.menuBarPresentation)

        XCTAssertNil(try JSONDecoder().decode(AppPreferences.self, from: Data("{}".utf8)).menuBarPresentation)
    }
}
