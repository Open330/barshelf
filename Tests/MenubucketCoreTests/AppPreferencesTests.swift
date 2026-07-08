import XCTest
@testable import MenubucketCore

final class AppPreferencesTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("app-prefs-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testRoundTripPersistsPreferences() throws {
        let fileURL = tempDir.appendingPathComponent("app-prefs.json")
        let prefs = AppPreferences(
            menuBarSymbol: "gauge",
            refreshMultiplier: 2,
            pauseWhenClosed: true,
            launchAtLogin: true
        )

        try prefs.save(to: fileURL)
        let loaded = AppPreferences.load(from: fileURL)

        XCTAssertEqual(loaded, prefs)
    }

    func testLenientDecodeDefaultsAndNormalizes() throws {
        let json = """
        {
          "menuBarSymbol": "   ",
          "refreshMultiplier": -10
        }
        """

        let decoded = try JSONDecoder().decode(AppPreferences.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.menuBarSymbol, AppPreferences.defaultMenuBarSymbol)
        XCTAssertEqual(decoded.refreshMultiplier, 1)
        XCTAssertFalse(decoded.pauseWhenClosed)
        XCTAssertFalse(decoded.launchAtLogin)
    }

    func testInitializerNormalizesMultiplierAndSymbol() {
        let prefs = AppPreferences(menuBarSymbol: "  ", refreshMultiplier: 3.1)

        XCTAssertEqual(prefs.menuBarSymbol, AppPreferences.defaultMenuBarSymbol)
        XCTAssertEqual(prefs.refreshMultiplier, 4)
    }
}
