import Foundation
import MenubucketCore

/// What an exec widget's command rendered to: the view, the menu bar status
/// that goes with it, and when an adapter wants to run again.
struct ExecRender {
    var viewTree: UINode
    /// An adapter's deadline (`AdapterResult.nextRefreshAtMs`).
    var nextRefreshAtMs: Double?
    /// Live menu-bar text: an adapter's status text or a plugin's title.
    var statusLabel: String?
    var statusIcon: String?
    var statusTint: String?
}

/// The command an exec widget's refresh runs, and the `permissions.exec`
/// entry that covers it.
struct ExecRefreshPlan: Equatable {
    var source: Manifest.Source
    var command: [String]
    var permission: Manifest.ExecPermission
}

/// The runtime's side of an exec refresh: the main-actor state a refresh
/// running off it has to ask for. Starting the refresh and applying its
/// outcome are the runtime's.
@MainActor
protocol ExecRefresherHost: AnyObject {
    /// Whether the refresh started under `token` may launch its next command:
    /// still the current one, and the widget still enabled and approved.
    func execRefreshMayContinue(_ widget: LoadedWidget, token: NativeRefreshGate.Token) -> Bool
    /// What an adapter reads as its settings: the manifest's defaults under
    /// what the user saved.
    func adapterSettings(for widget: LoadedWidget) -> [String: JSONValue]
}

/// Runs one exec (`source.command`) refresh: decides which command runs under
/// which `permissions.exec` entry, launches it with the environment that
/// entry allows, and turns its output into a view — a UI tree as is, an
/// xbar/SwiftBar plugin's lines, or a builtin adapter's result. Owns the
/// adapter registry and what a widget's command may see of the environment.
///
/// Main-actor isolated, like the runtime it reports to, but the refresh
/// itself is `nonisolated` and hops to the main actor for each thing it asks
/// the host. Without a host a refresh is cancelled at its first check.
@MainActor
final class ExecRefresher {
    /// A builtin adapter for `output = "data"` sources (M1 contract: async,
    /// context-carrying, may return a deadline + status text).
    typealias Adapter = @Sendable (Data, AdapterContext) async throws -> AdapterResult
    /// Launches the source command and returns its stdout.
    typealias Launch = @Sendable (
        _ widget: LoadedWidget, _ source: Manifest.Source,
        _ command: [String], _ permission: Manifest.ExecPermission
    ) async -> Result<Data, ExecService.ExecError>

    /// Why a widget's command cannot run at all; `message` goes on the card.
    struct Refusal: Error, Equatable {
        let message: String
    }

    /// The runtime. Weak: the runtime owns the refresher.
    weak var host: ExecRefresherHost?

    nonisolated private let execService: ExecService
    nonisolated private let auditLog: AuditLog
    nonisolated private let adapters: [String: Adapter]
    /// Nil launches through `dispatchDirectExec`.
    nonisolated private let launch: Launch?

    nonisolated static let builtinAdapters: [String: Adapter] = [
        AasUsageAdapter.name: { try await AasUsageAdapter.adapt($0, context: $1) },
        OtpeekAdapter.name: { try await OtpeekAdapter.adapt($0, context: $1) },
    ]

    /// - Parameters:
    ///   - execService: Runs the source command, and what an adapter runs.
    ///   - adapters: Nil is the builtin registry.
    ///   - launch: Nil is `dispatchDirectExec` on `execService`.
    init(
        execService: ExecService,
        auditLog: AuditLog,
        adapters: [String: Adapter]? = nil,
        launch: Launch? = nil
    ) {
        self.execService = execService
        self.auditLog = auditLog
        if let adapters {
            self.adapters = adapters
        } else {
            self.adapters = Self.builtinAdapters
        }
        self.launch = launch
    }

    // MARK: - Plan

