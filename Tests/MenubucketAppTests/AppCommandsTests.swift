import AppKit
import XCTest
@testable import MenubucketApp

/// The app's shortcuts are real menu items, wired at launch.
final class AppCommandsTests: XCTestCase {
    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// The hidden zero-opacity buttons that used to carry ⌘, and ⌘F only
    /// worked while their view was on screen and were invisible to VoiceOver
    /// and to the menu bar; the commands now live in the main menu.
    func testNoViewCarriesAShortcutOnAnInvisibleButton() throws {
        for path in [
            "Sources/MenubucketApp/Hub/HubView.swift",
            "Sources/MenubucketApp/Popover/RootView.swift",
            "Sources/MenubucketApp/Popover/SearchOverlay.swift",
        ] {
            let text = try source(path)
            XCTAssertFalse(text.contains("Button(\"\")"), "\(path) still has an unlabeled shortcut button")
        }
    }

    func testLaunchInstallsTheCommandsIntoTheMainMenu() throws {
        let main = try source("Sources/MenubucketApp/main.swift")
        XCTAssertTrue(main.contains("installCommands(in:"))
    }

    /// AppKit treats the first item as the application menu while the hub
    /// makes BarShelf a regular app, so the app menu must come first and
    /// every command must carry its documented shortcut.
    func testTheApplicationMenuComesFirstWithTheDocumentedShortcuts() throws {
        let commands = try source("Sources/MenubucketApp/AppCommands.swift")
        XCTAssertTrue(commands.contains("mainMenu.insertItem(appItem, at: 0)"))
        for (title, key) in [
            ("Settings…", ","), ("Quit BarShelf", "q"), ("Refresh All", "r"),
            ("Create Widget…", "n"), ("Find…", "f"), ("Edit Shelf", "e"),
        ] {
            XCTAssertTrue(
                commands.contains("command(\"\(title)\", ") && commands.contains("\"\(key)\")"),
                "\(title) should be bound to ⌘\(key.uppercased())"
            )
        }
    }

    /// The status item's right-click menu and the popup's ⋯ menu are one
    /// list: both are built from `AppMenu.sections`.
    func testBothAppMenusAreBuiltFromOneDefinition() throws {
        let commands = try source("Sources/MenubucketApp/AppCommands.swift")
        let more = try source("Sources/MenubucketApp/Popover/ShelfMenus.swift")
        let controller = try source("Sources/MenubucketApp/StatusItemController.swift")
        XCTAssertTrue(commands.contains("for (index, section) in AppMenu.sections.enumerated()"))
        XCTAssertTrue(more.contains("AppMenu.sections.enumerated()"))
        XCTAssertTrue(controller.contains("NSMenu.popUpContextMenu(makeAppMenu()"))
        XCTAssertFalse(controller.contains("Install Widget from URL…"), "the status menu is AppMenu only")
    }

    func testTheAppMenuHasTheDocumentedCommandsAndShortcuts() {
        XCTAssertEqual(
            AppMenu.sections,
            [[.editShelf, .addWidget, .menuBar], [.openBarShelf, .checkForUpdates], [.quit]]
        )
        XCTAssertEqual(AppMenuCommand.editShelf.keyEquivalent, "e")
        XCTAssertEqual(AppMenuCommand.openBarShelf.keyEquivalent, ",")
        XCTAssertEqual(AppMenuCommand.quit.keyEquivalent, "q")
        XCTAssertEqual(AppMenuCommand.addWidget.title, "Add Widget…")
    }

    /// Every "add a widget" entry point says the same thing.
    func testAddWidgetEntryPointsShareOneName() throws {
        for path in [
            "Sources/MenubucketApp/Popover/RootView.swift",
            "Sources/MenubucketApp/Popover/WelcomeCardView.swift",
        ] {
            let text = try source(path)
            XCTAssertTrue(text.contains("\"Add Widget…\""), path)
            XCTAssertFalse(text.contains("\"Open Widget Gallery\""), path)
            XCTAssertFalse(text.contains("\"Widget Gallery…\""), path)
        }
    }
}
