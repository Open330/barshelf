import XCTest
@testable import MenubucketApp

final class WidgetPrefsTests: XCTestCase {
    private var fileURL: URL!

    override func setUpWithError() throws {
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("widget-prefs-\(UUID().uuidString)")
            .appendingPathComponent("prefs.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
    }

    func testDisabledAndOverridesRoundTrip() {
        let prefs = WidgetPrefs(fileURL: fileURL)
        prefs.setDisabled("a", true)
        prefs.setOverride(group: "Ops", order: 3, for: "b")
        prefs.setOverride(group: nil, order: 7, for: "c")

        let reloaded = WidgetPrefs(fileURL: fileURL)
        XCTAssertTrue(reloaded.isDisabled("a"))
        XCTAssertFalse(reloaded.isDisabled("b"))
        XCTAssertEqual(reloaded.override(for: "b"), BucketOverride(group: "Ops", order: 3))
        XCTAssertEqual(reloaded.override(for: "c"), BucketOverride(group: nil, order: 7))
    }

    func testDecodesOldPrefsWithoutNewFields() throws {
        let legacy = #"{"pinned":["x"],"settings":{}}"#
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(legacy.utf8).write(to: fileURL)

        let prefs = WidgetPrefs(fileURL: fileURL)
        XCTAssertTrue(prefs.isPinned("x"))
        XCTAssertFalse(prefs.isDisabled("x"))
        XCTAssertNil(prefs.override(for: "x"))
    }

    func testSetOverrideWithBothNilClearsEntry() {
        let prefs = WidgetPrefs(fileURL: fileURL)
        prefs.setOverride(group: "Ops", order: 2, for: "a")
        prefs.setOverride(group: nil, order: nil, for: "a")

        XCTAssertNil(prefs.override(for: "a"))
    }

    func testRemoveAllStateErasesEveryTrace() {
        let prefs = WidgetPrefs(fileURL: fileURL)
        prefs.togglePin("a")
        prefs.setDisabled("a", true)
        prefs.setOverride(group: "Ops", order: 1, for: "a")

        prefs.removeAllState(for: "a")

        XCTAssertFalse(prefs.isPinned("a"))
        XCTAssertFalse(prefs.isDisabled("a"))
        XCTAssertNil(prefs.override(for: "a"))
        // Persisted: a fresh load sees nothing either.
        let reloaded = WidgetPrefs(fileURL: fileURL)
        XCTAssertFalse(reloaded.isPinned("a"))
        XCTAssertFalse(reloaded.isDisabled("a"))
        XCTAssertNil(reloaded.override(for: "a"))
    }
}
