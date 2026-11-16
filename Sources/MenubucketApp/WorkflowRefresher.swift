import AppKit
import Foundation
import MenubucketCore

/// What a workflow evaluated to: the view, and the menu bar status that
/// goes with it.
struct WorkflowRender {
    var viewTree: UINode
    /// Live menu-bar text (`status.label`).
    var statusLabel: String?
    var statusMetrics: [StatusMetric]?
    var statusPrefix: String?
    var statusIcon: String?
    var statusTint: String?
    var statusPresentation: MenuBarPresentation?
    /// Longer form for the menu-bar tooltip (`status.tooltip`).
    var statusTooltip: String?
    /// What the widget says is wrong (`status.problem`), in the app's
    /// language.
    var statusProblem: String?
}

/// What one workflow refresh produced, plus whether the workflow reads
/// `widget.visible` (nil when it never got as far as decoding).
struct WorkflowRefreshOutcome {
    var result: Result<WorkflowRender, Error>
    var readsWidgetVisibility: Bool?
    /// Whether the workflow declares alerts (nil when it never decoded).
    var hasAlerts: Bool?
}

/// The runtime's side of a workflow refresh: the main-actor state a refresh
/// running off it has to ask for, and what it hands back on the way. Starting
/// the refresh and applying its outcome are the runtime's.
@MainActor
protocol WorkflowRefresherHost: AnyObject {
    /// Whether the refresh started under `token` may run its next source or
    /// perform its next side effect: still the current one, and the widget
    /// still enabled and approved.
    func workflowRefreshMayContinue(_ widget: LoadedWidget, token: NativeRefreshGate.Token) -> Bool
    /// Every read root the widget has now: declared, plus picked folders.
    func effectiveReadPaths(for widget: LoadedWidget) -> [String]
    /// An `fs.directory` source with `watch: true` listed `directory`.
    func watchWorkflowDirectory(_ directory: FileSource.AuthorizedDirectory, widgetID: String)
    /// An alert of the widget's fired on a refresh that is still current.
    func deliverWorkflowAlert(_ alert: WorkflowEngine.AlertSample, for widget: LoadedWidget)
    /// Where a `vault.items` source gets its rows.
    var vaultBroker: VaultBroker { get }
}

/// Runs one workflow refresh: loads the definition, runs its sources under
/// the widget's permissions, evaluates the view, decides which alerts fire
/// and commits the `store` block. Owns the decoded definitions and what each
/// alert last saw.
///
/// Main-actor isolated, like the runtime it reports to, but the refresh
/// itself is `nonisolated` and hops to the main actor for each thing it asks
/// the host. Without a host a refresh is cancelled at its first check.
@MainActor
final class WorkflowRefresher {
    /// The runtime. Weak: the runtime owns the refresher.
    weak var host: WorkflowRefresherHost?

    nonisolated private let execService: ExecService
    nonisolated private let storage: StorageService
    nonisolated private let auditLog: AuditLog
    /// Decoded `workflow.json` files, reused while unchanged on disk.
    nonisolated private let workflowDefinitions: WorkflowDefinitionCache
    /// What each workflow alert last saw, and when it last fired.
    nonisolated private let alertStates: AlertStateStore
    nonisolated private let defaultTimeoutMs: Int

    /// - Parameters:
    ///   - execService: Runs `exec` sources.
    ///   - storage: The widgets' key-value store; the namespace script
    ///     widgets see too.
    ///   - definitions: Nil is an empty cache.
    ///   - alertStates: Nil is the shipped `alert-state.json`.
    ///   - defaultTimeoutMs: For an `exec` source that names none.
    init(
        execService: ExecService,
        storage: StorageService,
        auditLog: AuditLog,
        definitions: WorkflowDefinitionCache? = nil,
        alertStates: AlertStateStore? = nil,
        defaultTimeoutMs: Int = WidgetRuntime.defaultTimeoutMs
    ) {
        self.execService = execService
        self.storage = storage
        self.auditLog = auditLog
        if let definitions {
            self.workflowDefinitions = definitions
        } else {
            self.workflowDefinitions = WorkflowDefinitionCache()
        }
        if let alertStates {
            self.alertStates = alertStates
        } else {
            self.alertStates = AlertStateStore(
                fileURL: WidgetRuntime.applicationSupportDirectory.appendingPathComponent("alert-state.json")
            )
        }
        self.defaultTimeoutMs = defaultTimeoutMs
    }

    // MARK: - Housekeeping

    /// Drops the decoded definitions of files no widget uses any more.
    func retainDefinitions(fileURLs: Set<URL>) {
        workflowDefinitions.retain(fileURLs: fileURLs)
    }

    /// Forgets what the widget's alerts last saw.
    func forgetAlerts(widgetID: String) {
        alertStates.forget(widgetID: widgetID)
    }

    /// Forgets the alerts of widgets that are gone.
    func retainAlerts(widgetIDs: Set<String>) {
        alertStates.retain(widgetIDs: widgetIDs)
    }

    // MARK: - Refresh

    /// The refresh may go on only while the host says so; see
    /// `WidgetRuntime.nativeRefreshMayContinue` for why this asks the main actor.
    nonisolated private func checkMayContinue(_ widget: LoadedWidget, token: NativeRefreshGate.Token) async throws {
        let mayContinue = await MainActor.run {
            self.host?.workflowRefreshMayContinue(widget, token: token) ?? false
        }
        guard mayContinue else { throw CancellationError() }
    }

    /// Reads the preferences; see `checkMayContinue`.
    nonisolated private func currentReadPaths(for widget: LoadedWidget) async -> [String] {
        await MainActor.run { self.host?.effectiveReadPaths(for: widget) ?? [] }
    }

