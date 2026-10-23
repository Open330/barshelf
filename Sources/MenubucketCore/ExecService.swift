import Darwin
import Foundation

/// Runs widget commands as isolated subprocesses.
///
/// Guarantees:
/// - No shell — `executableURL` is invoked directly with an argv array.
/// - Binary discovery: `$ENVVAR` → `~`-expanded absolute paths → literal "PATH"
///   (env PATH plus `/opt/homebrew/bin:/usr/local/bin:~/.cargo/bin` fallbacks).
/// - `timeoutMs` enforced (SIGTERM, escalating to SIGKILL after 2s).
/// - stdout capped at 1 MB; stderr drained on a separate pipe (capped at 64 KB).
public final class ExecService {
    private static let posixUTF8Locales: [String] =
        ((try? FileManager.default.contentsOfDirectory(atPath: "/usr/share/locale")) ?? [])
            .filter { $0.hasSuffix(".UTF-8") }.sorted()
    public static let maxStdoutBytes = 1_048_576
    public static let maxStderrBytes = 65_536
    public static let fallbackPathDirectories = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        ("~/.cargo/bin" as NSString).expandingTildeInPath,
    ]

    /// Minimal process environment plus explicitly authorized/injected values.
    public static func childEnvironment(
        extraEnvironment: [String: String]? = nil,
        hostEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        locale: Locale = .current
    ) -> [String: String] {
        var environment: [String: String] = [:]
        for key in ["HOME", "TMPDIR", "USER", "LOGNAME", "LANG", "LC_ALL", "LC_CTYPE", "LC_TIME", "LC_NUMERIC"] {
            if let value = hostEnvironment[key], !value.isEmpty { environment[key] = value }
        }
        // GUI apps launched by launchd usually have no LANG. Commands such as
        // /bin/date would otherwise produce English inside a localized app.
        if environment["LANG"] == nil {
            let base = locale.identifier.components(separatedBy: "@")[0].replacingOccurrences(of: "-", with: "_")
            let candidate = base.contains(".") ? base : base + ".UTF-8"
            let language = locale.language.languageCode?.identifier ?? String(base.prefix { $0 != "_" })
            // ICU locales such as ko_US do not necessarily exist as POSIX
            // locales. Use an installed locale of the same language instead.
            environment["LANG"] = Self.posixUTF8Locales.contains(candidate) ? candidate
                : Self.posixUTF8Locales.first { $0.hasPrefix(language + "_") } ?? "en_US.UTF-8"
            // Shell widgets emit JSON numbers; localize dates without turning
            // printf's decimal point into a comma on a German-language Mac.
            if environment["LC_NUMERIC"] == nil { environment["LC_NUMERIC"] = "C" }
        }
        let systemPath = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
        environment["PATH"] = (hostEnvironment["PATH"].map { $0.isEmpty ? nil : $0 } ?? nil)
            .map { "\($0):\(systemPath)" } ?? systemPath
        if let extraEnvironment {
            environment.merge(extraEnvironment) { _, injected in injected }
        }
        return environment
    }

    public init() {}

    public enum ExecError: Error, LocalizedError, Sendable {
        case emptyCommand
        case binaryNotFound(command: String, searched: [String])
        case launchFailed(String)
        case timeout(ms: Int)
        case outputTooLarge(limit: Int)
        case nonZeroExit(code: Int32, stderr: String)

        public var errorDescription: String? {
            switch self {
            case .emptyCommand:
                return "empty command"
            case let .binaryNotFound(command, searched):
                return "'\(command)' not found (searched: \(searched.joined(separator: ", ")))"
            case let .launchFailed(reason):
                return "failed to launch: \(reason)"
            case let .timeout(ms):
                return "timed out after \(ms) ms"
            case let .outputTooLarge(limit):
                return "output exceeded \(limit) bytes"
            case let .nonZeroExit(code, stderr):
                let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                return detail.isEmpty ? "exited with code \(code)" : "exited with code \(code): \(detail)"
            }
        }
    }

    /// Raw process outcome — non-zero exits are *not* errors here (the script
    /// runtime surfaces `exitCode` to widgets; the exec-widget pipeline maps
    /// non-zero to `ExecError.nonZeroExit` itself in `runSync`).
    public struct Capture: Sendable {
        public var exitCode: Int32
        public var stdout: Data
        public var stderr: Data
        public var durationMs: Double

        public init(exitCode: Int32, stdout: Data, stderr: Data, durationMs: Double) {
            self.exitCode = exitCode
            self.stdout = stdout
            self.stderr = stderr
            self.durationMs = durationMs
        }
    }

    private let queue = DispatchQueue(label: "dev.barshelf.exec", qos: .utility, attributes: .concurrent)

    /// Serializes launch with cancellation, including cancellation before the
    /// dispatch queue starts. The handle is cleared before capture returns.
    private final class ProcessControl: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        private var process: Process?

        var isCancelled: Bool { lock.withLock { cancelled } }

        func launch(_ process: Process) throws -> Bool {
            try lock.withLock {
                guard !cancelled else { return false }
                try process.run()
                self.process = process
                return true
            }
        }

        func cancel() {
            lock.withLock {
                cancelled = true
                if let process { ExecService.terminate(process) }
            }
        }

        func finish() { lock.withLock { process = nil } }
    }

    // Preserve the existing result/error API while reporting cancellation.
    private static var cancellationError: ExecError { .launchFailed("cancelled") }

    private final class CaptureState: @unchecked Sendable {
        private let lock = NSLock()
        private var stdout = Data()
        private var stderr = Data()
        private var stdoutOverflowed = false
        private var timedOut = false

        func appendStdout(_ chunk: Data, limit: Int) -> Bool {
            lock.withLock {
                stdout.append(chunk)
                if stdout.count > limit {
                    stdoutOverflowed = true
                    return true
                }
                return false
            }
        }

        func appendStderr(_ chunk: Data, limit: Int) {
            lock.withLock {
                guard stderr.count < limit else { return }
                stderr.append(chunk.prefix(limit - stderr.count))
            }
        }

        func markTimedOut() {
            lock.withLock { timedOut = true }
        }

        func snapshot() -> (stdout: Data, stderr: Data, overflowed: Bool, timedOut: Bool) {
            lock.withLock { (stdout, stderr, stdoutOverflowed, timedOut) }
        }
    }

    /// Runs `command` and delivers stdout data (or an error) on an arbitrary queue.
    /// `workingDirectory` doubles as the base for `./relative` command paths
    /// (used by widgets shipping their own scripts). `extraEnvironment` is
    /// merged over a minimal environment (declared value/secret injection).
    public func run(
        command: [String],
        discover: [String]?,
        timeoutMs: Int,
        workingDirectory: URL?,
        extraEnvironment: [String: String]? = nil,
        stdoutLimit: Int = ExecService.maxStdoutBytes,
        completion: @escaping @Sendable (Result<Data, ExecError>) -> Void
    ) {
        queue.async {
            completion(Self.runSync(
                command: command,
                discover: discover,
                timeoutMs: timeoutMs,
                workingDirectory: workingDirectory,
                extraEnvironment: extraEnvironment,
                stdoutLimit: stdoutLimit
            ))
        }
    }

    /// Cancellable async execution, using the same stdout mapping as `runSync`.
    public func run(
        command: [String],
        discover: [String]?,
        timeoutMs: Int,
        workingDirectory: URL?,
        extraEnvironment: [String: String]? = nil,
        stdoutLimit: Int = ExecService.maxStdoutBytes
    ) async -> Result<Data, ExecError> {
        Self.stdoutResult(await Self.capture(
            command: command,
            discover: discover,
            timeoutMs: timeoutMs,
            workingDirectory: workingDirectory,
            extraEnvironment: extraEnvironment,
            stdoutLimit: stdoutLimit
        ))
    }

    public static func runSync(
        command: [String],
        discover: [String]?,
        timeoutMs: Int,
        workingDirectory: URL?,
        extraEnvironment: [String: String]? = nil,
        stdoutLimit: Int = ExecService.maxStdoutBytes
    ) -> Result<Data, ExecError> {
        stdoutResult(captureSync(
            command: command,
            discover: discover,
            timeoutMs: timeoutMs,
            workingDirectory: workingDirectory,
            extraEnvironment: extraEnvironment,
            stdoutLimit: stdoutLimit
        ))
    }

    private static func stdoutResult(_ result: Result<Capture, ExecError>) -> Result<Data, ExecError> {
        switch result {
        case let .failure(error):
            return .failure(error)
        case let .success(capture):
            if capture.exitCode != 0 {
                let stderrText = String(data: capture.stderr, encoding: .utf8) ?? ""
                return .failure(.nonZeroExit(code: capture.exitCode, stderr: stderrText))
            }
            return .success(capture.stdout)
        }
    }

    /// Runs off the caller's executor; task cancellation terminates the child
    /// and returns `launchFailed("cancelled")` after bounded cleanup.
    public static func capture(
        command: [String],
        discover: [String]?,
        timeoutMs: Int,
        workingDirectory: URL?,
        extraEnvironment: [String: String]? = nil,
        stdoutLimit: Int = ExecService.maxStdoutBytes
    ) async -> Result<Capture, ExecError> {
        let control = ProcessControl()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(returning: captureSync(
                        command: command,
                        discover: discover,
                        timeoutMs: timeoutMs,
                        workingDirectory: workingDirectory,
                        extraEnvironment: extraEnvironment,
                        stdoutLimit: stdoutLimit,
                        control: control
                    ))
                }
            }
        } onCancel: {
            control.cancel()
        }
    }

    public static func captureSync(
        command: [String],
        discover: [String]?,
        timeoutMs: Int,
        workingDirectory: URL?,
        extraEnvironment: [String: String]? = nil,
        stdoutLimit: Int = ExecService.maxStdoutBytes
    ) -> Result<Capture, ExecError> {
        captureSync(
            command: command, discover: discover, timeoutMs: timeoutMs,
            workingDirectory: workingDirectory, extraEnvironment: extraEnvironment,
            stdoutLimit: stdoutLimit, control: ProcessControl()
        )
    }

    private static func captureSync(
        command: [String],
        discover: [String]?,
        timeoutMs: Int,
        workingDirectory: URL?,
        extraEnvironment: [String: String]?,
        stdoutLimit: Int,
        control: ProcessControl
    ) -> Result<Capture, ExecError> {
        defer { control.finish() }
        guard !control.isCancelled else { return .failure(cancellationError) }
        guard let executableName = command.first, !executableName.isEmpty else {
            return .failure(.emptyCommand)
        }
        var searched: [String] = []
        guard let executableURL = resolveExecutable(
            command0: executableName,
            discover: discover,
            workingDirectory: workingDirectory,
            searched: &searched
        ) else {
            return .failure(.binaryNotFound(command: executableName, searched: searched))
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = Array(command.dropFirst())
        if let workingDirectory {
            process.currentDirectoryURL = workingDirectory
        }
        // Start from a minimal environment. Widgets receive declared values
        // through `extraEnvironment`; inheriting the whole app environment can
        // leak unrelated tokens from shells, IDEs, or launch agents.
        process.environment = childEnvironment(extraEnvironment: extraEnvironment)

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice

        let captureState = CaptureState()
        let readGroup = DispatchGroup()
        let readQueue = DispatchQueue(label: "dev.barshelf.exec.read", attributes: .concurrent)

        let startedAt = Date()
        do {
            guard try control.launch(process) else {
                Self.closePipe(stdoutPipe)
                Self.closePipe(stderrPipe)
                return .failure(cancellationError)
            }
        } catch {
            Self.closePipe(stdoutPipe)
            Self.closePipe(stderrPipe)
            return .failure(.launchFailed(error.localizedDescription))
        }

        let deadline = ReadDeadline(DispatchTime.now() + .milliseconds(max(timeoutMs, 1)))
        readGroup.enter()
        readQueue.async {
            defer { readGroup.leave() }
            let handle = stdoutPipe.fileHandleForReading
            Self.drain(handle, until: deadline.value, cancelled: { control.isCancelled }, timedOut: { captureState.markTimedOut() }) { chunk in
                if captureState.appendStdout(chunk, limit: stdoutLimit) {
                    Self.terminate(process)
                    return true
                }
                return false
            }
            try? handle.close()
        }

        readGroup.enter()
        readQueue.async {
            defer { readGroup.leave() }
            let handle = stderrPipe.fileHandleForReading
            Self.drain(handle, until: deadline.value, cancelled: { control.isCancelled }, timedOut: { captureState.markTimedOut() }) { chunk in
                captureState.appendStderr(chunk, limit: maxStderrBytes)
                return false
            }
            try? handle.close()
        }

        let timeoutItem = DispatchWorkItem {
            captureState.markTimedOut()
            Self.terminate(process)
        }
        DispatchQueue.global().asyncAfter(
            deadline: .now() + .milliseconds(max(timeoutMs, 1)),
            execute: timeoutItem
        )

        process.waitUntilExit()
        // Exited in time: the timer has nothing left to stop, and the readers
        // get a moment past the deadline to drain what is already buffered.
        // A process ending at 995 ms of 1000 was reported as timed out while
        // its output was still being read. A descendant that keeps the pipe
        // open is still cut off, a second later.
        timeoutItem.cancel()
        if !captureState.snapshot().timedOut {
            deadline.extend(to: DispatchTime.now() + .seconds(1))
        }
        readGroup.wait()

        let capture = captureState.snapshot()

        if control.isCancelled { return .failure(cancellationError) }
        if capture.overflowed {
            return .failure(.outputTooLarge(limit: stdoutLimit))
        }
        if capture.timedOut {
            return .failure(.timeout(ms: timeoutMs))
        }
        return .success(Capture(
            exitCode: process.terminationStatus,
            stdout: capture.stdout,
            stderr: capture.stderr,
            durationMs: Date().timeIntervalSince(startedAt) * 1000
        ))
    }

    /// Every resource-limit and lifecycle exit gets the same bounded grace
    /// period, including scripts that deliberately ignore SIGTERM.
    static func terminate(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    /// Foundation can retain pipe endpoints after a failed Process launch.
    /// Close both ends explicitly instead of relying on object destruction.
    static func closePipe(_ pipe: Pipe) {
        try? pipe.fileHandleForReading.close()
        try? pipe.fileHandleForWriting.close()
    }

    // MARK: - Binary discovery

    /// A descendant may inherit a pipe after the launched process exits.
    /// Poll for readable bytes/EOF with the same deadline as the process,
    /// rather than blocking indefinitely in FileHandle.availableData.
    private static func drain(_ handle: FileHandle, until currentDeadline: () -> DispatchTime,
                              cancelled: () -> Bool, timedOut: () -> Void, onChunk: (Data) -> Bool) {
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            guard !cancelled() else { return }
            let deadline = currentDeadline()
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline.uptimeNanoseconds else { timedOut(); return }
            let remaining = (deadline.uptimeNanoseconds - now) / 1_000_000 + 1
            var descriptor = pollfd(fd: handle.fileDescriptor, events: Int16(POLLIN), revents: 0)
            // Recheck cancellation even if a descendant keeps the pipe open.
            let ready = poll(&descriptor, 1, Int32(min(remaining, 100)))
            if ready == 0 { continue }
            if ready < 0 {
                if errno == EINTR { continue }
                return
            }
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(handle.fileDescriptor, bytes.baseAddress, bytes.count)
            }
            if count == 0 { return }
            if count < 0 {
                if errno == EINTR { continue }
                return
            }
            if onChunk(Data(buffer.prefix(count))) { return }
        }
    }

    public static func resolveExecutable(
        command0: String,
        discover: [String]?,
        workingDirectory: URL?,
        searched: inout [String]
    ) -> URL? {
        let fm = FileManager.default

        func executableURL(atPath path: String) -> URL? {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDirectory),
                  !isDirectory.boolValue,
                  fm.isExecutableFile(atPath: path)
            else { return nil }
            return URL(fileURLWithPath: path)
        }

        func matchesCommandIdentity(_ candidate: URL) -> Bool {
            let trustedBareCommand = command0.contains("/")
                ? nil
                : searchPATH(for: command0, executableURL: executableURL)
            return executableMatchesCommandIdentity(
                command0: command0,
                candidate: candidate,
                workingDirectory: workingDirectory,
                trustedBareCommand: trustedBareCommand
            )
        }

        func authorizedExecutableURL(atPath path: String) -> URL? {
            guard let candidate = executableURL(atPath: path), matchesCommandIdentity(candidate) else {
                return nil
            }
            return candidate
        }

        if let discover, !discover.isEmpty {
            for candidate in discover {
                if candidate == "PATH" {
                    searched.append("PATH")
                    if let found = searchPATH(for: command0, executableURL: authorizedExecutableURL) {
                        return found
                    }
                } else if candidate.hasPrefix("$") {
                    let variable = String(candidate.dropFirst())
                    searched.append(candidate)
                    guard let value = ProcessInfo.processInfo.environment[variable], !value.isEmpty else {
                        continue
                    }
                    let expanded = (value as NSString).expandingTildeInPath
                    if let found = authorizedExecutableURL(atPath: expanded) {
                        return found
                    }
                } else {
                    let expanded = (candidate as NSString).expandingTildeInPath
                    searched.append(expanded)
                    if let found = authorizedExecutableURL(atPath: expanded) {
                        return found
                    }
                }
            }
            return nil
        }

        // No discover list: relative/absolute paths resolve directly, bare names via PATH.
        if command0.hasPrefix("./") || command0.hasPrefix("../") {
            let base = workingDirectory ?? URL(fileURLWithPath: fm.currentDirectoryPath)
            let path = base.appendingPathComponent(command0).standardizedFileURL.path
            searched.append(path)
            return executableURL(atPath: path)
        }
        if command0.contains("/") {
            let expanded = (command0 as NSString).expandingTildeInPath
            searched.append(expanded)
            return executableURL(atPath: expanded)
        }
        searched.append("PATH")
        return searchPATH(for: command0, executableURL: executableURL)
    }

    static func executableMatchesCommandIdentity(
        command0: String,
        candidate: URL,
        workingDirectory: URL?,
        trustedBareCommand: URL?
    ) -> Bool {
        let canonicalCandidate = candidate.standardizedFileURL.resolvingSymlinksInPath()
        if !command0.contains("/") {
            guard candidate.lastPathComponent == command0 else { return false }
            if canonicalCandidate.lastPathComponent == command0 { return true }
            guard let trustedBareCommand else { return false }
            return canonicalCandidate.path
                == trustedBareCommand.standardizedFileURL.resolvingSymlinksInPath().path
        }

        let declared: URL
        if command0.hasPrefix("./") || command0.hasPrefix("../") {
            let base = workingDirectory
                ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            declared = base.appendingPathComponent(command0)
        } else {
            declared = URL(fileURLWithPath: (command0 as NSString).expandingTildeInPath)
        }
        return canonicalCandidate.path
            == declared.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func searchPATH(
        for name: String,
        executableURL: (String) -> URL?
    ) -> URL? {
        var directories: [String] = []
        if let envPath = ProcessInfo.processInfo.environment["PATH"] {
            directories.append(contentsOf: envPath.split(separator: ":").map(String.init))
        }
        directories.append(contentsOf: fallbackPathDirectories)
        for directory in directories where !directory.isEmpty {
            if let found = executableURL((directory as NSString).appendingPathComponent(name)) {
                return found
            }
        }
        return nil
    }
}

/// The readers' deadline: the timeout, moved later once the process has
/// exited in time so buffered output can still be read.
private final class ReadDeadline: @unchecked Sendable {
    private let lock = NSLock()
    private var deadline: DispatchTime

    init(_ deadline: DispatchTime) { self.deadline = deadline }

    var value: () -> DispatchTime {
        { [self] in
            lock.lock()
            defer { lock.unlock() }
            return deadline
        }
    }

    func extend(to later: DispatchTime) {
        lock.lock()
        if later > deadline { deadline = later }
        lock.unlock()
    }
}
