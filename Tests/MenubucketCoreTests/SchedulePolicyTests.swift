import XCTest
@testable import MenubucketCore

final class SchedulePolicyTests: XCTestCase {
    // MARK: - Interval policy

    func testForegroundIntervalClampedToMinimum() {
        XCTAssertEqual(
            SchedulePolicy.effectiveInterval(configured: 1, popupOpen: true, runInBackground: false),
            5
        )
        XCTAssertEqual(
            SchedulePolicy.effectiveInterval(configured: 60, popupOpen: true, runInBackground: false),
            60
        )
    }

    func testClosedPopupPollsOnlyRunInBackgroundWidgets() {
        XCTAssertNil(
            SchedulePolicy.effectiveInterval(configured: 60, popupOpen: false, runInBackground: false)
        )
        // 4× relaxation with a 60 s floor.
        XCTAssertEqual(
            SchedulePolicy.effectiveInterval(configured: 60, popupOpen: false, runInBackground: true),
            240
        )
        XCTAssertEqual(
            SchedulePolicy.effectiveInterval(configured: 5, popupOpen: false, runInBackground: true),
            60
        )
    }

    func testNilOrNonPositiveIntervalDisablesPolling() {
        XCTAssertNil(SchedulePolicy.effectiveInterval(configured: nil, popupOpen: true, runInBackground: true))
        XCTAssertNil(SchedulePolicy.effectiveInterval(configured: 0, popupOpen: true, runInBackground: true))
        XCTAssertNil(SchedulePolicy.effectiveInterval(configured: -3, popupOpen: true, runInBackground: true))
    }

    // MARK: - Backoff

    func testBackoffProgression15_60_300Capped() {
        XCTAssertEqual(BackoffState.delay(afterConsecutiveFailures: 1), 15)
        XCTAssertEqual(BackoffState.delay(afterConsecutiveFailures: 2), 60)
        XCTAssertEqual(BackoffState.delay(afterConsecutiveFailures: 3), 300)
        XCTAssertEqual(BackoffState.delay(afterConsecutiveFailures: 4), 300, "capped at 300s")
        XCTAssertEqual(BackoffState.delay(afterConsecutiveFailures: 99), 300)
    }

    func testBackoffGatesAutomaticRefreshUntilRetryAt() {
        var state = BackoffState()
        let start = Date(timeIntervalSince1970: 1_000_000)

        XCTAssertTrue(state.allowsAutomaticRefresh(now: start))

        state.recordFailure(now: start)
        XCTAssertEqual(state.consecutiveFailures, 1)
        XCTAssertFalse(state.allowsAutomaticRefresh(now: start.addingTimeInterval(14)))
        XCTAssertTrue(state.allowsAutomaticRefresh(now: start.addingTimeInterval(15)))

        state.recordFailure(now: start.addingTimeInterval(15))
        XCTAssertFalse(state.allowsAutomaticRefresh(now: start.addingTimeInterval(15 + 59)))
        XCTAssertTrue(state.allowsAutomaticRefresh(now: start.addingTimeInterval(15 + 60)))
    }

    func testBackoffResetsOnSuccess() {
        var state = BackoffState()
        let now = Date()
        state.recordFailure(now: now)
        state.recordFailure(now: now)
        state.recordSuccess()
        XCTAssertEqual(state.consecutiveFailures, 0)
        XCTAssertTrue(state.allowsAutomaticRefresh(now: now))
        // After a reset the ladder restarts at 15 s.
        state.recordFailure(now: now)
        XCTAssertEqual(state.retryAt, now.addingTimeInterval(15))
    }

    // MARK: - Staleness (snapshot policy reused by wake/onOpen triggers)

    func testSnapshotStaleness() {
        let now = Date()
        var snapshot = WidgetSnapshot(widgetID: "w")
        XCTAssertTrue(snapshot.isStale(after: 600, now: now), "no updatedAt → always stale")

        snapshot.updatedAt = now.addingTimeInterval(-100)
        XCTAssertFalse(snapshot.isStale(after: 600, now: now))
        XCTAssertTrue(snapshot.isStale(after: 50, now: now))
        XCTAssertTrue(snapshot.isStale(after: nil, now: now), "nil staleAfterSec → always stale")
    }
}
