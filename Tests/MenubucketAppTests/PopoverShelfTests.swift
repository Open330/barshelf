import AppKit
import MenubucketCore
import XCTest
@testable import MenubucketApp

/// The popover's rules that do not need a window: attention, pins, height,
/// freshness, and the native approval card's contents.
final class PopoverShelfTests: XCTestCase {
    // MARK: - Attention

    private func reasons(
        ids: [String] = ["a", "b"],
        disabled: Set<String> = [],
        overlays: [String: CardOverlay] = [:],
        errors: [String: String] = [:]
    ) -> ShelfAttention.Reasons {
        ShelfAttention.widgetReasons(
            widgetIDs: ids,
            isDisabled: disabled.contains,
            overlay: { overlays[$0] },
            error: { errors[$0] }
        )
    }

    func testAttentionIsQuietWhenNothingIsWrong() {
        XCTAssertEqual(reasons(), [])
    }

    func testPendingApprovalAndErrorsNeedAttention() {
        XCTAssertEqual(reasons(overlays: ["a": .approvalNeeded([])]), .approvalNeeded)
        XCTAssertEqual(reasons(errors: ["b": "HTTP 500"]), .widgetError)
        XCTAssertEqual(reasons(overlays: ["a": .disabled(reason: "crashed")]), .widgetError)
        XCTAssertEqual(
            reasons(overlays: ["a": .approvalNeeded([])], errors: ["b": "boom"]),
            [.approvalNeeded, .widgetError]
        )
    }

    func testDeniedAndDisabledWidgetsDoNotNeedAttention() {
        // Denying is the user's decision; the error it leaves is not news.
        XCTAssertEqual(reasons(overlays: ["a": .denied([])], errors: ["a": "denied"]), [])
        XCTAssertEqual(reasons(disabled: ["a"], overlays: ["a": .approvalNeeded([])]), [])
    }

    func testAttentionPublishesOnlyOnChange() {
        let attention = ShelfAttention()
        var published = 0
        let cancellable = attention.$reasons.dropFirst().sink { _ in published += 1 }
        attention.set(.widgetError, true)
        attention.set(.widgetError, true)
        attention.set(.updateAvailable, true)
        attention.set(.widgetError, false)
        XCTAssertEqual(published, 3)
        XCTAssertEqual(attention.reasons, .updateAvailable)
        XCTAssertTrue(attention.needsAttention)
        cancellable.cancel()
    }

    @MainActor
    func testStatusItemSaysWhenItNeedsAttention() {
        let button = NSStatusBarButton(frame: NSRect(x: 0, y: 0, width: 28, height: 22))
        BarShelfStatusIcon.configure(
            button, symbol: AppPreferences.defaultMenuBarSymbol, fallback: "tray.full", badged: true
        )
        XCTAssertEqual(button.accessibilityLabel(), "BarShelf, needs attention")
        XCTAssertEqual(button.image?.isTemplate, true)
        BarShelfStatusIcon.configure(
            button, symbol: AppPreferences.defaultMenuBarSymbol, fallback: "tray.full", badged: false
        )
        XCTAssertEqual(button.accessibilityLabel(), "BarShelf")
    }

    // MARK: - Pins

    func testPinCapCountsOnlyEnabledPins() {
        let enabled: Set<String> = ["a", "b", "c"]
        XCTAssertTrue(PinnedShelf.canPin("c", pinned: ["a"], enabledIDs: enabled))
        XCTAssertFalse(PinnedShelf.canPin("c", pinned: ["a", "b"], enabledIDs: enabled))
        // Unpinning is always possible.
        XCTAssertTrue(PinnedShelf.canPin("a", pinned: ["a", "b"], enabledIDs: enabled))
        // A disabled pinned widget does not take a slot.
        XCTAssertTrue(PinnedShelf.canPin("c", pinned: ["a", "gone"], enabledIDs: enabled))
    }

