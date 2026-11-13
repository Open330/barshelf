import AppKit
import Combine
import Foundation
import MenubucketCore

private final class WeakWidgetRuntimeBox: @unchecked Sendable {
    weak var value: WidgetRuntime?

    init(_ value: WidgetRuntime) {
        self.value = value
    }
}

/// A discovered widget: manifest plus the directory it was loaded from.
struct LoadedWidget: Identifiable {
    let manifest: Manifest
    let directory: URL
    let instanceID: String
    /// Changes on every rescan so resident script processes cannot be reused
    /// across package/code/permission updates that keep the same widget id.
    let loadRevision: String

    init(
        manifest: Manifest,
        directory: URL,
        instanceID: String? = nil,
        loadRevision: String = UUID().uuidString
    ) {
        self.manifest = manifest
        self.directory = directory
        self.instanceID = instanceID ?? manifest.id
        self.loadRevision = loadRevision
    }

    var id: String { instanceID }
    var displayName: String {
        // In the app's language when the manifest carries a translation.
        let name = manifest.localizedName()
        let prefix = manifest.id + "--"
        guard instanceID.hasPrefix(prefix) else { return name }
        let label = String(instanceID.dropFirst(prefix.count))
        return label.isEmpty ? name : "\(name) · \(label)"
    }
    var group: String { manifest.bucket?.group ?? "General" }
    var order: Int { manifest.bucket?.order ?? 0 }
    var size: String { manifest.bucket?.size ?? "M" }

    /// Sensitive widgets never log stdout and never cache renders to disk.
    /// A vault widget always is: its card lists item names.
    var isSensitive: Bool {
        (manifest.permissions?.exec?.contains { $0.sensitiveOutput == true } ?? false)
            || manifest.permissions?.vault != nil
    }
}

/// One popup page = one bucket group.
struct WidgetPage: Identifiable {
    let group: String
    let widgets: [LoadedWidget]

    var id: String { group }
}

/// Per-widget observable state: only the card whose snapshot/overlay changed
/// re-renders (R05 perf) — `WidgetRuntime.objectWillChange` no longer fires on
/// snapshot updates, so one widget refreshing does not invalidate the whole
/// popup view tree.
final class WidgetCardModel: ObservableObject {
    @Published fileprivate(set) var snapshot: WidgetSnapshot
    @Published fileprivate(set) var overlay: CardOverlay?

    fileprivate init(snapshot: WidgetSnapshot, overlay: CardOverlay?) {
        self.snapshot = snapshot
        self.overlay = overlay
    }
}

/// A state the host shows *instead of* a widget's own content until it is
/// resolved. The runtime decides which one applies; `CardStateViews` draws it.
enum CardOverlay: Equatable {
    /// New or changed permissions waiting for the user's decision.
    case approvalNeeded([PermissionRequest])
    /// The user denied the current permission set; the widget does not run.
    case denied([PermissionRequest])
    /// A script widget kept crashing and was stopped.
    case disabled(reason: String)

    var needsApproval: Bool {
        if case .approvalNeeded = self { return true }
        return false
    }
}

/// One capability a widget asks for, as the approval card lists it.
struct PermissionRequest: Equatable, Hashable {
    let symbol: String
    let description: String
    /// The exact command lines behind the words, for "Details".
    var details: [String] = []
    /// Something that blocks the widget outright rather than a permission
    /// the user can grant.
    var isWarning = false
}

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

/// Loads manifests, delegates trigger scheduling to `Scheduler`, and publishes
/// per-widget snapshots.
///
/// Refresh triggers (M1): popup open (`refresh.onOpen` + staleness), manual,
/// interval, adapter deadline (`nextRefreshAtMs`), FSEvents watch, and system
/// wake. In-flight refreshes are coalesced; failures keep the last-good render
/// (surfaced via `snapshot.error`) and feed the exponential backoff.
/// Why a refresh the user asked for did not run.
enum RefreshRejection: Equatable {
    /// The widget is switched off.
    case disabled
    /// Nothing runs until its permissions are allowed.
    case waitingForPermission
    /// Made for a newer BarShelf than this one.
    case needsNewerBarShelf

    /// The toast's first line: what is in the way.
    func message(widgetName: String) -> String {
        switch self {
        case .disabled:
            return String(localized: "\(widgetName) is turned off")
        case .waitingForPermission:
            return String(localized: "\(widgetName) is waiting for your permission")
        case .needsNewerBarShelf:
            return String(localized: "\(widgetName) needs a newer BarShelf")
        }
    }

    /// The second line: what to do. Its presence also keeps the toast up
    /// long enough to read.
    var detail: String {
        switch self {
        case .disabled:
            return String(localized: "Turn it on in Settings to refresh it.")
        case .waitingForPermission:
            return String(localized: "Allow it on its card or in Privacy settings, then refresh.")
        case .needsNewerBarShelf:
            return String(localized: "Update BarShelf to refresh it.")
        }
    }
}

/// A toast the runtime raises for something the user did: a refresh that
/// was turned away, an action that failed.
struct RuntimeFeedback: Equatable {
    let message: String
    let detail: String?
    let tone: Toast.Tone
    let surface: ToastSurface
}

@MainActor
final class WidgetRuntime: ObservableObject {
    @Published private(set) var widgets: [LoadedWidget] = []
    /// Where `RuntimeFeedback` goes; tests replace it to observe.
    var feedback: (RuntimeFeedback) -> Void = { item in
        Task { @MainActor in
            ToastCenter.shared.show(item.message, detail: item.detail, tone: item.tone, on: item.surface)
        }
    }
    /// Feeds the macOS widget extension (R14); owns the publisher.
    private let desktopMirror: DesktopWidgetMirror
    /// Whether this build can put widgets on the desktop.
    var desktopWidgetsEnabled: Bool { desktopMirror.isEnabled }
    /// The on-disk render cache; owns its throttle state.
    private let snapshotCache = SnapshotDiskCache()
    /// Source of truth for renders. Deliberately *not* `@Published`: updates
    /// are routed to the affected widget's `WidgetCardModel` only (publish
    /// suppressed when the snapshot is unchanged, `Equatable`).
    private(set) var snapshots: [String: WidgetSnapshot] = [:]
    /// Host-generated cards rendered *instead of* the snapshot tree:
    /// permission approval prompts and crash-loop "Restart Widget" cards.
    /// Same publish routing as `snapshots`.
    private(set) var overlayCards: [String: CardOverlay] = [:]
    private var cardModels: [String: WidgetCardModel] = [:]
    /// Pinned widgets + per-widget settings overrides (user preferences).
    let prefs = WidgetPrefs()
    let appPrefs: AppPrefs
    /// Observed by the Monitoring pane only — see `RefreshStatsModel`.
    let refreshStats = RefreshStatsModel()
    /// Local-only counts of what gets opened and pressed (Settings ▸ Privacy).
    let usageStore: UsageStore
    /// Widgets already counted as seen since the shelf last opened, so a page
    /// flipped back and forth counts once.
    private var viewsCountedThisOpen: Set<String> = []
    /// Whether a widget is waiting on the user (approval, error). Observed by
    /// the status item's badge only.
    let attention = ShelfAttention()
    /// Widget id the UI should jump to and highlight (post-install reveal, R11).
    /// Consumers clear it after handling.
    @Published var pendingReveal: String?
    /// The page "add a widget here" was chosen on: the next widget installed
    /// lands there (`landNewWidgets`) until `until`.
    var newWidgetPage: (name: String, until: Date)?
    /// Live menu-bar text for promoted widgets. Observed by the menu bar only,
    /// so a 2 s status refresh never invalidates the popup's view tree.
    let menuBar = MenuBarStatusStore()

    nonisolated private let execService = ExecService()
    let scheduler = Scheduler()
    private let refreshStatsStore: RefreshStatsStore
    private var cancellables: Set<AnyCancellable> = []
    private var inFlight: Set<String> = []
    /// Manual refreshes that arrived while that widget was already refreshing.
    /// They used to be dropped, so a change that lands mid-refresh (a vault
    /// unlocking, a button's action) showed only on the next timer or open.
    private var refreshAgain: Set<String> = []
    private var nativeRefreshes = NativeRefreshGate()
    /// The task behind each in-flight exec/workflow refresh. Revoke, Deny,
    /// Disable and reload cancel it, so the process it is waiting on is
    /// cancelled too instead of only having its result ignored.
    private var nativeRefreshTasks: [String: (token: NativeRefreshGate.Token, task: Task<Void, Never>)] = [:]
    private var runActionTasks: [String: [UUID: Task<Void, Never>]] = [:]
    private var scriptRefreshes = ScriptRefreshCoalescer()
    nonisolated private let scriptCallbackGate = ScriptCallbackGate()
    /// Shutdowns started by Disable. Re-enable waits for this task so a late
    /// stop cannot terminate the newly launched process.
    private var scriptDisableStopTokens: [String: UInt] = [:]
    private var scriptReloadBarrier: Task<Void, Never>?
    private var scriptTimerPolicyRevision: UInt = 0
    private var scriptTimerPolicyInitialized = false
    private var lastScriptTimerAllowedIDs: Set<String>?
    /// Selected-page widgets plus pinned widgets. Automatic refresh and
    /// permission-triggering work is lazy outside this set.
    private(set) var visibleWidgetIDs: Set<String> = []
    private var refreshStartedAt: [String: Date] = [:]
    private var hotReloadWatchers: [DirectoryWatcher] = []
    /// Re-evaluates menu-bar staleness on a slow tick. Without it a widget that
    /// stopped refreshing (battery saver, a crash-looping script) would keep
    /// showing its last value at full contrast forever.
    private var menuBarStalenessTimer: Timer?
    /// `fs.directory` sources with `watch: true`, keyed by widget id.
    private var workflowWatchers: [String: DirectoryWatcher] = [:]
    /// The widget whose card is open in its own menu bar popover, if any.
    /// Set by the status item controller; a widget shown this way is visible
    /// even though the shelf is closed.
    var menuBarPopoverWidgetID: String? {
        didSet {
            guard menuBarPopoverWidgetID != oldValue else { return }
            syncScriptTimerActivity()
            refreshWidgetsAwaitingVisibility()
        }
    }
    /// Widgets whose last refresh ran a workflow that reads `widget.visible`,
    /// and the value it saw. Only these need re-running when a card appears.
    private var visibilityAwareWidgetIDs: Set<String> = []
    private var lastRefreshVisibility: [String: Bool] = [:]
    /// Decoded `workflow.json` files, reused while unchanged on disk.
    nonisolated private let workflowDefinitions = WorkflowDefinitionCache()

    // MARK: Script runtime + permission enforcement (M2)

    nonisolated let auditLog = AuditLog()
    let permissionStore: PermissionStore
    private let notificationService = NotificationService()
    /// Widgets whose next workflow refresh the user asked for.
    private var userRequestedRefreshIDs: Set<String> = []
    /// What each workflow alert last saw, and when it last fired.
    nonisolated private let alertStates = AlertStateStore(
        fileURL: WidgetRuntime.applicationSupportDirectory.appendingPathComponent("alert-state.json")
    )
    let alertGate = AlertDeliveryGate()
    /// Unlocked password-vault sessions, in memory only (`VaultBroker`).
    lazy var vaultBroker: VaultBroker = MainActor.assumeIsolated {
        let broker = VaultBroker()
        // Every vault widget shares a provider's session: redraw them all.
        broker.onChange = { [weak self] in
            guard let self else { return }
            for widget in self.widgets where widget.manifest.permissions?.vault != nil {
                self.refresh(widgetID: widget.id, manual: true)
            }
        }
        broker.audit = { [weak self] event, widgetID, detail in
            self?.auditLog.record(event, widgetId: widgetID, detail: detail)
        }
        broker.start()
        return broker
    }
    /// Widgets whose workflow alerts need refreshes off-page too (Scheduler).
    private var alertMonitoringIDs: Set<String> = []
    private var scriptSupervisorStorage: RuntimeSupervisor?
    /// `host.secret.*` values, per widget instance. Removing a widget erases
    /// that instance's entries.
    private let secretStore: SecretStoring
    /// Widgets `removeWidget` is waiting to stop and purge.
    private var removingWidgetIDs: Set<String> = []

    /// Per-widget persistent KV store, shared by the script runtime
    /// (`host.storage.*`) and workflow persistence (`storage.*` reads +
    /// `store` writes) so both see one namespace per widget.
    nonisolated private let storage = StorageService(
        directory: WidgetRuntime.applicationSupportDirectory
            .appendingPathComponent("storage", isDirectory: true)
    )

    /// Builtin adapter registry for `output = "data"` sources (M1 contract:
    /// async, context-carrying, may return a deadline + status text).
    nonisolated private let adapters: [String: (Data, AdapterContext) async throws -> AdapterResult] = [
        AasUsageAdapter.name: AasUsageAdapter.adapt,
        OtpeekAdapter.name: OtpeekAdapter.adapt,
    ]

    nonisolated private static let defaultTimeoutMs = 25_000
    /// This build's version, read once: the check on every refresh must not
    /// re-read the bundle's Info.plist.
    nonisolated static let hostVersion = AppVersionInfo.current.version
    private static let hotReloadDebounceSec: TimeInterval = 0.4

