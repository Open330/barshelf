import Foundation
import XCTest

@testable import MenubucketCore

/// Steady widths, the presentation fields behind them, and the row keys and
/// cadence that came with them.
final class MenuBarWidthPolicyTests: XCTestCase {
    private let fs = String(MenuBarPolicy.figureSpace)

    // MARK: Digit reservation

    func testShortNumbersArePaddedInFrontWithFigureSpaces() {
        XCTAssertEqual(MenuBarPolicy.reservingDigits("9°", digits: 2), fs + "9°")
        XCTAssertEqual(MenuBarPolicy.reservingDigits("5%", digits: 3), fs + fs + "5%")
        // Only the integer part counts: 5.5 W needs one pad for two digits.
        XCTAssertEqual(MenuBarPolicy.reservingDigits("5.5 W", digits: 2), fs + "5.5 W")
        // Text before the number stays put; the pad sits right before it.
        XCTAssertEqual(MenuBarPolicy.reservingDigits("↑7 KB/s", digits: 2), "↑" + fs + "7 KB/s")
    }

    func testLongEnoughNumbersAndTextAreUnchanged() {
        XCTAssertEqual(MenuBarPolicy.reservingDigits("10°", digits: 2), "10°")
        XCTAssertEqual(MenuBarPolicy.reservingDigits("100%", digits: 2), "100%")
        XCTAssertEqual(MenuBarPolicy.reservingDigits("—", digits: 2), "—")
        XCTAssertEqual(MenuBarPolicy.reservingDigits("", digits: 2), "")
        // Non-ASCII numerals are not tabular and must not be padded.
        XCTAssertEqual(MenuBarPolicy.reservingDigits("٥%", digits: 2), "٥%")
    }

    func testFitModeLeavesTextAlone() {
        let fit = MenuBarPresentation(width: .fit)
        XCTAssertEqual(MenuBarPolicy.reservedValue("9°", presentation: fit), "9°")
        let auto = MenuBarPresentation()
        XCTAssertEqual(MenuBarPolicy.reservedValue("9°", presentation: auto), fs + "9°")
        let three = MenuBarPresentation(digits: 3)
        XCTAssertEqual(MenuBarPolicy.reservedValue("9°", presentation: three), fs + fs + "9°")
    }

    func testPresentationPadsTextLabelsAndSingleMetrics() {
        let text = MenuBarEntry(widgetID: "w", name: "W", label: "7°")
        XCTAssertEqual(
            MenuBarPolicy.applyingPresentation(MenuBarPresentation(), to: text).label, fs + "7°"
        )
        let metric = MenuBarEntry(
            widgetID: "w", name: "W",
            metrics: [StatusMetric(label: "CPU", value: "8%")]
        )
        let applied = MenuBarPolicy.applyingPresentation(MenuBarPresentation(), to: metric)
        XCTAssertEqual(applied.metrics.first?.value, fs + "8%")
        XCTAssertEqual(applied.label, fs + "8%")
    }

    func testTheMinusSignStaysAgainstItsDigits() {
        XCTAssertEqual(MenuBarPolicy.reservingDigits("-5°", digits: 2), fs + "-5°")
        XCTAssertEqual(MenuBarPolicy.reservingDigits("\u{2212}5°", digits: 2), fs + "\u{2212}5°")
    }

    /// Unchecking Label means the value alone — not the metric's own label
    /// creeping back in, and not the widget's name.
    func testANoLabelChoiceShowsTheValueAlone() {
        let inline = MenuBarEntry(
            widgetID: "w", name: "System", prefix: "", style: .inline,
            metrics: [StatusMetric(id: "cpu", label: "CPU", value: "23%")]
        )
        XCTAssertEqual(MenuBarPolicy.entryText(inline), "23%")
        var unset = inline
        unset.prefix = nil
        XCTAssertEqual(MenuBarPolicy.entryText(unset), "CPU 23%", "unset still falls back to the metric's label")
    }

