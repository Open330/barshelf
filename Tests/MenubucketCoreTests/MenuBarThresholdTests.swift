import Foundation
import XCTest

@testable import MenubucketCore

/// Warning and danger thresholds, and "show only when".
final class MenuBarThresholdTests: XCTestCase {
    private func entry(_ metrics: [StatusMetric], tint: MenuBarTint? = .good) -> MenuBarEntry {
        MenuBarEntry(widgetID: "w", name: "W", tint: tint, metrics: metrics)
    }

    private func percent(_ value: Double, tint: String? = "good") -> StatusMetric {
        StatusMetric(id: "cpu", label: "CPU", number: value, format: "percent", tint: tint)
    }

    func testThresholdsReplaceTheWidgetsColours() {
        let presentation = MenuBarPresentation(warningAt: 60, dangerAt: 85)
        func tint(_ value: Double) -> (String?, MenuBarTint?) {
            let applied = MenuBarPolicy.applyingPresentation(presentation, to: entry([percent(value)]))
            return (applied.metrics.first?.tint, applied.tint)
        }
        XCTAssertEqual(tint(40).0, nil, "below warning drops the widget's own green")
        XCTAssertEqual(tint(40).1, nil)
        XCTAssertEqual(tint(60).0, "warning", "at the threshold counts")
        XCTAssertEqual(tint(90).0, "danger")
        XCTAssertEqual(tint(90).1, .danger)
    }

    func testLowerIsWorse() {
        let presentation = MenuBarPresentation(warningAt: 30, dangerAt: 10, thresholdDirection: .below)
        let low = MenuBarPolicy.applyingPresentation(presentation, to: entry([percent(8)]))
        let mid = MenuBarPolicy.applyingPresentation(presentation, to: entry([percent(25)]))
        let high = MenuBarPolicy.applyingPresentation(presentation, to: entry([percent(80)]))
        XCTAssertEqual(low.tint, .danger)
        XCTAssertEqual(mid.tint, .warning)
        XCTAssertNil(high.tint)
    }

    func testItemTintIsTheWorstReading() {
        let presentation = MenuBarPresentation(warningAt: 60, dangerAt: 85)
        let applied = MenuBarPolicy.applyingPresentation(presentation, to: entry([
            percent(70), StatusMetric(id: "ram", label: "RAM", number: 90, format: "percent"),
        ]))
        XCTAssertEqual(applied.metrics.map(\.tint), ["warning", "danger"])
        XCTAssertEqual(applied.tint, .danger)
    }

    func testColourChoicesStillWin() {
        let mono = MenuBarPolicy.applyingPresentation(
            MenuBarPresentation(color: "monochrome", warningAt: 1), to: entry([percent(90)])
        )
        XCTAssertNil(mono.tint)
        XCTAssertNil(mono.metrics.first?.tint)
    }

    func testTextOnlyReadingsKeepTheWidgetsColour() {
        let applied = MenuBarPolicy.applyingPresentation(
            MenuBarPresentation(warningAt: 1),
            to: entry([StatusMetric(label: "Net", value: "up", tint: "good")])
        )
        XCTAssertEqual(applied.tint, .good)
    }

    func testThresholdUnits() {
        XCTAssertEqual(MenuBarPolicy.thresholdValue(StatusMetric(number: 8e9, format: "bytes")), 8)
        XCTAssertEqual(MenuBarPolicy.thresholdValue(StatusMetric(number: 2.5e6, format: "bytesPerSecond")), 2.5)
        XCTAssertEqual(MenuBarPolicy.thresholdValue(StatusMetric(number: 71, unit: "°C")), 71)
        XCTAssertNil(MenuBarPolicy.thresholdValue(StatusMetric(number: .nan)))
        XCTAssertEqual(MenuBarPolicy.thresholdUnit([StatusMetric(number: 1, format: "bytes")]), "GB")
        XCTAssertEqual(MenuBarPolicy.thresholdUnit([StatusMetric(number: 1, unit: "°C")]), "°C")
    }

    func testShowWhen() {
        func dormant(_ value: Double, _ direction: MenuBarThresholdDirection? = nil) -> Bool {
            let presentation = MenuBarPresentation(thresholdDirection: direction, showWhen: 50)
            return MenuBarPolicy.isDormant(MenuBarPolicy.applyingPresentation(presentation, to: entry([percent(value)])))
        }
        XCTAssertTrue(dormant(20))
        XCTAssertFalse(dormant(50))
        XCTAssertFalse(dormant(20, .below))
        XCTAssertTrue(dormant(80, .below))

        let textOnly = MenuBarPolicy.applyingPresentation(
            MenuBarPresentation(showWhen: 50), to: entry([StatusMetric(label: "Net", value: "up")])
        )
        XCTAssertFalse(MenuBarPolicy.isDormant(textOnly), "nothing to judge never hides an item for good")
    }

    func testThresholdsAreNotAppWide() {
        XCTAssertNil(MenuBarPolicy.globalStyle(MenuBarPresentation(warningAt: 1, showWhen: 2)))
        let cleared = MenuBarPolicy.clearingGlobalStyle(MenuBarPresentation(width: .fit, dangerAt: 9))
        XCTAssertEqual(cleared, MenuBarPresentation(dangerAt: 9))
    }

    func testDecodingIsLenient() throws {
        let json = Data(#"{"warningAt":60,"dangerAt":"lots","thresholdDirection":"sideways","showWhen":5}"#.utf8)
        let decoded = try JSONDecoder().decode(MenuBarPresentation.self, from: json)
        XCTAssertEqual(decoded, MenuBarPresentation(warningAt: 60, showWhen: 5))
        let resolved = MenuBarPolicy.resolvedPresentation(
            user: MenuBarPresentation(dangerAt: 80), live: MenuBarPresentation(warningAt: 50, dangerAt: 70), manifest: nil
        )
        XCTAssertEqual(resolved.warningAt, 50)
        XCTAssertEqual(resolved.dangerAt, 80)
    }
}
