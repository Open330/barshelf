import Foundation
import MenubucketCore

/// Generation-aware ownership for script refreshes. A widget may have only
/// one active load, and late completion from an older process/package cannot
/// release the newer generation that reused the same widget id.
struct ScriptRefreshCoalescer {
    private struct Entry {
        let generation: String
        var rendered = false
    }

    private var entries: [String: Entry] = [:]

    mutating func begin(widgetID: String, generation: String) -> Bool {
        guard entries[widgetID] == nil else { return false }
        entries[widgetID] = Entry(generation: generation)
        return true
    }

    mutating func markRendered(widgetID: String, generation: String) -> Bool {
        guard var entry = entries[widgetID], entry.generation == generation else {
            return false
        }
        entry.rendered = true
        entries[widgetID] = entry
        return true
    }

    /// Returns whether this generation rendered before it completed. Nil means
    /// the completion is stale or does not belong to an active host refresh.
    mutating func finish(widgetID: String, generation: String) -> Bool? {
        guard let entry = entries[widgetID], entry.generation == generation else {
            return nil
        }
        entries.removeValue(forKey: widgetID)
        return entry.rendered
    }

    mutating func cancel(widgetID: String, generation: String? = nil) -> Bool {
        guard let entry = entries[widgetID],
              generation == nil || entry.generation == generation
        else { return false }
        entries.removeValue(forKey: widgetID)
        return true
    }

    mutating func cancelAll() -> Set<String> {
        let widgetIDs = Set(entries.keys)
        entries.removeAll()
        return widgetIDs
    }
}

/// Thread-safe invalidation tokens for callbacks crossing from the script
/// supervisor to the main actor.  A queued render from a process stopped by a
/// disable must not be applied if the widget is enabled again before the main
/// queue drains it.
final class ScriptCallbackGate: @unchecked Sendable {
    private let lock = NSLock()
    private var epochs: [String: UInt] = [:]

    func token(for widgetID: String) -> UInt {
        lock.withLock { epochs[widgetID, default: 0] }
    }

    func invalidate(widgetID: String) {
        lock.withLock { epochs[widgetID, default: 0] &+= 1 }
    }

    func accepts(widgetID: String, token: UInt) -> Bool {
        lock.withLock { epochs[widgetID, default: 0] == token }
    }
}

/// Which script widgets may keep their `host.timer.*` timers running: the
/// facts the rule is decided from, and the rule.
struct ScriptTimerPolicy: Equatable {
    /// The "pause when closed" preference. Off, timers are unrestricted.
    var pauseWhenClosed: Bool
    /// Every widget the menu bar owns, dormant ones included.
    var menuBarWidgetIDs: Set<String> = []
    var dockWidgetIDs: Set<String> = []
    var shelfIsOpen = false
    /// Selected-page widgets plus pinned ones; they count while the shelf
    /// is open.
    var visibleWidgetIDs: Set<String> = []
    /// The widget whose card is open in its own menu bar popover, if any.
    var menuBarPopoverWidgetID: String?
    var disabledWidgetIDs: Set<String> = []

    /// Nil is unrestricted; a set allows only those widgets.
    var allowedWidgetIDs: Set<String>? {
        guard pauseWhenClosed else { return nil }
        var allowed = menuBarWidgetIDs.union(dockWidgetIDs)
        if shelfIsOpen { allowed.formUnion(visibleWidgetIDs) }
        if let id = menuBarPopoverWidgetID { allowed.insert(id) }
        return allowed.subtracting(disabledWidgetIDs)
    }
}

/// The runtime's side of the bridge: what the bridge asks before it lets an
/// event through, and where the events that pass go. Applying them — the
/// snapshot, sensitivity, the cache, the scheduler — is the runtime's.
@MainActor
protocol ScriptRuntimeBridgeHost: AnyObject {
    /// The facts the timer policy is decided from, as they are now.
    var scriptTimerPolicy: ScriptTimerPolicy { get }
    /// Whether the widget takes script events at all: not disabled, and not
    /// being stopped by a disable that has yet to finish.
    func acceptsScriptEvents(for widgetID: String) -> Bool
    /// The loaded, approved widget a render is for; nil when it does not
    /// take events, is gone, or is not approved.
    func scriptRenderTarget(for widgetID: String) -> LoadedWidget?

    /// A render from the current process; one that belongs to a load is of
    /// the generation in flight, and that load is now marked as rendered.
    func scriptDidRender(_ widget: LoadedWidget, params: RenderParams)
    /// The load in flight for the widget ended and its bookkeeping is
    /// released. `rendered` is whether it rendered before completing.
    func scriptLoadDidComplete(widgetID: String, rendered: Bool, error: String?)
    /// The widget's process changed state. A load still in flight is left
    /// for the runtime to cancel (`cancelRefresh`).
    func scriptStateDidChange(widgetID: String, state: ScriptWidgetState)
}

