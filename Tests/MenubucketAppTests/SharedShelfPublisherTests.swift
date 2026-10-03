import XCTest
@testable import MenubucketApp

final class SharedShelfPublisherTests: XCTestCase {
    /// macOS budgets widget reloads; changes inside 15 minutes wait.
    func testReloadsAreAtLeastFifteenMinutesApart() {
        let now = Date()
        XCTAssertEqual(SharedShelfPublisher.reloadDelay(lastReload: nil, now: now), 0)
        XCTAssertEqual(SharedShelfPublisher.reloadDelay(lastReload: now.addingTimeInterval(-60), now: now), 14 * 60, accuracy: 0.001)
        XCTAssertEqual(SharedShelfPublisher.reloadDelay(lastReload: now.addingTimeInterval(-3600), now: now), 0)
    }

    /// A test or dev build without the App Group writes nothing, so macOS
    /// never asks the user about another app's data.
    func testAnUnentitledBuildPublishesNothing() {
        let publisher = SharedShelfPublisher(container: nil)
        XCTAssertFalse(publisher.isEnabled)
        publisher.publishIndex([.init(id: "a", name: "A")])
        publisher.withdraw(widgetID: "a")
        XCTAssertNil(SharedShelfPublisher.entitledContainer(), "the test runner has no App Group entitlement")
    }

    func testTheBuildSignsTheExtensionBeforeTheAppAndNeverDeep() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let script = try String(contentsOf: root.appendingPathComponent("scripts/build_app.sh"), encoding: .utf8)
        let ext = try XCTUnwrap(script.range(of: #"sign_code "${WIDGET_EXTENSION_PATH}""#))
        let app = try XCTUnwrap(script.range(of: #"sign_code "${APP_BUNDLE_PATH}" "${HOST_ENTITLEMENTS}""#))
        XCTAssertTrue(ext.upperBound < app.lowerBound, "the extension is signed before the app around it")
        let developerIDPath = script[ext.lowerBound..<app.upperBound]
        XCTAssertFalse(developerIDPath.contains("--deep"))
    }
}
