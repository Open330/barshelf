import AppKit
@testable import MenubucketApp
import MenubucketCore
import XCTest

/// The decisions `MenuBarClusterController` makes itself. The controller
/// needs a live `NSStatusItem` (a WindowServer session), so these go through
/// the pure functions its entry points call.
@MainActor
final class MenuBarClusterControllerTests: XCTestCase {
    private func chip(_ id: String, widget: String? = nil) -> ClusterChip {
        ClusterChip(id: id, widgetID: widget ?? id, name: id, initial: "x")
    }

    /// cpu, then a widget with two profiles, then battery.
    private var chips: [ClusterChip] {
        [chip("cpu"), chip("mail#work", widget: "mail"), chip("mail#home", widget: "mail"), chip("battery")]
    }

    private let now = Date(timeIntervalSinceReferenceDate: 1_000)

    // MARK: - Click

    func testAClickOnAChipOpensItsWidget() {
        XCTAssertEqual(MenuBarClusterController.chipClick(on: "cpu", closing: nil, shownCard: nil, now: now), .open)
    }

    func testAClickOnTheOpenCardsChipClosesIt() {
        XCTAssertEqual(MenuBarClusterController.chipClick(on: "cpu", closing: nil, shownCard: "cpu", now: now), .closeCard)
        // Another widget's card being open does not close anything here.
        XCTAssertEqual(MenuBarClusterController.chipClick(on: "cpu", closing: nil, shownCard: "mail", now: now), .open)
    }

    func testTheClickWhoseMouseDownClosedTheCardDoesNotOpenItAgain() {
        let closing = (widgetID: "cpu", at: now.addingTimeInterval(-0.1))
        XCTAssertEqual(MenuBarClusterController.chipClick(on: "cpu", closing: closing, shownCard: nil, now: now), .swallow)
    }

    func testAClosingClickOnlyCoversItsOwnWidgetAndItsOwnMoment() {
        // The mouse-down closed cpu's card, the mouse-up is on mail: open mail.
        let other = (widgetID: "cpu", at: now.addingTimeInterval(-0.1))
        XCTAssertEqual(MenuBarClusterController.chipClick(on: "mail", closing: other, shownCard: nil, now: now), .open)
        // A later click on the same chip is a new click.
        let window = MenuBarClusterController.closingClickWindow
        let old = (widgetID: "cpu", at: now.addingTimeInterval(-window))
        XCTAssertEqual(MenuBarClusterController.chipClick(on: "cpu", closing: old, shownCard: nil, now: now), .open)
        let recent = (widgetID: "cpu", at: now.addingTimeInterval(-window + 0.01))
        XCTAssertEqual(MenuBarClusterController.chipClick(on: "cpu", closing: recent, shownCard: nil, now: now), .swallow)
    }

    // MARK: - Which chip the card hangs off

    func testTheCardHangsOffThePressedChipOfAWidgetWithSeveral() {
        XCTAssertEqual(MenuBarClusterController.cardIndex(for: "mail", pressed: 2, in: chips), 2)
        XCTAssertEqual(MenuBarClusterController.cardIndex(for: "mail", pressed: nil, in: chips), 1)
    }

    func testAPressOnAnotherWidgetsChipOrAChipThatIsGoneFallsBackToTheWidgetsFirst() {
        XCTAssertEqual(MenuBarClusterController.cardIndex(for: "mail", pressed: 0, in: chips), 1)
        XCTAssertEqual(MenuBarClusterController.cardIndex(for: "battery", pressed: 9, in: chips), 3)
        XCTAssertEqual(MenuBarClusterController.cardIndex(for: "battery", pressed: -1, in: chips), 3)
    }

    func testAWidgetWithNoChipHasNoCard() {
        XCTAssertNil(MenuBarClusterController.cardIndex(for: "disk", pressed: 0, in: chips))
        XCTAssertNil(MenuBarClusterController.cardIndex(for: "cpu", pressed: nil, in: []))
    }

    // MARK: - Chips come and go under an open card