    func testPinnedOverflowIsWhatTheCapLeavesOut() {
        let enabled: Set<String> = ["a", "b", "c"]
        XCTAssertEqual(PinnedShelf.displayedIDs(pinned: ["a", "x", "b", "c"], enabledIDs: enabled), ["a", "b"])
        XCTAssertEqual(PinnedShelf.overflowIDs(pinned: ["a", "x", "b", "c"], enabledIDs: enabled), ["c"])
        XCTAssertEqual(PinnedShelf.overflowIDs(pinned: ["a"], enabledIDs: enabled), [])
    }

    // MARK: - Height

    func testPopupHeightFollowsContentUpToTheScreen() {
        // Short content: as tall as it needs, but not below the floor.
        XCTAssertEqual(RootView.popupHeight(chrome: 40, content: 300, maxHeight: 900), 340)
        XCTAssertEqual(RootView.popupHeight(chrome: 40, content: 20, maxHeight: 900), RootView.minimumHeight)
        // Tall content: capped by the screen.
        XCTAssertEqual(RootView.popupHeight(chrome: 40, content: 2000, maxHeight: 900), 900)
        // Not measured yet: the old default, still within the screen.
        XCTAssertEqual(RootView.popupHeight(chrome: 40, content: nil, maxHeight: 900), RootView.defaultSize.height)
        XCTAssertEqual(RootView.popupHeight(chrome: 40, content: nil, maxHeight: 300), 300)
    }

    func testMaximumHeightLeavesAMargin() {
        XCTAssertEqual(RootView.maximumHeight(screenVisibleHeight: 1000), 1000 - RootView.screenMargin)
        XCTAssertEqual(RootView.maximumHeight(screenVisibleHeight: 100), RootView.minimumHeight)
    }

    // MARK: - Freshness

    func testFreshnessLabel() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        XCTAssertEqual(CardFreshness.label(updatedAt: now.addingTimeInterval(-20), now: now), "Updated just now")
        let older = CardFreshness.label(updatedAt: now.addingTimeInterval(-5 * 60), now: now)
        XCTAssertTrue(older.hasPrefix("Updated "), older)
        XCTAssertTrue(older.contains("5"), older)
        // A clock that moved backwards never yields "in 3 min".
        XCTAssertEqual(CardFreshness.label(updatedAt: now.addingTimeInterval(180), now: now), "Updated just now")
    }

    // MARK: - Approval card

    func testPermissionRequestsDescribeEachCapability() {
        let manifest = Manifest(
            schemaVersion: 1,
            id: "dev.test.approval",
            name: "Approval",
            entry: .init(kind: "workflow"),
            permissions: .init(
                exec: [.init(command: "/usr/bin/top", allowedArgs: [["-l", "1"]])],
                network: ["api.example.com"],
                notifications: true
            )
        )
        let widget = LoadedWidget(manifest: manifest, directory: FileManager.default.temporaryDirectory)
        let requests = WidgetRuntime.permissionRequests(for: widget)
        XCTAssertEqual(requests.map(\.symbol), ["terminal", "bell.fill", "network"])
        XCTAssertEqual(requests.first?.description, "Run top -l 1")
        XCTAssertTrue(requests.allSatisfy { !$0.isWarning })
    }

    func testCommandWidgetWithoutAnAllowlistIsFlagged() {
        let manifest = Manifest(
            schemaVersion: 1, id: "dev.test.exec", name: "Exec", entry: .init(kind: "exec")
        )
        let widget = LoadedWidget(manifest: manifest, directory: FileManager.default.temporaryDirectory)
        let requests = WidgetRuntime.permissionRequests(for: widget)
        XCTAssertEqual(requests.count, 1)
        XCTAssertTrue(requests[0].isWarning)
    }

    func testOverlayKnowsWhenItNeedsApproval() {
        XCTAssertTrue(CardOverlay.approvalNeeded([]).needsApproval)
        XCTAssertFalse(CardOverlay.denied([]).needsApproval)
        XCTAssertFalse(CardOverlay.disabled(reason: "x").needsApproval)
    }
}