    func testFixedWidthHasOneDefault() {
        XCTAssertEqual(MenuBarPresentation(width: .fixed).effectiveFixedWidth, MenuBarPresentation.defaultFixedWidth)
        XCTAssertEqual(MenuBarPresentation(valueWidth: 70, width: .fixed).effectiveFixedWidth, 70)
    }

    /// A template can produce nan, inf or 1e300 for `digits`; converting any
    /// of them to Int traps, so they must read as unset instead.
    func testWildTemplatedDigitsDoNotCrash() throws {
        for raw in ["nan", "inf", "1e300", "-3", "9"] {
            let def = try WorkflowDefinition.decode(from: Data("""
            {"schemaVersion":1,"sources":{},
             "status":{"label":"x","presentation":{"digits":"${settings.d}"}},
             "view":{"type":"text","text":"x"}}
            """.utf8))
            let output = try WorkflowEngine.evaluate(
                def, sources: [:], settings: .object(["d": .string(raw)])
            )
            XCTAssertNil(output.statusPresentation?.digits, raw)
        }
    }

    // MARK: Decoding and resolution

    func testNewFieldsDecodeLenientlyAndResolveUserFirst() throws {
        let json = #"{"width":"sideways","digits":9,"alignment":"center","weight":"bold","size":"large","showUnits":false}"#
        let decoded = try JSONDecoder().decode(MenuBarPresentation.self, from: Data(json.utf8))
        XCTAssertNil(decoded.width, "an unknown mode reads as unset, not as a decode failure")
        XCTAssertNil(decoded.digits, "digits outside 1–6 are dropped")
        XCTAssertEqual(decoded.alignment, .center)
        XCTAssertEqual(decoded.weight, .bold)
        XCTAssertEqual(decoded.size, .large)
        XCTAssertEqual(decoded.showUnits, false, "the other fields survive a bad one")

        let resolved = MenuBarPolicy.resolvedPresentation(
            user: MenuBarPresentation(width: .fixed),
            live: MenuBarPresentation(width: .fit, digits: 3),
            manifest: MenuBarPresentation(alignment: .trailing)
        )
        XCTAssertEqual(resolved.width, .fixed)
        XCTAssertEqual(resolved.digits, 3)
        XCTAssertEqual(resolved.alignment, .trailing)
        XCTAssertEqual(MenuBarPresentation().effectiveAlignment, .leading, "the look items always had")
    }

    func testPresentationRoundTrips() throws {
        let original = MenuBarPresentation(
            valueWidth: 64, width: .fixed, digits: 3, alignment: .trailing, weight: .medium, size: .small
        )
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(MenuBarPresentation.self, from: data), original)
    }

    // MARK: Row keys

    func testMetricKeysAreAlwaysUnique() {
        let keys = MenuBarPolicy.metricKeys([
            StatusMetric(id: "a", label: "", value: ""),
            StatusMetric(id: "a", label: "", value: ""),
            StatusMetric(id: "row:3", label: "", value: ""),
            StatusMetric(label: "", value: ""),  // would be row:3 too
        ])
        XCTAssertEqual(keys, ["a", "a#2", "row:3", "row:3#2"])
        XCTAssertEqual(Set(keys).count, keys.count)
    }

    func testOrderRanksKeepTheFirstPositionOfARepeat() {
        XCTAssertEqual(MenuBarPolicy.orderRanks(["b", "a", "b"]), ["b": 0, "a": 1])
    }

    // MARK: Cadence

    func testPlacementIntervalIsClampedAndDecodedLeniently() throws {
        XCTAssertEqual(MenuBarPlacement(enabled: true, interval: 0.2).interval, 1)
        XCTAssertEqual(MenuBarPlacement(enabled: true, interval: 99999).interval, 3600)
        XCTAssertNil(MenuBarPlacement(enabled: true, interval: -5).interval)
        let decoded = try JSONDecoder().decode(
            MenuBarPlacement.self, from: Data(#"{"enabled":true,"interval":"fast"}"#.utf8)
        )
        XCTAssertNil(decoded.interval, "a bad interval does not cost the placement")
        XCTAssertTrue(decoded.enabled)
    }
}
