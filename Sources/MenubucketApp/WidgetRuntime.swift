import AppKit
import Combine
import Foundation
import MenubucketCore

/// A discovered widget: manifest plus the directory it was loaded from.
struct LoadedWidget: Identifiable {
    let manifest: Manifest
    let directory: URL

    var id: String { manifest.id }
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
    @Published private(set) var refreshStatsSnapshot: [String: WidgetRefreshStats] = [:]
    /// Widget id the UI should jump to and highlight (post-install reveal, R11).
    /// Consumers clear it after handling.
    @Published var pendingReveal: String?

    private let execService = ExecService()
    let scheduler = Scheduler()
    private let refreshStatsStore: RefreshStatsStore
    private var cancellables: Set<AnyCancellable> = []
    private var inFlight: Set<String> = []
    private var refreshStartedAt: [String: Date] = [:]
    private var hotReloadWatchers: [DirectoryWatcher] = []
    /// `fs.directory` sources with `watch: true`, keyed by widget id.
    private var workflowWatchers: [String: DirectoryWatcher] = [:]
    private var workflowWatchedPaths: [String: String] = [:]

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
        self.refreshStatsSnapshot = self.refreshStatsStore.all
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
        seedStarterWidgets()
        loadWidgets()
        startHotReload()
    }

    private func applyAppPreferences(_ preferences: AppPreferences) {
        scheduler.configurePolicy(
            refreshMultiplier: preferences.refreshMultiplier,
            pauseWhenClosed: preferences.pauseWhenClosed
        )
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
                let appearance = NSApp?.effectiveAppearance
                    .bestMatch(from: [.darkAqua, .aqua])
                return appearance == .darkAqua ? "dark" : "light"
            }
        )
        let events = RuntimeSupervisorEvents(
            onRender: { [weak self] widgetId, params, revision in
                DispatchQueue.main.async {
                    self?.handleScriptRender(widgetId: widgetId, params: params, revision: revision)
                }
            },
            onStateChange: { [weak self] widgetId, state in
                DispatchQueue.main.async {
                    self?.handleScriptStateChange(widgetId: widgetId, state: state)
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
        var snapshot = snapshots[widgetId] ?? WidgetSnapshot(widgetID: widgetId)
        snapshot.isLoading = false
        snapshot.viewTree = params.root
        snapshot.updatedAt = Date()
        snapshot.error = nil
        setSnapshot(snapshot, for: widgetId)
        let sensitive = params.sensitive == true || widget.isSensitive
        if sensitive {
            pendingPersists[widgetId]?.cancel() // no queued write may survive
            Self.removeCachedSnapshot(widgetID: widgetId) // memory-only render
        } else {
            persistSnapshot(snapshot)
        }
        if let label = params.status?.label {
            NSLog("barshelf[%@] status: %@ (rev %d)", widgetId, label, revision)
        }
        scheduler.noteRefreshSucceeded(widgetID: widgetId, nextRefreshAtMs: params.nextRefreshAt)
        inFlight.remove(widgetId)
        recordRefreshSuccess(widgetID: widgetId)
    }

    private func handleScriptStateChange(widgetId: String, state: ScriptWidgetState) {
        switch state {
        case .running:
            break
        case .stopped:
            // A crash before the first render would otherwise spin forever.
            if snapshots[widgetId]?.isLoading == true {
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
                    : "\(widget.manifest.name) requests these permissions:",
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
    /// widget ids the earlier directory wins (dev overrides installed).
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
        var loaded: [LoadedWidget] = []
        var seenIDs: Set<String> = []
        let fm = FileManager.default

        for baseDirectory in Self.widgetSearchDirectories {
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
                    guard !seenIDs.contains(manifest.id) else { continue }
                    seenIDs.insert(manifest.id)
                    loaded.append(LoadedWidget(manifest: manifest, directory: entry))
                } catch {
                    NSLog("barshelf: skipping \(manifestURL.path): \(error)")
                }
            }
        }

        widgets = loaded
        // Remove per-widget state of widgets that disappeared (hot reload).
        removeWidgetState(notIn: seenIDs)
        refreshStatsStore.retain(widgetIDs: seenIDs)
        publishRefreshStats()

        for widget in loaded {
            if snapshots[widget.id] == nil {
                if widget.isSensitive {
                    // Sensitive renders are memory-only; also scrub any cache
                    // left behind by an older manifest revision.
                    Self.removeCachedSnapshot(widgetID: widget.id)
                    setSnapshot(WidgetSnapshot(widgetID: widget.id), for: widget.id)
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

        // Stop script processes for removed widgets (hot reload cleanup).
        scriptDisabledReasonCache = scriptDisabledReasonCache.filter { seenIDs.contains($0.key) }
        if let supervisor = scriptSupervisorStorage {
            Task { await supervisor.retain(widgetIds: seenIDs) }
        }

        scheduler.configure(widgets: loaded.filter { !prefs.isDisabled($0.id) })
    }

    static let supportedEntryKinds: Set<String> = ["exec", "script", "workflow"]

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
        try FileManager.default.removeItem(at: widget.directory)
        pendingPersists[id]?.cancel() // no queued write may re-create the cache
        pendingPersists.removeValue(forKey: id)
        Self.removeCachedSnapshot(widgetID: id)
        permissionStore.reset(widgetId: id)
        prefs.removeAllState(for: id)
        loadWidgets()
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
        for widget in widgets where snapshots[widget.id]?.viewTree == nil {
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

    // MARK: - Popup lifecycle

    func popupOpened() {
        scheduler.popupOpened()
        for widget in widgets {
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
            if backgroundOnly, widget.manifest.refresh?.runInBackground != true { continue }
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
        // Runtime allowlist enforcement: a declared exec allowlist must also
        // cover the widget's own source command.
        if let execPermissions = widget.manifest.permissions?.exec, !execPermissions.isEmpty,
           ExecAllowlist.match(command: command, permissions: execPermissions) == nil {
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
            let outcome = await self.performRefresh(widget: widget, source: source, command: command)
            self.finishRefresh(widget: widget, outcome: outcome, startedAt: startedAt)
        }
    }

    /// Script widgets: ensure the resident process runs and (re)send
    /// `widget.load`. Renders arrive asynchronously via `handleScriptRender`.
    private func refreshScript(_ widget: LoadedWidget, manual: Bool) {
        let id = widget.id
        markRefreshStarted(widgetID: id)
        updateSnapshot(id) { $0.isLoading = true }
        let descriptor = ScriptWidgetDescriptor(manifest: widget.manifest, directory: widget.directory)
        let isFirstLoad = snapshots[id]?.viewTree == nil
        let reason = manual ? "manual" : (isFirstLoad ? "install" : "open")
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.scriptSupervisor.load(
                    descriptor,
                    reason: reason,
                    settings: self.prefs.effectiveSettings(for: widget.manifest)
                )
            } catch {
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
        var statusText: String?
    }

    private func performRefresh(
        widget: LoadedWidget,
        source: Manifest.Source,
        command: [String]
    ) async -> Result<RefreshSuccess, Error> {
        let extraEnvironment = Self.secretEnvironment(for: widget.manifest)
        let permission = ExecAllowlist.match(
            command: command, permissions: widget.manifest.permissions?.exec
        )
        auditLog.record("exec.run", widgetId: widget.id, detail: [
            "command": .string(
                permission?.sensitiveOutput == true
                    ? (command.first ?? "") : command.joined(separator: " ")
            ),
            "trigger": .string("refresh"),
        ])
        let execResult = await execService.run(
            command: command,
            discover: source.discover,
            timeoutMs: source.timeoutMs ?? Self.defaultTimeoutMs,
            workingDirectory: widget.directory,
            extraEnvironment: extraEnvironment,
            stdoutLimit: permission?.maxOutputBytes ?? ExecService.maxStdoutBytes
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
                        extraEnvironment: extraEnvironment,
                        defaultTimeoutMs: source.timeoutMs ?? Self.defaultTimeoutMs
                    )
                    let result = try await adapter(data, context)
                    return .success(RefreshSuccess(
                        viewTree: result.viewTree,
                        nextRefreshAtMs: result.nextRefreshAtMs,
                        statusText: result.statusText
                    ))
                }
                let tree = try JSONDecoder().decode(UINode.self, from: data)
                return .success(RefreshSuccess(viewTree: tree))
            } catch {
                return .failure(error)
            }
        }
    }

    // MARK: - Workflow refresh (entry.kind == "workflow")

    private func refreshWorkflow(_ widget: LoadedWidget) {
        let id = widget.id
        let workflowURL = widget.directory
            .appendingPathComponent(widget.manifest.entry.main ?? "workflow.json")
        let settings = prefs.effectiveSettings(for: widget.manifest)

        let startedAt = markRefreshStarted(widgetID: id)
        inFlight.insert(id)
        updateSnapshot(id) { $0.isLoading = true }

        Task { @MainActor [weak self] in
            guard let self else { return }
            let outcome = await self.performWorkflowRefresh(
                widget: widget, workflowURL: workflowURL, settings: settings
            )
            self.finishRefresh(widget: widget, outcome: outcome, startedAt: startedAt)
        }
    }

    private func performWorkflowRefresh(
        widget: LoadedWidget,
        workflowURL: URL,
        settings: JSONValue
    ) async -> Result<RefreshSuccess, Error> {
        do {
            let definition = try WorkflowDefinition.decode(from: try Data(contentsOf: workflowURL))
            // Storage is opt-in: only widgets that declare `permissions.storage`
            // (as `true` or an object) can read `storage.*` or commit a `store`
            // block. An explicit `false` declines.
            let storageAllowed = widget.manifest.permissions?.storage?.granted == true
            let storageSnapshot: JSONValue = storageAllowed
                ? .object(storage.snapshot(widgetId: widget.id))
                : .object([:])
            // Expose the widget's effective size so a workflow can switch its
            // layout per size (native small/medium/large), e.g. via a `switch`.
            let widgetContext: JSONValue = .object([
                "size": .string(effectiveSize(for: widget.id)),
            ])
            let params = try WorkflowEngine.resolvedSourceParams(
                definition, settings: settings, storage: storageSnapshot, widget: widgetContext
            )

            var sourceValues: [String: JSONValue] = [:]
            for (sourceID, source) in definition.sources {
                let value = params[sourceID] ?? .object([:])
                switch source.use {
                case "fs.directory":
                    let fsParams = try FileSource.Params(from: value)
                    sourceValues[sourceID] = try await Task.detached(priority: .userInitiated) {
                        try FileSource.list(fsParams)
                    }.value
                    if fsParams.watch {
                        registerWorkflowWatch(widgetID: widget.id, path: fsParams.path)
                    }
                case "exec":
                    sourceValues[sourceID] = try await runWorkflowExecSource(
                        widget: widget, params: value
                    )
                case "http":
                    sourceValues[sourceID] = try await runWorkflowHTTPSource(
                        widget: widget, params: value
                    )
                case "value":
                    sourceValues[sourceID] = value
                default:
                    throw RuntimeError.invalidWorkflow(
                        "unknown source use \"\(source.use)\" (v1: exec, fs.directory, http, value)"
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
                statusText: output.statusTooltip
            ))
        } catch {
            return .failure(error)
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
        if let execPermissions = widget.manifest.permissions?.exec,
           !execPermissions.isEmpty, permission == nil {
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
                permission?.sensitiveOutput == true
                    ? (command.first ?? "") : command.joined(separator: " ")
            ),
            "trigger": .string("workflow"),
        ])

        let discover = params.objectValue?["discover"]?.arrayValue?.compactMap(\.stringValue)
        let timeoutMs = params.objectValue?["timeoutMs"]?.numberValue.map(Int.init)
        let data = try await execService.run(
            command: command,
            discover: discover,
            timeoutMs: timeoutMs ?? Self.defaultTimeoutMs,
            workingDirectory: widget.directory,
            extraEnvironment: Self.secretEnvironment(for: widget.manifest),
            stdoutLimit: permission?.maxOutputBytes ?? ExecService.maxStdoutBytes
        ).get()

        if params.objectValue?["parse"]?.stringValue == "text" {
            return .string(String(data: data, encoding: .utf8) ?? "")
        }
        // Default: JSON (the DSL transforms/templates need structured data).
        return try JSONDecoder().decode(JSONValue.self, from: data)
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
        guard let allowed = manifest.permissions?.network, !allowed.isEmpty,
              let host = URL(string: url)?.host?.lowercased()
        else { return false }
        for raw in allowed {
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

    // MARK: - URL refresh trigger (`barshelf://refresh?widget=<id>`)

    /// Deep-link trigger handler. Refreshes only widgets that opted in with a
    /// `url` trigger: a specific `widgetID` refreshes that widget (unknown or
    /// non-opted-in id → no-op); `nil` refreshes every url-trigger widget.
    func handleURLRefreshTrigger(widgetID: String?) {
        for widget in widgets where declaresURLTrigger(widget.manifest) {
            if let widgetID, widget.id != widgetID { continue }
            refresh(widget, manual: false)
        }
    }

    private func declaresURLTrigger(_ manifest: Manifest) -> Bool {
        manifest.refresh?.triggers?.contains(.url) ?? false
    }

    private func registerWorkflowWatch(widgetID: String, path: String) {
        // Re-arm only when the watched path changes (settings edit).
        if workflowWatchers[widgetID] != nil, workflowWatchedPaths[widgetID] == path { return }
        workflowWatchers[widgetID]?.cancel()
        workflowWatchedPaths[widgetID] = path
        do {
            workflowWatchers[widgetID] = try DirectoryWatcher(
                paths: [path],
                debounce: Scheduler.watchDebounceSec
            ) { [weak self] in
                guard let self, self.scheduler.popupIsOpen else { return }
                self.refresh(widgetID: widgetID, manual: false)
            }
        } catch {
            NSLog("barshelf: workflow watch unavailable for \(path): \(error)")
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
        refreshStatsSnapshot = refreshStatsStore.all
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

    /// Keychain-backed env injection: for `permissions.keychain == true`, each
    /// declared env var missing from the host environment is looked up in the
    /// Keychain (service `dev.barshelf`, account = lowercased var with `_`→`-`).
    static func secretEnvironment(for manifest: Manifest) -> [String: String]? {
        guard manifest.permissions?.keychain == true else { return nil }
        var extra: [String: String] = [:]
        let hostEnvironment = ProcessInfo.processInfo.environment
        for name in declaredEnvironmentVariables(for: manifest)
        where hostEnvironment[name] == nil {
            let account = KeychainStore.account(forEnvironmentVariable: name)
            if let value = KeychainStore.readPassword(account: account) {
                extra[name] = value
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
        let source = widget.manifest.source
        let discover = (command.first == source?.command?.first) ? source?.discover : nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.execService.run(
                command: command,
                discover: discover,
                timeoutMs: source?.timeoutMs ?? Self.defaultTimeoutMs,
                workingDirectory: widget.directory,
                extraEnvironment: Self.secretEnvironment(for: widget.manifest),
                stdoutLimit: permission.maxOutputBytes ?? ExecService.maxStdoutBytes
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

    enum RuntimeError: Error, LocalizedError {
        case missingAdapter(String)
        case invalidWorkflow(String)
        case widgetNotFound(String)
        case notRemovable(String)

        var errorDescription: String? {
            switch self {
            case let .missingAdapter(message): return message
            case let .invalidWorkflow(message): return message
            case let .widgetNotFound(id): return "widget \"\(id)\" was not found"
            case let .notRemovable(message): return message
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

    private static var cacheDirectory: URL? {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else { return nil }
        return appSupport
            .appendingPathComponent("barshelf", isDirectory: true)
            .appendingPathComponent("cache", isDirectory: true)
    }

    private static func cacheURL(for widgetID: String) -> URL? {
        let sanitized = widgetID.map { character -> Character in
            character.isLetter || character.isNumber || character == "." || character == "-"
                ? character : "_"
        }
        return cacheDirectory?.appendingPathComponent(String(sanitized) + ".json")
    }

    /// Snapshot cache writes are debounced per widget and performed off the
    /// main thread (R05 perf): a 1 Hz-refreshing widget previously did a
    /// synchronous JSON encode + disk write on the main queue every tick.
    /// Losing the trailing write on quit only costs one cached render.
    private static let persistQueue = DispatchQueue(
        label: "dev.barshelf.snapshot-cache", qos: .utility
    )
    static let persistDebounceSec: TimeInterval = 0.5
    private var pendingPersists: [String: DispatchWorkItem] = [:]

    private func persistSnapshot(_ snapshot: WidgetSnapshot) {
        guard let directory = Self.cacheDirectory,
              let url = Self.cacheURL(for: snapshot.widgetID)
        else { return }
        pendingPersists[snapshot.widgetID]?.cancel()
        let item = DispatchWorkItem {
            do {
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true
                )
                try snapshot.serialized().write(to: url, options: .atomic)
            } catch {
                NSLog("barshelf: failed to cache snapshot for \(snapshot.widgetID): \(error)")
            }
        }
        pendingPersists[snapshot.widgetID] = item
        Self.persistQueue.asyncAfter(
            deadline: .now() + Self.persistDebounceSec, execute: item
        )
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
/// binary, and inherit the widget's secret environment.
struct HostAdapterContext: AdapterContext, @unchecked Sendable {
    let widget: LoadedWidget
    let execService: ExecService
    let extraEnvironment: [String: String]?
    let defaultTimeoutMs: Int

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
            extraEnvironment: extraEnvironment,
            stdoutLimit: permission.maxOutputBytes ?? ExecService.maxStdoutBytes
        )
        switch result {
        case let .success(data): return data
        case let .failure(error): throw error
        }
    }
}
