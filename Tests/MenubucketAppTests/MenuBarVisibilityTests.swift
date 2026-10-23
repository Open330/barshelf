import AppKit
import XCTest
@testable import MenubucketApp

final class MenuBarVisibilityTests: XCTestCase {
    private typealias Area = MenuBarVisibility.ScreenArea

    /// A 1512×982 MacBook with a notch: the menu bar either side of a
    /// 200-point notch in the middle (AppKit coordinates, origin bottom left).
    private let notched = Area(
        frame: NSRect(x: 0, y: 0, width: 1512, height: 982),
        leftOfNotch: NSRect(x: 0, y: 950, width: 656, height: 32),
        rightOfNotch: NSRect(x: 856, y: 950, width: 656, height: 32)
    )
    private let external = Area(frame: NSRect(x: 1512, y: 0, width: 2560, height: 1440))

    private func item(x: CGFloat, y: CGFloat = 950, width: CGFloat = 24) -> NSRect {
        NSRect(x: x, y: y, width: width, height: 32)
    }

    func testItemBesideTheNotchIsVisible() {
        XCTAssertTrue(MenuBarVisibility.isVisible(itemFrame: item(x: 1200), screens: [notched]))
        XCTAssertTrue(MenuBarVisibility.isVisible(itemFrame: item(x: 300), screens: [notched]))
    }

    func testItemBehindTheNotchIsHidden() {
        XCTAssertFalse(MenuBarVisibility.isVisible(itemFrame: item(x: 740), screens: [notched]))
    }

    /// What macOS 26 does with items it has no room for on a notched
    /// MacBook: parks them at the notch's right edge, mostly underneath.
    /// Measured on a 1710-point display with the notch at 751–959.
    func testItemParkedAtTheNotchEdgeIsHidden() {
        let macBook = Area(
            frame: NSRect(x: 0, y: 0, width: 1710, height: 1112),
            leftOfNotch: NSRect(x: 0, y: 1074.5, width: 751, height: 37.5),
            rightOfNotch: NSRect(x: 959, y: 1074.5, width: 751, height: 37.5)
        )
        XCTAssertFalse(MenuBarVisibility.isVisible(
            itemFrame: NSRect(x: 927, y: 1074, width: 71, height: 38), screens: [macBook]))
        XCTAssertTrue(MenuBarVisibility.isVisible(
            itemFrame: NSRect(x: 1300, y: 1074, width: 71, height: 38), screens: [macBook]))
    }

    /// Where macOS puts an item it has no room for: off every screen (seen at
    /// y = -26, below a 1440-point display, on macOS 26).
    func testItemOffEveryScreenIsHidden() {
        XCTAssertFalse(MenuBarVisibility.isVisible(itemFrame: item(x: 1838, y: -26), screens: [notched, external]))
        XCTAssertFalse(MenuBarVisibility.isVisible(itemFrame: item(x: -40), screens: [notched]))
    }

    func testItemOnAScreenWithoutANotchIsVisible() {
        XCTAssertTrue(MenuBarVisibility.isVisible(itemFrame: item(x: 3000, y: 1410), screens: [notched, external]))
    }

    func testZeroWidthItemIsHidden() {
        XCTAssertFalse(MenuBarVisibility.isVisible(itemFrame: item(x: 1200, width: 0), screens: [notched]))
    }
}