    /// The command the widget's refresh runs, or why none does. Runtime
    /// allowlist enforcement is fail-closed: missing/empty exec permissions
    /// authorize nothing, and a command they do not cover is audited.
    nonisolated func plan(for widget: LoadedWidget) -> Result<ExecRefreshPlan, Refusal> {
        guard let source = widget.manifest.source,
              let command = source.command, !command.isEmpty
        else {
            return .failure(Refusal(message: "manifest has no source.command"))
        }
        guard let permission = ExecAllowlist.match(
            command: command, permissions: widget.manifest.permissions?.exec
        ) else {
            auditLog.record("exec.blocked", widgetId: widget.id, detail: [
                "command": .string(command.joined(separator: " ")),
                "reason": .string("source.command not in permissions.exec allowlist"),
            ])
            return .failure(Refusal(message: "source.command is not covered by permissions.exec allowlist"))
        }
        return .success(ExecRefreshPlan(source: source, command: command, permission: permission))
    }

    // MARK: - Refresh

    /// The refresh may go on only while the host says so; see
    /// `WidgetRuntime.nativeRefreshMayContinue` for why this asks the main actor.
    nonisolated private func mayContinue(_ widget: LoadedWidget, token: NativeRefreshGate.Token) async -> Bool {
        await MainActor.run { self.host?.execRefreshMayContinue(widget, token: token) ?? false }
    }

    /// Runs the planned command and renders its output.
    nonisolated func refresh(
        widget: LoadedWidget,
        plan: ExecRefreshPlan,
        token: NativeRefreshGate.Token
    ) async -> Result<ExecRender, Error> {
        let source = plan.source
        let command = plan.command
        let permission = plan.permission
        guard await mayContinue(widget, token: token) else {
            return .failure(CancellationError())
        }
        auditLog.record("exec.run", widgetId: widget.id, detail: [
            "command": .string(
                permission.sensitiveOutput == true
                    ? (command.first ?? "") : command.joined(separator: " ")
            ),
            "trigger": .string("refresh"),
        ])
        let execResult: Result<Data, ExecService.ExecError>
        if let launch {
            execResult = await launch(widget, source, command, permission)
        } else {
            execResult = await Self.dispatchDirectExec(
                execService: execService,
                widget: widget,
                source: source,
                command: command,
                permission: permission
            )
        }

        switch execResult {
        case let .failure(error):
            return .failure(error)
        case let .success(data):
            do {
                // An adapter may run more commands of its own.
                guard await mayContinue(widget, token: token) else { throw CancellationError() }
                if source.output == "data" {
                    guard let adapterName = source.adapter else {
                        throw WidgetRuntime.RuntimeError.missingAdapter("source.output is \"data\" but no adapter is set")
                    }
                    guard let adapter = adapters[adapterName] else {
                        throw WidgetRuntime.RuntimeError.missingAdapter("unknown adapter \"\(adapterName)\"")
                    }
                    // The preferences are main-actor state and this runs
                    // off it; see `mayContinue`.
                    guard let adapterSettings = await MainActor.run(body: {
                        self.host?.adapterSettings(for: widget)
                    }) else { throw CancellationError() }
                    let context = HostAdapterContext(
                        widget: widget,
                        execService: execService,
                        defaultTimeoutMs: source.timeoutMs ?? WidgetRuntime.defaultTimeoutMs,
                        settings: adapterSettings
                    )
                    let result = try await adapter(data, context)
                    return .success(ExecRender(
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
                    return .success(ExecRender(
                        viewTree: rendered.tree,
                        statusLabel: rendered.statusLabel,
                        statusIcon: rendered.statusIcon,
                        statusTint: rendered.statusTint
                    ))
                }
                let tree = try JSONDecoder().decode(UINode.self, from: data)
                return .success(ExecRender(viewTree: tree))
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
            timeoutMs: source.timeoutMs ?? WidgetRuntime.defaultTimeoutMs,
            workingDirectory: widget.directory,
            extraEnvironment: pluginEnvironment(
                for: widget.manifest,
                secretEnvironment(for: widget.manifest, permission: permission)
            ),
            stdoutLimit: permission.maxOutputBytes ?? ExecService.maxStdoutBytes
        )
    }

    // MARK: - xbar / SwiftBar plugins

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
}
