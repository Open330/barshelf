import Foundation

/// Security audit trail (JSON lines, append-only).
///
/// Default location: `~/Library/Logs/BarShelf/audit.log`. Records exec
/// runs/blocks, secret access, and permission approve/deny events. Secret
/// *values* are never logged — callers pass keys/commands only.
///
/// Two limits keep it from growing forever (it reached 33 MB on a Mac that
/// ran BarShelf all day, nearly all of it `exec.run` from automatic
/// refreshes):
/// - Routine runs (`exec.run`, `network.fetch` not started by a click) are
///   written once per `routineWindow` for the same widget, command or URL,
///   trigger and exit code. The next one written carries `repeats`: how
///   many identical runs it stands for since the last entry. Anything else
///   (a different command, a failure, a permission decision, a click) is
///   written at once.
/// - At `rotateAtBytes` the file moves to `audit.log.1` (and `.1` to `.2`),
///   so at most three files are kept.
public final class AuditLog: @unchecked Sendable {
    public static func defaultFileURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/BarShelf/audit.log")
    }

    public static let rotateAtBytes = 5 * 1_048_576
    public static let keepRotations = 2
    public static let routineWindow: TimeInterval = 600
    static let routineEvents: Set<String> = ["exec.run", "network.fetch"]

    private let fileURL: URL
    private let rotateAtBytes: Int
    private let routineWindow: TimeInterval
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    /// Per routine key: when it was last written, and how many identical
    /// runs were skipped since.
    private var routine: [String: (writtenAt: Date, skipped: Int)] = [:]

    public init(
        fileURL: URL = AuditLog.defaultFileURL(),
        rotateAtBytes: Int = AuditLog.rotateAtBytes,
        routineWindow: TimeInterval = AuditLog.routineWindow,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.fileURL = fileURL
        self.rotateAtBytes = rotateAtBytes
        self.routineWindow = routineWindow
        self.now = now
    }

    /// Appends one JSON line: `{"ts": ..., "event": ..., "widgetId": ..., ...detail}`.
    public func record(_ event: String, widgetId: String, detail: [String: JSONValue] = [:]) {
        let date = now()
        var object: [String: JSONValue] = detail

        lock.lock()
        defer { lock.unlock() }
        if let key = Self.routineKey(event: event, widgetId: widgetId, detail: detail) {
            if let last = routine[key], date.timeIntervalSince(last.writtenAt) < routineWindow {
                routine[key] = (last.writtenAt, last.skipped + 1)
                return
            }
            if let skipped = routine[key]?.skipped, skipped > 0 {
                object["repeats"] = .number(Double(skipped))
            }
            routine[key] = (date, 0)
            if routine.count > 2_000 { pruneRoutineLocked(before: date) }
        }

        let timestampFormatter = ISO8601DateFormatter()
        timestampFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        object["ts"] = .string(timestampFormatter.string(from: date))
        object["event"] = .string(event)
        object["widgetId"] = .string(widgetId)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard var data = try? encoder.encode(JSONValue.object(object)) else { return }
        data.append(0x0A)

        do {
            let fm = FileManager.default
            try fm.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            rotateIfNeededLocked()
            if !fm.fileExists(atPath: fileURL.path) {
                fm.createFile(atPath: fileURL.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            NSLog("barshelf: audit log write failed: \(error)")
        }
    }

    /// The key that makes two routine runs "the same", or nil for an event
    /// that is always written. A run someone clicked is never routine.
    static func routineKey(event: String, widgetId: String, detail: [String: JSONValue]) -> String? {
        guard routineEvents.contains(event) else { return nil }
        if case .string("run-action")? = detail["trigger"] { return nil }
        func text(_ key: String) -> String {
            switch detail[key] {
            case .string(let value)?: return value
            case .number(let value)?: return String(value)
            case nil: return ""
            default: return "?"
            }
        }
        return [event, widgetId, text("command"), text("url"), text("trigger"), text("exitCode")]
            .joined(separator: "\u{1F}")
    }

    private func pruneRoutineLocked(before date: Date) {
        routine = routine.filter { date.timeIntervalSince($0.value.writtenAt) < routineWindow }
    }

    private func rotateIfNeededLocked() {
        let fm = FileManager.default
        guard let size = (try? fm.attributesOfItem(atPath: fileURL.path)[.size]) as? Int,
              size >= rotateAtBytes
        else { return }
        let path = fileURL.path
        try? fm.removeItem(atPath: path + ".\(Self.keepRotations)")
        for index in stride(from: Self.keepRotations - 1, through: 1, by: -1) {
            let from = path + ".\(index)"
            if fm.fileExists(atPath: from) {
                try? fm.moveItem(atPath: from, toPath: path + ".\(index + 1)")
            }
        }
        try? fm.moveItem(atPath: path, toPath: path + ".1")
    }
}

/// Per-widget log files backing `host.log` and script stderr.
///
/// `<directory>/<widget-id>.log`, rotated at 1 MB keeping the 5 most recent
/// files (`.log.1` … `.log.5`).
public final class WidgetLogStore: @unchecked Sendable {
    public static let rotateAtBytes = 1_048_576
    public static let keepRotations = 5

    public static func defaultDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/BarShelf/widgets", isDirectory: true)
    }

    private let directory: URL
    private let rotateAtBytes: Int
    private let lock = NSLock()

    public init(directory: URL = WidgetLogStore.defaultDirectory(), rotateAtBytes: Int = WidgetLogStore.rotateAtBytes) {
        self.directory = directory
        self.rotateAtBytes = rotateAtBytes
    }

    public func fileURL(widgetId: String) -> URL {
        directory.appendingPathComponent(StorageService.sanitized(widgetId) + ".log")
    }

    public func append(widgetId: String, level: String, message: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        // One log record per line; newlines inside the message stay readable
        // but never split into fake records ("\n" → "\n\t").
        let sanitizedMessage = message.replacingOccurrences(of: "\n", with: "\n\t")
        let line = "[\(ts)] [\(level)] \(sanitizedMessage)\n"

        lock.lock()
        defer { lock.unlock() }
        let url = fileURL(widgetId: widgetId)
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            rotateIfNeededLocked(url: url)
            if !fm.fileExists(atPath: url.path) {
                fm.createFile(atPath: url.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
        } catch {
            NSLog("barshelf: widget log write failed for \(widgetId): \(error)")
        }
    }

    private func rotateIfNeededLocked(url: URL) {
        let fm = FileManager.default
        guard let size = (try? fm.attributesOfItem(atPath: url.path)[.size]) as? Int,
              size >= rotateAtBytes
        else { return }
        // Shift <name>.log.(n) → .(n+1); drop the oldest.
        try? fm.removeItem(atPath: url.path + ".\(Self.keepRotations)")
        for index in stride(from: Self.keepRotations - 1, through: 1, by: -1) {
            let from = url.path + ".\(index)"
            if fm.fileExists(atPath: from) {
                try? fm.moveItem(atPath: from, toPath: url.path + ".\(index + 1)")
            }
        }
        try? fm.moveItem(atPath: url.path, toPath: url.path + ".1")
    }
}
