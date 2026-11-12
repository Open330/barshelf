import XCTest
@testable import MenubucketApp

/// A countdown ring's short label ("12m", not "720") and number settings
/// shown without float noise.
final class RendererLabelTests: XCTestCase {
    func testShortDurationRoundsUpAndStaysShort() {
        XCTAssertEqual(CountdownLabel.shortDuration(0), "0s")
        XCTAssertEqual(CountdownLabel.shortDuration(44.2), "45s")
        XCTAssertEqual(CountdownLabel.shortDuration(60), "1m")
        XCTAssertEqual(CountdownLabel.shortDuration(2972), "50m")
        XCTAssertEqual(CountdownLabel.shortDuration(3600), "1h")
        XCTAssertEqual(CountdownLabel.shortDuration(3900), "1h5m")
        XCTAssertEqual(CountdownLabel.shortDuration(-5), "0s")
    }

    func testNumberSettingText() {
        XCTAssertEqual(WidgetSettingsView.numberText(37), "37")
        XCTAssertEqual(WidgetSettingsView.numberText(37.5665), "37.5665")
        XCTAssertEqual(WidgetSettingsView.numberText(126.97802), "126.97802")
        XCTAssertEqual(WidgetSettingsView.numberText(-0.5), "-0.5")
    }
}
