import AppKit
import MenubucketCore

/// What the promoter reads from the runtime, and nothing else: enough to
/// decide which widgets the menu bar owns and how each is drawn. Read-only,
/// so the promoter can be tested against a stand-in without a
/// `WidgetRuntime`.
@MainActor
protocol MenuBarPromoterSource: AnyObject {
    /// In the runtime's own order: the last tie-break among candidates.
    var widgets: [LoadedWidget] { get }
    var snapshots: [String: WidgetSnapshot] { get }
    func isDisabled(_ widgetID: String) -> Bool
    func permissionStatus(for manifest: Manifest) -> PermissionStore.Status
    /// The widget's placement as stored, resolved against its manifest.
    func menuBarPlacement(for widget: LoadedWidget) -> MenuBarPlacement
    /// The app-wide menu bar style.
    var globalMenuBarPresentation: MenuBarPresentation? { get }
    /// The one staleness rule for a reading (`WidgetRuntime.readingIsStale`).
    func readingIsStale(_ widget: LoadedWidget, updatedAt: Date?, now: Date) -> Bool
    /// The widgets whose output must not touch disk: sensitive by manifest
    /// or by what they last rendered.
    var sensitiveWidgetIDs: Set<String> { get }
}

/// What one sync leaves for the runtime to act on: the scheduler and the
/// first refresh of a newly promoted widget are the runtime's, not the
/// promoter's.
struct MenuBarSyncResult: Equatable {
    /// Every widget the menu bar owns after the sync, dormant ones included.
    var ownedWidgetIDs: Set<String>
    /// Owned now and not before the sync.
    var newlyOwnedWidgetIDs: Set<String>
    /// Whether the owned set differs from the one before the sync; losing an
    /// id is a change too.
    var ownedSetChanged: Bool
    /// The refresh interval each candidate's menu bar item asks for. Every
    /// candidate with one, including those past the cap.
    var intervalOverrides: [String: Double]
}

/// Decides what the menu bar draws: which widgets it owns, in what order,
/// which of those are hidden by their "show only when" threshold, and the
/// chart each carries. Owns that state and the store the menu bar observes.
///
/// Main-actor isolated, like the runtime it reads and the store it applies
/// to.
@MainActor
final class MenuBarPromoter {
    /// Whether a name is an SF Symbol, as AppKit answers it.
    nonisolated static let defaultIsSymbolName: @Sendable (String) -> Bool = {
        NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil
    }

    /// Live menu bar entries: the owned ones that are not dormant.
    let menuBar: MenuBarStatusStore
    /// The chart histories; `nil` at init means one at the shipped location.
    private let chartRecorder: MenuBarChartRecorder
    private let isSymbolName: (String) -> Bool
    /// The runtime. Weak: the runtime owns the promoter. With none, a sync
    /// sees no widgets and nothing is saved.
    weak var source: MenuBarPromoterSource?

    /// Every entry the menu bar owns, in order and capped: drawn now, or
    /// hidden by its "show only when" threshold.
    private(set) var ownedEntries: [MenuBarEntry] = []
    /// The owned entries hidden for now by their "show only when" threshold.
    private(set) var dormantWidgetIDs: Set<String> = []
    /// When each "show only when" item last qualified, and how long it
    /// stays after that.
    private var showWhenHold: MenuBarShowWhenHold
    /// When the menu bar is synced again without anyone asking: the batch
    /// behind a burst of new readings, and the staleness tick.
    private let syncDriver: MenuBarSyncDriver

