import AppKit
import Foundation
import MenubucketCore

/// Owns all refresh triggers beyond "popup just opened" (M1):
///
/// - `interval`: repeating timers — while the popup is open only visible-page
///   and pinned widgets with `refresh.interval` poll (min 5 s); while closed only
///   `runInBackground == true` widgets poll, at a 4× relaxed cadence (min 60 s).
///   Widgets promoted to the menu bar are exempt from both gates: their value is
///   on screen either way, so they poll at their configured cadence (min 1 s)
///   regardless of the `pauseWhenClosed` battery saver, which is about work
///   nobody can see.
/// - `deadline`: when an adapter returns `nextRefreshAtMs`, re-run exactly once
///   at that time while its page is visible. Timers are cancelled offscreen or
///   while the popup is closed and re-evaluated when visibility changes.
/// - `watch`: FSEvents on `refresh.watchPaths` (250 ms debounce). While the
///   popup is closed events only mark the widget pending; pending widgets are
///   refreshed when their page next becomes visible.
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
    /// Widgets on the selected page plus pinned widgets. Automatic work while
    /// the popup is open is restricted to this set.
    private var visibleWidgetIDs: Set<String> = []
    private var backoff: [String: BackoffState] = [:]
    private var intervalTimers: [String: Timer] = [:]
    private var deadlineTimers: [String: Timer] = [:]
    /// Pending adapter deadlines (epoch ms), survives popup close.
    private var deadlines: [String: Double] = [:]
    private var watchers: [String: DirectoryWatcher] = [:]
    /// Automatic work deferred while its widget is offscreen (or while the
    /// popup is closed and the widget is not background-capable).
    private var pendingAutomaticEvents: Set<String> = []
    private var wakeObserver: NSObjectProtocol?
    private var refreshMultiplier: Double = 1
    private var pauseWhenClosed = false
    /// Widgets drawn in the menu bar. Their value is on screen whether or not
    /// the popup is open, so they poll at their own cadence in both states —
    /// the visibility and `runInBackground` gates exist to spare *hidden*
    /// widgets, which these are not.
    private var menuBarWidgetIDs: Set<String> = []
    /// Whether App Nap is currently being held off. Test surface: the
    /// assertion itself is opaque, and "does a promoted widget keep polling"
    /// is not something a unit test can observe.
    var holdsActivityAssertion: Bool { activityAssertion != nil }

    /// Non-nil while a widget is in the menu bar; see `updateActivityAssertion`.
    private var activityAssertion: NSObjectProtocol?

    // MARK: R12 event triggers (`refresh.triggers`)

    /// Widget ids declaring the `wake` / `popup-open` triggers.
    private var wakeTriggerIDs: Set<String> = []
    private var popupOpenTriggerIDs: Set<String> = []
    /// `fs` trigger watchers (one per widget, 2 s coalesced), keyed by id.
    private var triggerWatchers: [String: DirectoryWatcher] = [:]
    /// Last automatic refresh the scheduler issued per widget — the spacing
    /// reference that stops event triggers double-firing alongside interval
    /// polling / debounces repeated popup-open triggers.
    private var lastAutoRefreshAt: [String: Date] = [:]

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
            // `wake`-trigger widgets refresh explicitly (spacing-gated) even
            // when they carry no interval / staleness config.
            for id in self.wakeTriggerIDs {
                self.fireTrigger(id, minSpacing: SchedulePolicy.triggerMinSpacingSec)
            }
        }
    }

    deinit {
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        if let activityAssertion {
            ProcessInfo.processInfo.endActivity(activityAssertion)
        }
        for timer in intervalTimers.values { timer.invalidate() }
        for timer in deadlineTimers.values { timer.invalidate() }
        for watcher in watchers.values { watcher.cancel() }
        for watcher in triggerWatchers.values { watcher.cancel() }
    }

    // MARK: - Configuration (widget set changed)

    func configure(widgets: [LoadedWidget]) {
        self.widgets = widgets
        let liveIDs = Set(widgets.map(\.id))
        backoff = backoff.filter { liveIDs.contains($0.key) }
        deadlines = deadlines.filter { liveIDs.contains($0.key) }
        lastAutoRefreshAt = lastAutoRefreshAt.filter { liveIDs.contains($0.key) }
        visibleWidgetIDs.formIntersection(liveIDs)
        menuBarWidgetIDs.formIntersection(liveIDs)
        // `setMenuBarWidgetIDs` normally owns this transition, but a reload
        // or disable removes ids directly during configuration.  Release the
        // assertion here too; otherwise the now-empty promoted set can keep
        // this accessory app out of App Nap for the rest of its lifetime.
        updateActivityAssertion()
        pendingAutomaticEvents.formIntersection(liveIDs)
        rebuildIntervalTimers()
        rebuildDeadlineTimers()
        rebuildWatchers()
        rebuildTriggers()
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

    /// Updates page visibility without changing the configured widget set.
    /// Switching pages re-arms only the timers needed by the newly visible
    /// widgets and drains automatic work that was deferred while offscreen.
    func setVisibleWidgetIDs(_ ids: Set<String>) {
        let liveIDs = Set(widgets.map(\.id))
        let normalized = ids.intersection(liveIDs)
        guard normalized != visibleWidgetIDs else { return }
        visibleWidgetIDs = normalized
        guard popupIsOpen else { return }
        rebuildIntervalTimers()
        rebuildDeadlineTimers()
        flushVisiblePendingEvents()
    }

    /// Updates the promoted set. Timers are re-armed because promotion changes
    /// a widget's effective interval in both popup states.
    /// Per-widget refresh intervals the user chose for menu bar items.
    private(set) var intervalOverrides: [String: Double] = [:]

    /// Applies only while a widget is promoted: the override is a menu bar
    /// setting, so an unpromoted widget on an open shelf keeps its own cadence.
    func setIntervalOverrides(_ overrides: [String: Double]) {
        guard overrides != intervalOverrides else { return }
        intervalOverrides = overrides
        rebuildIntervalTimers()
    }

    /// The first fire of a repeating timer, on a whole multiple of its interval
    /// since the reference date.
    ///
    /// Timers armed at arbitrary moments wake the process at arbitrary moments:
    /// a 2 s and a 3 s item started 0.4 s apart never fire together. Put on a
    /// shared clock they coincide every 6 s, and items with the same interval
    /// always do — one wakeup instead of several for an app that is awake all
    /// day. The first tick may come early, never late.
    static func alignedFireDate(interval: TimeInterval, now: Date = Date()) -> Date {
        let t = now.timeIntervalSinceReferenceDate
        let next = (floor(t / interval) + 1) * interval
        return Date(timeIntervalSinceReferenceDate: next)
    }

    func setMenuBarWidgetIDs(_ ids: Set<String>) {
        let liveIDs = Set(widgets.map(\.id))
        let normalized = ids.intersection(liveIDs)
        guard normalized != menuBarWidgetIDs else { return }
        menuBarWidgetIDs = normalized
        updateActivityAssertion()
        rebuildIntervalTimers()
        flushPromotedPendingEvents()
    }

    /// Holds App Nap off while anything is drawn in the menu bar.
    ///
    /// An accessory app with no windows is exactly what App Nap is for, and it
    /// took this one: the process ran at low priority (`ps` shows `SN`) and a
    /// two-second repeating timer fired about once every eight seconds. The
    /// menu bar reading then sat at whatever it last managed to compute, which
    /// is worse than showing nothing.
    ///
    /// Scoped to promotion rather than taken for the whole process life: with
    /// an empty menu bar there is nothing on screen to keep current, and the
    /// app should nap like any other. `allowingIdleSystemSleep` because this
    /// is about not being throttled, not about keeping the Mac awake.
    private func updateActivityAssertion() {
        let wanted = !menuBarWidgetIDs.isEmpty
        if wanted, activityAssertion == nil {
            activityAssertion = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep],
                reason: "Showing live widget values in the menu bar"
            )
        } else if !wanted, let assertion = activityAssertion {
            ProcessInfo.processInfo.endActivity(assertion)
            activityAssertion = nil
        }
    }

    /// Test/diagnostic surface for verifying that offscreen widgets do not own
    /// interval timers. Kept internal so it is not part of the public API.
    var activeIntervalWidgetIDs: Set<String> {
        Set(intervalTimers.keys)
    }

    // MARK: - Popup lifecycle

    func popupOpened() {
        popupIsOpen = true
        rebuildIntervalTimers()
        rebuildDeadlineTimers() // re-evaluate deadlines (fire overdue ones)
        flushVisiblePendingEvents()
        // `popup-open` triggers: debounced ≥5 s per widget (uses the shared
        // last-refresh reference, so a burst of opens fires at most once).
        for id in popupOpenTriggerIDs {
            fireTrigger(id, minSpacing: SchedulePolicy.popupOpenTriggerDebounceSec)
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
            if widget.manifest.refresh?.popupOnly == true { continue }
            let promoted = menuBarWidgetIDs.contains(widget.id)
            if popupIsOpen, !promoted, !visibleWidgetIDs.contains(widget.id) { continue }
            let configured = promoted
                ? (intervalOverrides[widget.id] ?? widget.manifest.refresh?.interval)
                : widget.manifest.refresh?.interval
            guard let interval = SchedulePolicy.effectiveInterval(
                configured: configured,
                popupOpen: popupIsOpen,
                runInBackground: widget.manifest.refresh?.runInBackground ?? false,
                multiplier: refreshMultiplier,
                pauseWhenClosed: pauseWhenClosed,
                menuBarPromoted: promoted
            ) else { continue }

            let id = widget.id
            let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                self?.fireAutomatic(id)
            }
            timer.fireDate = Self.alignedFireDate(interval: interval)
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
        guard let widget = widgets.first(where: { $0.id == widgetID }),
              popupIsOpen,
              visibleWidgetIDs.contains(widgetID),
              widget.manifest.refresh?.popupOnly != true,
              let deadlineMs = deadlines[widgetID]
        else { return }

        let fireDate = Date(timeIntervalSince1970: deadlineMs / 1000)
        let delay = max(fireDate.timeIntervalSinceNow, 0.05)
        let timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.deadlineTimers.removeValue(forKey: widgetID)
            self.deadlines.removeValue(forKey: widgetID) // exactly once
            self.fireAutomatic(widgetID)
        }
        deadlineTimers[widgetID] = timer
    }

    // MARK: - Watch trigger (FSEvents)

    private func rebuildWatchers() {
        for watcher in watchers.values { watcher.cancel() }
        watchers.removeAll()

        for widget in widgets {
            if widget.manifest.refresh?.popupOnly == true { continue }
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
                NSLog("barshelf: failed to watch paths for \(id): \(error)")
            }
        }
    }

    private func watchFired(widgetID: String) {
        fireAutomatic(widgetID)
    }

    // MARK: - Event triggers (`refresh.triggers`)

    /// Records an automatic refresh's time (spacing reference) and forwards it.
    private func fireAutomatic(_ id: String, now: Date = Date()) {
        guard automaticRefreshEligible(widgetID: id) else {
            pendingAutomaticEvents.insert(id)
            return
        }
        lastAutoRefreshAt[id] = now
        requestRefresh?(id, false)
    }

    private func automaticRefreshEligible(widgetID: String) -> Bool {
        guard let widget = widgets.first(where: { $0.id == widgetID }) else { return false }
        // `popupOnly` disables every automatic path. Timer/watch/trigger
        // construction already skips these widgets, so this only guards the
        // invariant against a future caller.
        if widget.manifest.refresh?.popupOnly == true { return false }
        if menuBarWidgetIDs.contains(widgetID) {
            // Promoted widgets are on screen in both popup states, and the
            // battery saver is about work nobody can see. Pausing one left a
            // menu bar reading frozen at whatever it happened to say.
            return true
        }
        if popupIsOpen {
            return visibleWidgetIDs.contains(widgetID)
        }
        return !pauseWhenClosed && widget.manifest.refresh?.runInBackground == true
    }

    private func flushVisiblePendingEvents() {
        let ready = pendingAutomaticEvents.intersection(visibleWidgetIDs)
        pendingAutomaticEvents.subtract(ready)
        for id in ready {
            fireAutomatic(id)
        }
    }

    /// Drains work deferred while a widget was hidden, once promotion makes it
    /// eligible again.
    private func flushPromotedPendingEvents() {
        let ready = pendingAutomaticEvents.intersection(menuBarWidgetIDs)
        pendingAutomaticEvents.subtract(ready)
        for id in ready {
            fireAutomatic(id)
        }
    }

    /// Fires an event-triggered refresh only when it clears `minSpacing` from
    /// the widget's last automatic refresh (no double-fire with interval /
    /// debounce of repeated triggers). Spacing math lives in `SchedulePolicy`.
    private func fireTrigger(_ id: String, minSpacing: Double, now: Date = Date()) {
        guard SchedulePolicy.triggerAllowed(
            lastRefreshAt: lastAutoRefreshAt[id], now: now, minSpacing: minSpacing
        ) else { return }
        fireAutomatic(id, now: now)
    }

    private func rebuildTriggers() {
        for watcher in triggerWatchers.values { watcher.cancel() }
        triggerWatchers.removeAll()
        wakeTriggerIDs.removeAll()
        popupOpenTriggerIDs.removeAll()

        for widget in widgets {
            if widget.manifest.refresh?.popupOnly == true { continue }
            guard let triggers = widget.manifest.refresh?.triggers, !triggers.isEmpty else { continue }
            let id = widget.id
            var fsPaths: [String] = []
            for trigger in triggers {
                switch trigger {
                case .wake: wakeTriggerIDs.insert(id)
                case .popupOpen: popupOpenTriggerIDs.insert(id)
                case .url: break // routed via the barshelf://refresh deep link
                case let .fs(path): fsPaths.append(path)
                }
            }
            guard !fsPaths.isEmpty else { continue }
            do {
                triggerWatchers[id] = try DirectoryWatcher(
                    paths: fsPaths,
                    debounce: SchedulePolicy.fsTriggerCoalesceSec
                ) { [weak self] in
                    self?.triggerWatchFired(widgetID: id)
                }
            } catch {
                NSLog("barshelf: failed to arm fs trigger for \(id): \(error)")
            }
        }
    }

    private func triggerWatchFired(widgetID: String) {
        fireTrigger(widgetID, minSpacing: SchedulePolicy.triggerMinSpacingSec)
    }
}
