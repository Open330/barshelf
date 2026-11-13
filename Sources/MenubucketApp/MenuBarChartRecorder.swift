import Foundation
import MenubucketCore

/// The short history of readings behind each menu bar item's chart, and the
/// file that carries it across a relaunch.
///
/// Main-actor isolated: the histories are only ever touched from the
/// runtime's main-actor code and from the save timer, which is scheduled on
/// the main run loop.
@MainActor
final class MenuBarChartRecorder {
    /// Beside refresh-stats.json, outside the per-widget snapshot cache,
    /// whose `<id>.json` names a widget id could collide with.
    nonisolated static var defaultFileURL: URL {
        BarShelfDirectories.applicationSupport.appendingPathComponent("menu-bar-charts.json")
    }
    nonisolated static let defaultSaveInterval: TimeInterval = MenuBarChartHistoryStore.saveInterval

    private let fileURL: URL
    private let saveInterval: TimeInterval
    /// Recent readings of each charting item, oldest first.
    private(set) var histories: [String: MenuBarChartHistory] = [:]
    /// Widgets with a snapshot the chart has not taken a point from yet.
    private var pending: Set<String> = []
    private var lastSaved: [String: MenuBarChartHistory] = [:]
    private var saveTimer: Timer?

    /// The widgets whose output must not touch disk, asked at every save.
    /// `nil` — nobody to ask — saves nothing rather than everything.
    var sensitiveWidgetIDs: () -> Set<String>? = { nil }

    init(
        fileURL: URL = MenuBarChartRecorder.defaultFileURL,
        saveInterval: TimeInterval = MenuBarChartRecorder.defaultSaveInterval
    ) {
        self.fileURL = fileURL
        self.saveInterval = saveInterval
    }

    /// Whether the periodic save is scheduled.
    var isSaving: Bool { saveTimer != nil }

    /// Takes up what the last run saved, if it is recent enough to join onto.
    func restore() {
        histories = MenuBarChartHistoryStore.load(from: fileURL)
    }

    /// The widget has a new reading its chart has not taken a point from.
    func markPending(_ widgetID: String) {
        pending.insert(widgetID)
    }

    /// `entry` carrying its widget's history, after taking a point from it
    /// if the widget was marked pending.
    func charting(_ entry: MenuBarEntry) -> MenuBarEntry {
        let id = entry.widgetID
        // A new snapshot adds a point; a sync for any other reason
        // (a settings change, the staleness tick) must not repeat it.
        if pending.remove(id) != nil, let sample = MenuBarPolicy.chartSample(entry) {
            histories[id] = MenuBarPolicy.recordingChart(
                histories[id], sample, at: SleepAwareClock.now()
            )
        }
        return MenuBarPolicy.applyingChart(entry, history: histories[id])
    }

    /// Drops the history of every widget that is neither in `charting` nor
    /// kept by `keeping`, and the pending mark of every widget not in
    /// `charting`.
    func prune(charting: Set<String>, keeping: (String) -> Bool) {
        histories = histories.filter { id, _ in
            charting.contains(id) || keeping(id)
        }
        pending.formIntersection(charting)
    }

    /// Graphs pick up where they were after a relaunch — an in-app update
    /// included — instead of starting empty. Saved on a timer as well as at
    /// quit: an update starts the new build *before* the old one quits, and
    /// `barshelf upgrade` stops the app with a signal that runs no quit
    /// handlers, so a save at quit alone would never reach the next run.
    /// Widgets whose output must not touch disk are left out.
    func save() {
        guard let sensitive = sensitiveWidgetIDs() else { return }
        let kept = histories.filter { !sensitive.contains($0.key) }
        guard kept != lastSaved else { return }
        do {
            try MenuBarChartHistoryStore.save(kept, to: fileURL)
            lastSaved = kept
        } catch {
            // Leave it dirty: transient I/O failures must retry at the next
            // maintenance tick rather than being mistaken for a saved history.
        }
    }

    /// Runs the periodic save while there is a history to save; with none,
    /// stops it and saves once.
    func updateSaver() {
        guard !histories.isEmpty else {
            saveTimer?.invalidate()
            saveTimer = nil
            save()
            return
        }
        guard saveTimer == nil else { return }
        // `assumeIsolated` holds because the timer is added to the main run
        // loop, from a main-actor method: it only ever fires on the main thread.
        let timer = Timer(timeInterval: saveInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.save() }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        saveTimer = timer
    }
}
