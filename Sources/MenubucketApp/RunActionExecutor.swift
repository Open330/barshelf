import Foundation
import MenubucketCore

/// The runtime's side of a `run` action: the widget, whether it may act,
/// and where the result goes.
@MainActor
protocol RunActionExecutorHost: AnyObject {
    /// The loaded widget with this id, if any.
    func runActionWidget(_ widgetID: String) -> LoadedWidget?
    /// Whether the widget may act at all: enabled, and not being removed.
    func runActionMayStart(widgetID: String) -> Bool
    /// Whether the widget's permissions are approved; when they are not,
    /// puts up the card that asks for them.
    func gateRunActionPermissions(for widget: LoadedWidget) -> Bool
    /// Whether the widget's permissions are approved now. Asks nothing.
    func runActionIsApproved(_ widget: LoadedWidget) -> Bool
    /// Tells the person an action was blocked or failed.
    func reportRunActionFeedback(_ feedback: RuntimeFeedback)
    /// The action asked for a refresh once its command succeeded.
    func refreshAfterRunAction(widgetID: String)
}

/// Runs a widget's declarative `run` action: checks its command against the
/// widget's `permissions.exec` allowlist, launches it with the environment
/// that entry allows, and reports a failure where the button was. Owns the
/// tasks of the actions still running, so stopping a widget cancels them.
///
/// Main-actor isolated, like the runtime it reports to. Without a host no
/// action runs.
@MainActor
final class RunActionExecutor {
    /// Launches an action's command and returns its stdout.
    typealias Launch = @Sendable (
        _ widget: LoadedWidget, _ command: [String], _ permission: Manifest.ExecPermission
    ) async -> Result<Data, ExecService.ExecError>

    /// The runtime. Weak: the runtime owns the executor.
    weak var host: RunActionExecutorHost?

    private let execService: ExecService
    private let auditLog: AuditLog
    private let callbackGate: ScriptCallbackGate
    /// Nil launches through `dispatchRunActionExec`.
    private let launch: Launch?
    private var tasks: [String: [UUID: Task<Void, Never>]] = [:]

    /// - Parameters:
    ///   - execService: Runs the action's command.
    ///   - callbackGate: Invalidated when a widget is stopped; an action
    ///     started before that does not go on.
    ///   - launch: Nil is `dispatchRunActionExec` on `execService`.
    init(
        execService: ExecService,
        auditLog: AuditLog,
        callbackGate: ScriptCallbackGate,
        launch: Launch? = nil
    ) {
        self.execService = execService
        self.auditLog = auditLog
        self.callbackGate = callbackGate
        self.launch = launch
    }

    // MARK: - Run

    /// Executes a `run` action's command iff it matches the widget's
    /// `permissions.exec` allowlist; mismatches are blocked and logged.
    @discardableResult
    func perform(
        action: NodeAction, widgetID: String, title: String? = nil, surface: ToastSurface = .popup
    ) -> Task<Void, Never>? {
        guard let host, let widget = host.runActionWidget(widgetID) else { return nil }
        guard host.runActionMayStart(widgetID: widgetID) else { return nil }
        guard host.gateRunActionPermissions(for: widget) else { return nil }
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
            host.reportRunActionFeedback(RuntimeFeedback(
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
        let callbackGate = callbackGate
        let callbackToken = callbackGate.token(for: widgetID)
        let execService = execService
        let launch = launch
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.tasks[widgetID]?.removeValue(forKey: actionID)
                if self.tasks[widgetID]?.isEmpty == true { self.tasks.removeValue(forKey: widgetID) }
            }
            // Held for the whole action, as the runtime used to hold itself.
            guard let host = self.host else { return }
            guard !Task.isCancelled, callbackGate.accepts(widgetID: widgetID, token: callbackToken),
                  host.runActionMayStart(widgetID: widgetID),
                  host.runActionIsApproved(widget) else { return }
            let result: Result<Data, ExecService.ExecError>
            if let launch {
                result = await launch(widget, command, permission)
            } else {
                result = await Self.dispatchRunActionExec(
                    execService: execService,
                    widget: widget,
                    command: command,
                    permission: permission
                )
            }
            guard !Task.isCancelled, callbackGate.accepts(widgetID: widgetID, token: callbackToken),
                  host.runActionIsApproved(widget) else { return }
            switch result {
            case .success:
                if thenRefresh {
                    host.refreshAfterRunAction(widgetID: widgetID)
                }
            case let .failure(error):
                // An action has its own channel: a toast where the button
                // was. The card's reading is still as good as it was, so the
                // snapshot keeps it — no "Cached — refresh failed" badge for
                // something that was not a refresh.
                let raw = error.localizedDescription
                NSLog("barshelf: run action from %@ failed: %@", widgetID, raw)
                let explanation = ErrorExplainer.explain(raw, context: .action)
                host.reportRunActionFeedback(RuntimeFeedback(
                    message: Self.actionFailureTitle(title),
                    detail: "\(explanation.cause) \(explanation.fix)",
                    tone: .failure, surface: surface
                ))
            }
        }
        tasks[widgetID, default: [:]][actionID] = task
        return task
    }

    // MARK: - Running actions

    /// The widget's actions still running, for whoever has to wait for them.
    func tasks(for widgetID: String) -> [Task<Void, Never>] {
        Array(tasks[widgetID]?.values ?? [:].values)
    }

    /// Cancels the widget's running actions and forgets them.
    func cancel(widgetID: String) {
        for task in tasks.removeValue(forKey: widgetID)?.values ?? [:].values { task.cancel() }
    }

    /// After a rescan: cancels the actions of widgets that are gone
    /// (not in `liveIDs`) or whose package changed (`changedIDs`).
    func cancel(widgetsNotIn liveIDs: Set<String>, orIn changedIDs: Set<String>) {
        for id in Array(tasks.keys) where !liveIDs.contains(id) || changedIDs.contains(id) {
            cancel(widgetID: id)
        }
    }

    // MARK: - Wording and launch

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
            timeoutMs: source?.timeoutMs ?? WidgetRuntime.defaultTimeoutMs,
            workingDirectory: widget.directory,
            extraEnvironment: ExecRefresher.pluginEnvironment(
                for: widget.manifest,
                ExecRefresher.secretEnvironment(for: widget.manifest, permission: permission)
            ),
            stdoutLimit: permission.maxOutputBytes ?? ExecService.maxStdoutBytes
        )
    }
}
