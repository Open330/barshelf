import XCTest
import MenubucketCore
@testable import MenubucketApp

final class SchedulerVisibilityTests: XCTestCase {
    private func widget(
        _ id: String,
        interval: Double? = nil,
        triggers: [TriggerSpec]? = nil,
        runInBackground: Bool = false,
        popupOnly: Bool = false
    ) -> LoadedWidget {
        LoadedWidget(
            manifest: Manifest(
                schemaVersion: 1,
                id: id,
                name: id,
                entry: .init(kind: "exec"),
                refresh: .init(
                    onOpen: true,
                    interval: interval,
                    runInBackground: runInBackground,
                    popupOnly: popupOnly,
                    triggers: triggers
                )
            ),
            directory: URL(fileURLWithPath: "/tmp/\(id)")
        )
    }

    func testPopupTriggerWaitsUntilItsPageBecomesVisible() {
        let scheduler = Scheduler()
        let first = widget("first", triggers: [.popupOpen])
        let hidden = widget("hidden", triggers: [.popupOpen])
        var refreshed: [String] = []
        scheduler.requestRefresh = { id, _ in refreshed.append(id) }
        scheduler.configure(widgets: [first, hidden])
        scheduler.setVisibleWidgetIDs([first.id])

        scheduler.popupOpened()
        XCTAssertEqual(refreshed, [first.id])

        scheduler.setVisibleWidgetIDs([hidden.id])
        XCTAssertEqual(refreshed, [first.id, hidden.id])
        scheduler.popupClosed()
    }

    func testOnlyVisibleWidgetsOwnOpenPopupIntervalTimers() {
        let scheduler = Scheduler()
        let first = widget("first", interval: 60)
        let hidden = widget("hidden", interval: 60)
        scheduler.configure(widgets: [first, hidden])
        scheduler.setVisibleWidgetIDs([first.id])

        scheduler.popupOpened()
        XCTAssertEqual(scheduler.activeIntervalWidgetIDs, [first.id])

        scheduler.setVisibleWidgetIDs([hidden.id])
        XCTAssertEqual(scheduler.activeIntervalWidgetIDs, [hidden.id])

        scheduler.popupClosed()
        XCTAssertTrue(scheduler.activeIntervalWidgetIDs.isEmpty)
    }

    func testPopupOnlyWidgetRejectsEverySchedulerAutomationPath() {
        let scheduler = Scheduler()
        let guarded = widget(
            "guarded",
            interval: 5,
            triggers: [.popupOpen, .wake],
            runInBackground: true,
            popupOnly: true
        )
        var refreshed: [String] = []
        scheduler.requestRefresh = { id, _ in refreshed.append(id) }
        scheduler.configure(widgets: [guarded])
        scheduler.setVisibleWidgetIDs([guarded.id])

        scheduler.popupOpened()
        XCTAssertTrue(refreshed.isEmpty)
        XCTAssertTrue(scheduler.activeIntervalWidgetIDs.isEmpty)
        scheduler.popupClosed()
        XCTAssertTrue(scheduler.activeIntervalWidgetIDs.isEmpty)
    }

    // MARK: - Menu-bar promotion

    func testPromotedWidgetsPollWhileHiddenAndWhileThePopupIsClosed() {
        let scheduler = Scheduler()
        let promoted = widget("promoted", interval: 2)
        let hidden = widget("hidden", interval: 2)
        scheduler.configure(widgets: [promoted, hidden])
        scheduler.setVisibleWidgetIDs([])
        scheduler.setMenuBarWidgetIDs([promoted.id])

        // Closed popup: only the promoted widget owns a timer, even though
        // neither declares runInBackground.
        XCTAssertEqual(scheduler.activeIntervalWidgetIDs, [promoted.id])

        // Open popup on a page that shows neither: promotion keeps it polling.
        scheduler.popupOpened()
        XCTAssertEqual(scheduler.activeIntervalWidgetIDs, [promoted.id])
        scheduler.popupClosed()
    }

    func testDemotingAWidgetStopsItsTimer() {
        let scheduler = Scheduler()
        let promoted = widget("promoted", interval: 2)
        scheduler.configure(widgets: [promoted])
        scheduler.setMenuBarWidgetIDs([promoted.id])
        XCTAssertEqual(scheduler.activeIntervalWidgetIDs, [promoted.id])

        scheduler.setMenuBarWidgetIDs([])
        XCTAssertTrue(scheduler.activeIntervalWidgetIDs.isEmpty)
    }

    func testPromotionDoesNotOverridePopupOnly() {
        let scheduler = Scheduler()
        let restricted = widget("restricted", interval: 2, popupOnly: true)
        var refreshed: [String] = []
        scheduler.requestRefresh = { id, _ in refreshed.append(id) }
        scheduler.configure(widgets: [restricted])
        scheduler.setMenuBarWidgetIDs([restricted.id])
        XCTAssertTrue(scheduler.activeIntervalWidgetIDs.isEmpty)

        // `popupOnly` is the author's hard opt-out: no automatic path may run
        // it, including the ones promotion newly exempts from other gates.
        scheduler.popupClosed()
        scheduler.setVisibleWidgetIDs([restricted.id])
        scheduler.popupOpened()
        XCTAssertTrue(scheduler.activeIntervalWidgetIDs.isEmpty)
        XCTAssertTrue(refreshed.isEmpty)
        scheduler.popupClosed()
    }

    func testPromotedIDsAreDroppedWhenTheWidgetDisappears() {
        let scheduler = Scheduler()
        let promoted = widget("promoted", interval: 2)
        scheduler.configure(widgets: [promoted])
        scheduler.setMenuBarWidgetIDs([promoted.id])
        XCTAssertEqual(scheduler.activeIntervalWidgetIDs, [promoted.id])

        scheduler.configure(widgets: [])
        XCTAssertTrue(scheduler.activeIntervalWidgetIDs.isEmpty)
        // Re-adding the widget must not silently resurrect its promotion.
        scheduler.configure(widgets: [promoted])
        XCTAssertTrue(scheduler.activeIntervalWidgetIDs.isEmpty)
    }

}
