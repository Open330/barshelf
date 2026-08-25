import AppKit
import MenubucketCore
import XCTest
@testable import MenubucketApp

@MainActor
final class StatusItemAccessibilityTests: XCTestCase {
    func testDefaultLogoNamesStatusBarButton() {
        let button = makeStatusBarButton()
        BarShelfStatusIcon.configure(
            button,
            symbol: AppPreferences.defaultMenuBarSymbol,
            fallback: "tray.full"
        )

        XCTAssertEqual(button.accessibilityLabel(), "BarShelf")
        XCTAssertEqual(button.imagePosition, .imageOnly)
        XCTAssertNotNil(button.image)
    }

    func testSFSymbolNamesStatusBarButton() {
        let button = makeStatusBarButton()
        BarShelfStatusIcon.configure(
            button,
            symbol: "tray.full",
            fallback: BarShelfStatusIcon.logoSymbol
        )

        XCTAssertEqual(button.accessibilityLabel(), "BarShelf")
        XCTAssertEqual(button.imagePosition, .imageOnly)
        XCTAssertNotNil(button.image)
    }

    /// `NSStatusBar.system.statusItem` requires a live WindowServer session and
    /// aborts headless GitHub runners inside CoreGraphics. Constructing the
    /// concrete button directly still exercises the production API and its
    /// accessibility attributes without registering a global menu-bar item.
    private func makeStatusBarButton() -> NSStatusBarButton {
        NSStatusBarButton(frame: NSRect(x: 0, y: 0, width: 28, height: 22))
    }
}
