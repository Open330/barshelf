import XCTest
@testable import MenubucketApp
@testable import MenubucketCore

final class AppPrefsTests: XCTestCase {
    private var fileURL: URL!

    override func setUp() {
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("app-prefs-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// An edit cannot leave the app without a status item symbol or with an
    /// off-step multiplier, whichever field it touched.
    func testUpdateAppliesTheSameRulesAsLoading() {
        let prefs = AppPrefs(fileURL: fileURL)
        prefs.update {
            $0.menuBarSymbol = "  "
            $0.refreshMultiplier = 3.3
            $0.popupHotkey = " "
        }
        XCTAssertEqual(prefs.preferences.menuBarSymbol, AppPreferences.defaultMenuBarSymbol)
        XCTAssertEqual(
            prefs.preferences.refreshMultiplier,
            SchedulePolicy.normalizedRefreshMultiplier(3.3)
        )
        XCTAssertEqual(prefs.preferences.popupHotkey, AppPreferences.defaultPopupHotkey)
    }

    /// Changing one preference keeps every other one, and what is saved is
    /// what is read back.
    func testUpdateKeepsUntouchedFieldsAndPersists() {
        let prefs = AppPrefs(fileURL: fileURL)
        prefs.update {
            $0.copySoundEnabled = true
            $0.pauseWhenClosed = true
        }
        prefs.update { $0.menuBarSymbol = "gauge" }

        XCTAssertTrue(prefs.preferences.copySoundEnabled)
        XCTAssertTrue(prefs.preferences.pauseWhenClosed)
        XCTAssertEqual(AppPrefs(fileURL: fileURL).preferences, prefs.preferences)
    }
}
