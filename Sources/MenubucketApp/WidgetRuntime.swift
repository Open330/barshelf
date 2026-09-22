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
        let prefix = manifest.id + "--"
        guard instanceID.hasPrefix(prefix) else { return manifest.name }
        let label = String(instanceID.dropFirst(prefix.count))
        return label.isEmpty ? manifest.name : "\(manifest.name) · \(label)"
    }
    var group: String { manifest.bucket?.group ?? "General" }
    var order: Int { manifest.bucket?.order ?? 0 }
    var size: String { manifest.bucket?.size ?? "M" }

    /// Sensitive widgets never log stdout and never cache renders to disk.
    var isSensitive: Bool {
        manifest.permissions?.exec?.contains { $0.sensitiveOutput == true } ?? false
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
    @Published fileprivate(set) var overlay: UINode?

    fileprivate init(snapshot: WidgetSnapshot, overlay: UINode?) {
        self.snapshot = snapshot
        self.overlay = overlay
    }
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

/// Loads manifests, delegates trigger scheduling to `Scheduler`, and publishes
/// per-widget snapshots.
///
/// Refresh triggers (M1): popup open (`refresh.onOpen` + staleness), manual,
/// interval, adapter deadline (`nextRefreshAtMs`), FSEvents watch, and system
/// wake. In-flight refreshes are coalesced; failures keep the last-good render
/// (surfaced via `snapshot.error`) and feed the exponential backoff.
final class WidgetRuntime: ObservableObject {
    @Published private(set) var widgets: [LoadedWidget] = []
    /// Source of truth for renders. Deliberately *not* `@Published`: updates
    /// are routed to the affected widget's `WidgetCardModel` only (publish
    /// suppressed when the snapshot is unchanged, `Equatable`).
    private(set) var snapshots: [String: WidgetSnapshot] = [:]
    /// Host-generated cards rendered *instead of* the snapshot tree:
    /// permission approval prompts and crash-loop "Restart Widget" cards.
    /// Same publish routing as `snapshots`.
    private(set) var overlayCards: [String: UINode] = [:]
    private var cardModels: [String: WidgetCardModel] = [:]
    /// Pinned widgets + per-widget settings overrides (user preferences).
    let prefs = WidgetPrefs()
    let appPrefs: AppPrefs
    /// Observed by the Monitoring pane only — see `RefreshStatsModel`.
    let refreshStats = RefreshStatsModel()
    /// Widget id the UI should jump to and highlight (post-install reveal, R11).
    /// Consumers clear it after handling.
    @Published var pendingReveal: String?
    /// Live menu-bar text for promoted widgets. Observed by the menu bar only,
    /// so a 2 s status refresh never invalidates the popup's view tree.
    let menuBar = MenuBarStatusStore()

    private let execService = ExecService()
    let scheduler = Scheduler()
    private let refreshStatsStore: RefreshStatsStore
    private var cancellables: Set<AnyCancellable> = []
    private var inFlight: Set<String> = []
    private var scriptRefreshes = ScriptRefreshCoalescer()
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
            refreshWidgetsAwaitingVisibility()
        }
    }
    /// Widgets whose last refresh ran a workflow that reads `widget.visible`,
    /// and the value it saw. Only these need re-running when a card appears.
    private var visibilityAwareWidgetIDs: Set<String> = []
    private var lastRefreshVisibility: [String: Bool] = [:]
    /// Decoded `workflow.json` files, reused while unchanged on disk.
    private let workflowDefinitions = WorkflowDefinitionCache()

    // MARK: Script runtime + permission enforcement (M2)

    private let auditLog = AuditLog()
    private let permissionStore = PermissionStore(
        fileURL: WidgetRuntime.applicationSupportDirectory
            .appendingPathComponent("permissions.json")
    )
    private let notificationService = NotificationService()
    private var scriptSupervisorStorage: RuntimeSupervisor?

    /// Per-widget persistent KV store, shared by the script runtime
    /// (`host.storage.*`) and workflow persistence (`storage.*` reads +
    /// `store` writes) so both see one namespace per widget.
    private let storage = StorageService(
        directory: WidgetRuntime.applicationSupportDirectory
            .appendingPathComponent("storage", isDirectory: true)
    )

    /// Builtin adapter registry for `output = "data"` sources (M1 contract:
    /// async, context-carrying, may return a deadline + status text).
    private let adapters: [String: (Data, AdapterContext) async throws -> AdapterResult] = [
        AasUsageAdapter.name: AasUsageAdapter.adapt,
        OtpeekAdapter.name: OtpeekAdapter.adapt,
    ]

    private static let defaultTimeoutMs = 25_000
    private static let hotReloadDebounceSec: TimeInterval = 0.4

    init(
        appPrefs: AppPrefs = .shared,
        refreshStatsStore: RefreshStatsStore? = nil
    ) {
        self.appPrefs = appPrefs
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
                self?.flushPendingPersists()
                self?.refreshStatsStore.flush()
            }
            .store(in: &cancellables)
        seedStarterWidgets()
        refreshBundledWidgets()
        loadWidgets()
        startHotReload()
        startMenuBarStalenessTicker()
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

    static var applicationSupportDirectory: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("barshelf", isDirectory: true)
    }

    /// Created on first script-widget use (deno-based launch plans injected;
    /// tests build their own supervisor with stub launch plans).
    private var scriptSupervisor: RuntimeSupervisor {
        if let existing = scriptSupervisorStorage { return existing }
        let appSupport = Self.applicationSupportDirectory
        let notificationService = self.notificationService
        let weakRuntime = WeakWidgetRuntimeBox(self)
        let configuration = RuntimeSupervisorConfiguration(
            makeLaunchPlan: { widget in
                try DenoRuntime.makeLaunchPlan(
                    widget: widget,
                    stateDirectory: appSupport.appendingPathComponent("runtime", isDirectory: true)
                )
            },
            storage: storage,
            secrets: KeychainSecretStore(),
            notify: { title, body in
                try await notificationService.show(title: title, body: body)
            },
            audit: auditLog,
            widgetLogs: WidgetLogStore(),
            appearance: {
                UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
                    ? "dark"
                    : "light"
            }
        )
        let events = RuntimeSupervisorEvents(
            onRender: { widgetId, params, revision in
                DispatchQueue.main.async {
                    weakRuntime.value?.handleScriptRender(
                        widgetId: widgetId,
                        params: params,
                        revision: revision
                    )
                }
            },
            onLoadComplete: { widgetId, generation, error in
                DispatchQueue.main.async {
                    weakRuntime.value?.handleScriptLoadComplete(
                        widgetId: widgetId,
                        generation: generation,
                        error: error
                    )
                }
            },
            onStateChange: { widgetId, state in
                DispatchQueue.main.async {
                    weakRuntime.value?.handleScriptStateChange(widgetId: widgetId, state: state)
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
        return supervisor
    }

    private func handleScriptRender(widgetId: String, params: RenderParams, revision: Int) {
        guard let widget = widgets.first(where: { $0.id == widgetId }) else { return }
        if let generation = params.loadGeneration {
            _ = scriptRefreshes.markRendered(widgetID: widgetId, generation: generation)
        }
        var snapshot = snapshots[widgetId] ?? WidgetSnapshot(widgetID: widgetId)
        snapshot.isLoading = false
        snapshot.viewTree = params.root
        snapshot.updatedAt = Date()
        snapshot.error = nil
        snapshot.statusLabel = params.status?.label
        snapshot.statusPrefix = params.status?.prefix
        snapshot.statusIcon = params.status?.icon
        snapshot.statusTint = params.status?.tint
        snapshot.statusTooltip = params.status?.tooltip
        snapshot.safeForSensitiveCache = false
        setSnapshot(snapshot, for: widgetId)
        let sensitive = params.sensitive == true || widget.isSensitive
        if sensitive {
            cancelPendingPersist(widgetId)
            if let cacheRoot = params.cacheRoot {
                // Keep the live tree memory-only. Persist only the separate
                // widget-supplied tree whose contract requires sensitive
                // fields to be removed before host.render.
                var cached = snapshot
                cached.viewTree = cacheRoot
                cached.safeForSensitiveCache = true
                persistSnapshot(cached)
            } else {
                Self.removeCachedSnapshot(widgetID: widgetId)
            }
        } else {
            persistSnapshot(snapshot)
        }
        scheduler.noteRefreshSucceeded(widgetID: widgetId, nextRefreshAtMs: params.nextRefreshAt)
        recordRefreshSuccess(widgetID: widgetId)
    }

    private func handleScriptLoadComplete(
        widgetId: String, generation: String, error: String?
    ) {
        guard let rendered = scriptRefreshes.finish(
            widgetID: widgetId, generation: generation
        ) else { return }
        inFlight.remove(widgetId)
        if let error {
            updateSnapshot(widgetId) {
                $0.isLoading = false
                $0.error = error
            }
            scheduler.noteRefreshFailed(widgetID: widgetId)
            recordRefreshFailure(widgetID: widgetId, error: error)
            return
        }
        // A script may intentionally retain its last-good render. Completion
        // still ends loading/backoff and records the successful no-change load.
        if !rendered {
            updateSnapshot(widgetId) { $0.isLoading = false }
            scheduler.noteRefreshSucceeded(widgetID: widgetId, nextRefreshAtMs: nil)
            recordRefreshSuccess(widgetID: widgetId)
        }
    }

    private func handleScriptStateChange(widgetId: String, state: ScriptWidgetState) {
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
                inFlight.remove(widgetId)
                scheduler.noteRefreshFailed(widgetID: widgetId)
                recordRefreshFailure(
                    widgetID: widgetId, error: "script exited unexpectedly"
                )
            }
        case let .disabled(reason):
            scriptDisabledReasonCache[widgetId] = reason
            setOverlay(Self.disabledCard(reason: reason), for: widgetId)
            updateSnapshot(widgetId) {
                $0.isLoading = false
                $0.error = "Widget disabled: \(reason)"
            }
            _ = scriptRefreshes.cancel(widgetID: widgetId)
            inFlight.remove(widgetId)
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
        if overlayCards[widget.id] == nil {
            auditLog.record("permission.requested", widgetId: widget.id, detail: [
                "hash": .string(PermissionStore.permissionsHash(of: widget.manifest)),
            ])
        }
        setOverlay(Self.approvalCard(for: widget, denied: denied), for: widget.id)
    }

    func approvePermissions(widgetID: String) {
        guard let widget = widgets.first(where: { $0.id == widgetID }) else { return }
        permissionStore.approve(widget.manifest)
        auditLog.record("permission.approved", widgetId: widgetID, detail: [
            "hash": .string(PermissionStore.permissionsHash(of: widget.manifest)),
        ])
        setOverlay(nil, for: widgetID)
        refresh(widget, manual: true)
    }

    func denyPermissions(widgetID: String) {
        guard let widget = widgets.first(where: { $0.id == widgetID }) else { return }
        permissionStore.deny(widget.manifest)
        auditLog.record("permission.denied", widgetId: widgetID, detail: [
            "hash": .string(PermissionStore.permissionsHash(of: widget.manifest)),
        ])
        setOverlay(Self.approvalCard(for: widget, denied: true), for: widgetID)
    }

    /// "Restart Widget" after a crash-loop disable.
    func restartScriptWidget(widgetID: String) {
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

    // MARK: - Host-generated cards

    static func approvalCard(for widget: LoadedWidget, denied: Bool) -> UINode {
        var rows: [UINode] = []
        let permissions = widget.manifest.permissions
        for exec in permissions?.exec ?? [] {
            if let patterns = exec.allowedArgs, !patterns.isEmpty {
                for pattern in patterns {
                    rows.append(permissionRow(
                        icon: "terminal",
                        title: describeExec(command: exec.command, args: pattern)
                    ))
                }
            } else if exec.allowedArgs != nil {
                rows.append(permissionRow(
                    icon: "terminal",
                    title: describeExec(command: exec.command, args: [])
                ))
            } else {
                rows.append(permissionRow(
                    icon: "terminal",
                    title: "Run \(friendlyCommandName(exec.command)) with any arguments"
                ))
            }
        }
        if permissions?.exec?.isEmpty != false,
           widget.manifest.entry.kind == "exec" {
            rows.append(permissionRow(
                icon: "exclamationmark.triangle.fill",
                title: "Blocked: executable source has no command allowlist"
            ))
        }
        if permissions?.keychain == true {
            rows.append(permissionRow(icon: "key.fill", title: "Read & write Keychain secrets"))
        }
        if permissions?.notifications == true {
            rows.append(permissionRow(icon: "bell.fill", title: "Post notifications"))
        }
        if let net = permissions?.network, !net.isEmpty {
            let hosts = net.prefix(4).joined(separator: ", ")
            let suffix = net.count > 4 ? ", …" : ""
            rows.append(permissionRow(icon: "network", title: "Connect to \(hosts)\(suffix)"))
        }
        for path in permissions?.readPaths ?? [] {
            rows.append(permissionRow(icon: "folder.fill", title: "Read files in \(path)"))
        }
        if permissions?.storage?.granted == true {
            rows.append(permissionRow(icon: "internaldrive.fill", title: "Save small data on this Mac"))
        }
        if let env = permissions?.env, !env.isEmpty {
            rows.append(permissionRow(
                icon: "leaf.fill",
                title: "Read environment: \(env.joined(separator: ", "))"
            ))
        }
        if rows.isEmpty {
            rows.append(permissionRow(icon: "checkmark.seal.fill", title: "No special permissions"))
        }

        var children: [UINode] = [
            UINode(
                type: "banner",
                text: denied
                    ? "Permissions denied — approve to run this widget"
                    : "\(widget.displayName) requests these permissions:",
                tone: denied ? "danger" : "warning"
            ),
        ]
        children.append(contentsOf: rows)
        children.append(UINode(type: "hstack", children: [
            UINode(type: "button", title: "Approve",
                   action: NodeAction(type: "permission.approve")),
            UINode(type: "button", title: "Deny",
                   action: NodeAction(type: "permission.deny")),
        ], spacing: 8))
        return UINode(type: "vstack", children: children, spacing: 6)
    }

    /// One permission line in the approval card: a leading SF Symbol and a
    /// human-readable description, instead of a raw shell command dump.
    private static func permissionRow(icon: String, title: String) -> UINode {
        UINode(type: "hstack", children: [
            UINode(
                type: "image",
                source: ImageSource(kind: "sfSymbol", name: icon),
                size: 12,
                tint: "secondary"
            ),
            UINode(type: "text", text: title, role: "caption", lineLimit: 2),
        ], spacing: 6)
    }

    /// Turns an exec permission (command + a specific argument pattern) into a
    /// readable sentence. Shell wrappers (`/bin/sh -c "<script>"`) are the ugly
    /// case: instead of printing the whole script we surface the tools it calls.
    static func describeExec(command: String, args: [String]) -> String {
        let name = friendlyCommandName(command)
        let shells: Set<String> = ["sh", "bash", "zsh", "dash", "ksh"]
        if shells.contains(name.lowercased()),
           let flag = args.firstIndex(of: "-c"), flag + 1 < args.count {
            let tools = referencedTools(in: args[flag + 1])
            guard !tools.isEmpty else { return "Run a shell command" }
            let shown = tools.prefix(6).joined(separator: ", ")
            let more = tools.count > 6 ? ", …" : ""
            return "Run system tools: \(shown)\(more)"
        }
        guard !args.isEmpty else { return "Run \(name)" }
        var detail = ([name] + args).joined(separator: " ")
        if detail.count > 72 { detail = String(detail.prefix(71)) + "…" }
        return "Run \(detail)"
    }

    /// The basename of an executable path (`/usr/bin/top` → `top`).
    static func friendlyCommandName(_ command: String) -> String {
        let name = (command as NSString).lastPathComponent
        return name.isEmpty ? command : name
    }

    /// Extracts the distinct executables a shell script invokes by absolute
    /// path (e.g. `/usr/bin/top`, `/bin/df`), in first-seen order, so a script
    /// can be summarized by the tools it runs rather than its full text.
    static func referencedTools(in script: String) -> [String] {
        let binDirs = ["/bin/", "/usr/bin/", "/sbin/", "/usr/sbin/",
                       "/opt/homebrew/bin/", "/usr/local/bin/"]
        let pathChars = Set(
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-")
        var tools: [String] = []
        var seen = Set<String>()
        let chars = Array(script)
        var i = 0
        while i < chars.count {
            guard chars[i] == "/" else { i += 1; continue }
            var j = i
            while j < chars.count, pathChars.contains(chars[j]) { j += 1 }
            let token = String(chars[i..<j])
            if binDirs.contains(where: { token.hasPrefix($0) }) {
                let name = (token as NSString).lastPathComponent
                if !name.isEmpty, seen.insert(name).inserted { tools.append(name) }
            }
            i = j
        }
        return tools
    }

    static func disabledCard(reason: String) -> UINode {
        UINode(type: "vstack", children: [
            UINode(type: "banner", text: "Widget disabled: \(reason)", tone: "danger"),
            UINode(type: "button", title: "Restart Widget",
                   action: NodeAction(type: "widget.restart")),
        ], spacing: 6)
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

        // A rescan replaces every script descriptor/process, even when the id
        // stays the same. Release only those script generations here; their
        // late SDK acknowledgements are ignored by generation matching.
        let cancelledScriptIDs = scriptRefreshes.cancelAll()
        inFlight.subtract(cancelledScriptIDs)
        for id in cancelledScriptIDs where seenIDs.contains(id) {
            updateSnapshot(id) { $0.isLoading = false }
        }

        widgets = loaded
        // Remove per-widget state of widgets that disappeared (hot reload).
        removeWidgetState(notIn: seenIDs)
        refreshStatsStore.retain(widgetIDs: seenIDs)
        publishRefreshStats()

        for widget in loaded {
            if snapshots[widget.id] == nil {
                if widget.isSensitive {
                    // A sensitive live tree is never restored. The only cache
                    // accepted here is an explicitly redacted fallback written
                    // through RenderParams.cacheRoot.
                    if let cached = loadCachedSnapshot(widgetID: widget.id),
                       cached.safeForSensitiveCache == true {
                        setSnapshot(cached, for: widget.id)
                    } else {
                        Self.removeCachedSnapshot(widgetID: widget.id)
                        setSnapshot(WidgetSnapshot(widgetID: widget.id), for: widget.id)
                    }
                } else {
                    setSnapshot(
                        loadCachedSnapshot(widgetID: widget.id)
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
            Task { await supervisor.retain(widgetIds: []) }
        }

        let enabled = loaded.filter { !prefs.isDisabled($0.id) }
        visibleWidgetIDs.formIntersection(Set(enabled.map(\.id)))
        scheduler.configure(widgets: enabled)
        scheduler.setVisibleWidgetIDs(visibleWidgetIDs)
        syncMenuBar()
    }

    static func discoverWidgets(in searchDirectories: [URL]) -> [LoadedWidget] {
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
    static func instanceID(manifestID: String, directoryName: String) -> String {
        let prefix = manifestID + "--"
        guard directoryName.hasPrefix(prefix), directoryName.count > prefix.count else {
            return manifestID
        }
        return directoryName
    }

    // MARK: - Widget management (R11)

    /// The single directory `removeWidget` is allowed to delete inside.
    static var userWidgetsRoot: URL {
        applicationSupportDirectory.appendingPathComponent("widgets", isDirectory: true)
    }

    /// True only for a proper subdirectory of the user widgets root. Resolving
    /// `..` first refuses path-traversal ids and dev-checkout (`./widgets/`)
    /// widgets, so `removeWidget` can never delete outside that root.
    static func isRemovableWidgetDirectory(_ directory: URL) -> Bool {
        let root = userWidgetsRoot.standardizedFileURL.path
        let target = directory.standardizedFileURL.path
        return target != root && target.hasPrefix(root + "/")
    }

    /// Deletes the widget's directory and scrubs every per-widget trace
    /// (cached snapshot, permissions, prefs), then rescans — which drops the
    /// in-memory snapshot, card model, refresh stats, and scheduler timers.
    /// Throws (deleting nothing) for unknown ids or directories outside the
    /// user widgets root.
    func removeWidget(id: String) throws {
        guard let widget = widgets.first(where: { $0.id == id }) else {
            throw RuntimeError.widgetNotFound(id)
        }
        guard Self.isRemovableWidgetDirectory(widget.directory) else {
            throw RuntimeError.notRemovable(
                "widget \"\(id)\" is not inside the user widgets directory"
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
                    "Remove the additional \"\(widget.manifest.name)\" instances before removing its package."
                )
            }
        }
        try FileManager.default.removeItem(at: widget.directory)
        cancelPendingPersist(id) // no queued write may re-create the cache
        Self.removeCachedSnapshot(widgetID: id)
        permissionStore.reset(widgetId: id)
        prefs.removeAllState(for: id)
        loadWidgets()
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
        let normalized = Self.normalizedInstanceLabel(label)
        guard !normalized.isEmpty else {
            throw RuntimeError.invalidInstanceName(
                "Instance name must contain a letter or number."
            )
        }

        let canonical = Self.userWidgetsRoot.appendingPathComponent(
            widget.manifest.id, isDirectory: true
        )
        var canonicalIsDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: canonical.path, isDirectory: &canonicalIsDirectory
        ), canonicalIsDirectory.boolValue else {
            throw RuntimeError.notRemovable(
                "Install \"\(widget.manifest.name)\" before adding another instance."
            )
        }

        let instanceID = widget.manifest.id + "--" + normalized
        let destination = Self.userWidgetsRoot.appendingPathComponent(instanceID)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw RuntimeError.invalidInstanceName(
                "An instance named \"\(normalized)\" already exists."
            )
        }
        do {
            try FileManager.default.createSymbolicLink(
                at: destination, withDestinationURL: canonical
            )
        } catch {
            throw RuntimeError.invalidInstanceName(
                "Could not create instance \"\(normalized)\": \(error.localizedDescription)"
            )
        }

        for (key, value) in prefs.settings(for: id) {
            prefs.setSetting(widgetID: instanceID, key: key, value: value)
        }
        if let appearance = prefs.appearanceOverride(for: id) {
            prefs.setAppearanceOverride(appearance, for: instanceID)
        }
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

    static func normalizedInstanceLabel(_ label: String) -> String {
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
        scheduler.configure(widgets: widgets.filter { !prefs.isDisabled($0.id) })
        setVisibleWidgetIDs(visibleWidgetIDs)
        syncMenuBar()
        objectWillChange.send()
        if !flag {
            refresh(widgetID: id, manual: true)
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
    private func effectiveOrder(for id: String) -> Double {
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
            groupSort: { self.prefs.groupSortKey($0) ?? .greatestFiniteMagnitude }
        )
    }

    /// Pure page layout: groups the enabled widgets, sorts members by effective
    /// order, and orders pages by an explicit group order (when set), then their
    /// first member's order, then group name.
    static func computePages(
        _ widgets: [LoadedWidget],
        group: (LoadedWidget) -> String,
        order: (LoadedWidget) -> Double,
        isDisabled: (LoadedWidget) -> Bool,
        groupSort: (String) -> Double = { _ in .greatestFiniteMagnitude }
    ) -> [WidgetPage] {
        let visible = widgets.filter { !isDisabled($0) }
        let grouped = Dictionary(grouping: visible, by: group)
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

    private func startMenuBarStalenessTicker() {
        menuBarStalenessTimer?.invalidate()
        let timer = Timer.scheduledTimer(
            withTimeInterval: Self.menuBarStalenessTickSec, repeats: true
        ) { [weak self] _ in
            guard let self, !self.menuBar.entries.isEmpty else { return }
            self.syncMenuBar()
        }
        timer.tolerance = Self.menuBarStalenessTickSec / 3
        menuBarStalenessTimer = timer
    }

    /// Recomputes what the menu bar draws and tells the scheduler which
    /// widgets must keep polling while the popup is closed.
    ///
    /// Newly promoted widgets are refreshed once so the strip fills in without
    /// waiting a whole interval for the first tick.
    func syncMenuBar() {
        let previous = menuBar.promotedWidgetIDs
        let multiplier = SchedulePolicy.normalizedRefreshMultiplier(
            appPrefs.preferences.refreshMultiplier
        )
        var candidates: [(entry: MenuBarEntry, order: Double?)] = []

        for widget in widgets where !prefs.isDisabled(widget.id) {
            let placement = prefs.menuBarPlacement(
                for: widget.manifest, widgetID: widget.id
            )
            guard placement.enabled else { continue }
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
                || !(statusItem.showsLabel || hasTextIcon)
            let entry = MenuBarEntry(
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
                tooltip: snapshot?.error ?? snapshot?.statusTooltip,
                isStale: MenuBarPolicy.isStale(
                    updatedAt: snapshot?.updatedAt,
                    interval: (widget.manifest.refresh?.interval).map { $0 * multiplier }
                ),
                separate: separate
            )
            candidates.append((entry, placement.order))
        }

        menuBar.apply(MenuBarPolicy.ordered(candidates))
        let promoted = menuBar.promotedWidgetIDs
        guard promoted != previous else { return }
        scheduler.setMenuBarWidgetIDs(promoted)
        for id in promoted.subtracting(previous) {
            let widget = widgets.first { $0.id == id }
            let staleAfter = effectiveStaleAfter(widget?.manifest.refresh?.staleAfterSec)
            let snapshot = snapshots[id] ?? WidgetSnapshot(widgetID: id)
            if snapshot.isStale(after: staleAfter) {
                refresh(widgetID: id, manual: false)
            }
        }
    }

    /// Promotes or demotes a widget in the menu bar (settings UI / context
    /// menu). Passing `nil` clears the stored choice.
    func setMenuBarPlacement(_ placement: MenuBarPlacement?, for id: String) {
        prefs.setMenuBarPlacement(placement, for: id)
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
        MenuBarPolicy.partition(menuBar.entries).strip.map(\.widgetID)
    }

    func canMoveInMenuBar(_ id: String, by offset: Int) -> Bool {
        MenuBarPolicy.canMove(id, by: offset, within: menuBarStripOrder)
    }

    /// Moves a widget within the shared strip.
    ///
    /// Every widget in the run gets a fresh key: the stored ones may be absent
    /// or stale (nothing set them before this existed), so re-deriving the
    /// whole order is what makes one move predictable.
    func moveInMenuBar(_ id: String, by offset: Int) {
        let ids = menuBarStripOrder
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
        guard changed, scheduler.popupIsOpen else { return }
        refreshVisibleWidgetsIfNeeded()
        refreshWidgetsAwaitingVisibility()
    }

    func popupOpened() {
        scheduler.popupOpened()
        refreshVisibleWidgetsIfNeeded()
        refreshWidgetsAwaitingVisibility()
    }

    /// Whether this widget's card is on screen: the shelf is open on its page,
    /// or it is showing in its own menu bar popover. Workflows read it as
    /// `widget.visible` and use it to skip work nobody can see.
    func isCardVisible(_ widgetID: String) -> Bool {
        if menuBarPopoverWidgetID == widgetID { return true }
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
               snapshot.isStale(after: effectiveStaleAfter(refresh?.staleAfterSec)) {
                self.refresh(widget, manual: false)
            }
        }
    }

    func popupClosed() {
        scheduler.popupClosed()
    }

    // MARK: - Refresh

    func refreshAll() {
        for widget in widgets {
            refresh(widget, manual: true)
        }
    }

    func refresh(widgetID: String, manual: Bool = true) {
        guard let widget = widgets.first(where: { $0.id == widgetID }) else { return }
        refresh(widget, manual: manual)
    }

    /// Refreshes stale widgets (system-wake batch). While the popup is closed
    /// only `runInBackground` widgets run (invariant 3).
    func refreshStaleWidgets(backgroundOnly: Bool) {
        for widget in widgets {
            if widget.manifest.refresh?.popupOnly == true { continue }
            if backgroundOnly, widget.manifest.refresh?.runInBackground != true { continue }
            if scheduler.popupIsOpen, !visibleWidgetIDs.contains(widget.id) { continue }
            let snapshot = snapshots[widget.id] ?? WidgetSnapshot(widgetID: widget.id)
            if snapshot.isStale(after: effectiveStaleAfter(widget.manifest.refresh?.staleAfterSec)) {
                refresh(widget, manual: false)
            }
        }
    }

    private func effectiveStaleAfter(_ configured: Double?) -> Double? {
        SchedulePolicy.effectiveStaleAfter(
            configured: configured,
            multiplier: appPrefs.preferences.refreshMultiplier
        )
    }

    func refresh(_ widget: LoadedWidget, manual: Bool = true) {
        let id = widget.id
        guard !prefs.isDisabled(id) else { return } // disabled widgets never run
        guard !inFlight.contains(id) else { return } // in-flight coalescing
        if !manual, !scheduler.allowsAutomaticRefresh(widgetID: id) {
            return // exponential backoff window — automatic triggers suppressed
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
        inFlight.insert(id)
        updateSnapshot(id) { $0.isLoading = true }

        Task { @MainActor [weak self] in
            guard let self else { return }
            let outcome = await self.performRefresh(
                widget: widget, source: source, command: command, permission: permission
            )
            self.finishRefresh(widget: widget, outcome: outcome, startedAt: startedAt)
        }
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
        let descriptor = ScriptWidgetDescriptor(
            manifest: widget.manifest,
            directory: widget.directory,
            instanceID: widget.id,
            revision: widget.loadRevision
        )
        let isFirstLoad = snapshots[id]?.viewTree == nil
        let reason = manual ? "manual" : (isFirstLoad ? "install" : "open")
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.scriptSupervisor.load(
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
                self.inFlight.remove(id)
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
        var statusPrefix: String?
        var statusIcon: String?
        var statusTint: String?
        /// Longer form for the menu-bar tooltip (`status.tooltip`).
        var statusTooltip: String?
    }

    private func performRefresh(
        widget: LoadedWidget,
        source: Manifest.Source,
        command: [String],
        permission: Manifest.ExecPermission
    ) async -> Result<RefreshSuccess, Error> {
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
                if source.output == "data" {
                    guard let adapterName = source.adapter else {
                        throw RuntimeError.missingAdapter("source.output is \"data\" but no adapter is set")
                    }
                    guard let adapter = adapters[adapterName] else {
                        throw RuntimeError.missingAdapter("unknown adapter \"\(adapterName)\"")
                    }
                    let context = HostAdapterContext(
                        widget: widget,
                        execService: execService,
                        defaultTimeoutMs: source.timeoutMs ?? Self.defaultTimeoutMs,
                        settings: prefs.effectiveSettings(
                            for: widget.manifest, widgetID: widget.id
                        ).objectValue ?? [:]
                    )
                    let result = try await adapter(data, context)
                    return .success(RefreshSuccess(
                        viewTree: result.viewTree,
                        nextRefreshAtMs: result.nextRefreshAtMs,
                        statusLabel: result.statusText
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
    static func dispatchDirectExec(
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
            extraEnvironment: secretEnvironment(
                for: widget.manifest, permission: permission
            ),
            stdoutLimit: permission.maxOutputBytes ?? ExecService.maxStdoutBytes
        )
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
        let widgetContext: JSONValue = .object([
            // `size` lets a workflow switch layout per bucket size; `visible`
            // lets it do less while nothing is on screen (the sensors widget
            // reads 46 SMC keys instead of 129 with its card closed).
            "size": .string(effectiveSize(for: id)),
            "visible": .bool(visible),
        ])

        let startedAt = markRefreshStarted(widgetID: id)
        inFlight.insert(id)
        updateSnapshot(id) { $0.isLoading = true }

        Task { @MainActor [weak self] in
            guard let self else { return }
            let outcome = await self.performWorkflowRefresh(
                widget: widget, workflowURL: workflowURL,
                settings: settings, widgetContext: widgetContext
            )
            // Before `finishRefresh`, whose catch-up reads this.
            if let reads = outcome.readsWidgetVisibility {
                self.recordVisibilityUse(widgetID: id, reads: reads, visible: visible)
            }
            self.finishRefresh(widget: widget, outcome: outcome.result, startedAt: startedAt)
        }
    }

    /// What one workflow refresh produced, plus whether the workflow reads
    /// `widget.visible` (nil when it never got as far as decoding).
    private struct WorkflowRefreshOutcome {
        var result: Result<RefreshSuccess, Error>
        var readsWidgetVisibility: Bool?
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

    private func performWorkflowRefresh(
        widget: LoadedWidget,
        workflowURL: URL,
        settings: JSONValue,
        widgetContext: JSONValue
    ) async -> WorkflowRefreshOutcome {
        let cached: WorkflowDefinitionCache.Entry
        do {
            cached = try workflowDefinitions.load(workflowURL)
        } catch {
            return WorkflowRefreshOutcome(result: .failure(error), readsWidgetVisibility: nil)
        }
        let result = await evaluateWorkflow(
            widget: widget, definition: cached.definition,
            settings: settings, widgetContext: widgetContext
        )
        return WorkflowRefreshOutcome(
            result: result, readsWidgetVisibility: cached.readsWidgetVisibility
        )
    }

    private func evaluateWorkflow(
        widget: LoadedWidget,
        definition: WorkflowDefinition,
        settings: JSONValue,
        widgetContext: JSONValue
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
            for (sourceID, source) in definition.sources {
                let value = params[sourceID] ?? .object([:])
                switch source.use {
                case "fs.directory":
                    let fsParams = try FileSource.Params(from: value)
                    let listing: FileSource.AuthorizedListing
                    do {
                        let readPaths = effectiveReadPaths(for: widget)
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
                    if fsParams.watch {
                        registerWorkflowWatch(widgetID: widget.id, directory: listing.directory)
                    }
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
                default:
                    throw RuntimeError.invalidWorkflow(
                        "unknown source use \"\(source.use)\" (v1: exec, fs.directory, http, system, value)"
                    )
                }
            }

            let output = try WorkflowEngine.evaluate(
                definition, sources: sourceValues, settings: settings,
                storage: storageSnapshot, widget: widgetContext
            )

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
                statusPrefix: output.statusPrefix,
                statusIcon: output.statusIcon,
                statusTint: output.statusTint,
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
    private func runWorkflowSystemSource(
        widget: LoadedWidget,
        params: JSONValue
    ) async throws -> JSONValue {
        let requested = SystemMetrics.requestedMetrics(from: params.objectValue?["metrics"])
        if let requested, requested.isEmpty {
            throw RuntimeError.invalidWorkflow(
                "system source \"metrics\" lists no known group"
                    + " (cpu, memory, disk, sensors)"
            )
        }
        let (allowed, denied) = SystemMetrics.authorized(
            requested, declared: widget.manifest.permissions?.system
        )
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
                    + " group (cpu, memory, disk, sensors)"
            )
        }
        let detail = params.objectValue?["detail"]?.boolValue == true
        let mountPoint = params.objectValue?["mount"]?.stringValue ?? "/"
        let sensorGroups = Self.sensorGroups(from: params.objectValue?["sensors"])
        // Sampling blocks on Mach/IOKit calls (and, on a cold CPU sampler, a
        // short baseline window), so it stays off the main thread.
        return await Task.detached(priority: .userInitiated) {
            SystemMetrics.sample(
                metrics: allowed,
                detail: detail,
                sensorGroups: sensorGroups,
                mountPoint: mountPoint
            )
        }.value
    }

    /// `"sensors"` on a system source: which sensor readings the widget
    /// actually shows, so the sampler can skip the IOKit round trips behind
    /// the rest. Accepts one name or a list of them; `nil` (absent, `"all"`,
    /// or anything unrecognized) reads every sensor, because a narrowing hint
    /// the host does not understand must never blank a reading.
    ///
    ///     "with": { "metrics": ["sensors"], "sensors": "cpu" }
    static func sensorGroups(from value: JSONValue?) -> Set<SensorSampler.SensorGroup>? {
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

    /// `exec` workflow source — same allowlist/audit semantics as an exec
    /// widget's `source.command`.
    private func runWorkflowExecSource(
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
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Workflow-source launch seam; the caller's matched permission is the
    /// sole command-level environment authority.
    static func dispatchWorkflowExec(
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
    private func runWorkflowHTTPSource(
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
    static func networkHostAllowed(url: String, manifest: Manifest) -> Bool {
        networkHostAllowed(url: url, allowlist: manifest.permissions?.network ?? [])
    }

    /// Allowlist-only variant — also used by the renderer to gate `url` image
    /// nodes on the widget's declared hosts.
    static func networkHostAllowed(url: String, allowlist: [String]) -> Bool {
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

    static func execCommandAllowed(_ command: [String], manifest: Manifest) -> Bool {
        ExecAllowlist.match(command: command, permissions: manifest.permissions?.exec) != nil
    }

    /// Symlink-aware file allowlist check shared by workflow reads, rendered
    /// file thumbnails/drag items, and open/reveal actions.
    static func filePathAllowed(_ path: String, manifest: Manifest) -> Bool {
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
    static func userGrantedReadPaths(
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

    static func filePathAllowed(_ path: String, allowlist: [String]) -> Bool {
        guard !allowlist.isEmpty else { return false }
        let target = canonicalFileURL(path)
        return allowlist.contains { allowed in
            let root = canonicalFileURL(allowed)
            return target.path == root.path || target.path.hasPrefix(root.path + "/")
        }
    }

    private static func canonicalFileURL(_ path: String) -> URL {
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
        startedAt: Date
    ) {
        let id = widget.id
        inFlight.remove(id)

        var snapshot = snapshots[id] ?? WidgetSnapshot(widgetID: id)
        snapshot.isLoading = false
        let completedAt = Date()

        switch outcome {
        case let .success(success):
            snapshot.viewTree = success.viewTree
            snapshot.updatedAt = completedAt
            snapshot.error = nil
            snapshot.statusLabel = success.statusLabel
            snapshot.statusPrefix = success.statusPrefix
            snapshot.statusIcon = success.statusIcon
            snapshot.statusTint = success.statusTint
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
    static func secretEnvironment(
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
    func performRun(action: NodeAction, widgetID: String) {
        guard let widget = widgets.first(where: { $0.id == widgetID }) else { return }
        guard gatePermissions(for: widget) else { return }
        guard let command = action.command, !command.isEmpty else {
            NSLog("barshelf: run action from %@ has no command", widgetID)
            return
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
            return
        }
        auditLog.record("exec.run", widgetId: widgetID, detail: [
            "command": .string(
                permission.sensitiveOutput == true
                    ? (command.first ?? "") : command.joined(separator: " ")
            ),
            "trigger": .string("run-action"),
        ])

        let thenRefresh = action.thenRefresh ?? false
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await Self.dispatchRunActionExec(
                execService: self.execService,
                widget: widget,
                command: command,
                permission: permission
            )
            switch result {
            case .success:
                if thenRefresh {
                    self.refresh(widgetID: widgetID, manual: true)
                }
            case let .failure(error):
                self.updateSnapshot(widgetID) {
                    $0.error = "run action failed: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Declarative run-action launch seam, also used by the production action
    /// task so tests can observe the exact child environment it supplies.
    static func dispatchRunActionExec(
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
            extraEnvironment: secretEnvironment(
                for: widget.manifest, permission: permission
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
            case let .widgetNotFound(id): return "widget \"\(id)\" was not found"
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
        guard snapshots[id] != snapshot else { return }
        snapshots[id] = snapshot
        cardModels[id]?.snapshot = snapshot
        if menuBar.promotedWidgetIDs.contains(id) { syncMenuBar() }
    }

    /// Single write path for overlay cards (`nil` removes), same suppression.
    private func setOverlay(_ node: UINode?, for id: String) {
        guard overlayCards[id] != node else { return }
        overlayCards[id] = node
        cardModels[id]?.overlay = node
    }

    /// Drops per-widget state for removed widget ids (hot reload cleanup).
    private func removeWidgetState(notIn liveIDs: Set<String>) {
        snapshots = snapshots.filter { liveIDs.contains($0.key) }
        overlayCards = overlayCards.filter { liveIDs.contains($0.key) }
        cardModels = cardModels.filter { liveIDs.contains($0.key) }
        inFlight.formIntersection(liveIDs)
        refreshStartedAt = refreshStartedAt.filter { liveIDs.contains($0.key) }
    }

    // MARK: - Render snapshot cache

    /// Resolved once: `FileManager.urls(for:in:)` is not free, and it was being
    /// asked on every snapshot write.
    private static let cacheDirectory: URL? = {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else { return nil }
        return appSupport
            .appendingPathComponent("barshelf", isDirectory: true)
            .appendingPathComponent("cache", isDirectory: true)
    }()

    private static func cacheURL(for widgetID: String) -> URL? {
        let sanitized = widgetID.map { character -> Character in
            character.isLetter || character.isNumber || character == "." || character == "-"
                ? character : "_"
        }
        return cacheDirectory?.appendingPathComponent(String(sanitized) + ".json")
    }

    /// Snapshot cache writes are throttled per widget and performed off the
    /// main thread (R05 perf).
    ///
    /// The cache exists so a relaunched popup shows the last render at once;
    /// a render half a minute old serves that just as well as one two seconds
    /// old. It used to be a 0.5 s *debounce* — cancel and reschedule on every
    /// snapshot — which for a widget refreshing every two seconds meant a
    /// JSON encode, an atomic write and a rename on every single refresh:
    /// ~11% of a promoted widget's CPU, profiled. A debounce is the wrong
    /// shape for a periodic stream (it either fires every tick or, if the
    /// period is shorter than the delay, never). This is a throttle: the first
    /// unwritten change opens a window, and when it closes the *latest*
    /// snapshot is written once. Quitting flushes whatever is still held.
    private static let persistQueue = DispatchQueue(
        label: "dev.barshelf.snapshot-cache", qos: .utility
    )
    static let persistIntervalSec: TimeInterval = 30
    /// A scheduled write per widget (on the main queue), and the snapshot it
    /// will write — replaced by every newer snapshot until it fires.
    private var pendingPersists: [String: DispatchWorkItem] = [:]
    private var unpersistedSnapshots: [String: WidgetSnapshot] = [:]

    private func persistSnapshot(_ snapshot: WidgetSnapshot) {
        let id = snapshot.widgetID
        unpersistedSnapshots[id] = snapshot
        guard pendingPersists[id] == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingPersists[id] = nil
            guard let latest = self.unpersistedSnapshots.removeValue(forKey: id)
            else { return }
            Self.persistQueue.async { Self.writeCachedSnapshot(latest) }
        }
        pendingPersists[id] = item
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.persistIntervalSec, execute: item
        )
    }

    /// Drops a scheduled write *and* the snapshot it held. The sensitive
    /// path depends on the second half: a live tree that must stay in memory
    /// can never be written by a throttle that fires after it arrived.
    private func cancelPendingPersist(_ id: String) {
        pendingPersists.removeValue(forKey: id)?.cancel()
        unpersistedSnapshots.removeValue(forKey: id)
    }

    /// Writes every snapshot the throttle is still holding. Called on quit, so
    /// a normal exit loses nothing to the longer window.
    func flushPendingPersists() {
        for item in pendingPersists.values { item.cancel() }
        pendingPersists.removeAll()
        let held = Array(unpersistedSnapshots.values)
        unpersistedSnapshots.removeAll()
        guard !held.isEmpty else { return }
        Self.persistQueue.sync {
            for snapshot in held { Self.writeCachedSnapshot(snapshot) }
        }
    }

    private static func writeCachedSnapshot(_ snapshot: WidgetSnapshot) {
        guard let directory = cacheDirectory,
              let url = cacheURL(for: snapshot.widgetID)
        else { return }
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
            try snapshot.serialized().write(to: url, options: .atomic)
        } catch {
            NSLog("barshelf: failed to cache snapshot for \(snapshot.widgetID): \(error)")
        }
    }

    private func loadCachedSnapshot(widgetID: String) -> WidgetSnapshot? {
        guard let url = Self.cacheURL(for: widgetID),
              let data = try? Data(contentsOf: url)
        else { return nil }
        return try? WidgetSnapshot.deserialize(data)
    }

    private static func removeCachedSnapshot(widgetID: String) {
        guard let url = cacheURL(for: widgetID) else { return }
        try? FileManager.default.removeItem(at: url)
    }
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