/// The bridge to the script runtime: owns the supervisor (created on first
/// use), the tokens that drop a stale callback, which script load is in
/// flight for each widget, and which widgets' timers may run.
///
/// Supervisor events arrive off the main actor. Each takes the widget's
/// callback token where it arrives, hops to the main queue, and is dropped
/// there unless the token still holds and the host still takes events for
/// the widget.
///
/// Main-actor isolated, like the runtime it reports to; only `callbackGate`
/// is read from elsewhere.
@MainActor
final class ScriptRuntimeBridge {
    typealias SupervisorFactory = @MainActor (
        RuntimeSupervisorConfiguration, RuntimeSupervisorEvents
    ) -> RuntimeSupervisor

    /// A weak reference the supervisor's event closures can carry off the
    /// main actor. Only `callbackGate` is touched there.
    private final class WeakBox: @unchecked Sendable {
        weak var value: ScriptRuntimeBridge?
        init(_ value: ScriptRuntimeBridge) { self.value = value }
    }

    /// The runtime. Weak: the runtime owns the bridge. With none, every
    /// event is dropped and the timer policy is left alone.
    weak var host: ScriptRuntimeBridgeHost?

    /// Invalidation tokens for everything queued on behalf of a widget.
    nonisolated let callbackGate = ScriptCallbackGate()

    private var supervisorStorage: RuntimeSupervisor?
    private let makeConfiguration: @MainActor () -> RuntimeSupervisorConfiguration
    private let makeSupervisor: SupervisorFactory
    private var refreshes = ScriptRefreshCoalescer()
    /// Counts the changes of the timer policy; the supervisor ignores one
    /// that arrives after a newer.
    private(set) var timerPolicyRevision: UInt = 0
    private var timerPolicyInitialized = false
    private var lastTimerAllowedIDs: Set<String>?

    /// - Parameters:
    ///   - supervisor: One made elsewhere (tests, with stub launch plans).
    ///     Its events are its maker's: it reports nothing to this bridge.
    ///   - makeConfiguration: Called once, when the supervisor is created.
    ///   - makeSupervisor: Nil is the shipped `RuntimeSupervisor`.
    init(
        supervisor: RuntimeSupervisor? = nil,
        makeConfiguration: @escaping @MainActor () -> RuntimeSupervisorConfiguration,
        makeSupervisor: SupervisorFactory? = nil
    ) {
        self.supervisorStorage = supervisor
        self.makeConfiguration = makeConfiguration
        if let makeSupervisor {
            self.makeSupervisor = makeSupervisor
        } else {
            self.makeSupervisor = { RuntimeSupervisor(configuration: $0, events: $1) }
        }
    }

    /// The shipped configuration: deno launch plans, and the host services
    /// scripts reach through `host.*`.
    static func denoConfiguration(
        stateDirectory: URL,
        storage: StorageService,
        secrets: SecretStoring,
        audit: AuditLog,
        permissionStore: PermissionStore,
        notificationService: NotificationService
    ) -> RuntimeSupervisorConfiguration {
        RuntimeSupervisorConfiguration(
            makeLaunchPlan: { widget in
                try DenoRuntime.makeLaunchPlan(
                    widget: widget,
                    stateDirectory: stateDirectory
                )
            },
            storage: storage,
            secrets: secrets,
            audit: audit,
            widgetLogs: WidgetLogStore(),
            locale: { WidgetLocalization.appLanguage },
            appearance: {
                UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
                    ? "dark"
                    : "light"
            },
            isApproved: { permissionStore.status(for: $0) == .approved },
            notifyAuthorized: { title, body, authorization in
                try await notificationService.show(title: title, body: body, authorization: authorization)
            }
        )
    }

    // MARK: - Supervisor

    /// The supervisor if there is one; never creates it.
    var existingSupervisor: RuntimeSupervisor? { supervisorStorage }

    /// Created on first script-widget use (deno-based launch plans injected;
    /// tests build their own supervisor with stub launch plans).
    var supervisor: RuntimeSupervisor {
        if let existing = supervisorStorage { return existing }
        let supervisor = makeSupervisor(makeConfiguration(), supervisorEvents)
        supervisorStorage = supervisor
        syncTimerActivity(force: true)
        return supervisor
    }

