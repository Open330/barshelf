import Foundation
import MenubucketCore

/// The runtime's side of the coordinator: what it asks about a widget
/// before a refresh may go on, and what the end of a refresh sets off.
@MainActor
protocol NativeRefreshCoordinatorHost: AnyObject {
    /// Whether the widget is switched off.
    func isDisabled(_ widgetID: String) -> Bool
    /// Where the widget's current permission set stands.
    func permissionStatus(for manifest: Manifest) -> PermissionStore.Status
    /// The widget as it is loaded now; nil when it is gone.
    func loadedWidget(_ widgetID: String) -> LoadedWidget?
    /// The widget's refresh ended with no outcome to record.
    func forgetRefreshStart(widgetID: String)
    /// The widget's card stops showing that it is loading.
    func refreshStoppedLoading(widgetID: String)
    /// An automatic refresh of a widget whose configuration changed under
    /// the refresh that just ended.
    func rerunRefresh(_ widget: LoadedWidget)
    /// The manual refresh that waited for the one that just ended.
    func refreshAgain(widgetID: String)
}

/// Which refresh is running for each widget, and whether its result still
/// counts when it ends.
///
/// Owns the in-flight set every kind of refresh shares (exec, workflow and
/// script), the manual requests waiting for a running refresh to end, and,
/// for the native kinds (exec and workflow), the gate their tokens come
/// from and the task behind each. Applying a result that counts is the
/// runtime's.
///
/// Main-actor isolated, like the runtime it reports to.
@MainActor
final class NativeRefreshCoordinator {
    /// Runs `work` on a later main-queue turn.
    typealias Deferral = (_ work: @escaping @MainActor @Sendable () -> Void) -> Void

    /// The runtime. Weak: the runtime owns the coordinator. With none, no
    /// refresh may continue and nothing is run again.
    weak var host: NativeRefreshCoordinatorHost?

    private var inFlight: Set<String> = []
    /// Manual refreshes that arrived while that widget was already refreshing.
    /// They used to be dropped, so a change that lands mid-refresh (a vault
    /// unlocking, a button's action) showed only on the next timer or open.
    private var refreshAgain: Set<String> = []
    private var gate = NativeRefreshGate()
    /// The task behind each in-flight exec/workflow refresh. Revoke, Deny,
    /// Disable and reload cancel it, so the process it is waiting on is
    /// cancelled too instead of only having its result ignored.
    private var tasks: [String: (token: NativeRefreshGate.Token, task: Task<Void, Never>)] = [:]
    private let runLater: Deferral

    /// - Parameter runLater: Nil is the main queue's next turn.
    init(runLater: Deferral? = nil) {
        if let runLater {
            self.runLater = runLater
        } else {
            self.runLater = { work in DispatchQueue.main.async { work() } }
        }
    }

    // MARK: - In flight

    /// Whether a refresh of the widget is running.
    func isInFlight(_ widgetID: String) -> Bool {
        inFlight.contains(widgetID)
    }

    /// In-flight coalescing: true when a refresh of the widget is already
    /// running, so this one must not start. A manual request runs once more
    /// when the running one ends.
    func joinsRunningRefresh(_ widgetID: String, manual: Bool) -> Bool {
        guard inFlight.contains(widgetID) else { return false }
        if manual { refreshAgain.insert(widgetID) }
        return true
    }

    /// A refresh with no token of its own (a script load) starts.
    func markInFlight(_ widgetID: String) {
        inFlight.insert(widgetID)
    }

    /// Ends a refresh; runs the one manual request that waited for it, if any.
    func endInFlight(_ widgetID: String) {
        inFlight.remove(widgetID)
        guard refreshAgain.remove(widgetID) != nil else { return }
        runLater { [weak self] in self?.host?.refreshAgain(widgetID: widgetID) }
    }

    /// The widget was stopped: it is no longer refreshing, and the manual
    /// request that waited is dropped with it.
    func endWithoutRerun(_ widgetID: String) {
        inFlight.remove(widgetID)
        refreshAgain.remove(widgetID) // stopped: no follow-up run
    }

