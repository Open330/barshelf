import Darwin
import Foundation

// MARK: - Descriptors / launch plans

/// A widget the supervisor can run (decoupled from the app's LoadedWidget).
public struct ScriptWidgetDescriptor: Sendable {
    public var manifest: Manifest
    public var directory: URL

    public init(manifest: Manifest, directory: URL) {
        self.manifest = manifest
        self.directory = directory
    }

    public var id: String { manifest.id }
}

/// Fully resolved process invocation. Production plans launch deno; tests
/// inject bash stubs — the supervisor never assumes a specific binary.
public struct ScriptLaunchPlan: Sendable {
    public var executable: URL
    public var arguments: [String]
    public var environment: [String: String]?
    public var currentDirectory: URL?

    public init(
        executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.currentDirectory = currentDirectory
    }
}

public enum RuntimeSupervisorError: Error, LocalizedError, Equatable {
    case widgetDisabled(String)
    case unknownWidget(String)

    public var errorDescription: String? {
        switch self {
        case let .widgetDisabled(reason): return "widget disabled: \(reason)"
        case let .unknownWidget(id): return "unknown script widget: \(id)"
        }
    }
}

/// Script widget process state, surfaced to the host UI.
public enum ScriptWidgetState: Equatable, Sendable {
    case stopped
    case running
    /// Crash loop (3 crashes / 5 min) — cleared with `restart(widgetId:)`.
    case disabled(reason: String)
}

// MARK: - Configuration / events

public struct RuntimeSupervisorConfiguration: @unchecked Sendable {
    /// Builds the process invocation for a widget (injectable: deno in
    /// production, bash stubs in tests).
    public var makeLaunchPlan: @Sendable (ScriptWidgetDescriptor) throws -> ScriptLaunchPlan
    public var storage: StorageService
    public var secrets: SecretStoring
    /// `host.notify.show` sink; nil → notifications unavailable.
    public var notify: (@Sendable (_ title: String, _ body: String?) async throws -> Void)?
    public var audit: AuditLog?
    public var widgetLogs: WidgetLogStore?
    public var locale: @Sendable () -> String
    /// "light" | "dark"
    public var appearance: @Sendable () -> String
    public var now: @Sendable () -> Date

    /// Default `host.exec.run` timeout (contract: unanswered-request cap 20 s).
    public var defaultExecTimeoutMs = 20_000
    /// `host.timer.every` floor (host policy `minInterval`).
    public var minTimerIntervalMs: Double = SchedulePolicy.minForegroundIntervalSec * 1000
    /// stdout line limit (1 MB per the contract).
    public var maxStdoutLineBytes = 1_048_576
    /// Crash loop: `crashLoopThreshold` crashes within `crashLoopWindowSec` → disabled.
    public var crashLoopWindowSec: TimeInterval = 300
    public var crashLoopThreshold = 3

    public init(
        makeLaunchPlan: @escaping @Sendable (ScriptWidgetDescriptor) throws -> ScriptLaunchPlan,
        storage: StorageService,
        secrets: SecretStoring,
        notify: (@Sendable (_ title: String, _ body: String?) async throws -> Void)? = nil,
        audit: AuditLog? = nil,
        widgetLogs: WidgetLogStore? = nil,
        locale: @escaping @Sendable () -> String = { Locale.current.identifier },
        appearance: @escaping @Sendable () -> String = { "light" },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.makeLaunchPlan = makeLaunchPlan
        self.storage = storage
        self.secrets = secrets
        self.notify = notify
        self.audit = audit
        self.widgetLogs = widgetLogs
        self.locale = locale
        self.appearance = appearance
        self.now = now
    }
}

/// Host-side callbacks (delivered off the main thread — hop as needed).
public struct RuntimeSupervisorEvents: Sendable {
    public var onRender: @Sendable (_ widgetId: String, _ params: RenderParams, _ revision: Int) -> Void
    public var onStateChange: @Sendable (_ widgetId: String, _ state: ScriptWidgetState) -> Void
    public var onWidgetLog: @Sendable (_ widgetId: String, _ level: String, _ message: String) -> Void

    public init(
        onRender: @escaping @Sendable (String, RenderParams, Int) -> Void = { _, _, _ in },
        onStateChange: @escaping @Sendable (String, ScriptWidgetState) -> Void = { _, _ in },
        onWidgetLog: @escaping @Sendable (String, String, String) -> Void = { _, _, _ in }
    ) {
        self.onRender = onRender
        self.onStateChange = onStateChange
        self.onWidgetLog = onWidgetLog
    }
}

