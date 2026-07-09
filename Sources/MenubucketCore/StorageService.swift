import Foundation

/// Per-widget key/value storage backing `host.storage.*`.
///
/// - One JSON file per widget (namespace isolation) under `directory`.
/// - Quota: 1 MB serialized per widget → `-32004 QuotaExceeded`.
/// - Optional TTL per entry; expired entries read as missing and are pruned
///   on the next write.
public final class StorageService: @unchecked Sendable {
    public static let quotaBytes = 1_048_576

    struct Entry: Codable, Equatable {
        var value: JSONValue
        /// Epoch ms after which the entry no longer exists.
        var expiresAt: Double?
    }

    private struct Namespace: Codable, Equatable {
        var entries: [String: Entry] = [:]
    }

    private let directory: URL
    private let quotaBytes: Int
    private let lock = NSLock()
    private var cache: [String: Namespace] = [:]

    public init(directory: URL, quotaBytes: Int = StorageService.quotaBytes) {
        self.directory = directory
        self.quotaBytes = quotaBytes
    }

    // MARK: - API

    public func get(widgetId: String, key: String, nowMs: Double = Date().timeIntervalSince1970 * 1000) -> JSONValue? {
        lock.lock()
        defer { lock.unlock() }
        var namespace = loadLocked(widgetId: widgetId)
        guard let entry = namespace.entries[key] else { return nil }
        if let expiresAt = entry.expiresAt, expiresAt <= nowMs {
            namespace.entries.removeValue(forKey: key)
            cache[widgetId] = namespace
            return nil
        }
        return entry.value
    }

    public func set(
        widgetId: String,
        key: String,
        value: JSONValue,
        ttlMs: Double? = nil,
        nowMs: Double = Date().timeIntervalSince1970 * 1000
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        var namespace = loadLocked(widgetId: widgetId)
        pruneExpiredLocked(&namespace, nowMs: nowMs)
        namespace.entries[key] = Entry(value: value, expiresAt: ttlMs.map { nowMs + $0 })
        let data = try serialize(namespace)
        guard data.count <= quotaBytes else {
            throw JsonRpcError.quotaExceeded(
                "storage quota exceeded for \(widgetId): \(data.count) > \(quotaBytes) bytes"
            )
        }
        try persistLocked(widgetId: widgetId, namespace: namespace, data: data)
    }

    public func delete(widgetId: String, key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        var namespace = loadLocked(widgetId: widgetId)
        namespace.entries.removeValue(forKey: key)
        try persistLocked(widgetId: widgetId, namespace: namespace, data: serialize(namespace))
    }

    /// All live (non-expired) entries for a widget as a plain object — the
    /// read surface the workflow engine injects as `storage.*`.
    public func snapshot(
        widgetId: String,
        nowMs: Double = Date().timeIntervalSince1970 * 1000
    ) -> [String: JSONValue] {
        lock.lock()
        defer { lock.unlock() }
        let namespace = loadLocked(widgetId: widgetId)
        var out: [String: JSONValue] = [:]
        for (key, entry) in namespace.entries {
            if let expiresAt = entry.expiresAt, expiresAt <= nowMs { continue }
            out[key] = entry.value
        }
        return out
    }

    public func list(
        widgetId: String,
        prefix: String? = nil,
        nowMs: Double = Date().timeIntervalSince1970 * 1000
    ) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        let namespace = loadLocked(widgetId: widgetId)
        return namespace.entries
            .filter { key, entry in
                if let expiresAt = entry.expiresAt, expiresAt <= nowMs { return false }
                if let prefix, !key.hasPrefix(prefix) { return false }
                return true
            }
            .keys
            .sorted()
    }

    // MARK: - Internals

    private func loadLocked(widgetId: String) -> Namespace {
        if let cached = cache[widgetId] { return cached }
        let url = fileURL(widgetId: widgetId)
        guard let data = try? Data(contentsOf: url),
              let namespace = try? JSONDecoder().decode(Namespace.self, from: data)
        else {
            let empty = Namespace()
            cache[widgetId] = empty
            return empty
        }
        cache[widgetId] = namespace
        return namespace
    }

    private func pruneExpiredLocked(_ namespace: inout Namespace, nowMs: Double) {
        namespace.entries = namespace.entries.filter { _, entry in
            guard let expiresAt = entry.expiresAt else { return true }
            return expiresAt > nowMs
        }
    }

    private func serialize(_ namespace: Namespace) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(namespace)
    }

    private func persistLocked(widgetId: String, namespace: Namespace, data: Data) throws {
        cache[widgetId] = namespace
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: fileURL(widgetId: widgetId), options: .atomic)
    }

    private func fileURL(widgetId: String) -> URL {
        directory.appendingPathComponent(Self.sanitized(widgetId) + ".json")
    }

    /// Filesystem-safe widget id (same policy as the render cache).
    static func sanitized(_ widgetId: String) -> String {
        String(widgetId.map { character -> Character in
            character.isLetter || character.isNumber || character == "." || character == "-"
                ? character : "_"
        })
    }
}
