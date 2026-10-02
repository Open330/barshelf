import XCTest
import MenubucketCore
@testable import MenubucketApp

final class HubSettingsTests: XCTestCase {
    /// Every page appears in the sidebar exactly once, workspace first.
    func testEveryHubPageIsInExactlyOneSidebarGroup() {
        let listed = HubTab.workspace + HubTab.settingsPages
        XCTAssertEqual(Set(listed), Set(HubTab.allCases))
        XCTAssertEqual(listed.count, HubTab.allCases.count)
        XCTAssertEqual(HubTab.workspace.first, .shelf)
    }

    /// Deep links and older call sites keep working after the rename.
    func testFormerTabNamesStillResolve() {
        XCTAssertEqual(HubTab.widgets, .shelf)
        XCTAssertEqual(HubTab(rawValue: "widgets"), .shelf)
        XCTAssertEqual(HubTab.settings, .general)
    }

    func testUpdatePreferencesDefaultToCheckingAndSkipNothing() throws {
        let decoded = try JSONDecoder().decode(AppPreferences.self, from: Data("{}".utf8))
        XCTAssertTrue(decoded.checkForUpdatesAutomatically)
        XCTAssertNil(decoded.skippedUpdateVersion)

        var prefs = AppPreferences()
        prefs.skippedUpdateVersion = "  "
        prefs.normalize()
        XCTAssertNil(prefs.skippedUpdateVersion, "a blank skip must not hide every update")
    }

    /// The popup opens at its long-standing size unless the user asks for more.
    func testPopupHeightDefaultsToStandard() throws {
        let decoded = try JSONDecoder().decode(AppPreferences.self, from: Data("{}".utf8))
        XCTAssertEqual(decoded.popupHeight, .standard)
        XCTAssertEqual(AppPreferences.PopupHeight.standard.points, 480)
        let unknown = try JSONDecoder().decode(AppPreferences.self, from: Data(#"{"popupHeight":"huge"}"#.utf8))
        XCTAssertEqual(unknown.popupHeight, .standard)
    }

    func testUpdatePreferencesRoundTrip() throws {
        let prefs = AppPreferences(checkForUpdatesAutomatically: false, skippedUpdateVersion: "0.5.0")
        let data = try JSONEncoder().encode(prefs)
        XCTAssertEqual(try JSONDecoder().decode(AppPreferences.self, from: data), prefs)
    }

    func testRecordedShortcutsReadLikeTheMenuBar() {
        XCTAssertEqual(HotkeyGrammar.displayText("cmd+shift+b"), "⇧⌘B")
        XCTAssertEqual(HotkeyGrammar.displayText("ctrl+opt+space"), "⌃⌥Space")
        XCTAssertEqual(HotkeyGrammar.keyName(for: 11), "b")
        XCTAssertNil(HotkeyGrammar.keyName(for: 999))
    }

    /// The recorder builds text the parser accepts for every key it knows.
    func testEveryRecordableKeyParses() {
        for code in UInt32(0)...UInt32(127) {
            guard let name = HotkeyGrammar.keyName(for: code) else { continue }
            guard case .success = HotkeyGrammar.parse("cmd+\(name)") else {
                return XCTFail("cmd+\(name) does not parse")
            }
        }
    }

    func testPermissionsReadAsPlainSentences() {
        let manifest = Manifest(
            schemaVersion: 1,
            id: "dev.test.summary",
            name: "Summary",
            entry: .init(kind: "exec"),
            permissions: .init(
                exec: [
                    .init(command: "/opt/homebrew/bin/gh"),
                    .init(command: "/usr/local/bin/gh"),
                    .init(command: "/bin/date"),
                ],
                network: ["api.github.com"],
                keychain: true
            )
        )
        let lines = WidgetPermissionSummary.lines(for: manifest).map(\.text)
        XCTAssertEqual(lines, [
            "Run gh and date",
            "Connect to api.github.com",
            "Read its own secrets from the Keychain",
        ])
    }

    func testAWidgetWithoutPermissionsHasNothingToApprove() {
        let manifest = Manifest(
            schemaVersion: 1, id: "dev.test.none", name: "None", entry: .init(kind: "workflow")
        )
        XCTAssertTrue(WidgetPermissionSummary.lines(for: manifest).isEmpty)
    }
}
