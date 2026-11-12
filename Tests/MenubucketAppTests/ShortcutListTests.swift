import XCTest
@testable import MenubucketApp

/// Settings ▸ Shortcuts is built from the main menu's commands and the
/// keys the popup, the Shelf board and the Dock handle, not typed by hand.
final class ShortcutListTests: XCTestCase {
    private var items: [ShortcutList.Item] { ShortcutList.sections().flatMap(\.items) }

    func testEveryMainMenuKeyIsListed() {
        let listed = Set(items.map(\.keys))
        for command in MainMenuCommand.allCases {
            guard let keys = ShortcutList.keys(for: command) else { continue }
            XCTAssertTrue(listed.contains(keys), "\(command) (\(keys)) is missing from Settings ▸ Shortcuts")
        }
        // ⌘E was missing from the hand-written list.
        XCTAssertTrue(listed.contains("⌘E"))
    }

    func testShelfAndDockKeysAreListed() {
        let listed = Set(items.map(\.keys))
        for keys in ["← → ↑ ↓", "⌥⌘ ← → ↑ ↓", "↩", "⌫", "⌘[", "⌃⌥1 … ⌃⌥9"] {
            XCTAssertTrue(listed.contains(keys), "\(keys) is missing")
        }
    }

    func testDockProfileKeysLeaveWhenTurnedOff() {
        let dock = ShortcutList.sections(dockProfileKeys: false).flatMap(\.items)
        XCTAssertFalse(dock.contains { $0.keys.hasPrefix("⌃⌥") })
        XCTAssertTrue(dock.contains { $0.keys == "⌘[" })
    }

    func testNoKeyIsListedTwice() {
        let keys = items.map(\.keys)
        XCTAssertEqual(keys.count, Set(keys).count)
    }

    func testMainMenuKeysMatchWhatTheMenuInstalls() {
        XCTAssertEqual(ShortcutList.keys(for: .settings), "⌘,")
        XCTAssertEqual(ShortcutList.keys(for: .find), "⌘F")
        XCTAssertNil(ShortcutList.keys(for: .checkForUpdates))
    }
}
