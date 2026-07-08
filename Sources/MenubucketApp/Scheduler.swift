import AppKit
import Foundation
import MenubucketCore

/// Owns all refresh triggers beyond "popup just opened" (M1):
///
/// - `interval`: repeating timers — while the popup is open every widget with
///   `refresh.interval` polls (min 5 s); while closed only
///   `runInBackground == true` widgets poll, at a 4× relaxed cadence (min 60 s).
/// - `deadline`: when an adapter returns `nextRefreshAtMs`, re-run exactly once
///   at that time. Timers are cancelled while the popup is closed and
///   re-evaluated when it opens.
/// - `watch`: FSEvents on `refresh.watchPaths` (250 ms debounce). While the
///   popup is closed events only mark the widget pending; pending widgets are
///   refreshed in one batch when the popup opens.
/// - wake: `NSWorkspace.didWakeNotification` refreshes stale widgets
///   (background-capable ones immediately; the rest on next open anyway).
/// - backoff: consecutive failures gate *automatic* triggers with 15s → 60s →
///   300s (capped) delays; success resets. Manual refreshes are never gated.
///
/// Policy math lives in `MenubucketCore.SchedulePolicy` / `BackoffState`
/// (unit-tested); this class only arms timers and routes callbacks. All entry
/// points run on the main queue.
final class Scheduler {
    /// Refresh request sink (`WidgetRuntime.refresh(widgetID:manual:)`).
    var requestRefresh: ((_ widgetID: String, _ manual: Bool) -> Void)?
    /// Wake handler asks the runtime which widgets are stale.
    var requestStaleRefresh: ((_ backgroundOnly: Bool) -> Void)?

    private(set) var popupIsOpen = false

    private var widgets: [LoadedWidget] = []
    private var backoff: [String: BackoffState] = [:]
    private var intervalTimers: [String: Timer] = [:]
    private var deadlineTimers: [String: Timer] = [:]
    /// Pending adapter deadlines (epoch ms), survives popup close.
    private var deadlines: [String: Double] = [:]
    private var watchers: [String: DirectoryWatcher] = [:]
    private var pendingWatchEvents: Set<String> = []
    private var wakeObserver: NSObjectProtocol?
    private var refreshMultiplier: Double = 1
    private var pauseWhenClosed = false

    static let watchDebounceSec: TimeInterval = 0.25

