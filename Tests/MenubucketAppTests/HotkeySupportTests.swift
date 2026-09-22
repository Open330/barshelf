import Carbon.HIToolbox
import XCTest
@testable import MenubucketApp

final class HotkeySupportTests: XCTestCase {
    func testParserAcceptsAliasesAndReturnsCanonicalShortcut() throws {
        let result = try XCTUnwrap(HotkeyGrammar.parse(" Command + alt + B ").get())

        XCTAssertEqual(result.canonicalText, "cmd+opt+b")
        XCTAssertEqual(result.modifiers, UInt32(cmdKey | optionKey))
        XCTAssertEqual(result.keyCode, 11)
    }

    func testParserAcceptsMacModifierGlyphs() throws {
        let result = try XCTUnwrap(HotkeyGrammar.parse("⌘+⇧+b").get())

        XCTAssertEqual(result.canonicalText, "cmd+shift+b")
        XCTAssertEqual(result.modifiers, UInt32(cmdKey | shiftKey))
    }

    func testParserRejectsAmbiguousOrIncompleteGrammar() {
        assertError("cmd+b+c", .multipleKeys)
        assertError("cmd+cmd+b", .duplicateModifier("cmd"))
        assertError("b", .missingModifier)
        assertError("cmd+", .missingKey)
        assertError("cmd+up", .unsupportedKey("up"))
    }

    func testFailedRegistrationKeepsWorkingPreference() {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("hotkey-test-\(UUID().uuidString).json")
        let prefs = AppPrefs(fileURL: fileURL)
        prefs.update {
            $0.popupHotkeyEnabled = true
            $0.popupHotkey = "ctrl+opt+m"
        }
        let coordinator = HotkeyRegistrationCoordinator()
        coordinator.register = { _ in false }
        coordinator.enable(draft: "cmd+shift+b", appPrefs: prefs)

        XCTAssertTrue(prefs.preferences.popupHotkeyEnabled)
        XCTAssertEqual(prefs.preferences.popupHotkey, "ctrl+opt+m")
        XCTAssertNotNil(coordinator.message)
        try? FileManager.default.removeItem(at: fileURL)
    }

    func testSuccessfulRegistrationCommitsCanonicalShortcut() {
        let candidate = try! HotkeyGrammar.parse("command + option + b").get()
        let result = HotkeyPreferencePolicy.committed(
            current: (false, "cmd+shift+b"), candidate: candidate,
            registrationSucceeded: true
        )

        XCTAssertTrue(result.enabled)
        XCTAssertEqual(result.shortcut, "cmd+opt+b")
    }

    func testCoordinatorTracksOnlySuccessfullyRegisteredShortcut() {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("hotkey-state-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let prefs = AppPrefs(fileURL: fileURL)
        prefs.update {
            $0.popupHotkeyEnabled = true
            $0.popupHotkey = "ctrl+opt+m"
        }
        let coordinator = HotkeyRegistrationCoordinator()
        var registered: [String] = []
        coordinator.register = {
            registered.append($0.canonicalText)
            return true
        }

        coordinator.enable(draft: "⌘+shift+b", appPrefs: prefs)

        XCTAssertEqual(registered, ["cmd+shift+b"])
        XCTAssertTrue(coordinator.isRegistered)
        XCTAssertTrue(prefs.preferences.popupHotkeyEnabled)
        coordinator.disable(appPrefs: prefs)
        XCTAssertFalse(coordinator.isRegistered)
        XCTAssertFalse(prefs.preferences.popupHotkeyEnabled)
    }

    func testFailedReplacementKeepsRegisteredState() {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("hotkey-replacement-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let prefs = AppPrefs(fileURL: fileURL)
        prefs.update {
            $0.popupHotkeyEnabled = true
            $0.popupHotkey = "ctrl+opt+m"
        }
        let coordinator = HotkeyRegistrationCoordinator()
        coordinator.registrationDidChange(isRegistered: true)
        coordinator.register = { _ in false }

        coordinator.enable(draft: "cmd+shift+b", appPrefs: prefs)

        XCTAssertTrue(coordinator.isRegistered)
        XCTAssertTrue(prefs.preferences.popupHotkeyEnabled)
        XCTAssertEqual(prefs.preferences.popupHotkey, "ctrl+opt+m")
        XCTAssertNotNil(coordinator.message)
    }

    private func assertError(_ input: String, _ expected: HotkeyGrammar.Error) {
        guard case .failure(let error) = HotkeyGrammar.parse(input) else {
            return XCTFail("Expected \(expected) for \(input)")
        }
        XCTAssertEqual(error, expected)
    }
}
