import Foundation
import MenubucketCore

/// Per-widget refresh statistics for the Monitoring pane.
///
/// Its own small store for the same reason as `WidgetCardModel` and
/// `MenuBarStatusStore`: stats change on *every* refresh, and while they were
/// a `@Published` property of `WidgetRuntime` each change fired the runtime's
/// `objectWillChange`. `RootView` observes the runtime and lives for the whole
/// session inside the popover's hosting controller, so a closed shelf
/// recomputed its pages and re-evaluated its body one and a half times a
/// second — for numbers only the Monitoring pane shows.
final class RefreshStatsModel: ObservableObject {
    @Published fileprivate(set) var stats: [String: WidgetRefreshStats] = [:]

    fileprivate func apply(_ stats: [String: WidgetRefreshStats]) {
        guard self.stats != stats else { return }
        self.stats = stats
    }
}

/// Keeps the books on refreshes: when each one started, how it ended and
/// how long it took. Owns the persisted stats (`RefreshStatsStore`) and the
/// model the Monitoring pane observes, and publishes to that model after
/// every change to the store.
///
/// Main-actor isolated, like the runtime that reports to it. It asks the
/// runtime nothing.
@MainActor
final class RefreshLedger {
    /// Observed by the Monitoring pane only — see `RefreshStatsModel`.
    let model = RefreshStatsModel()

    private let store: RefreshStatsStore
    private let now: () -> Date
    /// When the refresh each widget is waiting on started.
    private var startedAt: [String: Date] = [:]

    /// - Parameters:
    ///   - store: Nil is the stats file in Application Support.
    ///   - now: The clock a refresh's start is read from.
    init(store: RefreshStatsStore? = nil, now: @escaping () -> Date = { Date() }) {
        if let store {
            self.store = store
        } else {
            self.store = RefreshStatsStore(
                fileURL: WidgetRuntime.applicationSupportDirectory
                    .appendingPathComponent(RefreshStatsStore.defaultFileName)
            )
        }
        self.now = now
        model.apply(self.store.all)
    }

    // MARK: - A refresh's start

    /// Notes that the widget's refresh starts now; returns that moment.
    @discardableResult
    func markStarted(widgetID: String) -> Date {
        let date = now()
        startedAt[widgetID] = date
        return date
    }

    /// The widget's refresh ended without an outcome to record (cancelled,
    /// or its configuration changed under it).
    func forgetStart(widgetID: String) {
        startedAt.removeValue(forKey: widgetID)
    }

    /// Forgets the starts of widgets that are gone.
    func forgetStarts(notIn liveIDs: Set<String>) {
        startedAt = startedAt.filter { liveIDs.contains($0.key) }
    }

    // MARK: - A refresh's outcome

    /// Records a success. Its duration runs from `startedAt`, or from the
    /// start marked for the widget when that is nil; with neither, the
    /// success counts without a duration.
    func recordSuccess(widgetID: String, startedAt: Date? = nil, completedAt: Date) {
        let start = startedAt ?? self.startedAt[widgetID]
        self.startedAt.removeValue(forKey: widgetID)
        store.recordSuccess(
            widgetID: widgetID,
            durationMs: start.map { completedAt.timeIntervalSince($0) * 1000 },
            at: completedAt
        )
        publish()
    }

    /// Records a failure and its message; the duration is as for a success.
    func recordFailure(widgetID: String, error: String, startedAt: Date? = nil, completedAt: Date) {
        let start = startedAt ?? self.startedAt[widgetID]
        self.startedAt.removeValue(forKey: widgetID)
        store.recordFailure(
            widgetID: widgetID,
            error: error,
            durationMs: start.map { completedAt.timeIntervalSince($0) * 1000 },
            at: completedAt
        )
        publish()
    }

    // MARK: - The stats

    /// After a rescan: drops the stats of widgets that are gone.
    func retain(widgetIDs: Set<String>) {
        store.retain(widgetIDs: widgetIDs)
        publish()
    }

    /// Writes whatever the store's throttle is still holding.
    func flush() {
        store.flush()
    }

    private func publish() {
        model.apply(store.all)
    }
}