// MARK: - Supervisor

/// Host side of the script runtime protocol v1.
///
/// Lifecycle: one resident process per widget. A refresh trigger re-sends
/// `widget.load` when the process is alive and respawns it otherwise.
/// Script → host requests are routed through `JsonRpcDispatcher` with
/// manifest permission enforcement; crashes feed the crash-loop policy
/// (3 crashes within 5 minutes → `disabled`, cleared via `restart`).
public actor RuntimeSupervisor {
    private final class ScriptInstance {
        let process: Process
        let stdinHandle: FileHandle
        let dispatcher: JsonRpcDispatcher
        var readTask: Task<Void, Never>?
        var stopping = false

        init(process: Process, stdinHandle: FileHandle, dispatcher: JsonRpcDispatcher) {
            self.process = process
            self.stdinHandle = stdinHandle
            self.dispatcher = dispatcher
        }
    }

    private enum StdoutEvent {
        case line(Data)
        case overflow
    }

    private let configuration: RuntimeSupervisorConfiguration
    private let events: RuntimeSupervisorEvents

    private var instances: [String: ScriptInstance] = [:]
    private var descriptors: [String: ScriptWidgetDescriptor] = [:]
    private var revisions: [String: Int] = [:]
    private var crashTimes: [String: [Date]] = [:]
    private var disabledReasons: [String: String] = [:]
    private var timers: [String: [String: DispatchSourceTimer]] = [:]

    public init(configuration: RuntimeSupervisorConfiguration, events: RuntimeSupervisorEvents) {
        self.configuration = configuration
        self.events = events
    }

    // MARK: - Public API

    /// Ensures the widget process runs and sends `widget.load`.
    public func load(
        _ widget: ScriptWidgetDescriptor,
        reason: String,
        settings: JSONValue? = nil
    ) async throws {
        descriptors[widget.id] = widget
        if let reason = disabledReasons[widget.id] {
            throw RuntimeSupervisorError.widgetDisabled(reason)
        }
        let instance = try ensureRunning(widget)
        let params = WidgetLoadParams(
            widgetId: widget.id,
            reason: reason,
            now: nowMs(),
            locale: configuration.locale(),
            appearance: configuration.appearance(),
            settings: settings ?? widget.manifest.settingsDefaults(),
            lastRenderRevision: revisions[widget.id]
        )
        try send(method: ScriptMethod.widgetLoad, params: JSONValue.bridged(params), to: instance)
    }

    /// Forwards a UI `event` action to the script (`widget.action`).
    public func sendAction(widgetId: String, actionId: String, payload: JSONValue? = nil) async throws {
        guard let widget = descriptors[widgetId] else {
            throw RuntimeSupervisorError.unknownWidget(widgetId)
        }
        if let reason = disabledReasons[widgetId] {
            throw RuntimeSupervisorError.widgetDisabled(reason)
        }
        let instance = try ensureRunning(widget)
        let params = WidgetActionParams(actionId: actionId, payload: payload, now: nowMs())
        try send(method: ScriptMethod.widgetAction, params: JSONValue.bridged(params), to: instance)
    }

    /// Graceful shutdown: SIGTERM, escalating to SIGKILL after 2 s.
    public func stop(widgetId: String) {
        guard let instance = instances[widgetId] else { return }
        instance.stopping = true
        let process = instance.process
        if process.isRunning {
            process.terminate()
            Task.detached {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        cancelTimers(widgetId: widgetId)
    }

    /// Stops every widget not in `keeping` (hot-reload cleanup).
    public func retain(widgetIds keeping: Set<String>) {
        for id in instances.keys where !keeping.contains(id) {
            stop(widgetId: id)
        }
        for id in descriptors.keys where !keeping.contains(id) {
            descriptors.removeValue(forKey: id)
            disabledReasons.removeValue(forKey: id)
            crashTimes.removeValue(forKey: id)
            cancelTimers(widgetId: id)
        }
    }

    public func stopAll() {
        for id in instances.keys { stop(widgetId: id) }
    }

    /// "Restart Widget": clears the crash-loop `disabled` state and reloads.
    public func restart(widgetId: String) async throws {
        guard let widget = descriptors[widgetId] else {
            throw RuntimeSupervisorError.unknownWidget(widgetId)
        }
        disabledReasons.removeValue(forKey: widgetId)
        crashTimes.removeValue(forKey: widgetId)
        configuration.audit?.record("widget.restarted", widgetId: widgetId)
        try await load(widget, reason: "manual")
    }

    public func disabledReason(widgetId: String) -> String? {
        disabledReasons[widgetId]
    }

    public func isRunning(widgetId: String) -> Bool {
        instances[widgetId]?.process.isRunning ?? false
    }

    // MARK: - Process lifecycle

    private func ensureRunning(_ widget: ScriptWidgetDescriptor) throws -> ScriptInstance {
        if let instance = instances[widget.id], instance.process.isRunning {
            return instance
        }
        if let stale = instances.removeValue(forKey: widget.id) {
            stale.readTask?.cancel()
            try? stale.stdinHandle.close()
        }

        let plan = try configuration.makeLaunchPlan(widget)
        let process = Process()
        process.executableURL = plan.executable
        process.arguments = plan.arguments
        process.currentDirectoryURL = plan.currentDirectory ?? widget.directory
        if let environment = plan.environment {
            process.environment = ProcessInfo.processInfo.environment
                .merging(environment) { _, injected in injected }
        }

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let widgetId = widget.id
        let instance = ScriptInstance(
            process: process,
            stdinHandle: stdinPipe.fileHandleForWriting,
            dispatcher: makeDispatcher(widgetId: widgetId)
        )
        // Strong capture of `instance` is intentional; the handler clears
        // itself on invocation (and the stub/script exits on stdin EOF), so
        // the process→handler→instance cycle breaks at termination.
        process.terminationHandler = { [weak self] finished in
            finished.terminationHandler = nil
            let status = finished.terminationStatus
            Task { await self?.processTerminated(widgetId: widgetId, instance: instance, status: status) }
        }

        do {
            try process.run()
        } catch {
            throw JsonRpcError.internalError("failed to launch script runtime: \(error.localizedDescription)")
        }

        startStderrDrain(widgetId: widgetId, handle: stderrPipe.fileHandleForReading)
        instance.readTask = startStdoutReader(widgetId: widgetId, handle: stdoutPipe.fileHandleForReading)
        instances[widgetId] = instance
        events.onStateChange(widgetId, .running)
        return instance
    }

    /// stdout: newline-delimited JSON-RPC, 1 MB per-line limit.
    private func startStdoutReader(widgetId: String, handle: FileHandle) -> Task<Void, Never> {
        let maxLineBytes = configuration.maxStdoutLineBytes
        let stream = AsyncStream<StdoutEvent> { continuation in
            var buffer = Data()
            handle.readabilityHandler = { readHandle in
                let chunk = readHandle.availableData
                if chunk.isEmpty {
                    readHandle.readabilityHandler = nil
                    continuation.finish()
                    return
                }
                buffer.append(chunk)
                while let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                    let line = buffer.subdata(in: buffer.startIndex..<newlineIndex)
                    buffer.removeSubrange(buffer.startIndex...newlineIndex)
                    if !line.isEmpty {
                        continuation.yield(.line(line))
                    }
                }
                if buffer.count > maxLineBytes {
                    buffer.removeAll()
                    continuation.yield(.overflow)
                }
            }
        }
        return Task { [weak self] in
            for await event in stream {
                guard let self else { break }
                switch event {
                case let .line(data):
                    await self.handleLine(widgetId: widgetId, line: data)
                case .overflow:
                    await self.handleLineOverflow(widgetId: widgetId)
                }
            }
        }
    }

    /// stderr streams into the widget log.
    private func startStderrDrain(widgetId: String, handle: FileHandle) {
        let logs = configuration.widgetLogs
        let onWidgetLog = events.onWidgetLog
        var buffer = Data()
        handle.readabilityHandler = { readHandle in
            let chunk = readHandle.availableData
            if chunk.isEmpty {
                if !buffer.isEmpty, let text = String(data: buffer, encoding: .utf8), !text.isEmpty {
                    logs?.append(widgetId: widgetId, level: "stderr", message: text)
                    onWidgetLog(widgetId, "stderr", text)
                }
                readHandle.readabilityHandler = nil
                return
            }
            buffer.append(chunk)
            while let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = buffer.subdata(in: buffer.startIndex..<newlineIndex)
                buffer.removeSubrange(buffer.startIndex...newlineIndex)
                guard let text = String(data: line, encoding: .utf8), !text.isEmpty else { continue }
                logs?.append(widgetId: widgetId, level: "stderr", message: text)
                onWidgetLog(widgetId, "stderr", text)
            }
        }
    }

    private func handleLine(widgetId: String, line: Data) async {
        guard let instance = instances[widgetId] else { return }
        do {
            let message = try JsonRpcCodec.decode(line: line)
            guard case let .request(request) = message else {
                throw JsonRpcError.protocolError("host expects requests, not responses")
            }
            if let response = await instance.dispatcher.dispatch(request) {
                try send(response: response, to: instance)
            }
        } catch let error as JsonRpcError {
            widgetLog(widgetId, "error", "protocol error: \(error.message)")
            try? send(response: JsonRpcResponse(id: nil, error: error), to: instance)
        } catch {
            widgetLog(widgetId, "error", "protocol error: \(error)")
        }
    }

    private func handleLineOverflow(widgetId: String) {
        widgetLog(
            widgetId, "error",
            "stdout line exceeded \(configuration.maxStdoutLineBytes) bytes — terminating script"
        )
        instances[widgetId]?.process.terminate() // counts as a crash
    }

    private func processTerminated(widgetId: String, instance: ScriptInstance, status: Int32) {
        // Only evict the registry entry if it is still *this* instance — a
        // dead process may already have been replaced by a respawn.
        if instances[widgetId] === instance {
            instances.removeValue(forKey: widgetId)
        }
        instance.readTask?.cancel()
        try? instance.stdinHandle.close()

        if instance.stopping {
            events.onStateChange(widgetId, .stopped)
            return
        }

        widgetLog(widgetId, "error", "script exited with status \(status)")
        let now = configuration.now()
        var recent = (crashTimes[widgetId] ?? []).filter {
            now.timeIntervalSince($0) < configuration.crashLoopWindowSec
        }
        recent.append(now)
        crashTimes[widgetId] = recent

        if recent.count >= configuration.crashLoopThreshold {
            let reason = "crashed \(recent.count) times within \(Int(configuration.crashLoopWindowSec / 60)) minutes"
            disabledReasons[widgetId] = reason
            cancelTimers(widgetId: widgetId)
            configuration.audit?.record(
                "widget.disabled", widgetId: widgetId,
                detail: ["reason": .string(reason)]
            )
            events.onStateChange(widgetId, .disabled(reason: reason))
        } else {
            events.onStateChange(widgetId, .stopped)
        }
    }

    // MARK: - Outbound writes

    private func send(method: String, params: JSONValue?, to instance: ScriptInstance) throws {
        let request = JsonRpcRequest(id: nil, method: method, params: params)
        try write(.request(request), to: instance)
    }

    private func send(response: JsonRpcResponse, to instance: ScriptInstance) throws {
        try write(.response(response), to: instance)
    }

    private func write(_ message: JsonRpcMessage, to instance: ScriptInstance) throws {
        var data = try JsonRpcCodec.encode(message)
        data.append(0x0A)
        try instance.stdinHandle.write(contentsOf: data)
    }

    // MARK: - Request routing (script → host)

    private func makeDispatcher(widgetId: String) -> JsonRpcDispatcher {
        let dispatcher = JsonRpcDispatcher()
        let methods: [String: @Sendable (RuntimeSupervisor, String, JSONValue?) async throws -> JSONValue] = [
            ScriptMethod.hostRender: { supervisor, id, params in try await supervisor.handleRender(widgetId: id, params: params) },
            ScriptMethod.hostExecRun: { supervisor, id, params in try await supervisor.handleExecRun(widgetId: id, params: params) },
            ScriptMethod.hostStorageGet: { supervisor, id, params in try await supervisor.handleStorageGet(widgetId: id, params: params) },
            ScriptMethod.hostStorageSet: { supervisor, id, params in try await supervisor.handleStorageSet(widgetId: id, params: params) },
            ScriptMethod.hostStorageDelete: { supervisor, id, params in try await supervisor.handleStorageDelete(widgetId: id, params: params) },
            ScriptMethod.hostStorageList: { supervisor, id, params in try await supervisor.handleStorageList(widgetId: id, params: params) },
            ScriptMethod.hostSecretGet: { supervisor, id, params in try await supervisor.handleSecretGet(widgetId: id, params: params) },
            ScriptMethod.hostSecretSet: { supervisor, id, params in try await supervisor.handleSecretSet(widgetId: id, params: params) },
            ScriptMethod.hostTimerOnce: { supervisor, id, params in try await supervisor.handleTimer(widgetId: id, params: params, kind: .once) },
            ScriptMethod.hostTimerAfter: { supervisor, id, params in try await supervisor.handleTimer(widgetId: id, params: params, kind: .after) },
            ScriptMethod.hostTimerEvery: { supervisor, id, params in try await supervisor.handleTimer(widgetId: id, params: params, kind: .every) },
            ScriptMethod.hostTimerClear: { supervisor, id, params in try await supervisor.handleTimer(widgetId: id, params: params, kind: .clear) },
            ScriptMethod.hostNotifyShow: { supervisor, id, params in try await supervisor.handleNotify(widgetId: id, params: params) },
            ScriptMethod.hostLog: { supervisor, id, params in try await supervisor.handleLog(widgetId: id, params: params) },
        ]
        for (method, handler) in methods {
            dispatcher.register(method: method) { [weak self] params in
                guard let self else {
                    throw JsonRpcError.internalError("runtime supervisor is gone")
                }
                return try await handler(self, widgetId, params)
            }
        }
        return dispatcher
    }

    private func decodeParams<T: Decodable>(_ type: T.Type, from params: JSONValue?) throws -> T {
        guard let params else {
            throw JsonRpcError.protocolError("missing params")
        }
        do {
            return try params.decoded(type)
        } catch {
            throw JsonRpcError.protocolError("invalid params for \(type): \(error)")
        }
    }

    private func manifest(for widgetId: String) throws -> Manifest {
        guard let descriptor = descriptors[widgetId] else {
            throw JsonRpcError.internalError("no descriptor for widget \(widgetId)")
        }
        return descriptor.manifest
    }

    // MARK: host.render

    private func handleRender(widgetId: String, params: JSONValue?) async throws -> JSONValue {
        let render: RenderParams
        do {
            render = try decodeParams(RenderParams.self, from: params)
        } catch {
            throw JsonRpcError.protocolError("invalid render tree: \(error)")
        }
        let revision = (revisions[widgetId] ?? 0) + 1
        revisions[widgetId] = revision
        events.onRender(widgetId, render, revision)
        return try JSONValue.bridged(RenderResult(revision: revision))
    }

    // MARK: host.exec.run

    private func handleExecRun(widgetId: String, params: JSONValue?) async throws -> JSONValue {
        let exec = try decodeParams(ExecRunParams.self, from: params)
        let manifest = try manifest(for: widgetId)
        let argv = [exec.command] + (exec.args ?? [])
        let commandLine = argv.joined(separator: " ")

        guard let permission = ExecAllowlist.match(
            command: argv, permissions: manifest.permissions?.exec
        ) else {
            configuration.audit?.record(
                "exec.blocked", widgetId: widgetId,
                detail: ["command": .string(commandLine)]
            )
            throw JsonRpcError.permissionDenied(
                "command not allowed by manifest permissions.exec: \(commandLine)"
            )
        }

        // Env passthrough is restricted to variables declared in the manifest.
        var extraEnvironment: [String: String] = [:]
        let declaredEnv = Set((permission.env ?? []) + (manifest.permissions?.env ?? []))
        for (key, value) in exec.env ?? [:] where declaredEnv.contains(key) {
            extraEnvironment[key] = value
        }

        let source = manifest.source
        let discover = (argv.first == source?.command?.first) ? source?.discover : nil
        let sensitive = exec.sensitive == true || permission.sensitiveOutput == true

        let outcome = await ExecService.capture(
            command: argv,
            discover: discover,
            timeoutMs: exec.timeoutMs ?? configuration.defaultExecTimeoutMs,
            workingDirectory: descriptors[widgetId]?.directory,
            extraEnvironment: extraEnvironment.isEmpty ? nil : extraEnvironment,
            stdoutLimit: permission.maxOutputBytes ?? ExecService.maxStdoutBytes
        )

        switch outcome {
        case let .failure(error):
            configuration.audit?.record(
                "exec.failed", widgetId: widgetId,
                detail: [
                    "command": .string(sensitive ? exec.command : commandLine),
                    "error": .string(error.errorDescription ?? String(describing: error)),
                ]
            )
            switch error {
            case .binaryNotFound:
                throw JsonRpcError.execNotFound(error.errorDescription ?? "binary not found")
            case .timeout:
                throw JsonRpcError.timeout(error.errorDescription ?? "timed out")
            case .outputTooLarge:
                throw JsonRpcError.protocolError(error.errorDescription ?? "output too large")
            case .emptyCommand, .launchFailed, .nonZeroExit:
                throw JsonRpcError.internalError(error.errorDescription ?? String(describing: error))
            }
        case let .success(capture):
            configuration.audit?.record(
                "exec.run", widgetId: widgetId,
                detail: [
                    // Sensitive commands are audited by binary only (no args).
                    "command": .string(sensitive ? exec.command : commandLine),
                    "exitCode": .number(Double(capture.exitCode)),
                    "durationMs": .number((capture.durationMs * 10).rounded() / 10),
                ]
            )
            let stdout = String(data: capture.stdout, encoding: .utf8) ?? ""
            let stderr = String(data: capture.stderr, encoding: .utf8) ?? ""
            var json: JSONValue?
            switch exec.parse {
            case "json":
                json = try? JSONDecoder().decode(JSONValue.self, from: capture.stdout)
            case "lines":
                json = .array(
                    stdout.split(separator: "\n", omittingEmptySubsequences: true)
                        .map { .string(String($0)) }
                )
            default:
                break
            }
            return try JSONValue.bridged(ExecRunResult(
                exitCode: Int(capture.exitCode),
                stdout: stdout,
                stderr: stderr,
                json: json,
                durationMs: capture.durationMs
            ))
        }
    }

    // MARK: host.storage.*

    private func handleStorageGet(widgetId: String, params: JSONValue?) async throws -> JSONValue {
        let storage = try decodeParams(StorageParams.self, from: params)
        guard let key = storage.key else { throw JsonRpcError.protocolError("storage.get requires key") }
        return configuration.storage.get(widgetId: widgetId, key: key) ?? .null
    }

    private func handleStorageSet(widgetId: String, params: JSONValue?) async throws -> JSONValue {
        let storage = try decodeParams(StorageParams.self, from: params)
        guard let key = storage.key else { throw JsonRpcError.protocolError("storage.set requires key") }
        guard let value = storage.value else { throw JsonRpcError.protocolError("storage.set requires value") }
        do {
            try configuration.storage.set(widgetId: widgetId, key: key, value: value, ttlMs: storage.ttlMs)
        } catch let error as JsonRpcError {
            throw error
        } catch {
            throw JsonRpcError.internalError("storage write failed: \(error)")
        }
        return .null
    }

    private func handleStorageDelete(widgetId: String, params: JSONValue?) async throws -> JSONValue {
        let storage = try decodeParams(StorageParams.self, from: params)
        guard let key = storage.key else { throw JsonRpcError.protocolError("storage.delete requires key") }
        do {
            try configuration.storage.delete(widgetId: widgetId, key: key)
        } catch {
            throw JsonRpcError.internalError("storage delete failed: \(error)")
        }
        return .null
    }

    private func handleStorageList(widgetId: String, params: JSONValue?) async throws -> JSONValue {
        let storage = (try? decodeParams(StorageParams.self, from: params)) ?? StorageParams()
        let keys = configuration.storage.list(widgetId: widgetId, prefix: storage.prefix)
        return .array(keys.map { .string($0) })
    }

    // MARK: host.secret.*

    private func handleSecretGet(widgetId: String, params: JSONValue?) async throws -> JSONValue {
        let manifest = try manifest(for: widgetId)
        guard manifest.permissions?.keychain == true else {
            throw JsonRpcError.permissionDenied("secret access requires manifest permissions.keychain: true")
        }
        let secret = try decodeParams(SecretParams.self, from: params)
        configuration.audit?.record(
            "secret.get", widgetId: widgetId, detail: ["key": .string(secret.key)]
        )
        do {
            if let value = try configuration.secrets.get(widgetId: widgetId, key: secret.key) {
                return .string(value)
            }
            return .null
        } catch let error as JsonRpcError {
            throw error
        } catch {
            throw JsonRpcError.internalError("secret read failed: \(error)")
        }
    }

    private func handleSecretSet(widgetId: String, params: JSONValue?) async throws -> JSONValue {
        let manifest = try manifest(for: widgetId)
        guard manifest.permissions?.keychain == true else {
            throw JsonRpcError.permissionDenied("secret access requires manifest permissions.keychain: true")
        }
        let secret = try decodeParams(SecretParams.self, from: params)
        guard let value = secret.value else {
            throw JsonRpcError.protocolError("secret.set requires value")
        }
        // Audit records the key only — never the value.
        configuration.audit?.record(
            "secret.set", widgetId: widgetId, detail: ["key": .string(secret.key)]
        )
        do {
            try configuration.secrets.set(widgetId: widgetId, key: secret.key, value: value)
        } catch let error as JsonRpcError {
            throw error
        } catch {
            throw JsonRpcError.internalError("secret write failed: \(error)")
        }
        return .null
    }

    // MARK: host.timer.*

    private enum TimerKind { case once, after, every, clear }

    private func handleTimer(widgetId: String, params: JSONValue?, kind: TimerKind) async throws -> JSONValue {
        let timer = try decodeParams(TimerParams.self, from: params)
        switch kind {
        case .once:
            guard let atMs = timer.atMs else { throw JsonRpcError.protocolError("timer.once requires atMs") }
            let delaySec = max((atMs - nowMs()) / 1000, 0.05)
            scheduleTimer(widgetId: widgetId, timerId: timer.id, delaySec: delaySec, repeatingSec: nil)
        case .after:
            guard let delayMs = timer.delayMs else { throw JsonRpcError.protocolError("timer.after requires delayMs") }
            scheduleTimer(widgetId: widgetId, timerId: timer.id, delaySec: max(delayMs / 1000, 0), repeatingSec: nil)
        case .every:
            guard let intervalMs = timer.intervalMs else { throw JsonRpcError.protocolError("timer.every requires intervalMs") }
            // Host policy: minimum repeat interval is enforced, not errored.
            let clampedMs = max(intervalMs, configuration.minTimerIntervalMs)
            if clampedMs != intervalMs {
                widgetLog(widgetId, "warn", "timer.every interval \(intervalMs)ms clamped to \(clampedMs)ms (minInterval)")
            }
            scheduleTimer(
                widgetId: widgetId, timerId: timer.id,
                delaySec: clampedMs / 1000, repeatingSec: clampedMs / 1000
            )
        case .clear:
            timers[widgetId]?.removeValue(forKey: timer.id)?.cancel()
        }
        return .null
    }

    private func scheduleTimer(widgetId: String, timerId: String, delaySec: Double, repeatingSec: Double?) {
        timers[widgetId]?[timerId]?.cancel()
        let source = DispatchSource.makeTimerSource(queue: .global())
        if let repeatingSec {
            source.schedule(deadline: .now() + delaySec, repeating: repeatingSec)
        } else {
            source.schedule(deadline: .now() + delaySec)
        }
        let repeats = repeatingSec != nil
        source.setEventHandler { [weak self] in
            Task { await self?.timerFired(widgetId: widgetId, timerId: timerId, repeats: repeats) }
        }
        timers[widgetId, default: [:]][timerId] = source
        source.resume()
    }

    /// Timer metadata lives host-side: firing respawns a dead script process
    /// before delivering `widget.timer` (unless the widget is disabled).
    private func timerFired(widgetId: String, timerId: String, repeats: Bool) async {
        if !repeats {
            timers[widgetId]?.removeValue(forKey: timerId)?.cancel()
        }
        guard disabledReasons[widgetId] == nil, let widget = descriptors[widgetId] else { return }
        do {
            let instance = try ensureRunning(widget)
            let params = WidgetTimerParams(id: timerId, now: nowMs())
            try send(method: ScriptMethod.widgetTimer, params: JSONValue.bridged(params), to: instance)
        } catch {
            widgetLog(widgetId, "error", "timer \(timerId) delivery failed: \(error)")
        }
    }

    private func cancelTimers(widgetId: String) {
        if let widgetTimers = timers[widgetId] {
            for timer in widgetTimers.values { timer.cancel() }
        }
        timers.removeValue(forKey: widgetId)
    }

    // MARK: host.notify.show / host.log

    private func handleNotify(widgetId: String, params: JSONValue?) async throws -> JSONValue {
        let manifest = try manifest(for: widgetId)
        guard manifest.permissions?.notifications == true else {
            throw JsonRpcError.permissionDenied("notifications require manifest permissions.notifications: true")
        }
        let notify = try decodeParams(NotifyParams.self, from: params)
        guard let sink = configuration.notify else {
            throw JsonRpcError.internalError("notifications unavailable in this host")
        }
        do {
            try await sink(notify.title, notify.body)
        } catch let error as JsonRpcError {
            throw error
        } catch {
            throw JsonRpcError.internalError("notification failed: \(error.localizedDescription)")
        }
        return .null
    }

    private func handleLog(widgetId: String, params: JSONValue?) async throws -> JSONValue {
        let log = try decodeParams(LogParams.self, from: params)
        widgetLog(widgetId, log.level, log.message)
        return .null
    }

    // MARK: - Helpers

    private func widgetLog(_ widgetId: String, _ level: String, _ message: String) {
        configuration.widgetLogs?.append(widgetId: widgetId, level: level, message: message)
        events.onWidgetLog(widgetId, level, message)
    }

    private func nowMs() -> Double {
        configuration.now().timeIntervalSince1970 * 1000
    }
}

