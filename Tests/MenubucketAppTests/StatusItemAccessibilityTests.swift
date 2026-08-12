import AppKit
import MenubucketCore
import XCTest
@testable import MenubucketApp

@MainActor
final class StatusItemAccessibilityTests: XCTestCase {
    func testDefaultLogoNamesStatusBarButton() throws {
        try withStatusBarButton { button in
            BarShelfStatusIcon.configure(
                button,
                symbol: AppPreferences.defaultMenuBarSymbol,
                fallback: "tray.full"
            )

            XCTAssertEqual(button.accessibilityLabel(), "BarShelf")
            XCTAssertEqual(button.imagePosition, .imageOnly)
            XCTAssertNotNil(button.image)
        }
    }

    func testSFSymbolNamesStatusBarButton() throws {
        try withStatusBarButton { button in
            BarShelfStatusIcon.configure(
                button,
                symbol: "tray.full",
                fallback: BarShelfStatusIcon.logoSymbol
            )

            XCTAssertEqual(button.accessibilityLabel(), "BarShelf")
            XCTAssertEqual(button.imagePosition, .imageOnly)
            XCTAssertNotNil(button.image)
        }
    }

    private func withStatusBarButton(
        _ assertions: (NSStatusBarButton) throws -> Void
    ) throws {
        let statusItem = NSStatusBar.system.statusItem(withLength: 28)
        defer { NSStatusBar.system.removeStatusItem(statusItem) }

        let button = try XCTUnwrap(statusItem.button)
        try assertions(button)
    }
}