    /// These widgets' refreshes were released elsewhere (script loads
    /// cancelled by a rescan). A manual request that waited for one runs
    /// now when the widget is still there — what it waited for will never
    /// end — and is dropped with a widget that is gone. Left behind, it
    /// fired as an extra refresh after some later, unrelated one.
    func releaseInFlight(_ widgetIDs: Set<String>, live liveIDs: Set<String>) {
        for id in widgetIDs {
            if liveIDs.contains(id) { endInFlight(id) } else { endWithoutRerun(id) }
        }
    }

    /// Forgets the refreshes of widgets that are gone, and the manual
    /// requests that waited for them.
    func forgetInFlight(notIn liveIDs: Set<String>) {
        inFlight.formIntersection(liveIDs)
        refreshAgain.formIntersection(liveIDs)
    }

    // MARK: - A native refresh

    /// A native refresh of the widget starts; its token tells its result
    /// from a later refresh's.
    func begin(_ widgetID: String) -> NativeRefreshGate.Token {
        let token = gate.begin(widgetID)
        inFlight.insert(widgetID)
        return token
    }

    /// Keeps the task of the refresh started under `token`, so stopping the
    /// widget cancels it.
    func track(_ task: Task<Void, Never>, for widgetID: String, token: NativeRefreshGate.Token) {
        tasks[widgetID] = (token, task)
    }

    /// The task of the widget's native refresh, while it is running.
    func task(for widgetID: String) -> Task<Void, Never>? {
        tasks[widgetID]?.task
    }

    /// Whether `token` is still the widget's refresh, under the
    /// configuration it started with.
    func isCurrent(_ widgetID: String, token: NativeRefreshGate.Token) -> Bool {
        gate.isCurrent(widgetID, token: token)
    }

    /// Whether a native refresh started under `token` may launch its next
    /// command or perform its next side effect. The refresh task starts on a
    /// later main-actor turn and suspends between sources, so a Revoke, Deny,
    /// Disable or reload can land before the first launch or between two.
    ///
    /// Refreshes run off the main actor; the gate, the preferences and the
    /// permission store are main-actor state. Reading them from the refresh's
    /// own thread raced with the main thread changing them (a crash in
    /// `Dictionary` lookup under `NativeRefreshGate.isCurrent`), so the
    /// refreshers ask for this on the main actor.
    func mayContinue(_ widget: LoadedWidget, token: NativeRefreshGate.Token) -> Bool {
        guard !Task.isCancelled, gate.isCurrent(widget.id, token: token), let host else { return false }
        return !host.isDisabled(widget.id)
            && host.permissionStatus(for: widget.manifest) == .approved
    }

    /// Releases what the refresh started under `token` held; true when its
    /// result still counts. One that was stopped or replaced meanwhile is
    /// dropped; one whose widget was reloaded with a new configuration is
    /// dropped and run again.
    func finish(_ widgetID: String, token: NativeRefreshGate.Token) -> Bool {
        if tasks[widgetID]?.token == token { tasks.removeValue(forKey: widgetID) }
        switch gate.finish(widgetID, token: token) {
        case .superseded:
            return false
        case .staleConfiguration:
            endInFlight(widgetID)
            host?.forgetRefreshStart(widgetID: widgetID)
            if let host, let current = host.loadedWidget(widgetID), !host.isDisabled(widgetID) {
                host.refreshStoppedLoading(widgetID: widgetID)
                host.rerunRefresh(current)
            }
            return false
        case .current:
            endInFlight(widgetID)
            return true
        }
    }

    // MARK: - Stopping

    /// Cancels the widget's native refresh: its task, and its token, so
    /// its result is dropped when it ends.
    func cancel(_ widgetID: String) {
        tasks.removeValue(forKey: widgetID)?.task.cancel()
        gate.cancel(widgetID)
    }

    /// After a rescan: cancels the native refreshes of widgets that are
    /// gone (not in `liveIDs`) or whose configuration changed
    /// (`changedIDs`). A changed widget's refresh is run again when it ends.
    func reload(keeping liveIDs: Set<String>, changed changedIDs: Set<String>) {
        for (id, entry) in tasks where !liveIDs.contains(id) || changedIDs.contains(id) {
            entry.task.cancel()
            tasks.removeValue(forKey: id)
        }
        gate.reload(keeping: liveIDs, changed: changedIDs)
    }
}