// MARK: - Deno launch planning

public enum RuntimeLaunchError: Error, LocalizedError, Equatable {
    case denoNotFound
    case sdkNotFound
    case unsupportedRuntime(String)

    public var errorDescription: String? {
        switch self {
        case .denoNotFound:
            return "Deno runtime not found. \(DenoRuntime.installHint)"
        case .sdkNotFound:
            return "menubucket SDK (sdk/mod.ts) not found"
        case let .unsupportedRuntime(runtime):
            return "unsupported entry.runtime \"\(runtime)\" (supported: \(DenoRuntime.runtimeIdentifier))"
        }
    }
}

/// Production launch planning: locate deno + the TS SDK, generate the import
/// map, and assemble the sandboxed `deno run` invocation.
public enum DenoRuntime {
    public static let runtimeIdentifier = "deno-ts@1"
    public static let installHint = "Install Deno: brew install deno"

    /// `$DENO_BIN` → `/opt/homebrew/bin/deno` → `/usr/local/bin/deno` →
    /// `~/.deno/bin/deno` → PATH.
    public static let discoverChain = [
        "$DENO_BIN",
        "/opt/homebrew/bin/deno",
        "/usr/local/bin/deno",
        "~/.deno/bin/deno",
        "PATH",
    ]

    public static func locateDeno() -> URL? {
        var searched: [String] = []
        return ExecService.resolveExecutable(
            command0: "deno", discover: discoverChain, workingDirectory: nil, searched: &searched
        )
    }

