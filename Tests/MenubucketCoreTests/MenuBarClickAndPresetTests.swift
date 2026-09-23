import Foundation
import XCTest

@testable import MenubucketCore

/// Click actions, presets and copying another item's style.
final class MenuBarClickAndPresetTests: XCTestCase {
    func testClickActionRoundTripsAndStaysLenient() throws {
        let placement = MenuBarPlacement(enabled: true, separate: true, clickAction: .open,
                                         clickTarget: "  com.apple.ActivityMonitor ")
        XCTAssertEqual(placement.clickTarget, "com.apple.ActivityMonitor")
        let data = try JSONEncoder().encode(placement)
        XCTAssertEqual(try JSONDecoder().decode(MenuBarPlacement.self, from: data), placement)

        let odd = Data(#"{"enabled":true,"clickAction":"teleport","clickTarget":"  ","label":"CPU"}"#.utf8)
        let decoded = try JSONDecoder().decode(MenuBarPlacement.self, from: odd)
        XCTAssertNil(decoded.clickAction)
        XCTAssertEqual(decoded.effectiveClickAction, .card, "an unknown action still shows the card")
        XCTAssertNil(decoded.clickTarget)
        XCTAssertEqual(decoded.label, "CPU", "and costs nothing else")
    }

    func testPresetsLayerOverExistingChoices() {
        let mine = MenuBarPresentation(precision: 2, color: "accent", metricOrder: ["b"], width: .fixed)
        let compact = MenuBarPresentation.presets.first { $0.name == "Compact" }!.presentation
        let applied = mine.applying(preset: compact)
        XCTAssertEqual(applied.width, .fit)
        XCTAssertEqual(applied.size, .small)
        XCTAssertEqual(applied.color, "accent", "what the preset leaves alone stays")
        XCTAssertEqual(applied.precision, 2)
        XCTAssertEqual(applied.metricOrder, ["b"])
        XCTAssertEqual(Set(MenuBarPresentation.presets.map(\.name)).count, MenuBarPresentation.presets.count)
    }

    func testCopyingStyleKeepsThisWidgetsReadings() {
        let look = MenuBarPresentation(precision: 1, color: "warning", metricOrder: ["gpu"],
                                       metricOverrides: ["gpu": MenuBarMetricOverride(hidden: true)],
                                       size: .large, warningAt: 80, showWhen: 50, chart: .bars)
        let target = MenuBarPlacement(
            enabled: true, separate: true, label: "CPU", style: .stacked,
            presentation: MenuBarPresentation(precision: 0, metricOrder: ["cpu"], dangerAt: 95)
        )
        let copied = target.copyingStyle(layout: .metrics, look: look)
        XCTAssertEqual(copied.style, .metrics, "the layout the other item shows, even from its manifest")
        XCTAssertEqual(copied.presentation?.color, "warning")
        XCTAssertEqual(copied.presentation?.size, .large)
        XCTAssertEqual(copied.presentation?.chart, .bars)
        XCTAssertEqual(copied.presentation?.precision, 0, "precision suits this widget's readings")
        XCTAssertEqual(copied.presentation?.metricOrder, ["cpu"])
        XCTAssertNil(copied.presentation?.metricOverrides)
        XCTAssertNil(copied.presentation?.warningAt, "thresholds are in the other reading's unit")
        XCTAssertNil(copied.presentation?.showWhen)
        XCTAssertEqual(copied.presentation?.dangerAt, 95, "this item's own alerts stay")
        XCTAssertEqual(copied.label, "CPU", "its own label is not style")
    }

    func testAppWidePresetsAreThoseThatFullyApply() {
        let names = MenuBarPresentation.appWidePresets.map(\.name)
        XCTAssertTrue(names.contains("Compact"))
        XCTAssertFalse(names.contains("Graph"), "a chart is each widget's own")
        XCTAssertFalse(names.contains("Minimal"), "so are units")
    }
}
