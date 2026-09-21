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

    func testRefreshMultiplierScalesIntervalsBeforeClamps() {
        XCTAssertEqual(
            SchedulePolicy.effectiveInterval(
                configured: 30, popupOpen: true, runInBackground: false,
                multiplier: 2
            ),
            60
        )
        XCTAssertEqual(
            SchedulePolicy.effectiveInterval(
                configured: 2, popupOpen: true, runInBackground: false,
                multiplier: 0.5
            ),
            5
        )
        XCTAssertEqual(
            SchedulePolicy.effectiveInterval(
                configured: 30, popupOpen: false, runInBackground: true,
                multiplier: 2
            ),
            240
        )
    }

    func testPauseWhenClosedStopsBackgroundPolling() {
        XCTAssertNil(
            SchedulePolicy.effectiveInterval(
                configured: 60, popupOpen: false, runInBackground: true,
                multiplier: 1, pauseWhenClosed: true
            )
        )
        XCTAssertEqual(
            SchedulePolicy.effectiveInterval(
                configured: 60, popupOpen: true, runInBackground: true,
                multiplier: 1, pauseWhenClosed: true
            ),
            60
        )
    }

    func testEffectiveStaleAfterUsesNormalizedMultiplier() {
        XCTAssertEqual(
            SchedulePolicy.effectiveStaleAfter(configured: 60, multiplier: 2),
            120
        )
        XCTAssertEqual(
            SchedulePolicy.effectiveStaleAfter(configured: 60, multiplier: 0.49),
            30
        )
        XCTAssertNil(SchedulePolicy.effectiveStaleAfter(configured: nil, multiplier: 4))
    }

    // MARK: - Event trigger debounce / spacing (R12)

    func testTriggerAllowedWhenNeverRefreshed() {
        XCTAssertTrue(SchedulePolicy.triggerAllowed(lastRefreshAt: nil, now: Date()))
    }

    func testTriggerDebouncedWithinMinSpacing() {
        let last = Date(timeIntervalSince1970: 1_000_000)
        // popup-open trigger: ≥5 s per widget.
        XCTAssertFalse(
            SchedulePolicy.triggerAllowed(
                lastRefreshAt: last,
                now: last.addingTimeInterval(4),
                minSpacing: SchedulePolicy.popupOpenTriggerDebounceSec
            )
        )
        XCTAssertTrue(
            SchedulePolicy.triggerAllowed(
                lastRefreshAt: last,
                now: last.addingTimeInterval(5),
                minSpacing: SchedulePolicy.popupOpenTriggerDebounceSec
            )
        )
    }

    func testTriggerNeverDoubleFiresRightAfterIntervalRefresh() {
        let intervalRefresh = Date(timeIntervalSince1970: 2_000_000)
        // A wake/fs trigger arriving 1 s after an interval refresh is suppressed.
        XCTAssertFalse(
            SchedulePolicy.triggerAllowed(
                lastRefreshAt: intervalRefresh,
                now: intervalRefresh.addingTimeInterval(1),
                minSpacing: SchedulePolicy.triggerMinSpacingSec
            )
        )
        XCTAssertTrue(
            SchedulePolicy.triggerAllowed(
                lastRefreshAt: intervalRefresh,
                now: intervalRefresh.addingTimeInterval(SchedulePolicy.triggerMinSpacingSec),
                minSpacing: SchedulePolicy.triggerMinSpacingSec
            )
        )
    }

    func testTriggerSpacingConstants() {
        XCTAssertEqual(SchedulePolicy.popupOpenTriggerDebounceSec, 5)
        XCTAssertEqual(SchedulePolicy.fsTriggerCoalesceSec, 2)
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

    // MARK: - Menu-bar promotion

    func testPromotedWidgetKeepsItsCadenceWhileThePopupIsClosed() {
        // Not promoted: a closed popup silences a widget that is not
        // background-capable, and relaxes one that is.
        XCTAssertNil(SchedulePolicy.effectiveInterval(
            configured: 2, popupOpen: false, runInBackground: false
        ))
        XCTAssertEqual(
            SchedulePolicy.effectiveInterval(
                configured: 2, popupOpen: false, runInBackground: true
            ),
            60
        )
        // Promoted: its value is on screen, so it polls at its own cadence in
        // both popup states, with neither the 5 s nor the 60 s floor.
        XCTAssertEqual(
            SchedulePolicy.effectiveInterval(
                configured: 2, popupOpen: false, runInBackground: false,
                menuBarPromoted: true
            ),
            2
        )
        XCTAssertEqual(
            SchedulePolicy.effectiveInterval(
                configured: 2, popupOpen: true, runInBackground: false,
                menuBarPromoted: true
            ),
            2
        )
    }

    func testPromotionStillClampsToTheMenuBarFloorAndScalesWithTheMultiplier() {
        XCTAssertEqual(
            SchedulePolicy.effectiveInterval(
                configured: 0.1, popupOpen: false, runInBackground: false,
                menuBarPromoted: true
            ),
            SchedulePolicy.minMenuBarIntervalSec
        )
        XCTAssertEqual(
            SchedulePolicy.effectiveInterval(
                configured: 2, popupOpen: false, runInBackground: false,
                multiplier: 4, menuBarPromoted: true
            ),
            8
        )
        // No configured interval means no polling, promoted or not.
        XCTAssertNil(SchedulePolicy.effectiveInterval(
            configured: nil, popupOpen: false, runInBackground: false,
            menuBarPromoted: true
        ))
    }

    /// The battery saver used to stop promoted widgets too, which left a
    /// reading in the menu bar frozen at whatever it happened to say — on this
    /// project's own machines, for a day. The saver is about work nobody can
    /// see, and a promoted widget is the one thing that is always visible.
    func testTheBatterySaverDoesNotPauseAPromotedWidget() {
        for popupOpen in [true, false] {
            XCTAssertEqual(
                SchedulePolicy.effectiveInterval(
                    configured: 2, popupOpen: popupOpen, runInBackground: false,
                    pauseWhenClosed: true, menuBarPromoted: true
                ),
                2,
                "promoted widget paused with popupOpen=\(popupOpen)"
            )
        }
    }

    /// The saver still does its job for everything else, which is the point of
    /// carving out only the visible case.
    func testTheBatterySaverStillPausesWidgetsNobodyCanSee() {
        XCTAssertNil(SchedulePolicy.effectiveInterval(
            configured: 2, popupOpen: false, runInBackground: true,
            pauseWhenClosed: true, menuBarPromoted: false
        ))
    }

    /// Taking the widget out of the menu bar is how someone stops it polling —
    /// so that has to actually stop it.
    func testDemotingAWidgetPutsItBackUnderTheSaver() {
        XCTAssertNotNil(SchedulePolicy.effectiveInterval(
            configured: 2, popupOpen: false, runInBackground: false,
            pauseWhenClosed: true, menuBarPromoted: true
        ))
        XCTAssertNil(SchedulePolicy.effectiveInterval(
            configured: 2, popupOpen: false, runInBackground: false,
            pauseWhenClosed: true, menuBarPromoted: false
        ))
    }

}