    func testTheCardClosesWhenItsWidgetsLastChipGoes() {
        let ids = chips.map(\.id)
        XCTAssertEqual(MenuBarClusterController.cardFate(card: "battery", previous: ids, chips: Array(chips.dropLast())), .close)
        XCTAssertEqual(MenuBarClusterController.cardFate(card: "battery", previous: ids, chips: []), .close)
        // One of two profiles going leaves the widget's card open.
        var oneProfile = chips
        oneProfile.remove(at: 1)
        XCTAssertEqual(MenuBarClusterController.cardFate(card: "mail", previous: ids, chips: oneProfile), .move(to: 1))
    }

    func testTheCardFollowsItsWidgetWhenChipsComeOrGoBeforeIt() {
        let ids = chips.map(\.id)
        XCTAssertEqual(
            MenuBarClusterController.cardFate(card: "battery", previous: ids, chips: Array(chips.dropFirst())),
            .move(to: 2)
        )
        XCTAssertEqual(
            MenuBarClusterController.cardFate(card: "cpu", previous: ids, chips: [chip("disk")] + chips),
            .move(to: 1)
        )
    }

    func testANewReadingOnTheSameChipsLeavesTheCardWhereItIs() {
        var updated = chips
        updated[3].reading = "81%"
        XCTAssertEqual(MenuBarClusterController.cardFate(card: "battery", previous: chips.map(\.id), chips: updated), .stay)
    }

    func testWithNoCardOpenThereIsNothingToCloseOrMove() {
        XCTAssertEqual(MenuBarClusterController.cardFate(card: nil, previous: chips.map(\.id), chips: []), .stay)
    }

    // MARK: - Arrow keys with a card open

    func testLeftAndRightMoveTheCardToTheNeighbouringChip() {
        XCTAssertEqual(MenuBarClusterController.arrowKey(123, active: 1, count: 4), .move(to: 0))
        XCTAssertEqual(MenuBarClusterController.arrowKey(124, active: 1, count: 4), .move(to: 2))
        XCTAssertEqual(MenuBarClusterController.arrowKey(124, active: 2, count: 4), .move(to: 3))
    }

    func testTheCardStopsAtTheEndsInsteadOfWrapping() {
        XCTAssertEqual(MenuBarClusterController.arrowKey(123, active: 0, count: 4), .edge)
        XCTAssertEqual(MenuBarClusterController.arrowKey(124, active: 3, count: 4), .edge)
        XCTAssertEqual(MenuBarClusterController.arrowKey(124, active: 0, count: 1), .edge)
    }

    func testOtherKeysGoToTheCard() {
        // Down, up, return, escape.
        for key in [125, 126, 36, 53] {
            XCTAssertEqual(MenuBarClusterController.arrowKey(key, active: 1, count: 4), .other)
        }
    }

    // MARK: - The item on another display's menu bar

    func testTheItemKeepsItsDistanceFromTheRightEndOnAnotherDisplay() {
        // Home: 1512 wide at the origin; the item starts 300 from its right end.
        let home = NSRect(x: 0, y: 0, width: 1512, height: 982)
        let standIn = NSRect(x: 1212, y: 958, width: 80, height: 24)
        // A wider display to the left and higher up, with a 30pt menu bar.
        let other = NSRect(x: -2560, y: 200, width: 2560, height: 1440)
        let frame = MenuBarClusterController.itemFrame(
            standIn: standIn, home: home, screen: other, visibleMaxY: other.maxY - 30, thickness: 24
        )
        XCTAssertEqual(frame, NSRect(x: -300, y: 1610, width: 80, height: 30))
    }

    func testOnItsOwnDisplayTheItemIsWhereTheStandInIs() {
        let home = NSRect(x: 0, y: 0, width: 1512, height: 982)
        let standIn = NSRect(x: 1212, y: 958, width: 80, height: 24)
        let frame = MenuBarClusterController.itemFrame(
            standIn: standIn, home: home, screen: home, visibleMaxY: 958, thickness: 24
        )
        XCTAssertEqual(frame, standIn)
    }

