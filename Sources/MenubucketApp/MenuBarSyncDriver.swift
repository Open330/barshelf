import Combine
import Foundation

/// When the menu bar is synced again without a caller asking for it: the
/// batch that gathers a burst of new readings into one sync, and the slow
/// tick that re-evaluates staleness.
///
/// It decides only *when*. Both paths call `onSyncNeeded`, which the runtime
/// points at its `syncMenuBar`, the single entry point every sync goes
/// through.
///
/// Main-actor isolated: the batch runs on the main queue and the tick on the
/// main run loop.
@MainActor
final class MenuBarSyncDriver {
    /// How often owned entries are re-evaluated for staleness.
    nonisolated static let defaultStalenessInterval: TimeInterval = 15

    /// Starts a repeating tick and returns what stops it. Injected so a test
    /// can fire the tick itself instead of waiting for it.
    typealias TickerScheduler = (
        _ interval: TimeInterval, _ tick: @escaping @MainActor @Sendable () -> Void
    ) -> AnyCancellable

    /// The shipped tick: a repeating timer on the main run loop, allowed to
    /// slip by a third of its interval.
    static func stalenessTimer(
        interval: TimeInterval, tick: @escaping @MainActor @Sendable () -> Void
    ) -> Timer {
        // `assumeIsolated` holds because the timer is scheduled on the main
        // run loop, from a main-actor method: it only ever fires on the main
        // thread.
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated { tick() }
        }
        timer.tolerance = interval / 3
        return timer
    }

    /// What a batched sync and the staleness tick call.
    var onSyncNeeded: () -> Void = {}

    private let stalenessInterval: TimeInterval
    private let scheduleTicker: TickerScheduler
    private let batchDelay: DispatchTimeInterval
    private lazy var batch = MenuBarUpdateBatch(delay: batchDelay) { [weak self] in
        self?.onSyncNeeded()
    }
    /// Re-evaluates menu-bar staleness on a slow tick. Without it a widget that
    /// stopped refreshing (battery saver, a crash-looping script) would keep
    /// showing its last value at full contrast forever.
    private var ticker: AnyCancellable?

    /// `scheduleTicker` nil is the shipped timer (`stalenessTimer`).
    init(
        stalenessInterval: TimeInterval = MenuBarSyncDriver.defaultStalenessInterval,
        batchDelay: DispatchTimeInterval = MenuBarUpdateBatch.defaultDelay,
        scheduleTicker: TickerScheduler? = nil
    ) {
        self.stalenessInterval = stalenessInterval
        if let scheduleTicker {
            self.scheduleTicker = scheduleTicker
        } else {
            self.scheduleTicker = { interval, tick in
                let timer = MenuBarSyncDriver.stalenessTimer(interval: interval, tick: tick)
                return AnyCancellable { timer.invalidate() }
            }
        }
        self.batchDelay = batchDelay
    }

    // MARK: - Batch

    /// Whether a batched sync is queued.
    var hasPendingSync: Bool { batch.isPending }

    /// Asks for a sync a moment from now; requests made before it runs
    /// share it.
    func requestSync() {
        batch.request()
    }

    /// An immediate sync supersedes any queued one.
    func cancelPendingSync() {
        batch.cancel()
    }

    // MARK: - Staleness tick

    /// Whether the staleness tick is running.
    var isTicking: Bool { ticker != nil }

    /// Starts the tick if the menu bar owns anything and none is running;
    /// stops it when the menu bar owns nothing.
    func updateTicker(hasOwnedEntries: Bool) {
        guard hasOwnedEntries else {
            stopTicker()
            return
        }
        guard ticker == nil else { return }
        ticker = scheduleTicker(stalenessInterval) { [weak self] in
            self?.onSyncNeeded()
        }
    }

    /// Stops the tick. The next `updateTicker` that finds something owned
    /// starts it again.
    func stopTicker() {
        ticker?.cancel()
        ticker = nil
    }
}