    init(
        menuBar: MenuBarStatusStore = MenuBarStatusStore(),
        chartRecorder: MenuBarChartRecorder? = nil,
        showWhenHold: MenuBarShowWhenHold = MenuBarShowWhenHold(),
        syncDriver: MenuBarSyncDriver? = nil,
        isSymbolName: @escaping (String) -> Bool = MenuBarPromoter.defaultIsSymbolName
    ) {
        self.menuBar = menuBar
        // Not `??`: its right side is a nonisolated autoclosure, and the
        // recorder's initializer is main-actor isolated.
        let chartRecorder = if let chartRecorder { chartRecorder } else { MenuBarChartRecorder() }
        self.chartRecorder = chartRecorder
        self.showWhenHold = showWhenHold
        // Not `??`, as above.
        if let syncDriver { self.syncDriver = syncDriver } else { self.syncDriver = MenuBarSyncDriver() }
        self.isSymbolName = isSymbolName
        chartRecorder.sensitiveWidgetIDs = { [weak self] in
            self?.source?.sensitiveWidgetIDs
        }
    }

    /// Every widget the menu bar owns: on it now, or waiting for a reading
    /// that brings it back. These are the ones that keep polling.
    var ownedWidgetIDs: Set<String> {
        Set(ownedEntries.map(\.widgetID))
    }

    // MARK: - Charts

    /// Recent readings of each charting item, oldest first.
    var chartHistories: [String: MenuBarChartHistory] { chartRecorder.histories }

    /// Takes up the chart histories the last run saved, and starts the
    /// periodic save if there is anything to keep saving.
    func restoreCharts() {
        chartRecorder.restore()
        chartRecorder.updateSaver()
    }

    /// The widget has a new reading its chart has not taken a point from.
    func markPending(_ widgetID: String) {
        chartRecorder.markPending(widgetID)
    }

    /// Writes the chart histories now: at quit, and when a widget turns
    /// sensitive and its history must leave the disk.
    func saveCharts() {
        chartRecorder.save()
    }

    // MARK: - When to sync

    /// What a batched sync and the staleness tick call: the runtime's
    /// `syncMenuBar`, which runs `sync(now:)` and then its own follow-up.
    /// They never call `sync(now:)` directly, or that follow-up would be
    /// skipped.
    var onSyncNeeded: () -> Void {
        get { syncDriver.onSyncNeeded }
        set { syncDriver.onSyncNeeded = newValue }
    }

    /// Whether a batched sync is queued.
    var hasPendingSync: Bool { syncDriver.hasPendingSync }
    /// Whether the staleness tick is running.
    var isStalenessTicking: Bool { syncDriver.isTicking }

    /// Card loading/layout changes do not affect a status item. Avoid rebuilding
    /// every promoted entry (including symbol lookup and chart policy) for them.
    nonisolated static func snapshotAffectsMenuBar(
        from previous: WidgetSnapshot?, to current: WidgetSnapshot
    ) -> Bool {
        guard let previous else { return true }
        return previous.updatedAt != current.updatedAt || previous.error != current.error
            || previous.statusLabel != current.statusLabel || previous.statusMetrics != current.statusMetrics
            || previous.statusPrefix != current.statusPrefix || previous.statusIcon != current.statusIcon
            || previous.statusTint != current.statusTint || previous.statusPresentation != current.statusPresentation
            || previous.statusTooltip != current.statusTooltip
            || previous.statusProblem != current.statusProblem
    }

    /// Whether a snapshot change is a new measurement, one a chart takes a
    /// point from. Loading/error-only changes are not: inserting those into
    /// chart history repeated the previous reading.
    nonisolated static func snapshotIsNewMeasurement(
        from previous: WidgetSnapshot?, to current: WidgetSnapshot
    ) -> Bool {
        previous?.updatedAt != current.updatedAt || previous?.statusMetrics != current.statusMetrics
            || previous?.statusLabel != current.statusLabel
    }

    /// A widget's snapshot changed from `previous` to `current`. If the menu
    /// bar owns the widget and the change shows there, a batched sync is
    /// requested; a new measurement is first marked for its chart.
    func snapshotChanged(id: String, from previous: WidgetSnapshot?, to current: WidgetSnapshot) {
        guard ownedWidgetIDs.contains(id),
              Self.snapshotAffectsMenuBar(from: previous, to: current) else { return }
        if Self.snapshotIsNewMeasurement(from: previous, to: current) {
            markPending(id)
        }
        syncDriver.requestSync()
    }

