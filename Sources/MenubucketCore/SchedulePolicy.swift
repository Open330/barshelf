import Foundation

/// Pure scheduling policy (UI-free, unit-tested). The app-side `Scheduler`
/// consults these rules when arming timers and gating automatic refreshes.
public enum SchedulePolicy {
    /// Minimum interval while the popup is open.
    public static let minForegroundIntervalSec: Double = 5
    /// Minimum interval while the popup is closed (`runInBackground` only).
    public static let minBackgroundIntervalSec: Double = 60
    /// Closed-popup intervals are relaxed by this factor.
    public static let backgroundRelaxFactor: Double = 4

    /// Refresh multipliers offered by the app settings (R08). The configured
    /// interval and `staleAfter` judgments are both scaled by the multiplier;
    /// anything else is normalized to the nearest allowed step.
    public static let allowedRefreshMultipliers: [Double] = [0.5, 1, 2, 4]

    /// Snaps an arbitrary stored value to the nearest allowed multiplier
    /// (corrupt/hand-edited prefs must never produce a 0× or negative rate).
    public static func normalizedRefreshMultiplier(_ value: Double) -> Double {
        guard value.isFinite, value > 0 else { return 1 }
        return allowedRefreshMultipliers.min {
            abs($0 - value) < abs($1 - value)
        } ?? 1
    }

    /// Effective polling interval, or nil when no interval timer should run.
    ///
    /// - `multiplier`: user refresh multiplier (R08 app settings). Scales the
    ///   configured interval *before* the minimum clamps, so 0.5× can never
    ///   undercut the 5 s / 60 s floors.
    /// - `pauseWhenClosed`: battery saver — while the popup is closed nothing
    ///   polls, `runInBackground` widgets included.
    public static func effectiveInterval(
        configured: Double?,
        popupOpen: Bool,
        runInBackground: Bool,
        multiplier: Double = 1,
        pauseWhenClosed: Bool = false
    ) -> Double? {
        guard let configured, configured > 0 else { return nil }
        let scaled = configured * normalizedRefreshMultiplier(multiplier)
        if popupOpen {
            return max(scaled, minForegroundIntervalSec)
        }
        if pauseWhenClosed { return nil }
        guard runInBackground else { return nil }
        return max(scaled * backgroundRelaxFactor, minBackgroundIntervalSec)
    }

    // MARK: - Event triggers (R12)

    /// Minimum spacing between two `popup-open` trigger refreshes of the same
    /// widget (contract: debounce ≥5 s per widget).
    public static let popupOpenTriggerDebounceSec: Double = 5
    /// Trailing-edge coalescing window for `fs` triggers (bursts of FSEvents
    /// collapse into one refresh).
    public static let fsTriggerCoalesceSec: Double = 2
    /// Minimum spacing an event trigger keeps from the widget's most recent
    /// refresh so a trigger never double-fires alongside interval polling.
    public static let triggerMinSpacingSec: Double = 5

    /// True when an event-triggered refresh may fire, given when the widget was
    /// last refreshed (by any trigger) and the required spacing. `nil` last-time
    /// (never refreshed) always allows. Pure — unit-tested.
    public static func triggerAllowed(
        lastRefreshAt: Date?,
        now: Date = Date(),
        minSpacing: Double = triggerMinSpacingSec
    ) -> Bool {
        guard let lastRefreshAt else { return true }
        return now.timeIntervalSince(lastRefreshAt) >= minSpacing
    }

    /// `staleAfter` scaled by the refresh multiplier: at 2× data stays
    /// "fresh" twice as long. `nil` stays nil ("always stale").
    public static func effectiveStaleAfter(
        configured: Double?,
        multiplier: Double
    ) -> Double? {
        guard let configured else { return nil }
        return configured * normalizedRefreshMultiplier(multiplier)
    }
}

/// Exponential backoff for consecutive refresh failures: 15s → 60s → 300s
/// (capped), reset on success. Only automatic triggers are gated — manual
/// refreshes always run.
public struct BackoffState: Equatable {
    public static let delaySteps: [TimeInterval] = [15, 60, 300]

    public private(set) var consecutiveFailures: Int = 0
    public private(set) var retryAt: Date?

    public init() {}

    public static func delay(afterConsecutiveFailures count: Int) -> TimeInterval {
        precondition(count >= 1)
        return delaySteps[min(count, delaySteps.count) - 1]
    }

    public mutating func recordFailure(now: Date = Date()) {
        consecutiveFailures += 1
        retryAt = now.addingTimeInterval(Self.delay(afterConsecutiveFailures: consecutiveFailures))
    }

    public mutating func recordSuccess() {
        consecutiveFailures = 0
        retryAt = nil
    }

    /// False while inside the backoff window (automatic triggers suppressed).
    public func allowsAutomaticRefresh(now: Date = Date()) -> Bool {
        guard let retryAt else { return true }
        return now >= retryAt
    }
}