    /// Loads (or reuses) the definition at `workflowURL` and evaluates it.
    nonisolated func refresh(
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
    ) async -> Result<WorkflowRender, Error> {
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
                try await checkMayContinue(widget, token: token)
                let value = params[sourceID] ?? .object([:])
                do {
                switch source.use {
                case "fs.directory":
                    let fsParams = try FileSource.Params(from: value)
                    let listing: FileSource.AuthorizedListing
                    do {
                        let readPaths = await currentReadPaths(for: widget)
                        listing = try await Task.detached(priority: .userInitiated) {
                            try FileSource.list(fsParams, authorizedBy: readPaths)
                        }.value
                    } catch FileSource.FileSourceError.unauthorizedPath(_) {
                        auditLog.record("file.blocked", widgetId: widget.id, detail: [
                            "path": .string(fsParams.path),
                            "reason": .string("path not in permissions.readPaths or a picked folder"),
                        ])
                        throw WidgetRuntime.RuntimeError.invalidWorkflow(
                            "file source path is not covered by permissions.readPaths"
                        )
                    }
                    sourceValues[sourceID] = listing.value
                    try await checkMayContinue(widget, token: token)
                    if fsParams.watch {
                        // The watcher table is shared by every widget's
                        // refresh, and two can finish at once.
                        let directory = listing.directory
                        await MainActor.run {
                            self.host?.watchWorkflowDirectory(directory, widgetID: widget.id)
                        }
                    }
                case "fs.json":
                    let jsonParams = try FileSource.JSONFileParams(from: value)
                    let readPaths = await currentReadPaths(for: widget)
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
                    try await checkMayContinue(widget, token: token)
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
                        throw WidgetRuntime.RuntimeError.invalidWorkflow("vault.items needs permissions.vault")
                    }
                    guard let broker = await MainActor.run(body: { self.host?.vaultBroker }) else {
                        throw CancellationError()
                    }
                    sourceValues[sourceID] = await broker.itemsSource(widgetID: widget.id, permission: vault)
                default:
                    throw WidgetRuntime.RuntimeError.invalidWorkflow(
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

            try await checkMayContinue(widget, token: token)
            let output = try WorkflowEngine.evaluate(
                definition, sources: sourceValues, settings: settings,
                storage: storageSnapshot, widget: widgetContext, errors: sourceErrors
            )

            // Alerts: decided against host-held state after a refresh that is
            // still current, delivered only to a widget that declared
            // notifications and is still allowed when macOS answers.
            alertStates.reconcile(widgetID: widget.id, alertIDs: Set(output.alerts.map(\.id)))
            if !output.alerts.isEmpty, widget.manifest.permissions?.notifications == true {
                try await checkMayContinue(widget, token: token)
                let firing = alertStates.record(
                    widgetID: widget.id, samples: output.alerts, nowMs: Date().timeIntervalSince1970 * 1000
                )
                await MainActor.run { for alert in firing { self.host?.deliverWorkflowAlert(alert, for: widget) } }
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

            return .success(WorkflowRender(
                viewTree: output.viewTree,
                statusLabel: output.statusLabel,
                statusMetrics: output.statusMetrics,
                statusPrefix: output.statusPrefix,
                statusIcon: output.statusIcon,
                statusTint: output.statusTint,
                statusPresentation: output.statusPresentation,
                statusTooltip: output.statusTooltip,
                // An expression picks one of the widget's sentences; the
                // sentence it picked is then translated like any other text.
                statusProblem: output.statusProblem.map { widget.manifest.localization()?.text($0) ?? $0 }
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
            throw WidgetRuntime.RuntimeError.invalidWorkflow(
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
            throw WidgetRuntime.RuntimeError.invalidWorkflow(
                "system source metrics \(names.joined(separator: ", "))"
                    + " are not covered by permissions.system"
            )
        }
        guard !allowed.isEmpty else {
            throw WidgetRuntime.RuntimeError.invalidWorkflow(
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
            throw WidgetRuntime.RuntimeError.invalidWorkflow("exec source needs \"command\": [String]")
        }
        let command = rawCommand.compactMap(\.stringValue)
        guard !command.isEmpty else {
            throw WidgetRuntime.RuntimeError.invalidWorkflow("exec source command is empty")
        }
        let permission = ExecAllowlist.match(
            command: command, permissions: widget.manifest.permissions?.exec
        )
        guard let permission else {
            auditLog.record("exec.blocked", widgetId: widget.id, detail: [
                "command": .string(command.joined(separator: " ")),
                "reason": .string("workflow exec source not in permissions.exec allowlist"),
            ])
            throw WidgetRuntime.RuntimeError.invalidWorkflow(
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
            timeoutMs: timeoutMs ?? defaultTimeoutMs,
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
            extraEnvironment: WidgetRuntime.secretEnvironment(
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
            throw WidgetRuntime.RuntimeError.invalidWorkflow(
                "http source requires the \"network\" permission in the manifest"
            )
        }
        let httpParams = try HttpSource.Params(from: params)
        guard WidgetRuntime.networkHostAllowed(url: httpParams.url, manifest: widget.manifest) else {
            auditLog.record("network.blocked", widgetId: widget.id, detail: [
                "url": .string(httpParams.url),
                "reason": .string("host not in permissions.network allowlist"),
            ])
            throw WidgetRuntime.RuntimeError.invalidWorkflow(
                "http source host is not covered by the permissions.network allowlist"
            )
        }
        auditLog.record("network.fetch", widgetId: widget.id, detail: [
            "url": .string(httpParams.url),
            "trigger": .string("workflow"),
        ])
        return try await HttpSource.fetch(httpParams)
    }
}
