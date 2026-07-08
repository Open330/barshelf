import Foundation

/// Security audit trail (JSON lines, append-only).
///
/// Default location: `~/Library/Logs/MenuBucket/audit.log`. Records exec
/// runs/blocks, secret access, and permission approve/deny events. Secret
/// *values* are never logged — callers pass keys/commands only.
public final class AuditLog: @unchecked Sendable {
    public static func defaultFileURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/MenuBucket/audit.log")
    }

    private let fileURL: URL
    private let lock = NSLock()

    public init(fileURL: URL = AuditLog.defaultFileURL()) {
        self.fileURL = fileURL
    }

    /// Appends one JSON line: `{"ts": ..., "event": ..., "widgetId": ..., ...detail}`.
    public func record(_ event: String, widgetId: String, detail: [String: JSONValue] = [:]) {
        var object: [String: JSONValue] = detail
        object["ts"] = .string(Self.timestampFormatter.string(from: Date()))
        object["event"] = .string(event)
        object["widgetId"] = .string(widgetId)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard var data = try? encoder.encode(JSONValue.object(object)) else { return }
        data.append(0x0A)

        lock.lock()
        defer { lock.unlock() }
        do {
            let fm = FileManager.default
            try fm.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            if !fm.fileExists(atPath: fileURL.path) {
                fm.createFile(atPath: fileURL.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            NSLog("menubucket: audit log write failed: \(error)")
        }
    }

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
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
            .appendingPathComponent("Library/Logs/MenuBucket/widgets", isDirectory: true)
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
            NSLog("menubucket: widget log write failed for \(widgetId): \(error)")
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