    init(
        appPrefs: AppPrefs = .shared,
        refreshStatsStore: RefreshStatsStore? = nil,
        permissionStore: PermissionStore? = nil,
        scriptSupervisor: RuntimeSupervisor? = nil,
        secretStore: SecretStoring = KeychainSecretStore(),
        sharedShelf: SharedShelfPublisher? = nil,
        usageStore: UsageStore? = nil
    ) {
        self.appPrefs = appPrefs
        self.usageStore = usageStore ?? UsageStore(
            fileURL: Self.applicationSupportDirectory.appendingPathComponent("usage.json")
        )
        self.secretStore = secretStore
        self.desktopMirror = DesktopWidgetMirror(sharedShelf: sharedShelf ?? SharedShelfPublisher())
        self.permissionStore = permissionStore ?? PermissionStore(
            fileURL: Self.applicationSupportDirectory.appendingPathComponent("permissions.json")
        )
        // An update that only dropped permissions keeps its approval
        // without asking; the audit log still says it happened.
        let carriedAudit = auditLog
        self.permissionStore.onApprovalCarried = { widgetID, hash in
            carriedAudit.record("permission.narrowed", widgetId: widgetID, detail: ["hash": .string(hash)])
        }
        self.scriptSupervisorStorage = scriptSupervisor
        self.refreshStatsStore = refreshStatsStore ?? RefreshStatsStore(
            fileURL: Self.applicationSupportDirectory
                .appendingPathComponent(RefreshStatsStore.defaultFileName)
        )
        self.refreshStats.apply(self.refreshStatsStore.all)
        scheduler.requestRefresh = { [weak self] widgetID, manual in
            self?.refresh(widgetID: widgetID, manual: manual)
        }
        scheduler.requestStaleRefresh = { [weak self] backgroundOnly in
            self?.refreshStaleWidgets(backgroundOnly: backgroundOnly)
        }
        applyAppPreferences(appPrefs.preferences)
        appPrefs.$preferences
            .receive(on: RunLoop.main)
            .sink { [weak self] preferences in
                self?.applyAppPreferences(preferences)
            }
            .store(in: &cancellables)
        // Snapshot cache and refresh stats are written on a throttle; a normal
        // quit writes whatever they are still holding.
        NotificationCenter.default
            .publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in
                self?.snapshotCache.flush()
                self?.refreshStatsStore.flush()
                self?.chartRecorder.save()
            }
            .store(in: &cancellables)
        desktopMirror.source = self
        // On the same throttle as the cache: a widget refreshing every
        // two seconds must not rewrite the shared folder that often.
        snapshotCache.onThrottledWrite = { [weak self] snapshot in
            self?.desktopMirror.publish(snapshot)
        }
        seedStarterWidgets()
        refreshBundledWidgets()
        chartRecorder.sensitiveWidgetIDs = { [weak self] in
            guard let self else { return nil }
            return Set(self.widgets.filter(\.isSensitive).map(\.id)).union(self.sensitiveRenderIDs)
        }
        chartRecorder.restore()
        chartRecorder.updateSaver()
        loadWidgets()
        startHotReload()
        startMenuBarStalenessTicker()
        // The refresh button on a desktop widget.
        desktopMirror.observeRefreshRequests { [weak self] widget in
            self?.refresh(widget, manual: true)
        }
    }

    private func applyAppPreferences(_ preferences: AppPreferences) {
        scheduler.configurePolicy(
            refreshMultiplier: preferences.refreshMultiplier,
            pauseWhenClosed: preferences.pauseWhenClosed
        )
        // The multiplier scales the cadence a promoted widget is judged stale
        // against, so the strip is re-evaluated with it.
        syncMenuBar()
    }

    // MARK: - First-run seeding (R07 onboarding)

    /// Packaged apps launch with cwd `/`, so a fresh install used to show an
    /// empty popup. The CLI-free starter widgets bundled under
    /// `Resources/widgets/` are copied once into Application Support; dev
    /// checkouts (`./widgets/` present) are left untouched. When seeding
    /// happens the one-time welcome card is armed via prefs.
    private func seedStarterWidgets() {
        let outcome = StarterWidgetSeeder.seedIfNeeded(
            bundledWidgetsDirectory: Bundle.main.resourceURL?
                .appendingPathComponent("widgets", isDirectory: true),
            userWidgetsDirectory: Self.applicationSupportDirectory
                .appendingPathComponent("widgets", isDirectory: true),
            developmentWidgetsDirectory: URL(
                fileURLWithPath: FileManager.default.currentDirectoryPath
            ).appendingPathComponent("widgets", isDirectory: true)
        )
        if outcome.didSeed {
            NSLog(
                "barshelf: seeded starter widgets: %@",
                outcome.seededNames.joined(separator: ", ")
            )
            prefs.markWelcomePending()
            gatherStarters(outcome.seededNames)
        }
    }

    /// The page a new person's starters share. Their manifests file them
    /// under Demo, Files and Productivity — sensible once there are many
    /// widgets, but on day one it meant three pages of one card each.
    static let starterPage = "Everyday"

    private func gatherStarters(_ names: [String]) {
        let root = Self.applicationSupportDirectory.appendingPathComponent("widgets", isDirectory: true)
        for (index, name) in names.enumerated() {
            let manifestURL = root.appendingPathComponent(name).appendingPathComponent("widget.json")
            guard let data = try? Data(contentsOf: manifestURL),
                  let manifest = try? Manifest.decode(from: data),
                  prefs.override(for: manifest.id)?.group == nil else { continue }
            prefs.setOverride(group: Self.starterPage, order: Double(index), size: nil, for: manifest.id)
        }
    }

    /// Widget behaviour is data (`widget.json` / `workflow.json`), and until
    /// now that data only ever reached a Mac through a manual
    /// `barshelf install`: seeding is one-time, so an already-installed
    /// widget stayed frozen at whatever version first landed. Every launch
    /// now swaps in the bundled copy of an installed widget when the app
    /// ships a newer version of it, leaving deleted and locally edited
    /// widgets alone. Runs before `loadWidgets()` so the fresh files are what
    /// gets loaded.
    private func refreshBundledWidgets() {
        let outcome = BundledWidgetRefresher.refreshIfNeeded(
            bundledWidgetsDirectory: Bundle.main.resourceURL?
                .appendingPathComponent("widgets", isDirectory: true),
            userWidgetsDirectory: Self.applicationSupportDirectory
                .appendingPathComponent("widgets", isDirectory: true),
            developmentWidgetsDirectory: URL(
                fileURLWithPath: FileManager.default.currentDirectoryPath
            ).appendingPathComponent("widgets", isDirectory: true)
        )
        if outcome.didRefresh {
            NSLog(
                "barshelf: refreshed bundled widgets: %@",
                outcome.refreshed.map(\.summary).joined(separator: ", ")
            )
        }
        if !outcome.skippedLocallyModified.isEmpty {
            NSLog(
                "barshelf: kept locally modified widgets at their current "
                    + "version: %@",
                outcome.skippedLocallyModified.joined(separator: ", ")
            )
        }
    }

    // MARK: - Script runtime supervisor

    nonisolated static var applicationSupportDirectory: URL { BarShelfDirectories.applicationSupport }

    /// Created on first script-widget use (deno-based launch plans injected;
    /// tests build their own supervisor with stub launch plans).
    private var scriptSupervisor: RuntimeSupervisor {
        if let existing = scriptSupervisorStorage { return existing }
        let appSupport = Self.applicationSupportDirectory
        let notificationService = self.notificationService
        let permissionStore = self.permissionStore
        let weakRuntime = WeakWidgetRuntimeBox(self)
        let configuration = RuntimeSupervisorConfiguration(
            makeLaunchPlan: { widget in
                try DenoRuntime.makeLaunchPlan(
                    widget: widget,
                    stateDirectory: appSupport.appendingPathComponent("runtime", isDirectory: true)
                )
            },
            storage: storage,
            secrets: secretStore,
            audit: auditLog,
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
        let events = RuntimeSupervisorEvents(
            onRender: { widgetId, params, revision in
                let token = weakRuntime.value?.scriptCallbackGate.token(for: widgetId)
                DispatchQueue.main.async {
                    guard let token else { return }
                    weakRuntime.value?.handleScriptRender(
                        widgetId: widgetId,
                        params: params,
                        revision: revision,
                        callbackToken: token
                    )
                }
            },
            onLoadComplete: { widgetId, generation, error in
                let token = weakRuntime.value?.scriptCallbackGate.token(for: widgetId)
                DispatchQueue.main.async {
                    guard let token else { return }
                    weakRuntime.value?.handleScriptLoadComplete(
                        widgetId: widgetId,
                        generation: generation,
                        error: error,
                        callbackToken: token
                    )
                }
            },
            onStateChange: { widgetId, state in
                let token = weakRuntime.value?.scriptCallbackGate.token(for: widgetId)
                DispatchQueue.main.async {
                    guard let token else { return }
                    weakRuntime.value?.handleScriptStateChange(
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
        let supervisor = RuntimeSupervisor(configuration: configuration, events: events)
        scriptSupervisorStorage = supervisor
        syncScriptTimerActivity(force: true)
        return supervisor
    }

    private var allowedScriptTimerWidgetIDs: Set<String>? {
        guard appPrefs.preferences.pauseWhenClosed else { return nil }
        var allowed = menuBarWidgetIDs.union(dockWidgetIDs)
        if scheduler.popupIsOpen { allowed.formUnion(visibleWidgetIDs) }
        if let id = menuBarPopoverWidgetID { allowed.insert(id) }
        return allowed.subtracting(prefs.disabled)
    }

    private func syncScriptTimerActivity(force: Bool = false) {
        let allowed = allowedScriptTimerWidgetIDs
        guard force || !scriptTimerPolicyInitialized || lastScriptTimerAllowedIDs != allowed else { return }
        scriptTimerPolicyInitialized = true
        lastScriptTimerAllowedIDs = allowed
        scriptTimerPolicyRevision &+= 1
        guard let supervisor = scriptSupervisorStorage else { return }
        let revision = scriptTimerPolicyRevision
        Task { await supervisor.setTimerActivity(allowing: allowed, revision: revision) }
    }

    private func handleScriptRender(
        widgetId: String, params: RenderParams, revision: Int, callbackToken: UInt
    ) {
        guard scriptCallbackGate.accepts(widgetID: widgetId, token: callbackToken),
              scriptDisableStopTokens[widgetId] == nil,
              !prefs.isDisabled(widgetId),
              let widget = widgets.first(where: { $0.id == widgetId }),
              permissionStore.status(for: widget.manifest) == .approved else { return }
        if let generation = params.loadGeneration {
            guard scriptRefreshes.markRendered(widgetID: widgetId, generation: generation) else { return }
        }
        var snapshot = snapshots[widgetId] ?? WidgetSnapshot(widgetID: widgetId)
        snapshot.isLoading = false
        snapshot.viewTree = params.root
        snapshot.updatedAt = Date()
        snapshot.error = nil
        snapshot.statusLabel = params.status?.label
        snapshot.statusMetrics = params.status?.metrics
        snapshot.statusPrefix = params.status?.prefix
        snapshot.statusIcon = params.status?.icon
        snapshot.statusTint = params.status?.tint
        snapshot.statusPresentation = params.status?.presentation
        snapshot.statusTooltip = params.status?.tooltip
        snapshot.safeForSensitiveCache = false
        setSnapshot(snapshot, for: widgetId)
        let sensitive = params.sensitive == true || widget.isSensitive
        let wasSensitive = sensitiveRenderIDs.contains(widgetId)
        if sensitive { sensitiveRenderIDs.insert(widgetId) } else { sensitiveRenderIDs.remove(widgetId) }
        if sensitive != wasSensitive { desktopMirror.publishIndex() }
        if sensitive {
            desktopMirror.withdraw(widgetID: widgetId)
            snapshotCache.cancelPending(widgetId)
            if let cacheRoot = params.cacheRoot {
                // Keep the live tree memory-only. Persist only the separate
                // widget-supplied tree whose contract requires sensitive
                // fields to be removed before host.render.
                var cached = snapshot
                cached.viewTree = cacheRoot
                cached.safeForSensitiveCache = true
                persistSnapshot(cached)
            } else {
                snapshotCache.removeFile(widgetID: widgetId)
            }
        } else {
            persistSnapshot(snapshot)
        }
        scheduler.noteRefreshSucceeded(widgetID: widgetId, nextRefreshAtMs: params.nextRefreshAt)
        recordRefreshSuccess(widgetID: widgetId)
    }

    private func handleScriptLoadComplete(
        widgetId: String, generation: String, error: String?, callbackToken: UInt
    ) {
        guard scriptCallbackGate.accepts(widgetID: widgetId, token: callbackToken),
              scriptDisableStopTokens[widgetId] == nil,
              !prefs.isDisabled(widgetId) else { return }
        guard let rendered = scriptRefreshes.finish(
            widgetID: widgetId, generation: generation
        ) else { return }
        endInFlight(widgetId)
        if let error {
            updateSnapshot(widgetId) {
                $0.isLoading = false
                $0.error = error
            }
            persistShareableSnapshot(widgetID: widgetId)
            scheduler.noteRefreshFailed(widgetID: widgetId)
            recordRefreshFailure(widgetID: widgetId, error: error)
            return
        }
        // A script may intentionally retain its last-good render. Completion
        // still ends loading/backoff and records the successful no-change load.
        if !rendered {
            updateSnapshot(widgetId) { $0.isLoading = false; $0.error = nil }
            persistShareableSnapshot(widgetID: widgetId)
            scheduler.noteRefreshSucceeded(widgetID: widgetId, nextRefreshAtMs: nil)
            recordRefreshSuccess(widgetID: widgetId)
        }
    }

    private func handleScriptStateChange(
        widgetId: String, state: ScriptWidgetState, callbackToken: UInt
    ) {
        guard scriptCallbackGate.accepts(widgetID: widgetId, token: callbackToken),
              scriptDisableStopTokens[widgetId] == nil,
              !prefs.isDisabled(widgetId) else { return }
        switch state {
        case .running:
            break
        case .stopped:
            // A crash before the first render would otherwise spin forever.
            if scriptRefreshes.cancel(widgetID: widgetId) {
                updateSnapshot(widgetId) {
                    $0.isLoading = false
                    $0.error = "script exited unexpectedly"
                }
                persistShareableSnapshot(widgetID: widgetId)
                endInFlight(widgetId)
                scheduler.noteRefreshFailed(widgetID: widgetId)
                recordRefreshFailure(
                    widgetID: widgetId, error: "script exited unexpectedly"
                )
            }
        case let .disabled(reason):
            scriptDisabledReasonCache[widgetId] = reason
            setOverlay(.disabled(reason: reason), for: widgetId)
            updateSnapshot(widgetId) {
                $0.isLoading = false
                $0.error = "Widget disabled: \(reason)"
            }
            persistShareableSnapshot(widgetID: widgetId)
            _ = scriptRefreshes.cancel(widgetID: widgetId)
            endInFlight(widgetId)
            scheduler.noteRefreshFailed(widgetID: widgetId)
            recordRefreshFailure(widgetID: widgetId, error: "Widget disabled: \(reason)")
        }
    }

    // MARK: - Permission approval

    /// True only when the widget's *current* permission set is approved.
    private func gatePermissions(for widget: LoadedWidget) -> Bool {
        switch permissionStore.status(for: widget.manifest) {
        case .approved:
            // Clear a stale approval/denied card (but keep disabled cards).
            if overlayCards[widget.id] != nil,
               scriptDisabledReasonCache[widget.id] == nil {
                setOverlay(nil, for: widget.id)
            }
            return true
        case .pending:
            presentApprovalCard(for: widget, denied: false)
            return false
        case .denied:
            presentApprovalCard(for: widget, denied: true)
            return false
        }
    }

    /// Tracks crash-loop disabled reasons so approval logic doesn't clear
    /// restart cards.
    private var scriptDisabledReasonCache: [String: String] = [:]

    private func presentApprovalCard(for widget: LoadedWidget, denied: Bool) {
        // A permission overlay replaces the shelf card, but Dock glances and
        // menu-bar values also observe this snapshot. Withdraw their last
        // reading immediately, including a cache restored during a rescan.
        snapshotCache.cancelPending(widget.id)
        setSnapshot(WidgetSnapshot(widgetID: widget.id), for: widget.id)
        if overlayCards[widget.id] == nil {
            auditLog.record("permission.requested", widgetId: widget.id, detail: [
                "hash": .string(PermissionStore.permissionsHash(of: widget.manifest)),
            ])
        }
        let requests = Self.permissionRequests(for: widget)
        setOverlay(denied ? .denied(requests) : .approvalNeeded(requests), for: widget.id)
    }

    func approvePermissions(widgetID: String) {
        guard let widget = widgets.first(where: { $0.id == widgetID }) else { return }
        permissionStore.approve(widget.manifest)
        // The store is not observed: without this, Settings ▸ Privacy kept
        // showing "Waiting for your permission" until you left the page
        // (deny and revoke already announce their change).
        objectWillChange.send()
        auditLog.record("permission.approved", widgetId: widgetID, detail: [
            "hash": .string(PermissionStore.permissionsHash(of: widget.manifest)),
        ])
        let approvedCopies = widgets.filter {
            $0.manifest.id == widget.manifest.id && scriptDisabledReasonCache[$0.id] == nil
        }
        for copy in approvedCopies {
            setOverlay(nil, for: copy.id)
        }
        desktopMirror.publishIndex()
        // Revocation removes promoted items and can stop the staleness timer.
        // Approval must restore their placement without waiting for a render
        // or an unrelated menu-bar refresh.
        syncMenuBar()
        if widget.manifest.permissions?.notifications == true {
            NotificationService.requestAuthorization()
        }
        // Every copy was left with an empty card when the approval was taken
        // away; one that only refreshes on open would otherwise stay blank.
        for copy in approvedCopies {
            refresh(copy, manual: copy.id == widget.id)
        }
    }

    func denyPermissions(widgetID: String) {
        guard let widget = widgets.first(where: { $0.id == widgetID }) else { return }
        permissionStore.deny(widget.manifest)
        stopForPermissionChange(packageID: widget.manifest.id, denied: true)
        auditLog.record("permission.denied", widgetId: widgetID, detail: [
            "hash": .string(PermissionStore.permissionsHash(of: widget.manifest)),
        ])
    }

    /// Decisions belong to a package, so every running copy must stop too.
    func stopForPermissionChange(packageID: String, denied: Bool) {
        for widget in widgets where widget.manifest.id == packageID {
            stopWidgetExecution(widget.id)
            desktopMirror.withdraw(widgetID: widget.id)
            presentApprovalCard(for: widget, denied: denied)
        }
        desktopMirror.publishIndex()
        syncMenuBar()
        objectWillChange.send()
    }

    /// "Restart Widget" after a crash-loop disable.
    func restartScriptWidget(widgetID: String) {
        guard !removingWidgetIDs.contains(widgetID) else { return }
        setOverlay(nil, for: widgetID)
        scriptDisabledReasonCache.removeValue(forKey: widgetID)
        updateSnapshot(widgetID) { $0.error = nil }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.scriptSupervisor.restart(widgetId: widgetID)
            } catch {
                // Descriptor unknown (fresh app start) — fall back to a refresh.
                self.refresh(widgetID: widgetID, manual: true)
            }
        }
    }

    /// UI `event` action → `widget.action` notification to the script.
    func sendScriptEvent(actionId: String?, widgetID: String) {
        guard let actionId else {
            NSLog("barshelf: event action from %@ has no id", widgetID)
            return
        }
        guard let widget = widgets.first(where: { $0.id == widgetID }),
              widget.manifest.entry.kind == "script"
        else {
            NSLog("barshelf: 'event' action (id: %@) from %@ ignored (not a script widget)",
                  actionId, widgetID)
            return
        }
        guard gatePermissions(for: widget) else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.scriptSupervisor.sendAction(widgetId: widgetID, actionId: actionId)
            } catch {
                NSLog("barshelf: event %@ for %@ failed: %@",
                      actionId, widgetID, String(describing: error))
            }
        }
    }

    // MARK: - Host-generated card states

    /// What a widget is asking to be allowed to do, one line per capability,
    /// in words rather than raw commands. The approval card lists these.
    ///
    /// Every command is one row: what the commands do, each phrase once, with
    /// the exact command lines behind "Details". Two rows saying the same
    /// thing in different words read as two different permissions.
    nonisolated static func permissionRequests(for widget: LoadedWidget) -> [PermissionRequest] {
        permissionRequests(for: widget.manifest)
    }

    nonisolated static func permissionRequests(for manifest: Manifest, localization: WidgetLocalization?? = nil) -> [PermissionRequest] {
        var rows: [PermissionRequest] = []
        let permissions = manifest.permissions
        let table = localization ?? manifest.localization()
        let exec = ExecPermissionText.summary(for: manifest, localization: table)
        if let exec {
            rows.append(PermissionRequest(
                symbol: "terminal",
                description: exec.phrases.joined(separator: "\n"),
                details: exec.commandLines
            ))
        } else if manifest.entry.kind == "exec" {
            rows.append(PermissionRequest(
                symbol: "exclamationmark.triangle.fill",
                description: String(localized: "Blocked: this widget runs a command but does not say which"),
                isWarning: true
            ))
        }
        if permissions?.keychain == true {
            rows.append(PermissionRequest(symbol: "key.fill", description: String(localized: "Read and save passwords in your Keychain")))
        }
        if permissions?.notifications == true {
            rows.append(PermissionRequest(symbol: "bell.fill", description: String(localized: "Show notifications")))
        }
        if permissions?.quitApps == true {
            rows.append(PermissionRequest(symbol: "xmark.app.fill", description: String(localized: "Quit apps you choose, asking each time")))
        }
        if let net = permissions?.network, !net.isEmpty {
            let hosts = net.prefix(4).joined(separator: ", ")
            let suffix = net.count > 4 ? ", …" : ""
            rows.append(PermissionRequest(symbol: "network", description: String(localized: "Connect to \(hosts)\(suffix)")))
        }
        for path in permissions?.readPaths ?? [] {
            rows.append(PermissionRequest(symbol: "folder.fill", description: String(localized: "Read files in \(path)")))
        }
        if permissions?.storage?.granted == true {
            rows.append(PermissionRequest(symbol: "internaldrive.fill", description: String(localized: "Save a little data on this Mac", comment: "Permission: the widget keeps a small amount of its own data")))
        }
        // The widget's own variables and those a single command is handed.
        var env = permissions?.env ?? []
        for name in exec?.environment ?? [] where !env.contains(name) { env.append(name) }
        if !env.isEmpty {
            rows.append(PermissionRequest(
                symbol: "leaf.fill",
                description: String(localized: "Read settings from the environment: \(env.joined(separator: ", "))")
            ))
        }
        if let vault = permissions?.vault {
            rows.append(PermissionRequest(
                symbol: "lock.shield.fill",
                description: String(localized: "Unlock your Bitwarden vault when you ask; it locks after \(Int(vault.idleSeconds / 60)) minutes unused", comment: "Approval card: the vault permission, first of two rows")
            ))
            rows.append(PermissionRequest(
                symbol: "doc.on.doc",
                description: String(localized: "See item names and copy a username, password or code you pick", comment: "Approval card: the vault permission, second of two rows")
            ))
        }
        if rows.isEmpty {
            rows.append(PermissionRequest(symbol: "checkmark.seal.fill", description: String(localized: "No special permissions")))
        }
        return rows
    }

    /// One line on what the widget is for, shown above what it asks for: the
    /// widget.json `description` in the app's language, else the summary the
    /// gallery gives BarShelf's own widgets. The first sentence only.
    @MainActor static func permissionPurpose(for widget: LoadedWidget) -> String? {
        let key = widget.directory.path + "|" + widget.loadRevision
        if let cached = purposeCache[key] { return cached.isEmpty ? nil : cached }
        var text = widget.packageInfo.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !text.isEmpty {
            text = widget.manifest.localization()?.text(text) ?? text
        } else {
            text = GalleryEntryText.summary(forID: widget.manifest.id) ?? ""
        }
        text = firstSentence(text)
        purposeCache[key] = text
        return text.isEmpty ? nil : text
    }

    @MainActor private static var purposeCache: [String: String] = [:]

    static func firstSentence(_ text: String) -> String {
        guard let end = text.range(of: ". ") else { return text }
        return String(text[..<end.lowerBound]) + "."
    }

    // MARK: - Discovery

    /// Widget directory search order:
    /// 1. `./widgets/` relative to cwd (development mode)
    /// 2. `~/Library/Application Support/barshelf/widgets/`
    /// Each widget lives at `<dir>/<widget-name>/widget.json`. On duplicate
    /// instance ids the earlier directory wins (dev overrides installed),
    /// while `<manifest-id>--<label>` aliases remain independent instances.
    static var widgetSearchDirectories: [URL] {
        var directories: [URL] = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("widgets", isDirectory: true)
        ]
        if let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first {
            directories.append(
                appSupport
                    .appendingPathComponent("barshelf", isDirectory: true)
                    .appendingPathComponent("widgets", isDirectory: true)
            )
        }
        return directories
    }

    func loadWidgets() {
        let loaded = Self.discoverWidgets(in: Self.widgetSearchDirectories)
        let seenIDs = Set(loaded.map(\.id))
        let previous = Dictionary(widgets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let changedIDs = Set(loaded.filter { widget in
            guard let before = previous[widget.id] else { return true }
            return before.manifest != widget.manifest || before.directory != widget.directory
        }.map(\.id))
        for (id, entry) in nativeRefreshTasks where !seenIDs.contains(id) || changedIDs.contains(id) {
            entry.task.cancel()
            nativeRefreshTasks.removeValue(forKey: id)
        }
        for id in Array(runActionTasks.keys) where !seenIDs.contains(id) || changedIDs.contains(id) {
            for task in runActionTasks.removeValue(forKey: id)?.values ?? [:].values { task.cancel() }
        }
        nativeRefreshes.reload(keeping: seenIDs, changed: changedIDs)
        // Changed code or a removed widget: no alert raised under the old one
        // may still go out, and monitoring is re-learned on the next refresh.
        // Every workflow widget counts as changed here: its workflow.json can
        // change without widget.json, and pending alerts are rare enough that
        // dropping one on a rescan costs nothing.
        let workflowIDs = Set(previous.values.filter { $0.manifest.entry.kind == "workflow" }.map(\.id))
        for id in Set(previous.keys).subtracting(seenIDs).union(changedIDs).union(workflowIDs) {
            alertGate.invalidate(id)
        }
        // A removed widget, or changed code (widget.json or workflow.json),
        // holds no vault session.
        for id in Set(previous.keys).subtracting(seenIDs).union(changedIDs).union(workflowIDs) {
            endVaultSession(id, permission: previous[id]?.manifest.permissions?.vault)
        }
        if !alertMonitoringIDs.isDisjoint(with: changedIDs) || !alertMonitoringIDs.isSubset(of: seenIDs) {
            alertMonitoringIDs = alertMonitoringIDs.intersection(seenIDs).subtracting(changedIDs)
            scheduler.setMonitoringWidgetIDs(alertMonitoringIDs)
        }
        storage.retain(widgetIDs: seenIDs)
        let workflowURLs = Set(loaded.filter { $0.manifest.entry.kind == "workflow" }.compactMap {
            try? WidgetEntryResolver.resolve(directory: $0.directory, main: $0.manifest.entry.main, defaultName: "workflow.json")
        })
        workflowDefinitions.retain(fileURLs: workflowURLs)

        // A rescan replaces every script descriptor/process, even when the id
        // stays the same. Release only those script generations here; their
        // late SDK acknowledgements are ignored by generation matching.
        let cancelledScriptIDs = scriptRefreshes.cancelAll()
        for id in Set(previous.values.filter { $0.manifest.entry.kind == "script" }.map(\.id))
            .union(loaded.filter { $0.manifest.entry.kind == "script" }.map(\.id)) {
            scriptCallbackGate.invalidate(widgetID: id)
        }
        inFlight.subtract(cancelledScriptIDs)
        for id in cancelledScriptIDs where seenIDs.contains(id) {
            updateSnapshot(id) { $0.isLoading = false }
        }

        widgets = loaded
        prefs.migrateRenamedPages(inUse: Set(loaded.map { effectiveGroup(for: $0.id) }))
        if !previous.isEmpty {
            landNewWidgets(loaded.filter { previous[$0.id] == nil }.map(\.id))
        }
        // Remove per-widget state of widgets that disappeared (hot reload).
        removeWidgetState(notIn: seenIDs)
        refreshStatsStore.retain(widgetIDs: seenIDs)
        publishRefreshStats()

        for widget in loaded {
            // A widget that is sensitive now — including one that just became
            // so on hot reload, whose snapshot is still in memory — must not
            // have a pre-sensitive live tree written by a cache throttle that
            // was already holding it.
            if widget.isSensitive {
                snapshotCache.cancelPending(widget.id)
            }
            if snapshots[widget.id] == nil {
                if widget.isSensitive {
                    // A sensitive live tree is never restored. The only cache
                    // accepted here is an explicitly redacted fallback written
                    // through RenderParams.cacheRoot.
                    if let cached = snapshotCache.load(widgetID: widget.id),
                       cached.safeForSensitiveCache == true {
                        setSnapshot(cached, for: widget.id)
                    } else {
                        snapshotCache.removeFile(widgetID: widget.id)
                        setSnapshot(WidgetSnapshot(widgetID: widget.id), for: widget.id)
                    }
                } else {
                    setSnapshot(
                        snapshotCache.load(widgetID: widget.id)
                            ?? WidgetSnapshot(widgetID: widget.id),
                        for: widget.id
                    )
                }
            }
            // Unsupported entry kinds still load, but the card states why the
            // widget cannot run (clear error instead of a silent blank).
            if !Self.supportedEntryKinds.contains(widget.manifest.entry.kind) {
                updateSnapshot(widget.id) {
                    $0.error = "entry.kind \"\(widget.manifest.entry.kind)\" is not supported in M2 (only \"exec\", \"script\", \"workflow\")"
                }
            }
            // Every widget (bundled exec widgets included) goes through the
            // same one-time approval frame; changed permissions re-prompt.
            _ = gatePermissions(for: widget)
        }

        // A same-id package may have changed its code or permissions. Stop all
        // resident script processes and discard their descriptors before a
        // rescan can approve/start the replacement; retaining by id alone
        // would let old code continue under the previous descriptor.
        scriptDisabledReasonCache = scriptDisabledReasonCache.filter { seenIDs.contains($0.key) }
        if let supervisor = scriptSupervisorStorage {
            scriptReloadBarrier = Task { await supervisor.retain(widgetIds: []) }
        }

        let enabled = loaded.filter { !prefs.isDisabled($0.id) }
        visibleWidgetIDs.formIntersection(Set(enabled.map(\.id)))
        scheduler.configure(widgets: enabled)
        scheduler.setVisibleWidgetIDs(visibleWidgetIDs)
        syncMenuBar()
        // `configure` may have dropped dock widgets it did not know yet.
        dockWidgetIDs.formIntersection(seenIDs)
        scheduler.setMenuBarWidgetIDs(menuBarWidgetIDs.union(dockWidgetIDs))
        desktopMirror.publishIndex()
    }

    nonisolated static func discoverWidgets(in searchDirectories: [URL]) -> [LoadedWidget] {
        var loaded: [LoadedWidget] = []
        var seenIDs: Set<String> = []
        let fm = FileManager.default

        for baseDirectory in searchDirectories {
            guard let entries = try? fm.contentsOfDirectory(
                at: baseDirectory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let manifestURL = entry.appendingPathComponent("widget.json")
                guard fm.fileExists(atPath: manifestURL.path) else { continue }
                do {
                    let data = try Data(contentsOf: manifestURL)
                    let manifest = try Manifest.decode(from: data)
                    let instanceID = Self.instanceID(
                        manifestID: manifest.id,
                        directoryName: entry.lastPathComponent
                    )
                    guard !seenIDs.contains(instanceID) else { continue }
                    seenIDs.insert(instanceID)
                    loaded.append(LoadedWidget(
                        manifest: manifest,
                        directory: entry,
                        instanceID: instanceID
                    ))
                    if instanceID != manifest.id {
                        NSLog(
                            "barshelf: loaded widget instance %@ from package %@",
                            instanceID,
                            manifest.id
                        )
                    }
                } catch {
                    NSLog("barshelf: skipping \(manifestURL.path): \(error)")
                }
            }
        }
        return loaded
    }

    static let supportedEntryKinds: Set<String> = ["exec", "script", "workflow"]

    /// The canonical install directory keeps the manifest id. Additional
    /// instances are lightweight aliases named `<manifest-id>--<label>` and
    /// share the same package files while retaining independent runtime state.
    nonisolated static func instanceID(manifestID: String, directoryName: String) -> String {
        let prefix = manifestID + "--"
        guard directoryName.hasPrefix(prefix), directoryName.count > prefix.count else {
            return manifestID
        }
        return directoryName
    }

    // MARK: - Widget management (R11)

    /// The single directory `removeWidget` is allowed to delete inside.
    nonisolated static var userWidgetsRoot: URL {
        applicationSupportDirectory.appendingPathComponent("widgets", isDirectory: true)
    }

    /// True only for a proper subdirectory of the user widgets root. Resolving
    /// `..` first refuses path-traversal ids and dev-checkout (`./widgets/`)
    /// widgets, so `removeWidget` can never delete outside that root.
    nonisolated static func isRemovableWidgetDirectory(_ directory: URL) -> Bool {
        let root = userWidgetsRoot.standardizedFileURL.path
        let target = directory.standardizedFileURL.path
        return target != root && target.hasPrefix(root + "/")
    }

    /// Stops the widget, waits for its running work, then deletes its storage,
    /// secrets and directory and scrubs every per-widget trace (cached
    /// snapshot, permissions, prefs), then rescans — which drops the
    /// in-memory snapshot, card model, refresh stats, and scheduler timers.
    /// Throws (deleting nothing) for unknown ids or directories outside the
    /// user widgets root; throws with the widget still installed when its
    /// data cannot be erased.
    ///
    /// On the main actor: this class is not isolated, so an `async` method
    /// runs on the cooperative pool from its first line, and everything
    /// here (the task tables, the refresh gate, the preferences, the rescan
    /// that assigns `widgets` and re-arms the scheduler's timers) is state
    /// the main thread is using at the same time.
    @MainActor
    func removeWidget(id: String) async throws {
        guard let widget = widgets.first(where: { $0.id == id }) else {
            throw RuntimeError.widgetNotFound(id)
        }
        guard Self.isRemovableWidgetDirectory(widget.directory) else {
            throw RuntimeError.notRemovable(
                String(localized: "This widget came with BarShelf or was added from another folder, so it can’t be removed here. Turn it off instead.")
            )
        }
        if id == widget.manifest.id {
            let aliasPrefix = widget.manifest.id + "--"
            let hasInstances = (try? FileManager.default.contentsOfDirectory(
                at: Self.userWidgetsRoot,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ))?.contains { $0.lastPathComponent.hasPrefix(aliasPrefix) } ?? false
            if hasInstances {
                throw RuntimeError.notRemovable(
                    String(localized: "Remove the copies of “\(widget.manifest.name)” first, then remove the original.")
                )
            }
        }
        // Refresh, restart and duplicate stay off this widget until it is
        // gone or the removal failed.
        guard removingWidgetIDs.insert(id).inserted else {
            throw RuntimeError.notRemovable(
                String(localized: "\"\(widget.manifest.name)\" is already being removed.")
            )
        }
        do {
            // Wait for everything that could write the widget's storage or a
            // secret: its native refresh (and the command it runs), then the
            // script and its host commands. Only then is the purge final.
            let nativeRefresh = nativeRefreshTasks[id]?.task
            let actions = Array(runActionTasks[id]?.values ?? [:].values)
            stopWidgetExecution(id)
            await nativeRefresh?.value
            for action in actions { await action.value }
            await scriptSupervisorStorage?.stopAndWait(widgetId: id)
            // Purging before the files go means a failure leaves the widget
            // installed, not reported as removed with its data still on disk.
            try purgeInstanceData(id)
            try FileManager.default.removeItem(at: widget.directory)
        } catch {
            removingWidgetIDs.remove(id)
            storage.retain(widgetID: id)
            refresh(widgetID: id, manual: true) // resume what the stop halted
            throw error
        }
        removingWidgetIDs.remove(id)
        snapshotCache.forget(widgetID: id) // no queued write may re-create the cache
        // Decisions belong to the package, which other loaded copies still use.
        if !widgets.contains(where: { $0.id != id && $0.manifest.id == widget.manifest.id }) {
            permissionStore.reset(widgetId: widget.manifest.id)
        }
        prefs.removeAllState(for: id)
        loadWidgets()
    }

    /// Storage and secrets of exactly this instance; another instance of the
    /// same package keeps its own.
    /// Secrets first: the Keychain is what can refuse (locked, or no user
    /// interaction allowed), and failing there must leave the widget's
    /// storage intact, as the removal error promises.
    private func purgeInstanceData(_ id: String) throws {
        try secretStore.removeAll(widgetId: id)
        try storage.removeAll(widgetId: id)
        alertStates.forget(widgetID: id)
    }

    /// Creates a second independently configurable instance of an installed
    /// widget. A symlink keeps aliases on the canonical package so registry
    /// updates automatically update every instance instead of copying stale
    /// script and manifest files.
    @discardableResult
    func duplicateWidget(id: String, label: String) throws -> String {
        guard let widget = widgets.first(where: { $0.id == id }) else {
            throw RuntimeError.widgetNotFound(id)
        }
        guard !removingWidgetIDs.contains(id), !removingWidgetIDs.contains(widget.manifest.id) else {
            throw RuntimeError.notRemovable(
                String(localized: "\"\(widget.manifest.name)\" is being removed.")
            )
        }
        guard WidgetDiscovery.isValidWidgetID(widget.manifest.id) else {
            throw RuntimeError.invalidInstanceName(
                String(localized: "This widget can’t be duplicated because its widget ID isn’t valid. The widget’s author needs to fix it.")
            )
        }
        let normalized = Self.normalizedInstanceLabel(label)
        guard !normalized.isEmpty else {
            throw RuntimeError.invalidInstanceName(
                String(localized: "Give the copy a name with at least one letter or number.")
            )
        }

        guard Self.isRemovableWidgetDirectory(widget.directory),
              let installed = HeadlessInstaller.installedPackages(
                in: Self.userWidgetsRoot
              )[widget.manifest.id] else {
            throw RuntimeError.notRemovable(
                String(localized: "Install “\(widget.manifest.name)” before making a copy of it.")
            )
        }
        let canonical = installed.directory

        let instanceID = widget.manifest.id + "--" + normalized
        let destination = Self.userWidgetsRoot.appendingPathComponent(instanceID)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw RuntimeError.invalidInstanceName(
                String(localized: "There’s already a copy named “\(normalized)”. Choose another name.")
            )
        }
        do {
            try FileManager.default.createSymbolicLink(
                at: destination, withDestinationURL: canonical
            )
        } catch {
            throw RuntimeError.invalidInstanceName(
                String(localized: "Couldn’t make the copy “\(normalized)”. \(error.localizedDescription)")
            )
        }

        for (key, value) in prefs.settings(for: id) {
            prefs.setSetting(widgetID: instanceID, key: key, value: value)
        }
        if let appearance = prefs.appearanceOverride(for: id) {
            prefs.setAppearanceOverride(appearance, for: instanceID)
        }
        prefs.setRefreshInterval(prefs.refreshIntervals[id], for: instanceID)
        if let placement = prefs.override(for: id) {
            prefs.setOverride(
                group: placement.group,
                order: placement.order,
                size: placement.size,
                for: instanceID
            )
        }
        if prefs.isPinned(id) {
            prefs.togglePin(instanceID)
        }
        loadWidgets()
        return instanceID
    }

    nonisolated static func normalizedInstanceLabel(_ label: String) -> String {
        let lowered = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var result = ""
        var previousWasSeparator = false
        for scalar in lowered.unicodeScalars {
            let allowed = CharacterSet.alphanumerics.contains(scalar)
                || scalar == "." || scalar == "_" || scalar == "-"
            if allowed {
                result.unicodeScalars.append(scalar)
                previousWasSeparator = false
            } else if !previousWasSeparator, !result.isEmpty {
                result.append("-")
                previousWasSeparator = true
            }
        }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: "-._"))
    }

    /// Moves a widget to a bucket by writing an override, then republishes
    /// pages. Widgets are unchanged so only this explicit action republishes.
    func moveWidget(id: String, toGroup group: String) {
        let trimmed = group.trimmingCharacters(in: .whitespacesAndNewlines)
        // A page named here for the first time is one the user made: it
        // stays when its widgets leave, as pages made with New Page do.
        if !trimmed.isEmpty, !shelfPages.contains(where: { $0.group == trimmed }) {
            prefs.setKeptPages(prefs.keptPages + [trimmed])
        }
        prefs.setOverride(
            group: trimmed.isEmpty ? nil : trimmed,
            order: prefs.override(for: id)?.order,
            size: prefs.override(for: id)?.size,
            for: id
        )
        objectWillChange.send()
    }

    /// Drag-reorder within a panel: moves `draggedId` to sit just before
    /// `targetId` and reassigns dense order indices so the popup pages update.
    /// (Same-panel reordering; a drag onto another panel first needs a group
    /// move.) No-op if they aren't in the same page.
    func reorderWidget(id draggedId: String, before targetId: String) {
        guard draggedId != targetId,
              let page = pages.first(where: { p in p.widgets.contains { $0.id == targetId } }),
              page.widgets.contains(where: { $0.id == draggedId })
        else { return }
        var ids = page.widgets.map(\.id)
        guard let from = ids.firstIndex(of: draggedId) else { return }
        ids.remove(at: from)
        let to = ids.firstIndex(of: targetId) ?? ids.count
        ids.insert(draggedId, at: to)
        for (index, wid) in ids.enumerated() {
            let existing = prefs.override(for: wid)
            prefs.setOverride(
                group: existing?.group, order: Double(index), size: existing?.size, for: wid
            )
        }
        objectWillChange.send()
    }

    /// Changes the popup card size override. `nil` restores the manifest size.
    func resizeWidget(id: String, toSize size: String?) {
        let normalized = Self.normalizedBucketSize(size)
        let existing = prefs.override(for: id)
        prefs.setOverride(
            group: existing?.group,
            order: existing?.order,
            size: normalized,
            for: id
        )
        objectWillChange.send()
        // Re-evaluate so size-aware workflows (${widget.size}) re-render.
        refresh(widgetID: id)
    }

    /// Toggles a widget's disabled flag: disabled widgets leave the pages and
    /// stop being scheduled; re-enabling resumes scheduling and refreshes once.
    func setWidgetDisabled(_ id: String, _ flag: Bool) {
        guard prefs.isDisabled(id) != flag else { return }
        prefs.setDisabled(id, flag)
        desktopMirror.publishIndex()
        if flag {
            stopWidgetExecution(id)
        }
        scheduler.configure(widgets: widgets.filter { !prefs.isDisabled($0.id) })
        setVisibleWidgetIDs(visibleWidgetIDs)
        syncMenuBar()
        scheduler.setMenuBarWidgetIDs(menuBarWidgetIDs.union(dockWidgetIDs))
        updateAttention()
        objectWillChange.send()
        if !flag, scriptDisableStopTokens[id] == nil {
            refresh(widgetID: id, manual: true)
        }
    }

    /// Ends a vault widget's session: synchronously on the main thread,
    /// where the app's lifecycle calls come from; other callers (tests,
    /// background reloads) hop there. Widgets without a vault touch nothing.
    private func endVaultSession(_ id: String, permission: Manifest.VaultPermission?) {
        guard let permission else { return }
        if Thread.isMainThread {
            MainActor.assumeIsolated { vaultBroker.endWidget(id, permission: permission) }
        } else {
            Task { @MainActor [weak self] in self?.vaultBroker.endWidget(id, permission: permission) }
        }
    }

    /// Immediately invalidate callbacks, then stop the resident process. Both
    /// disabling and permission withdrawal use this path, including rapid
    /// re-enabling while the previous process is still shutting down.
    private func stopWidgetExecution(_ id: String) {
        alertGate.invalidate(id)
        // Disable, removal, revoke, denial: the vault locks with the widget.
        endVaultSession(id, permission: widgets.first(where: { $0.id == id })?.manifest.permissions?.vault)
        // A stopped widget does not monitor; its next refresh re-learns it.
        if alertMonitoringIDs.remove(id) != nil { scheduler.setMonitoringWidgetIDs(alertMonitoringIDs) }
        for task in runActionTasks.removeValue(forKey: id)?.values ?? [:].values { task.cancel() }
        nativeRefreshTasks.removeValue(forKey: id)?.task.cancel()
        nativeRefreshes.cancel(id)
        updateSnapshot(id) { $0.isLoading = false }
        scriptCallbackGate.invalidate(widgetID: id)
        _ = scriptRefreshes.cancel(widgetID: id)
        inFlight.remove(id)
        refreshAgain.remove(id) // stopped: no follow-up run
        guard let supervisor = scriptSupervisorStorage else { return }
        let stopToken = scriptCallbackGate.token(for: id)
        let stop = Task { await supervisor.stop(widgetId: id) }
        scriptDisableStopTokens[id] = stopToken
        Task { @MainActor [weak self] in
            await stop.value
            guard let self, self.scriptDisableStopTokens[id] == stopToken else { return }
            self.scriptCallbackGate.invalidate(widgetID: id)
            self.scriptDisableStopTokens.removeValue(forKey: id)
            if !self.prefs.isDisabled(id),
               let widget = self.widgets.first(where: { $0.id == id }),
               self.permissionStore.status(for: widget.manifest) == .approved {
                self.refresh(widgetID: id, manual: true)
            }
        }
    }

    /// The on-disk directory of a loaded widget (for "Reveal in Finder").
    func widgetDirectory(for id: String) -> URL? {
        widgets.first(where: { $0.id == id })?.directory
    }

    /// Requests the UI jump to and highlight a widget; always publishes on main.
    func reveal(widgetID: String) {
        if Thread.isMainThread {
            pendingReveal = widgetID
        } else {
            DispatchQueue.main.async { [weak self] in self?.pendingReveal = widgetID }
        }
    }

    // MARK: - Hot reload

    /// Watches the widget directories; any manifest/script change triggers a
    /// rescan. Snapshots are preserved per widget id, removed widgets cleaned.
    private func startHotReload() {
        let fm = FileManager.default
        for directory in Self.widgetSearchDirectories
        where fm.fileExists(atPath: directory.path) {
            do {
                let watcher = try DirectoryWatcher(
                    paths: [directory.path],
                    debounce: Self.hotReloadDebounceSec
                ) { [weak self] in
                    self?.hotReload()
                }
                hotReloadWatchers.append(watcher)
            } catch {
                NSLog("barshelf: hot reload unavailable for \(directory.path): \(error)")
            }
        }
    }

    private func hotReload() {
        NSLog("barshelf: widget directory changed — rescanning manifests")
        loadWidgets()
        // While the popup is open, immediately populate widgets that have
        // never rendered (new or previously broken manifests).
        guard scheduler.popupIsOpen else { return }
        for widget in widgets
        where visibleWidgetIDs.contains(widget.id)
            && widget.manifest.refresh?.popupOnly != true
            && snapshots[widget.id]?.viewTree == nil {
            refresh(widget, manual: false)
        }
    }

    // MARK: - Pages

    /// Distinct effective group names in page order (bucket picker / submenu).
    var allGroups: [String] {
        pages.map(\.group)
    }

    /// Distinct bucket groups in display order (for the builder's group picker).
    var bucketGroups: [String] {
        allGroups
    }

    /// The group a widget renders under: a user override wins over the manifest.
    func effectiveGroup(for id: String) -> String {
        if let override = prefs.override(for: id)?.group, !override.isEmpty {
            return override
        }
        return widgets.first(where: { $0.id == id })?.group ?? "General"
    }

    /// The card size a widget renders with: a user override wins over manifest.
    func effectiveSize(for id: String) -> String {
        if let override = prefs.override(for: id)?.size,
           let normalized = Self.normalizedBucketSize(override) {
            return normalized
        }
        return widgets.first(where: { $0.id == id })?.size ?? "M"
    }

    private static func normalizedBucketSize(_ size: String?) -> String? {
        guard let size else { return nil }
        let uppercased = size.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return ["XS", "S", "M", "L"].contains(uppercased) ? uppercased : nil
    }

    /// The sort key within a page: an override wins over the manifest order.
    func effectiveOrder(for id: String) -> Double {
        if let override = prefs.override(for: id)?.order { return override }
        return Double(widgets.first(where: { $0.id == id })?.order ?? 0)
    }

    /// Pages honor bucket overrides and hide disabled widgets; empty groups
    /// vanish. Kept side-effect free so recomputation never republishes cards.
    var pages: [WidgetPage] {
        Self.computePages(
            widgets,
            group: { self.effectiveGroup(for: $0.id) },
            order: { self.effectiveOrder(for: $0.id) },
            isDisabled: { self.prefs.isDisabled($0.id) },
            groupSort: { self.prefs.groupSortKey($0) ?? .greatestFiniteMagnitude },
            keptPages: prefs.keptPages
        )
    }

    /// Pure page layout: groups the enabled widgets, sorts members by effective
    /// order, and orders pages by an explicit group order (when set), then their
    /// first member's order, then group name.
    nonisolated static func computePages(
        _ widgets: [LoadedWidget],
        group: (LoadedWidget) -> String,
        order: (LoadedWidget) -> Double,
        isDisabled: (LoadedWidget) -> Bool,
        groupSort: (String) -> Double = { _ in .greatestFiniteMagnitude },
        keptPages: [String] = []
    ) -> [WidgetPage] {
        let visible = widgets.filter { !isDisabled($0) }
        var grouped = Dictionary(grouping: visible, by: group)
        // A page the user made stays while it has no widget showing, as a
        // place to add one; its switched-off widgets stay off.
        for name in keptPages where grouped[name] == nil { grouped[name] = [] }
        return grouped
            .map { groupName, members in
                WidgetPage(
                    group: groupName,
                    widgets: members.sorted { order($0) < order($1) }
                )
            }
            .sorted { lhs, rhs in
                let lhsGroup = groupSort(lhs.group), rhsGroup = groupSort(rhs.group)
                if lhsGroup != rhsGroup { return lhsGroup < rhsGroup }
                let lhsOrder = lhs.widgets.first.map(order) ?? 0
                let rhsOrder = rhs.widgets.first.map(order) ?? 0
                if lhsOrder != rhsOrder { return lhsOrder < rhsOrder }
                return lhs.group < rhs.group
            }
    }

    // MARK: - Menu bar promotion

    /// How often promoted entries are re-evaluated for staleness.
    private static let menuBarStalenessTickSec: TimeInterval = 15
    private lazy var menuBarUpdateBatch = MenuBarUpdateBatch { [weak self] in
        self?.syncMenuBar()
    }

    private func startMenuBarStalenessTicker() {
        guard !ownedMenuBarEntries.isEmpty else {
            menuBarStalenessTimer?.invalidate()
            menuBarStalenessTimer = nil
            return
        }
        guard menuBarStalenessTimer == nil else { return }
        let timer = Timer.scheduledTimer(
            withTimeInterval: Self.menuBarStalenessTickSec, repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.syncMenuBar()
            }
        }
        timer.tolerance = Self.menuBarStalenessTickSec / 3
        menuBarStalenessTimer = timer
    }

    /// Recomputes what the menu bar draws and tells the scheduler which
    /// widgets must keep polling while the popup is closed.
    ///
    /// Newly promoted widgets are refreshed once so the strip fills in without
    /// waiting a whole interval for the first tick.
    /// A failed refresh as the menu bar item's tooltip: what happened and
    /// what to do, the way the card says it, not the raw message.
    nonisolated static func errorTooltip(_ raw: String) -> String {
        let explanation = ErrorExplainer.explain(raw)
        return "\(explanation.cause)\n\(explanation.fix)"
    }

    /// How often this widget's reading is meant to change: the menu bar
    /// item's own interval, else the user's, else the author's, scaled by
    /// the app-wide refresh speed.
    func effectiveReadingInterval(for widget: LoadedWidget) -> Double? {
        let placement = prefs.menuBarPlacement(for: widget.manifest, widgetID: widget.id)
        let multiplier = SchedulePolicy.normalizedRefreshMultiplier(appPrefs.preferences.refreshMultiplier)
        return (placement.interval ?? prefs.refreshIntervals[widget.id] ?? widget.manifest.refresh?.interval)
            .map { $0 * multiplier }
    }

    /// The one staleness rule for a reading, wherever it is drawn (the menu
    /// bar item, its chip, its card): judged against the cadence the widget
    /// actually runs at, so a user who slows it to 30 s does not see it
    /// dimmed as stale after 2.
    func readingIsStale(_ widget: LoadedWidget, updatedAt: Date?, now: Date = Date()) -> Bool {
        MenuBarPolicy.isStale(updatedAt: updatedAt, interval: effectiveReadingInterval(for: widget), now: now)
    }

    func syncMenuBar() {
        menuBarUpdateBatch.cancel()
        let previous = menuBarWidgetIDs
        var candidates: [(entry: MenuBarEntry, order: Double?)] = []
        var intervalOverrides: [String: Double] = [:]
        var charting = Set<String>()

        for widget in widgets where !prefs.isDisabled(widget.id) {
            let placement = prefs.menuBarPlacement(
                for: widget.manifest, widgetID: widget.id
            )
            // Most widgets are not on the bar: the cheaper test first.
            guard placement.enabled,
                  permissionStore.status(for: widget.manifest) == .approved else { continue }
            let statusItem = MenuBarPolicy.effectiveStatusItem(widget.manifest.statusItem)
            let snapshot = snapshots[widget.id]
            // Only text can share the strip, so a widget that shows no label
            // gets its own item — unless the user gave it an emoji, which is
            // text and so can sit in the strip like any other.
            let hasTextIcon = MenuBarPolicy.normalizedIcon(placement.icon)
                .map { !$0.isEmpty && NSImage(systemSymbolName: $0, accessibilityDescription: nil) == nil }
                ?? false
            // Two rows cannot be drawn into a shared run of text, so the
            // stacked style takes its own item the way an icon-only widget does.
            let style = MenuBarPolicy.resolvedStyle(
                user: placement.style, manifest: statusItem.style
            )
            let separate = placement.separate
                || style == .stacked
                || style == .metrics
                || !(statusItem.showsLabel || hasTextIcon)
            let presentation = MenuBarPolicy.resolvedPresentation(
                user: placement.presentation,
                global: appPrefs.preferences.menuBarPresentation,
                live: snapshot?.statusPresentation,
                manifest: statusItem.presentation
            )
            var entry = MenuBarEntry(
                widgetID: widget.id,
                name: widget.displayName,
                symbol: statusItem.showsIcon
                    ? MenuBarPolicy.resolvedIcon(
                        user: nil,
                        live: snapshot?.statusIcon,
                        statusItem: statusItem.icon,
                        manifest: widget.manifest.icon
                    )
                    : nil,
                iconOverride: MenuBarPolicy.normalizedIcon(placement.icon),
                prefix: MenuBarPolicy.resolvedPrefix(
                    user: placement.label,
                    live: snapshot?.statusPrefix,
                    manifest: statusItem.label
                ),
                style: style,
                tint: MenuBarTint.named(snapshot?.statusTint),
                label: statusItem.showsLabel
                    ? MenuBarPolicy.normalizedLabel(snapshot?.statusLabel) : nil,
                metrics: statusItem.showsLabel
                    ? MenuBarPolicy.normalizedMetrics(snapshot?.statusMetrics ?? []) : [],
                tooltip: snapshot?.error.map(Self.errorTooltip) ?? snapshot?.statusTooltip,
                isStale: readingIsStale(widget, updatedAt: snapshot?.updatedAt),
                separate: separate,
                presentation: presentation
            )
            entry.iconSymbol = MenuBarPolicy.resolvedIcon(
                user: nil, live: snapshot?.statusIcon, statusItem: statusItem.icon, manifest: widget.manifest.icon
            )
            entry.profiles = statusItem.profiles ?? false
            if entry.profiles, statusItem.showsLabel {
                entry.profileMetrics = MenuBarPolicy.normalizedMetrics(
                    snapshot?.statusMetrics ?? [], limit: MenuBarClusterPolicy.maxChips
                )
            }
            if let interval = placement.interval { intervalOverrides[widget.id] = interval }
            var applied = MenuBarPolicy.applyingPresentation(presentation, to: entry)
            // Only an item with its own place draws a chart; the strip is
            // text, and history there would only make it redraw.
            if presentation.effectiveChart != .none, separate {
                applied = chartRecorder.charting(applied)
                charting.insert(widget.id)
            }
            candidates.append((applied, placement.order))
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
        let now = Date()
        var dormant = Set<String>()
        for entry in owned {
            switch MenuBarPolicy.meetsShowWhen(entry) {
            case nil:
                // No limit, or no reading yet: nothing to hide, and nothing
                // that should start the hold either.
                continue
            case true?:
                showWhenMetAt[entry.widgetID] = now
            case false?:
                // Held a while after its last qualifying reading, so a
                // reading hovering at the limit does not blink the item.
                let held = showWhenMetAt[entry.widgetID]
                    .map { now.timeIntervalSince($0) < Self.showWhenHold } ?? false
                if !held { dormant.insert(entry.widgetID) }
            }
        }
        showWhenMetAt = showWhenMetAt.filter { id, _ in owned.contains { $0.widgetID == id } }
        ownedMenuBarEntries = owned
        dormantMenuBarWidgetIDs = dormant
        menuBar.apply(owned.filter { !dormant.contains($0.widgetID) })
        startMenuBarStalenessTicker()
        chartRecorder.updateSaver()
        // Before the promoted-set check: a changed cadence re-arms timers even
        // when the set of promoted widgets is the same.
        scheduler.setWidgetIntervalOverrides(prefs.refreshIntervals)
        scheduler.setIntervalOverrides(intervalOverrides)
        syncScriptTimerActivity()
        let promoted = menuBarWidgetIDs
        guard promoted != previous else { return }
        scheduler.setMenuBarWidgetIDs(promoted.union(dockWidgetIDs))
        for id in promoted.subtracting(previous) {
            let widget = widgets.first { $0.id == id }
            let staleAfter = widget.flatMap { effectiveStaleAfter(for: $0) }
            let snapshot = snapshots[id] ?? WidgetSnapshot(widgetID: id)
            if snapshot.isStale(after: staleAfter) {
                refresh(widgetID: id, manual: false)
            }
        }
    }

    /// Recent menu bar readings for the trend in a menu bar item's card.
    let readingHistory = ReadingHistory()
    private let chartRecorder = MenuBarChartRecorder()
    /// Recent readings of each charting item, oldest first.
    var menuBarHistory: [String: MenuBarChartHistory] { chartRecorder.histories }
    /// Widgets whose last render asked to stay off disk.
    private var sensitiveRenderIDs: Set<String> = []

    /// Every entry the menu bar owns, in order and capped: drawn now, or
    /// hidden by its "show only when" threshold.
    private(set) var ownedMenuBarEntries: [MenuBarEntry] = []
    /// The owned entries hidden for now by their "show only when" threshold.
    private(set) var dormantMenuBarWidgetIDs: Set<String> = []
    /// When each "show only when" item last had a reading that qualified.
    private var showWhenMetAt: [String: Date] = [:]
    /// How long an item stays after its last qualifying reading.
    static let showWhenHold: TimeInterval = 60

    /// Every widget the menu bar owns: on it now, or waiting for a reading
    /// that brings it back. These are the ones that keep polling.
    var menuBarWidgetIDs: Set<String> {
        Set(ownedMenuBarEntries.map(\.widgetID))
    }

    /// Promotes or demotes a widget in the menu bar (settings UI / context
    /// menu). Passing `nil` clears the stored choice.
    func setMenuBarPlacement(_ placement: MenuBarPlacement?, for id: String) {
        prefs.setMenuBarPlacement(placement, for: id)
        syncMenuBar()
        objectWillChange.send()
    }

    /// The layout another item actually draws with: its own choice, else its
    /// widget's.
    func resolvedMenuBarStyle(for widget: LoadedWidget) -> MenuBarStyle {
        let placement = prefs.menuBarPlacement(for: widget.manifest, widgetID: widget.id)
        return MenuBarPolicy.resolvedStyle(
            user: placement.style, manifest: MenuBarPolicy.effectiveStatusItem(widget.manifest.statusItem).style
        )
    }

    /// How another item looks by its own and its widget's choices — without
    /// the app-wide style, which applies to every item anyway and would
    /// otherwise be pinned onto the one copying it.
    func resolvedMenuBarLook(for widget: LoadedWidget) -> MenuBarPresentation {
        let placement = prefs.menuBarPlacement(for: widget.manifest, widgetID: widget.id)
        return MenuBarPolicy.resolvedPresentation(
            user: placement.presentation,
            live: snapshots[widget.id]?.statusPresentation,
            manifest: MenuBarPolicy.effectiveStatusItem(widget.manifest.statusItem).presentation
        )
    }

    /// Items whose own width, text or colour choices would hide the app-wide
    /// menu bar style.
    var widgetsOverridingMenuBarStyle: [LoadedWidget] {
        widgets.filter { widget in
            guard let presentation = prefs.menuBarPlacements[widget.id]?.presentation else { return false }
            return MenuBarPolicy.clearingGlobalStyle(presentation) != presentation
        }
    }

    /// Drops every item's own width, text and colour choices so the app-wide
    /// style applies to all of them. Labels, icons, row order and precision
    /// are kept.
    func clearItemMenuBarStyles() {
        var changes: [String: MenuBarPlacement?] = [:]
        for widget in widgetsOverridingMenuBarStyle {
            guard var placement = prefs.menuBarPlacements[widget.id] else { continue }
            placement.presentation = MenuBarPolicy.clearingGlobalStyle(placement.presentation)
            let base = MenuBarPolicy.resolvedPlacement(stored: nil, statusItem: widget.manifest.statusItem)
            changes[widget.id] = .some(placement == base ? nil : placement)
        }
        prefs.setMenuBarPlacements(changes)
        syncMenuBar()
        objectWillChange.send()
    }

    /// Widgets worth listing in the menu bar picker: the author marked them
    /// promotable, or the user already promoted them. Any other widget can
    /// still be promoted from its own settings pane.
    var menuBarCandidates: [LoadedWidget] {
        widgets.filter { widget in
            guard !prefs.isDisabled(widget.id) else { return false }
            if widget.manifest.statusItem?.isPromotable == true { return true }
            return prefs.menuBarPlacement(
                for: widget.manifest, widgetID: widget.id
            ).enabled
        }
    }

    /// Widget ids currently drawn in the shared strip, left to right. This is
    /// what "move left" and "move right" operate on — the separate items are
    /// rearranged by dragging them in the menu bar itself.
    var menuBarStripOrder: [String] {
        // Owned, not drawn: a hidden item keeps its place, so a move among
        // the others cannot renumber around it.
        MenuBarPolicy.partition(ownedMenuBarEntries).strip.map(\.widgetID)
    }

    /// The run "left" and "right" move within: the items sharing the
    /// BarShelf icon, or, as a cluster, every chip (all items become chips).
    var menuBarMoveOrder: [String] {
        appPrefs.preferences.menuBarLayout == .cluster
            ? ownedMenuBarEntries.map(\.widgetID)
            : menuBarStripOrder
    }

    func canMoveInMenuBar(_ id: String, by offset: Int) -> Bool {
        MenuBarPolicy.canMove(id, by: offset, within: menuBarMoveOrder)
    }

    /// Moves a widget within the shared strip, or among the chips.
    ///
    /// Every widget in the run gets a fresh key: the stored ones may be absent
    /// or stale (nothing set them before this existed), so re-deriving the
    /// whole order is what makes one move predictable.
    func moveInMenuBar(_ id: String, by offset: Int) {
        let ids = menuBarMoveOrder
        guard MenuBarPolicy.canMove(id, by: offset, within: ids) else { return }
        for (widgetID, order) in MenuBarPolicy.reordered(ids, moving: id, by: offset) {
            guard let widget = widgets.first(where: { $0.id == widgetID }) else { continue }
            var placement = prefs.menuBarPlacement(for: widget.manifest, widgetID: widgetID)
            placement.order = order
            prefs.setMenuBarPlacement(placement, for: widgetID)
        }
        syncMenuBar()
        objectWillChange.send()
    }

    /// Edits one field of a widget's placement, keeping the rest. A menu
    /// command that toggles promotion must not silently drop the sort order
    /// the user arranged.
    func updateMenuBarPlacement(
        for id: String,
        _ change: (inout MenuBarPlacement) -> Void
    ) {
        guard let widget = widgets.first(where: { $0.id == id }) else { return }
        var placement = prefs.menuBarPlacement(for: widget.manifest, widgetID: id)
        change(&placement)
        setMenuBarPlacement(placement, for: id)
    }

    // MARK: - Popup lifecycle

    /// Called by the pager whenever the selected page changes. Page-local
    /// `onOpen` now means "when this widget's page becomes visible"; pinned
    /// widgets are included by the caller because they are always onscreen.
    func setVisibleWidgetIDs(_ ids: Set<String>) {
        let enabledIDs = Set(widgets.lazy.filter { !self.prefs.isDisabled($0.id) }.map(\.id))
        let normalized = ids.intersection(enabledIDs)
        let changed = normalized != visibleWidgetIDs
        visibleWidgetIDs = normalized
        scheduler.setVisibleWidgetIDs(normalized)
        if scheduler.popupIsOpen { countViews(normalized) }
        syncScriptTimerActivity()
        guard changed, scheduler.popupIsOpen else { return }
        refreshVisibleWidgetsIfNeeded()
        refreshWidgetsAwaitingVisibility()
    }

    func popupOpened() {
        scheduler.popupOpened()
        countUsage(.popupOpen)
        viewsCountedThisOpen = []
        countViews(visibleWidgetIDs)
        syncScriptTimerActivity()
        refreshVisibleWidgetsIfNeeded()
        refreshWidgetsAwaitingVisibility()
    }

    /// Widgets showing in the BarShelf Dock (R15). Like menu bar items they
    /// are on screen whether or not the popup is open, so they poll at their
    /// own cadence; an auto-hidden dock reports none.
    private(set) var dockWidgetIDs: Set<String> = []

    func setDockWidgetIDs(_ ids: Set<String>) {
        let normalized = ids.intersection(widgets.map(\.id))
        guard normalized != dockWidgetIDs else { return }
        let added = normalized.subtracting(dockWidgetIDs)
        dockWidgetIDs = normalized
        scheduler.setMenuBarWidgetIDs(menuBarWidgetIDs.union(normalized))
        syncScriptTimerActivity()
        for id in added {
            guard let widget = widgets.first(where: { $0.id == id }) else { continue }
            let snapshot = snapshots[id] ?? WidgetSnapshot(widgetID: id)
            if snapshot.isStale(after: effectiveStaleAfter(for: widget)) {
                refresh(widget, manual: false)
            } else if visibilityAwareWidgetIDs.contains(id), lastRefreshVisibility[id] == false {
                refresh(widget, manual: false)
            }
        }
    }

    /// Whether this widget's card is on screen: the shelf is open on its page,
    /// it is showing in its own menu bar popover, or it is in the dock.
    /// Workflows read it as `widget.visible` and use it to skip work nobody
    /// can see.
    func isCardVisible(_ widgetID: String) -> Bool {
        if menuBarPopoverWidgetID == widgetID { return true }
        if dockWidgetIDs.contains(widgetID) { return true }
        return scheduler.popupIsOpen && visibleWidgetIDs.contains(widgetID)
    }

    /// A workflow that reads `widget.visible` rendered its cheap variant while
    /// the card was closed, so opening the card has to re-run it rather than
    /// wait for the next tick — otherwise the sensor list would stay empty for
    /// up to a full refresh interval. Only widgets that actually read the flag
    /// and last ran with it off are refreshed.
    private func refreshWidgetsAwaitingVisibility() {
        for widget in widgets where visibilityAwareWidgetIDs.contains(widget.id) {
            guard isCardVisible(widget.id), lastRefreshVisibility[widget.id] == false
            else { continue }
            refresh(widget, manual: false)
        }
    }

    private func refreshVisibleWidgetsIfNeeded() {
        for widget in widgets where visibleWidgetIDs.contains(widget.id) {
            let refresh = widget.manifest.refresh
            let snapshot = snapshots[widget.id] ?? WidgetSnapshot(widgetID: widget.id)
            if refresh?.onOpen == true,
               snapshot.isStale(after: effectiveStaleAfter(for: widget)) {
                self.refresh(widget, manual: false)
            }
        }
    }

    /// Opening a reading is navigation, not an explicit refresh/retry. Reuse
    /// fresh content and preserve automatic failure backoff. Visibility-aware
    /// workflows are separately handled when menuBarPopoverWidgetID changes.
    func refreshMenuBarPopoverIfNeeded(_ widget: LoadedWidget) {
        let snapshot = snapshots[widget.id] ?? WidgetSnapshot(widgetID: widget.id)
        guard Self.needsMenuBarPopoverRefresh(
            snapshot: snapshot, staleAfterSec: effectiveStaleAfter(for: widget)
        ) else { return }
        refresh(widget, manual: false)
    }

    nonisolated static func needsMenuBarPopoverRefresh(
        snapshot: WidgetSnapshot, staleAfterSec: Double?, now: Date = Date()
    ) -> Bool {
        snapshot.viewTree == nil || snapshot.isStale(after: staleAfterSec, now: now)
    }

    func popupClosed() {
        scheduler.popupClosed()
        syncScriptTimerActivity()
    }

    // MARK: - Usage counts

    /// Counts one event on this Mac, unless the person turned counting off.
    func countUsage(_ event: UsageEvent, widgetID: String? = nil) {
        guard appPrefs.preferences.usageCountsEnabled else { return }
        usageStore.record(event, widgetID: widgetID)
    }

    /// Each widget shown on the open shelf counts as seen once per opening.
    private func countViews(_ ids: Set<String>) {
        for id in ids.subtracting(viewsCountedThisOpen).sorted() {
            countUsage(.view, widgetID: id)
        }
        viewsCountedThisOpen.formUnion(ids)
    }

    // MARK: - Refresh

    func refreshAll() {
        for widget in widgets {
            refresh(widget, manual: true)
        }
    }

    /// Ends a refresh; runs the one manual request that waited for it, if any.
    private func endInFlight(_ id: String) {
        inFlight.remove(id)
        guard refreshAgain.remove(id) != nil else { return }
        DispatchQueue.main.async { [weak self] in self?.refresh(widgetID: id, manual: true) }
    }

    func refresh(widgetID: String, manual: Bool = true) {
        guard let widget = widgets.first(where: { $0.id == widgetID }) else { return }
        refresh(widget, manual: manual)
    }

    /// Vault actions from a widget's buttons: the host does the work, the
    /// widget names only an opaque handle and a field.
    @MainActor
    func performVaultAction(_ action: NodeAction, widgetID: String) {
        guard let widget = widgets.first(where: { $0.id == widgetID }),
              let permission = widget.manifest.permissions?.vault,
              Manifest.VaultPermission.providers.contains(permission.provider),
              !prefs.isDisabled(widgetID), gatePermissions(for: widget) else { return }
        switch action.type {
        case "vaultUnlock":
            // "password" skips Touch ID: the card's Use Password button.
            vaultBroker.unlock(widgetID: widgetID, permission: permission, widgetName: widget.displayName,
                               usePassword: action.value == "password")
        case "vaultLock":
            vaultBroker.lock(permission)
        case "vaultSignOut":
            vaultBroker.signOut(widgetID: widgetID, permission: permission)
        case "vaultCopy":
            guard let handle = action.value, let field = action.field.flatMap(VaultField.init(rawValue:)) else { return }
            vaultBroker.copy(widgetID: widgetID, permission: permission, handle: handle, field: field)
        default:
            break
        }
    }

    /// A refresh the user asked for (a Refresh button, a refresh action).
    /// Workflows see `widget.requested: true` on it, so expensive work — a
    /// speed test — can wait for an explicit request instead of running on
    /// every open, resize or settings change.
    ///
    /// Returns why the refresh was turned away, if it was, so the place it
    /// was asked from can say so instead of doing nothing.
    @discardableResult
    func requestRefresh(widgetID: String) -> RefreshRejection? {
        let rejection = widgets.first { $0.id == widgetID }.flatMap(refreshRejection(for:))
        if rejection == nil { userRequestedRefreshIDs.insert(widgetID) }
        // Still goes through `refresh`: a widget waiting for permission
        // brings its approval card back, a too-new one says what to update.
        refresh(widgetID: widgetID, manual: true)
        return rejection
    }

    /// A refresh someone asked for on `surface`; a refused one is explained
    /// there with a toast.
    func requestRefresh(widgetID: String, feedbackOn surface: ToastSurface) {
        guard let rejection = requestRefresh(widgetID: widgetID),
              let widget = widgets.first(where: { $0.id == widgetID }) else { return }
        feedback(RuntimeFeedback(
            message: rejection.message(widgetName: widget.displayName),
            detail: rejection.detail, tone: .failure, surface: surface
        ))
    }

    /// Why a refresh asked for now would not run. `nil` when it would.
    func refreshRejection(for widget: LoadedWidget) -> RefreshRejection? {
        if prefs.isDisabled(widget.id) { return .disabled }
        if widget.manifest.incompatibility(hostVersion: Self.hostVersion) != nil { return .needsNewerBarShelf }
        if permissionStore.status(for: widget.manifest) != .approved { return .waitingForPermission }
        return nil
    }

    /// Refreshes stale widgets (system-wake batch). While the popup is closed
    /// only `runInBackground` widgets run (invariant 3).
    func refreshStaleWidgets(backgroundOnly: Bool) {
        for widget in widgets {
            if widget.manifest.refresh?.popupOnly == true { continue }
            if backgroundOnly, widget.manifest.refresh?.runInBackground != true { continue }
            if scheduler.popupIsOpen, !visibleWidgetIDs.contains(widget.id) { continue }
            let snapshot = snapshots[widget.id] ?? WidgetSnapshot(widgetID: widget.id)
            if snapshot.isStale(after: effectiveStaleAfter(for: widget)) {
                refresh(widget, manual: false)
            }
        }
    }

    private func effectiveStaleAfter(for widget: LoadedWidget) -> Double? {
        SchedulePolicy.effectiveStaleAfter(
            configured: widget.manifest.refresh?.staleAfterSec,
            multiplier: appPrefs.preferences.refreshMultiplier,
            intervalOverride: prefs.refreshIntervals[widget.id]
        )
    }

    func refresh(_ widget: LoadedWidget, manual: Bool = true) {
        guard !isStagedPreview else { return }
        let id = widget.id
        guard !prefs.isDisabled(id) else { return } // disabled widgets never run
        guard scriptDisableStopTokens[id] == nil else { return }
        guard !removingWidgetIDs.contains(id) else { return }
        if manual { RemoteImageService.shared.retryFailedImages() }
        guard !inFlight.contains(id) else {
            // In-flight coalescing; a manual request runs once more afterwards.
            if manual { refreshAgain.insert(id) }
            return
        }
        if !manual, !scheduler.allowsAutomaticRefresh(widgetID: id) {
            return // exponential backoff window — automatic triggers suppressed
        }
        // A widget for a newer BarShelf would render "—" or fail somewhere
        // obscure; it says what to update instead, and does not run.
        if let reason = widget.manifest.incompatibility(hostVersion: Self.hostVersion) {
            if snapshots[id]?.error != reason { updateSnapshot(id) { $0.error = reason } }
            return
        }
        // Permission enforcement: nothing runs until the user approved the
        // widget's current permission set (approval card shown instead).
        guard gatePermissions(for: widget) else { return }
        guard Self.supportedEntryKinds.contains(widget.manifest.entry.kind) else {
            let message = "entry.kind \"\(widget.manifest.entry.kind)\" is not supported in M2 (only \"exec\", \"script\", \"workflow\")"
            updateSnapshot(id) {
                $0.error = message
            }
            recordRefreshFailure(widgetID: id, error: message, startedAt: Date())
            return
        }
        if widget.manifest.entry.kind == "script" {
            refreshScript(widget, manual: manual)
            return
        }
        if widget.manifest.entry.kind == "workflow" {
            refreshWorkflow(widget)
            return
        }
        guard let source = widget.manifest.source,
              let command = source.command, !command.isEmpty
        else {
            let message = "manifest has no source.command"
            updateSnapshot(id) { $0.error = message }
            recordRefreshFailure(widgetID: id, error: message, startedAt: Date())
            return
        }
        // Runtime allowlist enforcement is fail-closed: missing/empty exec
        // permissions authorize nothing.
        guard let permission = ExecAllowlist.match(
            command: command, permissions: widget.manifest.permissions?.exec
        ) else {
            auditLog.record("exec.blocked", widgetId: id, detail: [
                "command": .string(command.joined(separator: " ")),
                "reason": .string("source.command not in permissions.exec allowlist"),
            ])
            let message = "source.command is not covered by permissions.exec allowlist"
            updateSnapshot(id) {
                $0.error = message
            }
            recordRefreshFailure(widgetID: id, error: message, startedAt: Date())
            return
        }

        let startedAt = markRefreshStarted(widgetID: id)
        let token = nativeRefreshes.begin(id)
        inFlight.insert(id)
        updateSnapshot(id) { $0.isLoading = true }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            let outcome = await self.performRefresh(
                widget: widget, source: source, command: command,
                permission: permission, token: token
            )
            self.finishRefresh(widget: widget, outcome: outcome, startedAt: startedAt, token: token)
        }
        nativeRefreshTasks[id] = (token, task)
    }

    /// Whether a native refresh started under `token` may launch its next
    /// command or perform its next side effect. The refresh task starts on a
    /// later main-actor turn and suspends between sources, so a Revoke, Deny,
    /// Disable or reload can land before the first launch or between two.
    private func nativeRefreshMayContinue(_ widget: LoadedWidget, token: NativeRefreshGate.Token) -> Bool {
        !Task.isCancelled
            && nativeRefreshes.isCurrent(widget.id, token: token)
            && !prefs.isDisabled(widget.id)
            && permissionStore.status(for: widget.manifest) == .approved
    }

    /// Shows one fired workflow alert. The authorization is re-read after
    /// macOS answers its prompt: a widget revoked in the meantime notifies
    /// nothing.
    private func deliverAlert(_ alert: WorkflowEngine.AlertSample, for widget: LoadedWidget) {
        let manifest = widget.manifest
        let store = permissionStore
        let gate = alertGate
        let widgetID = widget.id
        let generation = gate.permit(widgetID)
        let authorization = ScriptRequestAuthorization(isApproved: {
            gate.isCurrent(widgetID, generation)
                && manifest.permissions?.notifications == true
                && store.status(for: manifest) == .approved
        })
        let service = notificationService
        let audit = auditLog
        let key = UUID()
        let task = Task {
            defer { gate.finish(widgetID, key) }
            do {
                try await service.show(title: alert.title, body: alert.body, authorization: authorization)
                audit.record("notify.alert", widgetId: widgetID, detail: ["alert": .string(alert.id)])
            } catch is CancellationError {
                audit.record("notify.alert.dropped", widgetId: widgetID, detail: ["alert": .string(alert.id)])
            } catch {
                audit.record("notify.alert.failed", widgetId: widgetID, detail: [
                    "alert": .string(alert.id), "error": .string(error.localizedDescription),
                ])
            }
        }
        gate.track(widgetID, key, task)
    }

    /// Keeps the Scheduler's off-page monitoring set in step with which
    /// workflows have alerts that can fire (main actor).
    private func noteAlertMonitoring(_ widget: LoadedWidget, hasAlerts: Bool) {
        let monitors = hasAlerts
            && widget.manifest.permissions?.notifications == true
            && widget.manifest.refresh?.runInBackground == true
            && widget.manifest.refresh?.popupOnly != true
        if monitors { alertMonitoringIDs.insert(widget.id) } else { alertMonitoringIDs.remove(widget.id) }
        // Always forwarded: the Scheduler drops ids it is not configured with
        // (a disabled widget), and must get them back when they return. It
        // ignores an unchanged set.
        scheduler.setMonitoringWidgetIDs(alertMonitoringIDs)
    }

    /// Refreshes run off the main actor; the gate, the preferences and the
    /// permission store are main-actor state. Reading them from the refresh's
    /// own thread raced with the main thread changing them (a crash in
    /// `Dictionary` lookup under `NativeRefreshGate.isCurrent`), so the check
    /// goes to the main actor.
    nonisolated private func checkNativeRefresh(_ widget: LoadedWidget, token: NativeRefreshGate.Token) async throws {
        let mayContinue = await MainActor.run { self.nativeRefreshMayContinue(widget, token: token) }
        guard mayContinue else { throw CancellationError() }
    }

    /// Script widgets: ensure the resident process runs and (re)send
    /// `widget.load`. Renders arrive asynchronously via `handleScriptRender`.
    private func refreshScript(_ widget: LoadedWidget, manual: Bool) {
        let id = widget.id
        let generation = UUID().uuidString
        guard scriptRefreshes.begin(widgetID: id, generation: generation) else { return }
        inFlight.insert(id)
        markRefreshStarted(widgetID: id)
        updateSnapshot(id) { $0.isLoading = true }
        let callbackGate = scriptCallbackGate
        let callbackToken = callbackGate.token(for: id)
        let authorization = ScriptRequestAuthorization(isApproved: {
            callbackGate.accepts(widgetID: id, token: callbackToken)
        })
        let descriptor = ScriptWidgetDescriptor(
            manifest: widget.manifest,
            directory: widget.directory,
            instanceID: widget.id,
            revision: widget.loadRevision,
            authorization: authorization
        )
        let isFirstLoad = snapshots[id]?.viewTree == nil
        let reason = manual ? "manual" : (isFirstLoad ? "install" : "open")
        Task { @MainActor [weak self] in
            guard let self, authorization.isValid else { return }
            do {
                await self.scriptReloadBarrier?.value
                guard authorization.isValid else { return }
                let supervisor = self.scriptSupervisor
                await supervisor.setTimerActivity(allowing: self.allowedScriptTimerWidgetIDs, revision: self.scriptTimerPolicyRevision)
                guard authorization.isValid else { return }
                try await supervisor.load(
                    descriptor,
                    reason: reason,
                    settings: self.prefs.effectiveSettings(
                        for: widget.manifest, widgetID: widget.id
                    ),
                    loadGeneration: generation
                )
            } catch {
                guard self.scriptRefreshes.cancel(
                    widgetID: id, generation: generation
                ) else { return }
                let message = (error as? LocalizedError)?.errorDescription
                    ?? String(describing: error)
                self.updateSnapshot(id) {
                    $0.isLoading = false
                    $0.error = message // e.g. "Deno runtime not found. Install Deno: brew install deno"
                }
                self.persistShareableSnapshot(widgetID: id)
                self.endInFlight(id)
                self.scheduler.noteRefreshFailed(widgetID: id)
                self.recordRefreshFailure(widgetID: id, error: message)
            }
        }
    }

    private struct RefreshSuccess {
        var viewTree: UINode
        var nextRefreshAtMs: Double?
        /// Live menu-bar text (a workflow's `status.label`, or an adapter's
        /// status text).
        var statusLabel: String?
        var statusMetrics: [StatusMetric]?
        var statusPrefix: String?
        var statusIcon: String?
        var statusTint: String?
        var statusPresentation: MenuBarPresentation?
        /// Longer form for the menu-bar tooltip (`status.tooltip`).
        var statusTooltip: String?
    }

    nonisolated private func performRefresh(
        widget: LoadedWidget,
        source: Manifest.Source,
        command: [String],
        permission: Manifest.ExecPermission,
        token: NativeRefreshGate.Token
    ) async -> Result<RefreshSuccess, Error> {
        // Off the main actor here; see `checkNativeRefresh`.
        guard await MainActor.run(body: { self.nativeRefreshMayContinue(widget, token: token) }) else {
            return .failure(CancellationError())
        }
        auditLog.record("exec.run", widgetId: widget.id, detail: [
            "command": .string(
                permission.sensitiveOutput == true
                    ? (command.first ?? "") : command.joined(separator: " ")
            ),
            "trigger": .string("refresh"),
        ])
        let execResult = await Self.dispatchDirectExec(
            execService: execService,
            widget: widget,
            source: source,
            command: command,
            permission: permission
        )

        switch execResult {
        case let .failure(error):
            return .failure(error)
        case let .success(data):
            do {
                // An adapter may run more commands of its own.
                try await checkNativeRefresh(widget, token: token)
                if source.output == "data" {
                    guard let adapterName = source.adapter else {
                        throw RuntimeError.missingAdapter("source.output is \"data\" but no adapter is set")
                    }
                    guard let adapter = adapters[adapterName] else {
                        throw RuntimeError.missingAdapter("unknown adapter \"\(adapterName)\"")
                    }
                    // The preferences are main-actor state and this runs
                    // off it; see `checkNativeRefresh`.
                    let adapterSettings = await MainActor.run {
                        self.prefs.effectiveSettings(for: widget.manifest, widgetID: widget.id).objectValue ?? [:]
                    }
                    let context = HostAdapterContext(
                        widget: widget,
                        execService: execService,
                        defaultTimeoutMs: source.timeoutMs ?? Self.defaultTimeoutMs,
                        settings: adapterSettings
                    )
                    let result = try await adapter(data, context)
                    return .success(RefreshSuccess(
                        viewTree: result.viewTree,
                        nextRefreshAtMs: result.nextRefreshAtMs,
                        statusLabel: result.statusText
                    ))
                }
                if source.output == "xbar" {
                    let rendered = XbarPlugin.render(
                        XbarPlugin.parse(String(decoding: data, as: UTF8.self)),
                        context: Self.xbarContext(widget: widget, source: source)
                    )
                    return .success(RefreshSuccess(
                        viewTree: rendered.tree,
                        statusLabel: rendered.statusLabel,
                        statusIcon: rendered.statusIcon,
                        statusTint: rendered.statusTint
                    ))
                }
                let tree = try JSONDecoder().decode(UINode.self, from: data)
                return .success(RefreshSuccess(viewTree: tree))
            } catch {
                return .failure(error)
            }
        }
    }

    /// Direct-source launch seam. Keeping environment selection inside the
    /// dispatch used by production makes its command scope executable in tests.
    nonisolated static func dispatchDirectExec(
        execService: ExecService,
        widget: LoadedWidget,
        source: Manifest.Source,
        command: [String],
        permission: Manifest.ExecPermission
    ) async -> Result<Data, ExecService.ExecError> {
        await execService.run(
            command: command,
            discover: source.discover,
            timeoutMs: source.timeoutMs ?? Self.defaultTimeoutMs,
            workingDirectory: widget.directory,
            extraEnvironment: pluginEnvironment(
                for: widget.manifest,
                secretEnvironment(for: widget.manifest, permission: permission)
            ),
            stdoutLimit: permission.maxOutputBytes ?? ExecService.maxStdoutBytes
        )
    }

    /// An xbar/SwiftBar plugin also gets BarShelf's appearance markers, on
    /// its refresh and on the actions it runs (`XbarPlugin.environment`).
    nonisolated static func pluginEnvironment(for manifest: Manifest, _ base: [String: String]?) -> [String: String]? {
        guard manifest.source?.output == "xbar" else { return base }
        return (base ?? [:]).merging(XbarPlugin.environment(darkMode: systemIsDark)) { current, _ in current }
    }

    nonisolated static var systemIsDark: Bool {
        UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
    }

    /// How a plugin's `bash=` lines are read: the declared command, and the
    /// file it names, so the plugin calling itself through `$0` matches.
    nonisolated static func xbarContext(widget: LoadedWidget, source: Manifest.Source) -> XbarPlugin.Context {
        let command = source.command?.first ?? ""
        let file = command.hasPrefix("/") ? URL(fileURLWithPath: command)
            : command.isEmpty ? nil : widget.directory.appendingPathComponent(command)
        return XbarPlugin.Context(selfCommand: command, pluginFile: file, darkMode: systemIsDark)
    }

    // MARK: - Workflow refresh (entry.kind == "workflow")

    private func refreshWorkflow(_ widget: LoadedWidget) {
        let id = widget.id
        let workflowURL: URL
        do {
            workflowURL = try WidgetEntryResolver.resolve(
                directory: widget.directory,
                main: widget.manifest.entry.main,
                defaultName: "workflow.json"
            )
        } catch {
            updateSnapshot(id) { $0.error = error.localizedDescription }
            recordRefreshFailure(widgetID: id, error: error.localizedDescription)
            return
        }
        let settings = prefs.effectiveSettings(for: widget.manifest, widgetID: widget.id)
        // Read here, on the main actor, where visibility and size live. The
        // refresh itself runs off the main actor, and three promoted widgets
        // refresh at nearly the same moment — reading this state there, and
        // recording which workflows use it, raced.
        let visible = isCardVisible(id)
        let requested = userRequestedRefreshIDs.remove(id) != nil
        let widgetContext: JSONValue = .object([
            "locale": .string(WidgetLocalization.appLanguage),
            // `size` lets a workflow switch layout per bucket size; `visible`
            // lets it do less while nothing is on screen (the sensors widget
            // reads 46 SMC keys instead of 129 with its card closed).
            "size": .string(effectiveSize(for: id)),
            "visible": .bool(visible),
            // True only on a refresh the user asked for (`requestRefresh`).
            "requested": .bool(requested),
        ])

        let startedAt = markRefreshStarted(widgetID: id)
        let token = nativeRefreshes.begin(id)
        inFlight.insert(id)
        updateSnapshot(id) { $0.isLoading = true }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            let outcome = await self.performWorkflowRefresh(
                widget: widget, workflowURL: workflowURL,
                settings: settings, widgetContext: widgetContext, token: token
            )
            // Before `finishRefresh`, whose catch-up reads this.
            if self.nativeRefreshes.isCurrent(id, token: token), let reads = outcome.readsWidgetVisibility {
                self.recordVisibilityUse(widgetID: id, reads: reads, visible: visible)
            }
            if self.nativeRefreshes.isCurrent(id, token: token), let hasAlerts = outcome.hasAlerts {
                self.noteAlertMonitoring(widget, hasAlerts: hasAlerts)
            }
            self.finishRefresh(widget: widget, outcome: outcome.result, startedAt: startedAt, token: token)
        }
        nativeRefreshTasks[id] = (token, task)
    }

    /// What one workflow refresh produced, plus whether the workflow reads
    /// `widget.visible` (nil when it never got as far as decoding).
    private struct WorkflowRefreshOutcome {
        var result: Result<RefreshSuccess, Error>
        var readsWidgetVisibility: Bool?
        /// Whether the workflow declares alerts (nil when it never decoded).
        var hasAlerts: Bool?
    }

    /// Main actor only — see `refreshWidgetsAwaitingVisibility`.
    private func recordVisibilityUse(widgetID: String, reads: Bool, visible: Bool) {
        if reads {
            visibilityAwareWidgetIDs.insert(widgetID)
            lastRefreshVisibility[widgetID] = visible
        } else {
            visibilityAwareWidgetIDs.remove(widgetID)
            lastRefreshVisibility[widgetID] = nil
        }
    }

    nonisolated private func performWorkflowRefresh(
        widget: LoadedWidget,
        workflowURL: URL,
        settings: JSONValue,
        widgetContext: JSONValue,
        token: NativeRefreshGate.Token
    ) async -> WorkflowRefreshOutcome {
        let cached: WorkflowDefinitionCache.Entry
        do {
            cached = try workflowDefinitions.load(workflowURL)
        } catch {
            return WorkflowRefreshOutcome(result: .failure(error), readsWidgetVisibility: nil)
        }
        // Display text only, from the cached decode; widgets without a table
        // for the app's language use the cached tree as is.
        let definition = widget.manifest.localization()?.workflow(cached.definition) ?? cached.definition
        let result = await evaluateWorkflow(
            widget: widget, definition: definition,
            settings: settings, widgetContext: widgetContext, token: token
        )
        return WorkflowRefreshOutcome(
            result: result, readsWidgetVisibility: cached.readsWidgetVisibility,
            hasAlerts: !(cached.definition.alerts ?? [:]).isEmpty
        )
    }

    nonisolated private func evaluateWorkflow(
        widget: LoadedWidget,
        definition: WorkflowDefinition,
        settings: JSONValue,
        widgetContext: JSONValue,
        token: NativeRefreshGate.Token
    ) async -> Result<RefreshSuccess, Error> {
        do {
            // Storage is opt-in: only widgets that declare `permissions.storage`
            // (as `true` or an object) can read `storage.*` or commit a `store`
            // block. An explicit `false` declines.
            let storageAllowed = widget.manifest.permissions?.storage?.granted == true
            let storageSnapshot: JSONValue = storageAllowed
                ? .object(storage.snapshot(widgetId: widget.id))
                : .object([:])
            let params = try WorkflowEngine.resolvedSourceParams(
                definition, settings: settings, storage: storageSnapshot, widget: widgetContext
            )

            var sourceValues: [String: JSONValue] = [:]
            var sourceErrors: [String: JSONValue] = [:]
            for (sourceID, source) in definition.sources {
                // Each source runs after the previous one's suspension.
                try await checkNativeRefresh(widget, token: token)
                let value = params[sourceID] ?? .object([:])
                do {
                switch source.use {
                case "fs.directory":
                    let fsParams = try FileSource.Params(from: value)
                    let listing: FileSource.AuthorizedListing
                    do {
                        // Reads the preferences; see `checkNativeRefresh`.
                        let readPaths = await MainActor.run { self.effectiveReadPaths(for: widget) }
                        listing = try await Task.detached(priority: .userInitiated) {
                            try FileSource.list(fsParams, authorizedBy: readPaths)
                        }.value
                    } catch FileSource.FileSourceError.unauthorizedPath(_) {
                        auditLog.record("file.blocked", widgetId: widget.id, detail: [
                            "path": .string(fsParams.path),
                            "reason": .string("path not in permissions.readPaths or a picked folder"),
                        ])
                        throw RuntimeError.invalidWorkflow(
                            "file source path is not covered by permissions.readPaths"
                        )
                    }
                    sourceValues[sourceID] = listing.value
                    try await checkNativeRefresh(widget, token: token)
                    if fsParams.watch {
                        // The watcher table is shared by every widget's
                        // refresh, and two can finish at once.
                        let directory = listing.directory
                        await MainActor.run { self.registerWorkflowWatch(widgetID: widget.id, directory: directory) }
                    }
                case "fs.json":
                    let jsonParams = try FileSource.JSONFileParams(from: value)
                    let readPaths = await MainActor.run { self.effectiveReadPaths(for: widget) }
                    do {
                        sourceValues[sourceID] = try await Task.detached(priority: .userInitiated) {
                            try FileSource.readJSON(jsonParams, authorizedBy: readPaths)
                        }.value
                    } catch let error as FileSource.FileSourceError {
                        let reason: String
                        switch error {
                        case .unauthorizedPath: reason = "path not in permissions.readPaths or a picked folder"
                        case .notARegularFile: reason = "not a regular file"
                        case .tooLarge: reason = "over maxBytes"
                        default: throw error
                        }
                        auditLog.record("file.blocked", widgetId: widget.id, detail: [
                            "path": .string(jsonParams.path), "reason": .string(reason),
                        ])
                        throw error
                    }
                    try await checkNativeRefresh(widget, token: token)
                case "exec":
                    sourceValues[sourceID] = try await runWorkflowExecSource(
                        widget: widget, params: value
                    )
                case "http":
                    sourceValues[sourceID] = try await runWorkflowHTTPSource(
                        widget: widget, params: value
                    )
                case "system":
                    sourceValues[sourceID] = try await runWorkflowSystemSource(
                        widget: widget, params: value
                    )
                case "value":
                    sourceValues[sourceID] = value
                case "vault.items":
                    // Metadata and opaque handles from the host's own
                    // provider; never a secret, never a session.
                    guard let vault = widget.manifest.permissions?.vault else {
                        throw RuntimeError.invalidWorkflow("vault.items needs permissions.vault")
                    }
                    let broker = await MainActor.run { self.vaultBroker }
                    sourceValues[sourceID] = await broker.itemsSource(widgetID: widget.id, permission: vault)
                default:
                    throw RuntimeError.invalidWorkflow(
                        "unknown source use \"\(source.use)\" (v1: exec, fs.directory, fs.json, http, system, value, vault.items)"
                    )
                }
                } catch {
                    // An optional source's own failure becomes data the view
                    // can branch on; everything else still fails the refresh.
                    guard source.optional == true,
                          let failure = WorkflowSourceFailure.classify(error) else { throw error }
                    sourceValues[sourceID] = .null
                    sourceErrors[sourceID] = failure.value
                }
            }

            try await checkNativeRefresh(widget, token: token)
            let output = try WorkflowEngine.evaluate(
                definition, sources: sourceValues, settings: settings,
                storage: storageSnapshot, widget: widgetContext, errors: sourceErrors
            )

            // Alerts: decided against host-held state after a refresh that is
            // still current, delivered only to a widget that declared
            // notifications and is still allowed when macOS answers.
            alertStates.reconcile(widgetID: widget.id, alertIDs: Set(output.alerts.map(\.id)))
            if !output.alerts.isEmpty, widget.manifest.permissions?.notifications == true {
                try await checkNativeRefresh(widget, token: token)
                let firing = alertStates.record(
                    widgetID: widget.id, samples: output.alerts, nowMs: Date().timeIntervalSince1970 * 1000
                )
                await MainActor.run { for alert in firing { self.deliverAlert(alert, for: widget) } }
            }

            // Commit the store block after a successful eval. Failures here are
            // non-fatal (e.g. quota) — the view already rendered; log and move on.
            if storageAllowed {
                for write in output.writes {
                    do {
                        try storage.set(
                            widgetId: widget.id,
                            key: write.key,
                            value: write.value,
                            ttlMs: write.ttlMs
                        )
                    } catch {
                        NSLog("barshelf[%@] store %@ failed: %@",
                              widget.id, write.key, String(describing: error))
                    }
                }
            }

            return .success(RefreshSuccess(
                viewTree: output.viewTree,
                statusLabel: output.statusLabel,
                statusMetrics: output.statusMetrics,
                statusPrefix: output.statusPrefix,
                statusIcon: output.statusIcon,
                statusTint: output.statusTint,
                statusPresentation: output.statusPresentation,
                statusTooltip: output.statusTooltip
            ))
        } catch {
            return .failure(error)
        }
    }

    /// `system` workflow source — native CPU / memory / disk / sensor
    /// telemetry.
    ///
    /// No subprocess and no file access, but still permission-gated: each
    /// metric group must appear in `permissions.system`, and an undeclared
    /// group fails the refresh instead of being silently dropped, so a widget
    /// never renders a view whose data it was not allowed to read.
    nonisolated private func runWorkflowSystemSource(
        widget: LoadedWidget,
        params: JSONValue
    ) async throws -> JSONValue {
        let requested = SystemMetrics.requestedMetrics(from: params.objectValue?["metrics"])
        if let requested, requested.isEmpty {
            throw RuntimeError.invalidWorkflow(
                "system source \"metrics\" lists no known group"
                    + " (cpu, memory, disk, network, sensors, processes)"
            )
        }
        let (authorized, denied) = SystemMetrics.authorized(
            requested, declared: widget.manifest.permissions?.system
        )
        var allowed = authorized
        guard denied.isEmpty else {
            let names = denied.map(\.rawValue).sorted()
            auditLog.record("system.blocked", widgetId: widget.id, detail: [
                "metrics": .string(names.joined(separator: ", ")),
                "reason": .string("not declared in permissions.system"),
            ])
            throw RuntimeError.invalidWorkflow(
                "system source metrics \(names.joined(separator: ", "))"
                    + " are not covered by permissions.system"
            )
        }
        guard !allowed.isEmpty else {
            throw RuntimeError.invalidWorkflow(
                "system source needs permissions.system to declare at least one"
                    + " group (cpu, memory, disk, network, sensors)"
            )
        }
        let detail = params.objectValue?["detail"]?.boolValue == true
        let mountPoint = params.objectValue?["mount"]?.stringValue ?? "/"
        let networkInterface = params.objectValue?["interface"]?.stringValue
        let sensorGroups = Self.sensorGroups(from: params.objectValue?["sensors"])
        let sensorKeys = Self.sensorKeys(from: params.objectValue?["sensors"])
        let diskIO = params.objectValue?["io"]?.boolValue == true
        let processCount = ProcessMetrics.count(from: params.objectValue?["processes"])
        // `processes: {when: false}` skips the group for this sample — a
        // menu bar widget asks for it only while its card is on screen
        // (`"when": "${widget.visible}"`), not on every refresh.
        let skipsProcesses = allowed.contains(.processes)
            && params.objectValue?["processes"]?.objectValue?["when"]?.boolValue == false
        if skipsProcesses { allowed.remove(.processes) }
        // Running apps name the `processes` rows; read only when that group
        // is sampled.
        let apps = allowed.contains(.processes) ? await Self.runningAppIdentities() : nil
        // Sampling blocks on Mach/IOKit calls (and, on a cold CPU sampler, a
        // short baseline window), so it stays off the main thread.
        let sample = await Task.detached(priority: .userInitiated) {
            SystemMetrics.sample(
                metrics: allowed,
                detail: detail,
                sensorGroups: sensorGroups,
                sensorKeys: sensorKeys,
                diskIO: diskIO,
                mountPoint: mountPoint,
                networkInterface: networkInterface,
                processCount: processCount,
                apps: apps
            )
        }.value
        // A skipped group is an empty list, not a missing one, so a view's
        // `forEach` over it renders nothing instead of failing.
        guard skipsProcesses, case var .object(fields) = sample else { return sample }
        fields["processes"] = .array([])
        return .object(fields)
    }

    /// Regular (Dock) apps by pid: what a `processes` row calls an app.
    @MainActor
    static func runningAppIdentities() -> [Int32: ProcessMetrics.AppIdentity] {
        var apps: [Int32: ProcessMetrics.AppIdentity] = [:]
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            apps[app.processIdentifier] = ProcessMetrics.AppIdentity(
                name: app.localizedName ?? app.bundleIdentifier ?? "pid \(app.processIdentifier)",
                bundleID: app.bundleIdentifier
            )
        }
        return apps
    }

    /// `"sensors"` on a system source: which sensor readings the widget
    /// actually shows, so the sampler can skip the IOKit round trips behind
    /// the rest. Accepts one name or a list of them; `nil` (absent, `"all"`,
    /// or anything unrecognized) reads every sensor, because a narrowing hint
    /// the host does not understand must never blank a reading.
    ///
    ///     "with": { "metrics": ["sensors"], "sensors": "cpu" }
    nonisolated static func sensorGroups(from value: JSONValue?) -> Set<SensorSampler.SensorGroup>? {
        switch value {
        case let .string(name):
            return SensorSampler.groups(forReading: name)
        case let .array(items):
            var union: Set<SensorSampler.SensorGroup> = []
            for item in items {
                guard let name = item.stringValue,
                      let groups = SensorSampler.groups(forReading: name)
                else { return nil }
                union.formUnion(groups)
            }
            return union
        default:
            return nil
        }
    }

    /// The specific sensors a `"sensors"` value names as `key:<KEY>`, in
    /// order, at most 8 — each is its own read.
    ///
    ///     "sensors": ["cpu", "key:TC0P"]
    nonisolated static func sensorKeys(from value: JSONValue?) -> [String] {
        let names: [String]
        switch value {
        case let .string(name): names = [name]
        case let .array(items): names = items.compactMap(\.stringValue)
        default: return []
        }
        var seen = Set<String>()
        return Array(names.compactMap(SensorSampler.pickedKey).filter { seen.insert($0).inserted }.prefix(8))
    }

    /// `exec` workflow source — same allowlist/audit semantics as an exec
    /// widget's `source.command`.
    nonisolated private func runWorkflowExecSource(
        widget: LoadedWidget,
        params: JSONValue
    ) async throws -> JSONValue {
        guard case let .array(rawCommand)? = params.objectValue?["command"] else {
            throw RuntimeError.invalidWorkflow("exec source needs \"command\": [String]")
        }
        let command = rawCommand.compactMap(\.stringValue)
        guard !command.isEmpty else {
            throw RuntimeError.invalidWorkflow("exec source command is empty")
        }
        let permission = ExecAllowlist.match(
            command: command, permissions: widget.manifest.permissions?.exec
        )
        guard let permission else {
            auditLog.record("exec.blocked", widgetId: widget.id, detail: [
                "command": .string(command.joined(separator: " ")),
                "reason": .string("workflow exec source not in permissions.exec allowlist"),
            ])
            throw RuntimeError.invalidWorkflow(
                "exec source is not covered by permissions.exec allowlist"
            )
        }
        auditLog.record("exec.run", widgetId: widget.id, detail: [
            "command": .string(
                permission.sensitiveOutput == true
                    ? (command.first ?? "") : command.joined(separator: " ")
            ),
            "trigger": .string("workflow"),
        ])

        let discover = params.objectValue?["discover"]?.arrayValue?.compactMap(\.stringValue)
        let timeoutMs = params.objectValue?["timeoutMs"]?.numberValue.map(Int.init)
        let data = try await Self.dispatchWorkflowExec(
            execService: execService,
            widget: widget,
            command: command,
            discover: discover,
            timeoutMs: timeoutMs ?? Self.defaultTimeoutMs,
            permission: permission
        ).get()

        if params.objectValue?["parse"]?.stringValue == "text" {
            return .string(String(data: data, encoding: .utf8) ?? "")
        }
        // Default: JSON (the DSL transforms/templates need structured data).
        return try JSONValue.parse(data)
    }

    /// Workflow-source launch seam; the caller's matched permission is the
    /// sole command-level environment authority.
    nonisolated static func dispatchWorkflowExec(
        execService: ExecService,
        widget: LoadedWidget,
        command: [String],
        discover: [String]?,
        timeoutMs: Int,
        permission: Manifest.ExecPermission
    ) async -> Result<Data, ExecService.ExecError> {
        await execService.run(
            command: command,
            discover: discover,
            timeoutMs: timeoutMs,
            workingDirectory: widget.directory,
            extraEnvironment: secretEnvironment(
                for: widget.manifest, permission: permission
            ),
            stdoutLimit: permission.maxOutputBytes ?? ExecService.maxStdoutBytes
        )
    }

    /// `http` workflow source — gated behind the `network` manifest
    /// permission (declared + user-approved) and restricted to the declared
    /// host allowlist. The fetch itself (https-only, GET, 20 s / 5 MB caps,
    /// no redirect downgrade) lives in `MenubucketCore.HttpSource`.
    nonisolated private func runWorkflowHTTPSource(
        widget: LoadedWidget,
        params: JSONValue
    ) async throws -> JSONValue {
        guard PermissionStore.manifestDeclares(.network, in: widget.manifest) else {
            auditLog.record("network.blocked", widgetId: widget.id, detail: [
                "reason": .string("http source without permissions.network"),
            ])
            throw RuntimeError.invalidWorkflow(
                "http source requires the \"network\" permission in the manifest"
            )
        }
        let httpParams = try HttpSource.Params(from: params)
        guard Self.networkHostAllowed(url: httpParams.url, manifest: widget.manifest) else {
            auditLog.record("network.blocked", widgetId: widget.id, detail: [
                "url": .string(httpParams.url),
                "reason": .string("host not in permissions.network allowlist"),
            ])
            throw RuntimeError.invalidWorkflow(
                "http source host is not covered by the permissions.network allowlist"
            )
        }
        auditLog.record("network.fetch", widgetId: widget.id, detail: [
            "url": .string(httpParams.url),
            "trigger": .string("workflow"),
        ])
        return try await HttpSource.fetch(httpParams)
    }

    /// True when `url`'s host matches an entry in `permissions.network`.
    /// Entries may be a bare host (`api.github.com`), a leading-dot wildcard
    /// (`*.github.com`), a full URL/origin (host is extracted), or `*`.
    nonisolated static func networkHostAllowed(url: String, manifest: Manifest) -> Bool {
        networkHostAllowed(url: url, allowlist: manifest.permissions?.network ?? [])
    }

    /// Allowlist-only variant — also used by the renderer to gate `url` image
    /// nodes on the widget's declared hosts.
    nonisolated static func networkHostAllowed(url: String, allowlist: [String]) -> Bool {
        guard !allowlist.isEmpty,
              let host = URL(string: url)?.host?.lowercased()
        else { return false }
        for raw in allowlist {
            let entry = raw.trimmingCharacters(in: .whitespaces).lowercased()
            if entry.isEmpty { continue }
            if entry == "*" { return true }
            if entry.hasPrefix("*.") {
                if host.hasSuffix(String(entry.dropFirst())) { return true } // ".github.com"
                continue
            }
            if host == entry { return true }
            if let entryHost = URL(string: entry)?.host?.lowercased(), host == entryHost {
                return true
            }
        }
        return false
    }

    nonisolated static func execCommandAllowed(_ command: [String], manifest: Manifest) -> Bool {
        ExecAllowlist.match(command: command, permissions: manifest.permissions?.exec) != nil
    }

    /// Symlink-aware file allowlist check shared by workflow reads, rendered
    /// file thumbnails/drag items, and open/reveal actions.
    nonisolated static func filePathAllowed(_ path: String, manifest: Manifest) -> Bool {
        filePathAllowed(path, allowlist: manifest.permissions?.readPaths ?? [])
    }

    /// Folders the user picked themself in a `type: "directory"` setting.
    ///
    /// Choosing a folder in the settings UI *is* the grant, so a widget whose
    /// folder is user-selectable does not also have to declare every possible
    /// choice in `permissions.readPaths` (it cannot — it has no idea what the
    /// user will pick).
    ///
    /// `storedSettings` must be the user's saved values only, never the
    /// manifest defaults overlaid: a `default` is author-controlled, so
    /// honoring it here would let any widget self-grant a read root it was
    /// never approved for (`{"type": "directory", "default": "~/.ssh"}`).
    /// Defaults still have to be covered by `permissions.readPaths`.
    nonisolated static func userGrantedReadPaths(
        manifest: Manifest,
        storedSettings: [String: JSONValue]
    ) -> [String] {
        let directoryKeys = (manifest.settings ?? [])
            .filter { $0.type == "directory" }
            .compactMap(\.key)
        return directoryKeys.compactMap { key in
            guard let path = storedSettings[key]?.stringValue, !path.isEmpty else { return nil }
            return path
        }
    }

    /// Every read root a widget currently has: what its author declared, plus
    /// what the user picked. Use this over `manifest.permissions.readPaths`
    /// for any live permission check.
    func effectiveReadPaths(for widget: LoadedWidget) -> [String] {
        (widget.manifest.permissions?.readPaths ?? [])
            + Self.userGrantedReadPaths(
                manifest: widget.manifest,
                storedSettings: prefs.settings(for: widget.id)
            )
    }

    nonisolated static func filePathAllowed(_ path: String, allowlist: [String]) -> Bool {
        guard !allowlist.isEmpty else { return false }
        let target = canonicalFileURL(path)
        return allowlist.contains { allowed in
            let root = canonicalFileURL(allowed)
            return target.path == root.path || target.path.hasPrefix(root.path + "/")
        }
    }

    nonisolated private static func canonicalFileURL(_ path: String) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        var existing = URL(fileURLWithPath: expanded).standardizedFileURL
        var missingComponents: [String] = []
        while existing.path != "/", !FileManager.default.fileExists(atPath: existing.path) {
            missingComponents.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        var resolved = existing.resolvingSymlinksInPath()
        for component in missingComponents {
            resolved.appendPathComponent(component)
        }
        return resolved.standardizedFileURL
    }

    func filePathAllowed(_ path: String, widgetID: String) -> Bool {
        guard let widget = widgets.first(where: { $0.id == widgetID }) else { return false }
        let allowed = Self.filePathAllowed(path, allowlist: effectiveReadPaths(for: widget))
        if !allowed {
            auditLog.record("file.blocked", widgetId: widgetID, detail: [
                "path": .string(path),
                "reason": .string("path not in permissions.readPaths or a picked folder"),
            ])
        }
        return allowed
    }

    // MARK: - URL refresh trigger (`barshelf://refresh?widget=<id>`)

    /// Deep-link trigger handler. Refreshes only widgets that opted in with a
    /// `url` trigger: a specific `widgetID` refreshes that widget (unknown or
    /// non-opted-in id → no-op); `nil` refreshes every url-trigger widget.
    func handleURLRefreshTrigger(widgetID: String?) {
        for widget in widgets where declaresURLTrigger(widget.manifest) {
            if let widgetID, widget.id != widgetID { continue }
            // A deep link is an explicit operator action, even when the popup
            // is closed. Treat it like the refresh button so visibility and
            // automatic-backoff gates do not turn a documented trigger into a
            // silent no-op (especially for newly added instances).
            refresh(widget, manual: true)
        }
    }

    private func declaresURLTrigger(_ manifest: Manifest) -> Bool {
        manifest.refresh?.triggers?.contains(.url) ?? false
    }

    private func registerWorkflowWatch(
        widgetID: String,
        directory: FileSource.AuthorizedDirectory
    ) {
        // Re-arm from every successful listing so the watcher retains the
        // exact descriptor-authorized object, not a subsequently reopened path.
        workflowWatchers[widgetID]?.cancel()
        do {
            workflowWatchers[widgetID] = try DirectoryWatcher(
                directory: directory,
                debounce: Scheduler.watchDebounceSec
            ) { [weak self] in
                guard let self,
                      self.scheduler.popupIsOpen,
                      self.visibleWidgetIDs.contains(widgetID)
                else { return }
                self.refresh(widgetID: widgetID, manual: false)
            }
        } catch {
            NSLog("barshelf: workflow watch unavailable for \(directory.path): \(error)")
        }
    }

    private func finishRefresh(
        widget: LoadedWidget,
        outcome: Result<RefreshSuccess, Error>,
        startedAt: Date,
        token: NativeRefreshGate.Token
    ) {
        let id = widget.id
        if nativeRefreshTasks[id]?.token == token { nativeRefreshTasks.removeValue(forKey: id) }
        switch nativeRefreshes.finish(id, token: token) {
        case .superseded: return
        case .staleConfiguration:
            endInFlight(id)
            refreshStartedAt.removeValue(forKey: id)
            if let current = widgets.first(where: { $0.id == id }), !prefs.isDisabled(id) {
                updateSnapshot(id) { $0.isLoading = false }
                refresh(current, manual: false)
            }
            return
        case .current: break
        }
        endInFlight(id)
        // Stopped by a permission change or Disable, not failed: nothing
        // to publish and no backoff.
        if case let .failure(error) = outcome, error is CancellationError {
            refreshStartedAt.removeValue(forKey: id)
            updateSnapshot(id) { $0.isLoading = false }
            return
        }

        var snapshot = snapshots[id] ?? WidgetSnapshot(widgetID: id)
        snapshot.isLoading = false
        let completedAt = Date()

        switch outcome {
        case let .success(success):
            snapshot.viewTree = success.viewTree
            snapshot.updatedAt = completedAt
            snapshot.error = nil
            snapshot.statusLabel = success.statusLabel
            snapshot.statusMetrics = success.statusMetrics
            snapshot.statusPrefix = success.statusPrefix
            snapshot.statusIcon = success.statusIcon
            snapshot.statusTint = success.statusTint
            snapshot.statusPresentation = success.statusPresentation
            snapshot.statusTooltip = success.statusTooltip
            if !widget.isSensitive {
                persistSnapshot(snapshot) // sensitive renders stay memory-only
            }
            scheduler.noteRefreshSucceeded(widgetID: id, nextRefreshAtMs: success.nextRefreshAtMs)
            recordRefreshSuccess(
                widgetID: id, startedAt: startedAt, completedAt: completedAt
            )
        case let .failure(error):
            // Last-good render stays; only the error banner changes.
            let message = Self.describe(error: error, widget: widget)
            snapshot.error = message
            if !widget.isSensitive, !sensitiveRenderIDs.contains(id) {
                persistSnapshot(snapshot)
            }
            scheduler.noteRefreshFailed(widgetID: id)
            recordRefreshFailure(
                widgetID: id, error: message,
                startedAt: startedAt, completedAt: completedAt
            )
        }
        setSnapshot(snapshot, for: id)
        // A card that opened while this refresh was already running had its
        // forced re-run dropped by the in-flight guard. Now that the guard is
        // clear, the widget catches up rather than showing its cheap render
        // until the next tick. Only after a success: a workflow that fails
        // before it records its visibility would otherwise be re-run here
        // forever.
        if case .success = outcome {
            refreshWidgetsAwaitingVisibility()
        }
    }

    @discardableResult
    private func markRefreshStarted(widgetID: String) -> Date {
        let date = Date()
        refreshStartedAt[widgetID] = date
        return date
    }

    private func recordRefreshSuccess(
        widgetID: String,
        startedAt: Date? = nil,
        completedAt: Date = Date()
    ) {
        let start = startedAt ?? refreshStartedAt[widgetID]
        refreshStartedAt.removeValue(forKey: widgetID)
        refreshStatsStore.recordSuccess(
            widgetID: widgetID,
            durationMs: start.map { completedAt.timeIntervalSince($0) * 1000 },
            at: completedAt
        )
        publishRefreshStats()
    }

    private func recordRefreshFailure(
        widgetID: String,
        error: String,
        startedAt: Date? = nil,
        completedAt: Date = Date()
    ) {
        let start = startedAt ?? refreshStartedAt[widgetID]
        refreshStartedAt.removeValue(forKey: widgetID)
        refreshStatsStore.recordFailure(
            widgetID: widgetID,
            error: error,
            durationMs: start.map { completedAt.timeIntervalSince($0) * 1000 },
            at: completedAt
        )
        publishRefreshStats()
    }

    private func publishRefreshStats() {
        refreshStats.apply(refreshStatsStore.all)
    }

    /// Human-readable error; appends Keychain setup guidance when a
    /// keychain-enabled widget fails on a password (e.g. otpeek vault).
    private static func describe(error: Error, widget: LoadedWidget) -> String {
        let base = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        if widget.manifest.permissions?.keychain == true,
           base.lowercased().contains("password"),
           !base.contains("security add-generic-password") {
            let declaredEnv = declaredEnvironmentVariables(for: widget.manifest)
            let accounts = declaredEnv
                .filter { $0.hasSuffix("_PASSWORD") }
                .map(KeychainStore.account(forEnvironmentVariable:))
            if let account = accounts.first {
                return base + "\nStore the password in the Keychain:\n"
                    + "security add-generic-password -s \(KeychainStore.service) -a \(account) -w"
            }
        }
        return base
    }

    // MARK: - Secret / environment injection

    static func declaredEnvironmentVariables(for manifest: Manifest) -> [String] {
        var names: [String] = manifest.permissions?.env ?? []
        for permission in manifest.permissions?.exec ?? [] {
            names.append(contentsOf: permission.env ?? [])
        }
        var seen: Set<String> = []
        return names.filter { seen.insert($0).inserted }
    }

    /// Builds the only widget-specific environment values an exec may receive:
    /// explicitly declared host variables, with an optional Keychain fallback.
    nonisolated static func secretEnvironment(
        for manifest: Manifest,
        permission: Manifest.ExecPermission,
        hostEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        readSecret: (String) -> String? = { KeychainStore.readPassword(account: $0) }
    ) -> [String: String]? {
        var extra: [String: String] = [:]
        let declaredNames = (manifest.permissions?.env ?? []) + (permission.env ?? [])
        for name in Set(declaredNames) {
            if let value = hostEnvironment[name] {
                extra[name] = value
            } else if manifest.permissions?.keychain == true {
                let account = KeychainStore.account(forEnvironmentVariable: name)
                if let value = readSecret(account) {
                    extra[name] = value
                }
            }
        }
        return extra.isEmpty ? nil : extra
    }

    // MARK: - Declarative `run` action

    /// Executes a `run` action's command iff it matches the widget's
    /// `permissions.exec` allowlist; mismatches are blocked and logged.
    @discardableResult
    func performRun(
        action: NodeAction, widgetID: String, title: String? = nil, surface: ToastSurface = .popup
    ) -> Task<Void, Never>? {
        guard let widget = widgets.first(where: { $0.id == widgetID }) else { return nil }
        guard !prefs.isDisabled(widgetID), !removingWidgetIDs.contains(widgetID) else { return nil }
        guard gatePermissions(for: widget) else { return nil }
        guard let command = action.command, !command.isEmpty else {
            NSLog("barshelf: run action from %@ has no command", widgetID)
            return nil
        }
        guard let permission = ExecAllowlist.match(
            command: command, permissions: widget.manifest.permissions?.exec
        ) else {
            NSLog(
                "barshelf: BLOCKED run action from %@ — not in permissions.exec allowlist: %@",
                widgetID, command.joined(separator: " ")
            )
            auditLog.record("exec.blocked", widgetId: widgetID, detail: [
                "command": .string(command.joined(separator: " ")),
                "reason": .string("run action not in permissions.exec allowlist"),
            ])
            feedback(RuntimeFeedback(
                message: Self.actionFailureTitle(title),
                detail: String(localized: "This widget isn’t allowed to run that command. Check for a widget update."),
                tone: .failure, surface: surface
            ))
            return nil
        }
        auditLog.record("exec.run", widgetId: widgetID, detail: [
            "command": .string(
                permission.sensitiveOutput == true
                    ? (command.first ?? "") : command.joined(separator: " ")
            ),
            "trigger": .string("run-action"),
        ])

        let thenRefresh = action.thenRefresh ?? false
        let actionID = UUID()
        let callbackGate = scriptCallbackGate
        let callbackToken = callbackGate.token(for: widgetID)
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.runActionTasks[widgetID]?.removeValue(forKey: actionID)
                if self.runActionTasks[widgetID]?.isEmpty == true { self.runActionTasks.removeValue(forKey: widgetID) }
            }
            guard !Task.isCancelled, callbackGate.accepts(widgetID: widgetID, token: callbackToken),
                  !self.prefs.isDisabled(widgetID), !self.removingWidgetIDs.contains(widgetID),
                  self.permissionStore.status(for: widget.manifest) == .approved else { return }
            let result = await Self.dispatchRunActionExec(
                execService: self.execService,
                widget: widget,
                command: command,
                permission: permission
            )
            guard !Task.isCancelled, callbackGate.accepts(widgetID: widgetID, token: callbackToken),
                  self.permissionStore.status(for: widget.manifest) == .approved else { return }
            switch result {
            case .success:
                if thenRefresh {
                    self.refresh(widgetID: widgetID, manual: true)
                }
            case let .failure(error):
                // An action has its own channel: a toast where the button
                // was. The card's reading is still as good as it was, so the
                // snapshot keeps it — no "Cached — refresh failed" badge for
                // something that was not a refresh.
                let raw = error.localizedDescription
                NSLog("barshelf: run action from %@ failed: %@", widgetID, raw)
                let explanation = ErrorExplainer.explain(raw, context: .action)
                self.feedback(RuntimeFeedback(
                    message: Self.actionFailureTitle(title),
                    detail: "\(explanation.cause) \(explanation.fix)",
                    tone: .failure, surface: surface
                ))
            }
        }
        runActionTasks[widgetID, default: [:]][actionID] = task
        return task
    }

    /// "Couldn't Restart", or a plain "That didn't work" for a button with
    /// no words (an icon, a whole row).
    nonisolated static func actionFailureTitle(_ title: String?) -> String {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return String(localized: "That didn’t work") }
        return String(localized: "Couldn’t \(trimmed)", comment: "Toast: a widget's button failed; the argument is the button's title.")
    }

    /// Declarative run-action launch seam, also used by the production action
    /// task so tests can observe the exact child environment it supplies.
    nonisolated static func dispatchRunActionExec(
        execService: ExecService,
        widget: LoadedWidget,
        command: [String],
        permission: Manifest.ExecPermission
    ) async -> Result<Data, ExecService.ExecError> {
        let source = widget.manifest.source
        let discover = (command.first == source?.command?.first) ? source?.discover : nil
        return await execService.run(
            command: command,
            discover: discover,
            timeoutMs: source?.timeoutMs ?? Self.defaultTimeoutMs,
            workingDirectory: widget.directory,
            extraEnvironment: pluginEnvironment(
                for: widget.manifest,
                secretEnvironment(for: widget.manifest, permission: permission)
            ),
            stdoutLimit: permission.maxOutputBytes ?? ExecService.maxStdoutBytes
        )
    }

    enum RuntimeError: Error, LocalizedError {
        case missingAdapter(String)
        case invalidWorkflow(String)
        case widgetNotFound(String)
        case notRemovable(String)
        case invalidInstanceName(String)

        var errorDescription: String? {
            switch self {
            case let .missingAdapter(message): return message
            case let .invalidWorkflow(message): return message
            case .widgetNotFound: return String(localized: "This widget is no longer installed. It may have been removed or updated a moment ago.")
            case let .notRemovable(message): return message
            case let .invalidInstanceName(message): return message
            }
        }
    }

    private func updateSnapshot(_ id: String, mutate: (inout WidgetSnapshot) -> Void) {
        var snapshot = snapshots[id] ?? WidgetSnapshot(widgetID: id)
        mutate(&snapshot)
        setSnapshot(snapshot, for: id)
    }

    // MARK: - Staged preview (landing-page media)

    /// Set by `stagePreview`: from then on nothing refreshes and only staged
    /// renders reach the cards.
    private(set) var isStagedPreview = false
    private var isWritingStage = false

    /// Marketing renders only (`barshelf-app landing-media`): replaces the
    /// loaded widgets with `staged`, shows `renders` as their current
    /// snapshots, and stops every refresh, so recorded frames are
    /// deterministic and never carry this Mac's own data. The runtime is
    /// not usable for anything else afterwards.
    func stagePreview(widgets staged: [LoadedWidget], renders: [WidgetSnapshot]) {
        isStagedPreview = true
        scheduler.configure(widgets: [])
        for watcher in hotReloadWatchers { watcher.cancel() }
        hotReloadWatchers = []
        menuBarStalenessTimer?.invalidate()
        menuBarStalenessTimer = nil
        isWritingStage = true
        defer { isWritingStage = false }
        widgets = staged
        for id in Array(overlayCards.keys) { setOverlay(nil, for: id) }
        for render in renders { setSnapshot(render, for: render.widgetID) }
    }

    /// A staged widget's next render: one step of a recorded demo.
    func stageRender(_ render: WidgetSnapshot) {
        guard isStagedPreview else { return }
        isWritingStage = true
        defer { isWritingStage = false }
        setSnapshot(render, for: render.widgetID)
    }

    // MARK: - Per-widget publish routing (R05 perf)

    /// The card model the popup UI observes for this widget. Created lazily so
    /// closed-popup refreshes don't allocate view models.
    func cardModel(for widgetID: String) -> WidgetCardModel {
        if let existing = cardModels[widgetID] { return existing }
        let model = WidgetCardModel(
            snapshot: snapshots[widgetID] ?? WidgetSnapshot(widgetID: widgetID),
            overlay: overlayCards[widgetID]
        )
        cardModels[widgetID] = model
        return model
    }

    /// Single write path for snapshots: no-op (publish suppressed) when the
    /// snapshot is unchanged; otherwise only the affected card model publishes.
    private func setSnapshot(_ snapshot: WidgetSnapshot, for id: String) {
        // A staged preview shows only what was staged.
        guard !isStagedPreview || isWritingStage else { return }
        guard snapshots[id] != snapshot else { return }
        let previous = snapshots[id]
        let errorChanged = previous?.error != snapshot.error
        snapshots[id] = snapshot
        cardModels[id]?.snapshot = snapshot
        if errorChanged { updateAttention() }
        if menuBarWidgetIDs.contains(id), previous?.updatedAt != snapshot.updatedAt,
           let reading = ReadingHistory.reading(of: snapshot) {
            readingHistory.record(id, reading)
        }
        if menuBarWidgetIDs.contains(id), Self.menuBarStateChanged(from: previous, to: snapshot) {
            // Loading/error-only changes are not new measurements. Inserting
            // those into chart history repeated the previous reading.
            if previous?.updatedAt != snapshot.updatedAt || previous?.statusMetrics != snapshot.statusMetrics
                || previous?.statusLabel != snapshot.statusLabel {
                chartRecorder.markPending(id)
            }
            menuBarUpdateBatch.request()
        }
    }

    /// Card loading/layout changes do not affect a status item. Avoid rebuilding
    /// every promoted entry (including symbol lookup and chart policy) for them.
    nonisolated static func menuBarStateChanged(from previous: WidgetSnapshot?, to current: WidgetSnapshot) -> Bool {
        guard let previous else { return true }
        return previous.updatedAt != current.updatedAt || previous.error != current.error
            || previous.statusLabel != current.statusLabel || previous.statusMetrics != current.statusMetrics
            || previous.statusPrefix != current.statusPrefix || previous.statusIcon != current.statusIcon
            || previous.statusTint != current.statusTint || previous.statusPresentation != current.statusPresentation
            || previous.statusTooltip != current.statusTooltip
    }

    /// Single write path for overlay cards (`nil` removes), same suppression.
    private func setOverlay(_ overlay: CardOverlay?, for id: String) {
        guard !isStagedPreview || isWritingStage else { return }
        guard overlayCards[id] != overlay else { return }
        overlayCards[id] = overlay
        cardModels[id]?.overlay = overlay
        updateAttention()
    }

    /// Recomputes the widget part of `attention` from the current state.
    private func updateAttention() {
        let reasons = ShelfAttention.widgetReasons(
            widgetIDs: widgets.map(\.id),
            isDisabled: { prefs.isDisabled($0) },
            overlay: { overlayCards[$0] },
            error: { snapshots[$0]?.error }
        )
        attention.set(.approvalNeeded, reasons.contains(.approvalNeeded))
        attention.set(.widgetError, reasons.contains(.widgetError))
        attention.setWaitingWidgetIDs(widgets.map(\.id).filter { id in
            !prefs.isDisabled(id) && overlayCards[id]?.needsApproval == true
        })
    }

    /// Drops per-widget state for removed widget ids (hot reload cleanup).
    private func removeWidgetState(notIn liveIDs: Set<String>) {
        readingHistory.retain(liveIDs)
        alertStates.retain(widgetIDs: liveIDs)
        // A throttled cache write outlives the widget by up to the cache's
        // throttle interval; left alone it would re-create the cache file
        // of a widget removed by hot reload, and a reinstall would show it.
        snapshotCache.cancelPending(notIn: liveIDs)
        snapshots = snapshots.filter { liveIDs.contains($0.key) }
        overlayCards = overlayCards.filter { liveIDs.contains($0.key) }
        cardModels = cardModels.filter { liveIDs.contains($0.key) }
        updateAttention()
        inFlight.formIntersection(liveIDs)
        refreshStartedAt = refreshStartedAt.filter { liveIDs.contains($0.key) }
    }

    // MARK: - Render snapshot cache

    private func persistShareableSnapshot(widgetID: String) {
        guard let widget = widgets.first(where: { $0.id == widgetID }),
              !widget.isSensitive, !sensitiveRenderIDs.contains(widgetID),
              permissionStore.status(for: widget.manifest) == .approved,
              let snapshot = snapshots[widgetID] else { return }
        persistSnapshot(snapshot)
    }

    private func persistSnapshot(_ snapshot: WidgetSnapshot) {
        let id = snapshot.widgetID
        if desktopMirror.isAnswering(id) {
            // Someone pressed refresh on a desktop widget: this render goes
            // out now, and the cache is written with it.
            snapshotCache.writeNow(snapshot)
            desktopMirror.publish(snapshot)
            return
        }
        snapshotCache.writeThrottled(snapshot)
    }
}

