import XCTest
@testable import MenubucketApp
import MenubucketCore

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
        XCTAssertNil(prefs.appearanceOverride(for: "x"))
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
        prefs.setAppearanceOverride(WidgetAppearance(accent: "red"), for: "a")

        prefs.removeAllState(for: "a")

        XCTAssertFalse(prefs.isPinned("a"))
        XCTAssertFalse(prefs.isDisabled("a"))
        XCTAssertNil(prefs.override(for: "a"))
        XCTAssertNil(prefs.appearanceOverride(for: "a"))
        // Persisted: a fresh load sees nothing either.
        let reloaded = WidgetPrefs(fileURL: fileURL)
        XCTAssertFalse(reloaded.isPinned("a"))
        XCTAssertFalse(reloaded.isDisabled("a"))
        XCTAssertNil(reloaded.override(for: "a"))
        XCTAssertNil(reloaded.appearanceOverride(for: "a"))
    }

    // MARK: - Appearance overrides (R12)

    func testAppearanceOverrideRoundTrip() {
        let prefs = WidgetPrefs(fileURL: fileURL)
        let appearance = WidgetAppearance(
            accent: "purple", density: .compact, cardStyle: .tinted, showHeader: false
        )
        prefs.setAppearanceOverride(appearance, for: "a")

        let reloaded = WidgetPrefs(fileURL: fileURL)
        XCTAssertEqual(reloaded.appearanceOverride(for: "a"), appearance)
    }

    func testSetAppearanceOverrideNilClearsEntry() {
        let prefs = WidgetPrefs(fileURL: fileURL)
        prefs.setAppearanceOverride(WidgetAppearance(accent: "red"), for: "a")
        prefs.setAppearanceOverride(nil, for: "a")
        XCTAssertNil(prefs.appearanceOverride(for: "a"))
    }

    func testSetNeutralAppearanceClearsEntry() {
        let prefs = WidgetPrefs(fileURL: fileURL)
        prefs.setAppearanceOverride(WidgetAppearance(accent: "red"), for: "a")
        prefs.setAppearanceOverride(WidgetAppearance(), for: "a")
        XCTAssertNil(prefs.appearanceOverride(for: "a"))
    }

    func testEffectiveAppearanceMergesOverrideOverAuthorOverNeutral() {
        let manifest = Manifest(
            schemaVersion: 1, id: "w", name: "W", entry: .init(kind: "exec"),
            appearance: WidgetAppearance(accent: "blue", density: .regular)
        )
        let prefs = WidgetPrefs(fileURL: fileURL)

        // No override → author default.
        var effective = prefs.effectiveAppearance(for: manifest)
        XCTAssertEqual(effective.accent, "blue")
        XCTAssertEqual(effective.density, .regular)
        XCTAssertNil(effective.cardStyle)

        // Override wins field-wise; author fields fill the gaps.
        prefs.setAppearanceOverride(
            WidgetAppearance(accent: "red", cardStyle: .tinted), for: "w"
        )
        effective = prefs.effectiveAppearance(for: manifest)
        XCTAssertEqual(effective.accent, "red")       // override
        XCTAssertEqual(effective.density, .regular)    // author
        XCTAssertEqual(effective.cardStyle, .tinted)   // override
    }

    func testDecodesPrefsWithAppearanceOverrides() throws {
        let json = #"""
        {"pinned":[],"settings":{},"appearanceOverrides":{"a":{"accent":"green","density":"compact"}}}
        """#
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(json.utf8).write(to: fileURL)

        let prefs = WidgetPrefs(fileURL: fileURL)
        XCTAssertEqual(
            prefs.appearanceOverride(for: "a"),
            WidgetAppearance(accent: "green", density: .compact)
        )
    }
}
