import XCTest
import MenubucketCore
@testable import MenubucketApp

final class SchedulerVisibilityTests: XCTestCase {
    private func widget(
        _ id: String,
        interval: Double? = nil,
        triggers: [TriggerSpec]? = nil,
        runInBackground: Bool = false
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
}
