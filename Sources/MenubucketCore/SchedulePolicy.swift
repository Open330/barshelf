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

    /// Effective polling interval, or nil when no interval timer should run.
    public static func effectiveInterval(
        configured: Double?,
        popupOpen: Bool,
        runInBackground: Bool
    ) -> Double? {
        guard let configured, configured > 0 else { return nil }
        if popupOpen {
            return max(configured, minForegroundIntervalSec)
        }
        guard runInBackground else { return nil }
        return max(configured * backgroundRelaxFactor, minBackgroundIntervalSec)
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
