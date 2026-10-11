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
    public static let maxStdoutBytes = 1_048_576
    public static let maxStderrBytes = 65_536
    public static let fallbackPathDirectories = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        ("~/.cargo/bin" as NSString).expandingTildeInPath,
    ]

    /// Minimal process environment plus explicitly authorized/injected values.
    public static func childEnvironment(
        extraEnvironment: [String: String]? = nil
    ) -> [String: String] {
        let hostEnvironment = ProcessInfo.processInfo.environment
        var environment: [String: String] = [:]
        for key in ["HOME", "TMPDIR", "USER", "LOGNAME", "LANG", "LC_ALL", "LC_CTYPE"] {
            if let value = hostEnvironment[key], !value.isEmpty { environment[key] = value }
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

    /// async/await wrapper around `run`.
    public func run(
        command: [String],
        discover: [String]?,
        timeoutMs: Int,
        workingDirectory: URL?,
        extraEnvironment: [String: String]? = nil,
        stdoutLimit: Int = ExecService.maxStdoutBytes
    ) async -> Result<Data, ExecError> {
        await withCheckedContinuation { continuation in
            run(
                command: command,
                discover: discover,
                timeoutMs: timeoutMs,
                workingDirectory: workingDirectory,
                extraEnvironment: extraEnvironment,
                stdoutLimit: stdoutLimit
            ) { result in
                continuation.resume(returning: result)
            }
        }
    }

    public static func runSync(
        command: [String],
        discover: [String]?,
        timeoutMs: Int,
        workingDirectory: URL?,
        extraEnvironment: [String: String]? = nil,
        stdoutLimit: Int = ExecService.maxStdoutBytes
    ) -> Result<Data, ExecError> {
        switch captureSync(
            command: command,
            discover: discover,
            timeoutMs: timeoutMs,
            workingDirectory: workingDirectory,
            extraEnvironment: extraEnvironment,
            stdoutLimit: stdoutLimit
        ) {
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

    /// async/await wrapper around `captureSync` (runs off the caller's executor).
    public static func capture(
        command: [String],
        discover: [String]?,
        timeoutMs: Int,
        workingDirectory: URL?,
        extraEnvironment: [String: String]? = nil,
        stdoutLimit: Int = ExecService.maxStdoutBytes
    ) async -> Result<Capture, ExecError> {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: captureSync(
                    command: command,
                    discover: discover,
                    timeoutMs: timeoutMs,
                    workingDirectory: workingDirectory,
                    extraEnvironment: extraEnvironment,
                    stdoutLimit: stdoutLimit
                ))
            }
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
            try process.run()
        } catch {
            Self.closePipe(stdoutPipe)
            Self.closePipe(stderrPipe)
            return .failure(.launchFailed(error.localizedDescription))
        }

        let deadline = DispatchTime.now() + .milliseconds(max(timeoutMs, 1))
        readGroup.enter()
        readQueue.async {
            defer { readGroup.leave() }
            let handle = stdoutPipe.fileHandleForReading
            Self.drain(handle, until: deadline, timedOut: { captureState.markTimedOut() }) { chunk in
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
            Self.drain(handle, until: deadline, timedOut: { captureState.markTimedOut() }) { chunk in
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
        readGroup.wait()
        timeoutItem.cancel()

        let capture = captureState.snapshot()

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
    private static func drain(_ handle: FileHandle, until deadline: DispatchTime,
                              timedOut: () -> Void, onChunk: (Data) -> Bool) {
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline.uptimeNanoseconds else { timedOut(); return }
            let remaining = (deadline.uptimeNanoseconds - now) / 1_000_000 + 1
            var descriptor = pollfd(fd: handle.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, Int32(min(remaining, UInt64(Int32.max))))
            if ready == 0 { timedOut(); return }
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