    /// What a supervisor this bridge creates is given. Each closure may be
    /// called from any thread.
    var supervisorEvents: RuntimeSupervisorEvents {
        let weakBridge = WeakBox(self)
        return RuntimeSupervisorEvents(
            onRender: { widgetId, params, revision in
                let token = weakBridge.value?.callbackGate.token(for: widgetId)
                DispatchQueue.main.async {
                    guard let token else { return }
                    weakBridge.value?.handleRender(
                        widgetId: widgetId,
                        params: params,
                        revision: revision,
                        callbackToken: token
                    )
                }
            },
            onLoadComplete: { widgetId, generation, error in
                let token = weakBridge.value?.callbackGate.token(for: widgetId)
                DispatchQueue.main.async {
                    guard let token else { return }
                    weakBridge.value?.handleLoadComplete(
                        widgetId: widgetId,
                        generation: generation,
                        error: error,
                        callbackToken: token
                    )
                }
            },
            onStateChange: { widgetId, state in
                let token = weakBridge.value?.callbackGate.token(for: widgetId)
                DispatchQueue.main.async {
                    guard let token else { return }
                    weakBridge.value?.handleStateChange(
                        widgetId: widgetId, state: state, callbackToken: token
                    )
                }
            },
            onWidgetLog: { widgetId, level, message in
                if level == "error" {
                    NSLog("barshelf[%@] %@: %@", widgetId, level, message)
                }
            }
        )
    }

    // MARK: - Loads in flight

    /// Claims the widget's one load slot for `generation`; false while
    /// another load holds it.
    func beginRefresh(widgetID: String, generation: String) -> Bool {
        refreshes.begin(widgetID: widgetID, generation: generation)
    }

    /// Releases the widget's load, if it has one (of `generation`, when
    /// given). Its late render or completion is then dropped.
    func cancelRefresh(widgetID: String, generation: String? = nil) -> Bool {
        refreshes.cancel(widgetID: widgetID, generation: generation)
    }

    /// Releases every load; returns the widgets that had one.
    func cancelAllRefreshes() -> Set<String> {
        refreshes.cancelAll()
    }

    // MARK: - Timer policy

    /// Which widgets' timers may run now; nil is unrestricted, as it is
    /// without a host.
    var allowedTimerWidgetIDs: Set<String>? {
        host?.scriptTimerPolicy.allowedWidgetIDs
    }

    /// Tells the supervisor which timers may run, when that changed since
    /// the last call (or `force`). Before a supervisor exists the change is
    /// only counted; `sendTimerActivity` delivers it with the first load.
    func syncTimerActivity(force: Bool = false) {
        guard let host else { return }
        let allowed = host.scriptTimerPolicy.allowedWidgetIDs
        guard force || !timerPolicyInitialized || lastTimerAllowedIDs != allowed else { return }
        timerPolicyInitialized = true
        lastTimerAllowedIDs = allowed
        timerPolicyRevision &+= 1
        guard let supervisor = supervisorStorage else { return }
        let revision = timerPolicyRevision
        Task { await supervisor.setTimerActivity(allowing: allowed, revision: revision) }
    }

    /// Sends the policy as it is now, under the current revision, and waits
    /// for the supervisor to take it: a load must not start under an older
    /// one.
    func sendTimerActivity(to supervisor: RuntimeSupervisor) async {
        await supervisor.setTimerActivity(allowing: allowedTimerWidgetIDs, revision: timerPolicyRevision)
    }

    // MARK: - Events

    private func handleRender(
        widgetId: String, params: RenderParams, revision: Int, callbackToken: UInt
    ) {
        guard callbackGate.accepts(widgetID: widgetId, token: callbackToken),
              let host,
              let widget = host.scriptRenderTarget(for: widgetId) else { return }
        if let generation = params.loadGeneration {
            guard refreshes.markRendered(widgetID: widgetId, generation: generation) else { return }
        }
        host.scriptDidRender(widget, params: params)
    }

    private func handleLoadComplete(
        widgetId: String, generation: String, error: String?, callbackToken: UInt
    ) {
        guard callbackGate.accepts(widgetID: widgetId, token: callbackToken),
              let host,
              host.acceptsScriptEvents(for: widgetId) else { return }
        guard let rendered = refreshes.finish(
            widgetID: widgetId, generation: generation
        ) else { return }
        host.scriptLoadDidComplete(widgetID: widgetId, rendered: rendered, error: error)
    }

    private func handleStateChange(
        widgetId: String, state: ScriptWidgetState, callbackToken: UInt
    ) {
        guard callbackGate.accepts(widgetID: widgetId, token: callbackToken),
              let host,
              host.acceptsScriptEvents(for: widgetId) else { return }
        host.scriptStateDidChange(widgetID: widgetId, state: state)
    }
}