    func testAHiddenMenuBarStillHasTheStatusBarsHeight() {
        let home = NSRect(x: 0, y: 0, width: 1512, height: 982)
        let standIn = NSRect(x: 1212, y: 958, width: 80, height: 24)
        // Auto-hidden: the visible frame reaches the top of the screen.
        let frame = MenuBarClusterController.itemFrame(
            standIn: standIn, home: home, screen: home, visibleMaxY: home.maxY, thickness: 24
        )
        XCTAssertEqual(frame.height, 24)
        XCTAssertEqual(frame.maxY, home.maxY)
    }

    // MARK: - Where pointer moves are looked at

    func testTheBandCoversTheMenuBarAndEverythingTheHoverMarginReaches() {
        let screen = NSRect(x: -2560, y: 200, width: 2560, height: 1440)
        let band = MenuBarClusterController.menuBarBand(screen: screen, visibleMaxY: screen.maxY - 44, thickness: 24)
        XCTAssertEqual(band.minX, screen.minX)
        XCTAssertEqual(band.width, screen.width)
        // The item on this bar, and the lowest point still in its margin.
        let item = NSRect(x: -400, y: screen.maxY - 44, width: 80, height: 44)
        let lowest = NSPoint(x: item.midX, y: item.minY - ClusterHoverPolicy.slackBelow)
        XCTAssertEqual(ClusterHoverPolicy.zone(of: lowest, item: item), .margin)
        XCTAssertTrue(band.contains(lowest))
        // The top edge of the screen, where a pointer pushed up rests.
        XCTAssertTrue(band.contains(NSPoint(x: item.midX, y: screen.maxY)))
        // Not the rest of the screen, nor the next display.
        XCTAssertFalse(band.contains(NSPoint(x: item.midX, y: screen.maxY - 100)))
        XCTAssertFalse(band.contains(NSPoint(x: 10, y: screen.maxY - 5)))
    }

    func testAHiddenMenuBarsBandIsAsTallAsANotchedOne() {
        let screen = NSRect(x: 0, y: 0, width: 1512, height: 982)
        let hidden = MenuBarClusterController.menuBarBand(screen: screen, visibleMaxY: screen.maxY, thickness: 24)
        XCTAssertEqual(hidden.minY, screen.maxY - (40 + ClusterHoverPolicy.slackBelow + 2))
        let tall = MenuBarClusterController.menuBarBand(screen: screen, visibleMaxY: screen.maxY - 60, thickness: 24)
        XCTAssertEqual(tall.minY, screen.maxY - (60 + ClusterHoverPolicy.slackBelow + 2))
    }

    // MARK: - Peek

    func testThePeekIsCentredUnderItsChipJustBelowTheBar() {
        let screen = NSRect(x: 0, y: 0, width: 1512, height: 982)
        let chipRect = NSRect(x: 700, y: 958, width: 40, height: 24)
        let size = NSSize(width: 160, height: 60)
        let origin = MenuBarClusterController.peekOrigin(under: chipRect, size: size, screen: screen)
        XCTAssertEqual(origin.x + size.width / 2, chipRect.midX)
        // The view's own shadow margin overlaps the gap.
        XCTAssertEqual(origin.y + size.height, chipRect.minY - MenuBarClusterController.peekGap + Spacing.s)
    }

    func testThePeekStaysOnTheScreenAtEitherEnd() {
        let screen = NSRect(x: -2560, y: 200, width: 2560, height: 1440)
        let size = NSSize(width: 160, height: 60)
        let right = MenuBarClusterController.peekOrigin(
            under: NSRect(x: -30, y: 1616, width: 24, height: 24), size: size, screen: screen
        )
        XCTAssertEqual(right.x + size.width, screen.maxX)
        let left = MenuBarClusterController.peekOrigin(
            under: NSRect(x: -2556, y: 1616, width: 24, height: 24), size: size, screen: screen
        )
        XCTAssertEqual(left.x, screen.minX)
        // With no screen known it is left where the chip puts it.
        let free = MenuBarClusterController.peekOrigin(
            under: NSRect(x: -30, y: 1616, width: 24, height: 24), size: size, screen: nil
        )
        XCTAssertEqual(free.x, -98)
    }
}