    init() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            if self.pauseWhenClosed, !self.popupIsOpen { return }
            // While closed, only runInBackground widgets refresh (invariant 3);
            // everything else is picked up by onOpen staleness.
            self.requestStaleRefresh?(!self.popupIsOpen)
        }
    }

    deinit {
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        for timer in intervalTimers.values { timer.invalidate() }
        for timer in deadlineTimers.values { timer.invalidate() }
        for watcher in watchers.values { watcher.cancel() }
    }

    // MARK: - Configuration (widget set changed)

    func configure(widgets: [LoadedWidget]) {
        self.widgets = widgets
        let liveIDs = Set(widgets.map(\.id))
        backoff = backoff.filter { liveIDs.contains($0.key) }
        deadlines = deadlines.filter { liveIDs.contains($0.key) }
        pendingWatchEvents.formIntersection(liveIDs)
        rebuildIntervalTimers()
        rebuildDeadlineTimers()
        rebuildWatchers()
    }

    func configurePolicy(refreshMultiplier: Double, pauseWhenClosed: Bool) {
        let normalized = SchedulePolicy.normalizedRefreshMultiplier(refreshMultiplier)
        guard normalized != self.refreshMultiplier
            || pauseWhenClosed != self.pauseWhenClosed
        else { return }
        self.refreshMultiplier = normalized
        self.pauseWhenClosed = pauseWhenClosed
        rebuildIntervalTimers()
    }

    // MARK: - Popup lifecycle

    func popupOpened() {
        popupIsOpen = true
        rebuildIntervalTimers()
        rebuildDeadlineTimers() // re-evaluate deadlines (fire overdue ones)
        let pending = pendingWatchEvents
        pendingWatchEvents.removeAll()
        for id in pending {
            requestRefresh?(id, false)
        }
    }

    func popupClosed() {
        popupIsOpen = false
        rebuildIntervalTimers()
        cancelDeadlineTimers() // deadlines stay stored for re-evaluation
    }

    // MARK: - Refresh result feedback

    func noteRefreshSucceeded(widgetID: String, nextRefreshAtMs: Double?) {
        backoff[widgetID, default: BackoffState()].recordSuccess()
        if let nextRefreshAtMs {
            deadlines[widgetID] = nextRefreshAtMs
        } else {
            deadlines.removeValue(forKey: widgetID)
        }
        armDeadlineTimer(widgetID: widgetID)
    }

    func noteRefreshFailed(widgetID: String) {
        backoff[widgetID, default: BackoffState()].recordFailure()
    }

    /// Gate for automatic triggers (interval/deadline/watch/wake/onOpen).
    func allowsAutomaticRefresh(widgetID: String, now: Date = Date()) -> Bool {
        backoff[widgetID]?.allowsAutomaticRefresh(now: now) ?? true
    }

    // MARK: - Interval trigger

    private func rebuildIntervalTimers() {
        for timer in intervalTimers.values { timer.invalidate() }
        intervalTimers.removeAll()

        for widget in widgets {
            guard let interval = SchedulePolicy.effectiveInterval(
                configured: widget.manifest.refresh?.interval,
                popupOpen: popupIsOpen,
                runInBackground: widget.manifest.refresh?.runInBackground ?? false,
                multiplier: refreshMultiplier,
                pauseWhenClosed: pauseWhenClosed
            ) else { continue }

            let id = widget.id
            let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                self?.requestRefresh?(id, false)
            }
            timer.tolerance = interval * 0.1
            intervalTimers[id] = timer
        }
    }

    // MARK: - Deadline trigger

    private func rebuildDeadlineTimers() {
        cancelDeadlineTimers()
        guard popupIsOpen else { return }
        for id in deadlines.keys {
            armDeadlineTimer(widgetID: id)
        }
    }

    private func cancelDeadlineTimers() {
        for timer in deadlineTimers.values { timer.invalidate() }
        deadlineTimers.removeAll()
    }

    private func armDeadlineTimer(widgetID: String) {
        deadlineTimers[widgetID]?.invalidate()
        deadlineTimers.removeValue(forKey: widgetID)
        guard popupIsOpen, let deadlineMs = deadlines[widgetID] else { return }

        let fireDate = Date(timeIntervalSince1970: deadlineMs / 1000)
        let delay = max(fireDate.timeIntervalSinceNow, 0.05)
        let timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.deadlineTimers.removeValue(forKey: widgetID)
            self.deadlines.removeValue(forKey: widgetID) // exactly once
            self.requestRefresh?(widgetID, false)
        }
        deadlineTimers[widgetID] = timer
    }

    // MARK: - Watch trigger (FSEvents)

    private func rebuildWatchers() {
        for watcher in watchers.values { watcher.cancel() }
        watchers.removeAll()

        for widget in widgets {
            guard let paths = widget.manifest.refresh?.watchPaths, !paths.isEmpty else { continue }
            let id = widget.id
            do {
                watchers[id] = try DirectoryWatcher(
                    paths: paths,
                    debounce: Self.watchDebounceSec
                ) { [weak self] in
                    self?.watchFired(widgetID: id)
                }
            } catch {
                NSLog("menubucket: failed to watch paths for \(id): \(error)")
            }
        }
    }

    private func watchFired(widgetID: String) {
        if popupIsOpen {
            requestRefresh?(widgetID, false)
        } else {
            pendingWatchEvents.insert(widgetID) // batch on next open
        }
    }
}