    /// SDK module: development mode `./sdk/mod.ts` (cwd), bundled mode the
    /// app's resource directory.
    public static func locateSDKModule(fileManager: FileManager = .default) -> URL? {
        let development = URL(fileURLWithPath: fileManager.currentDirectoryPath)
            .appendingPathComponent("sdk/mod.ts")
        if fileManager.fileExists(atPath: development.path) { return development }
        if let resources = Bundle.main.resourceURL {
            let bundled = resources.appendingPathComponent("sdk/mod.ts")
            if fileManager.fileExists(atPath: bundled.path) { return bundled }
        }
        return nil
    }

    /// ```
    /// deno run --quiet --no-prompt --no-remote \
    ///   --allow-read=<widget-bundle-dir> \
    ///   --import-map=<generated-import-map.json> \
    ///   <bundle>/index.ts
    /// ```
    public static func makeLaunchPlan(
        widget: ScriptWidgetDescriptor,
        stateDirectory: URL
    ) throws -> ScriptLaunchPlan {
        if let runtime = widget.manifest.entry.runtime, runtime != runtimeIdentifier {
            throw RuntimeLaunchError.unsupportedRuntime(runtime)
        }
        guard let deno = locateDeno() else {
            throw RuntimeLaunchError.denoNotFound
        }
        guard let sdkModule = locateSDKModule() else {
            throw RuntimeLaunchError.sdkNotFound
        }
        let importMapURL = try writeImportMap(
            widgetId: widget.id, sdkModule: sdkModule, stateDirectory: stateDirectory
        )
        return ScriptLaunchPlan(
            executable: deno,
            arguments: [
                "run", "--quiet", "--no-prompt", "--no-remote",
                "--allow-read=\(widget.directory.path)",
                "--import-map=\(importMapURL.path)",
                widget.directory.appendingPathComponent("index.ts").path,
            ],
            currentDirectory: widget.directory
        )
    }

    /// `{"imports": {"menubucket": "file://<sdk>/mod.ts"}}`
    public static func writeImportMap(
        widgetId: String,
        sdkModule: URL,
        stateDirectory: URL
    ) throws -> URL {
        let widgetState = stateDirectory.appendingPathComponent(
            StorageService.sanitized(widgetId), isDirectory: true
        )
        try FileManager.default.createDirectory(at: widgetState, withIntermediateDirectories: true)
        let importMapURL = widgetState.appendingPathComponent("import-map.json")
        let map = JSONValue.object([
            "imports": .object(["menubucket": .string("file://" + sdkModule.path)])
        ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(map).write(to: importMapURL, options: .atomic)
        return importMapURL
    }
}
