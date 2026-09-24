import Foundation

/// Seconds on a clock that keeps counting while the Mac sleeps.
///
/// Rate samplers need it: `ProcessInfo.systemUptime` stops during sleep, so a
/// night asleep looked like a few seconds, and whatever moved during dark
/// wakes (Power Nap, backups) was divided by that — a one-tick spike instead
/// of the fresh baseline a long gap is supposed to force.
/// `mach_continuous_time` includes sleep, never goes backwards, and — unlike
/// `CLOCK_MONOTONIC`, which runs seconds apart from it — is not slewed.
public enum SleepAwareClock {
    private static let secondsPerTick: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1_000_000_000
    }()

    public static func now() -> TimeInterval {
        Double(mach_continuous_time()) * secondsPerTick
    }
}