// MARK: - Desktop widgets (R14)

/// The reads `DesktopWidgetMirror` is given; `widgets`, `snapshots` and
/// `effectiveGroup(for:)` are the runtime's own.
extension WidgetRuntime: DesktopWidgetMirrorSource {
    func hasSensitiveRender(_ widgetID: String) -> Bool {
        sensitiveRenderIDs.contains(widgetID)
    }

    func isDisabled(_ widgetID: String) -> Bool {
        prefs.isDisabled(widgetID)
    }

    func permissionStatus(for manifest: Manifest) -> PermissionStore.Status {
        permissionStore.status(for: manifest)
    }

    func accent(for widget: LoadedWidget) -> String? {
        prefs.effectiveAppearance(for: widget.manifest, widgetID: widget.id).accent
    }

    func refreshIntervalOverride(for widgetID: String) -> Double? {
        prefs.refreshIntervals[widgetID]
    }

    var refreshMultiplier: Double { appPrefs.preferences.refreshMultiplier }
}

// MARK: - Host adapter context

/// `AdapterContext` backed by the host's ExecService + manifest allowlist.
/// Extra execs reuse the source's discover chain when they target the same
/// binary. Environment values are resolved for the adapter command's own
/// matched permission rather than inherited from the source command.
struct HostAdapterContext: AdapterContext, @unchecked Sendable {
    let widget: LoadedWidget
    let execService: ExecService
    let defaultTimeoutMs: Int
    let settings: [String: JSONValue]

    func runAllowed(command: [String]) async throws -> Data {
        guard let permission = ExecAllowlist.match(
            command: command, permissions: widget.manifest.permissions?.exec
        ) else {
            NSLog(
                "barshelf: BLOCKED adapter exec from %@ — not in allowlist: %@",
                widget.id, command.joined(separator: " ")
            )
            throw AdapterError.execNotAllowed(command.joined(separator: " "))
        }

        let source = widget.manifest.source
        let discover = (command.first == source?.command?.first) ? source?.discover : nil
        let result = await execService.run(
            command: command,
            discover: discover,
            timeoutMs: defaultTimeoutMs,
            workingDirectory: widget.directory,
            extraEnvironment: WidgetRuntime.secretEnvironment(
                for: widget.manifest, permission: permission
            ),
            stdoutLimit: permission.maxOutputBytes ?? ExecService.maxStdoutBytes
        )
        switch result {
        case let .success(data): return data
        case let .failure(error): throw error
        }
    }
}