    /// Runs the staleness tick while the menu bar owns anything, and stops
    /// it otherwise. Every sync ends with this.
    func updateStalenessTicker() {
        syncDriver.updateTicker(hasOwnedEntries: !ownedEntries.isEmpty)
    }

    /// Stops the staleness tick for good; no later sync starts it again.
    /// A staged preview shows fixed readings, and a tick would come to dim
    /// them as stale while the frames are recorded.
    func endStalenessTicking() {
        syncDriver.endTicking()
    }

    // MARK: - Sync

    /// Recomputes what the menu bar owns and draws, applies it to the
    /// store, and reports what the runtime has to follow up on.
    ///
    /// An immediate sync supersedes a queued batched one, so that is
    /// dropped first; the staleness tick is settled last, against what is
    /// owned now.
    @discardableResult
    func sync(now: Date) -> MenuBarSyncResult {
        syncDriver.cancelPendingSync()
        let previous = ownedWidgetIDs
        let snapshots = source?.snapshots ?? [:]
        var candidates: [(entry: MenuBarEntry, order: Double?)] = []
        var intervalOverrides: [String: Double] = [:]
        var charting = Set<String>()

        if let source {
            for widget in source.widgets where !source.isDisabled(widget.id) {
                let placement = source.menuBarPlacement(for: widget)
                // Most widgets are not on the bar: the cheaper test first.
                guard placement.enabled,
                      source.permissionStatus(for: widget.manifest) == .approved else { continue }
                let snapshot = snapshots[widget.id]
                let built = MenuBarPolicy.buildEntry(MenuBarEntryInputs(
                    widgetID: widget.id,
                    name: widget.displayName,
                    manifestIcon: widget.manifest.icon,
                    statusItem: widget.manifest.statusItem,
                    placement: placement,
                    globalPresentation: source.globalMenuBarPresentation,
                    snapshot: snapshot,
                    isStale: source.readingIsStale(widget, updatedAt: snapshot?.updatedAt, now: now),
                    tooltip: snapshot?.error.map(WidgetRuntime.errorTooltip) ?? snapshot?.statusTooltip,
                    isSymbolName: isSymbolName
                ))
                if let interval = placement.interval { intervalOverrides[widget.id] = interval }
                var applied = built.entry
                if built.wantsChart {
                    applied = chartRecorder.charting(applied)
                    charting.insert(widget.id)
                }
                candidates.append((applied, placement.order))
            }
        }

        // A chart turned off, an item taken out of the bar, a widget
        // disabled or removed: its points go, so coming back starts afresh
        // instead of joining an hour-old line onto a new one.
        // A widget that has not rendered yet may take its chart from its
        // first render (`status.presentation`), so a history restored at
        // launch waits for that render before it can be judged unwanted.
        chartRecorder.prune(charting: charting) { id in
            snapshots[id]?.updatedAt == nil && candidates.contains { $0.entry.widgetID == id }
        }

        // "Show only when" items are ordered and capped like any other, then
        // left out of what is drawn: they keep their place in the strip and
        // their polling, so they notice when to come back.
        let owned = MenuBarPolicy.promoted(MenuBarPolicy.ordered(candidates))
        let dormant = showWhenHold.dormant(among: owned, now: now)
        ownedEntries = owned
        dormantWidgetIDs = dormant
        menuBar.apply(owned.filter { !dormant.contains($0.widgetID) })
        chartRecorder.updateSaver()
        updateStalenessTicker()

        let ownedIDs = ownedWidgetIDs
        return MenuBarSyncResult(
            ownedWidgetIDs: ownedIDs,
            newlyOwnedWidgetIDs: ownedIDs.subtracting(previous),
            ownedSetChanged: ownedIDs != previous,
            intervalOverrides: intervalOverrides
        )
    }
}
