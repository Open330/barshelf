import CryptoKit
import Foundation

/// Persistent per-widget permission approvals (App Support JSON).
///
/// A record stores a SHA-256 hash of the widget's declared permissions; when
/// the manifest's permissions change, the stored hash no longer matches and
/// the widget returns to `.pending` (re-approval required). No widget may
/// execute anything until its current permission set is `.approved`.
public final class PermissionStore: @unchecked Sendable {
    public enum Status: Equatable, Sendable {
        case pending
        case approved
        case denied
    }

    public struct Record: Codable, Equatable, Sendable {
        public var hash: String
        /// "approved" | "denied"
        public var decision: String
        public var decidedAt: Date
    }

    private let fileURL: URL
    private let lock = NSLock()
    private var records: [String: Record]

    public init(fileURL: URL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? Self.makeDecoder().decode([String: Record].self, from: data) {
            records = decoded
        } else {
            records = [:]
        }
    }

    // MARK: - Hashing

    /// Canonical hash of the manifest's declared permissions (sorted-keys
    /// JSON → SHA-256 hex). `nil` permissions hash deterministically too.
    public static func permissionsHash(of manifest: Manifest) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(manifest.permissions)) ?? Data("null".utf8)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - API

    public func status(for manifest: Manifest) -> Status {
        lock.lock()
        defer { lock.unlock() }
        guard let record = records[manifest.id] else { return .pending }
        guard record.hash == Self.permissionsHash(of: manifest) else {
            return .pending // permissions changed → re-approval required
        }
        return record.decision == "approved" ? .approved : .denied
    }

    public func approve(_ manifest: Manifest, at date: Date = Date()) {
        setDecision("approved", manifest: manifest, date: date)
    }

    public func deny(_ manifest: Manifest, at date: Date = Date()) {
        setDecision("denied", manifest: manifest, date: date)
    }

    public func record(forWidget widgetId: String) -> Record? {
        lock.lock()
        defer { lock.unlock() }
        return records[widgetId]
    }

    public func reset(widgetId: String) {
        lock.lock()
        defer { lock.unlock() }
        records.removeValue(forKey: widgetId)
        persistLocked()
    }

    // MARK: - Internals

    private func setDecision(_ decision: String, manifest: Manifest, date: Date) {
        lock.lock()
        defer { lock.unlock() }
        records[manifest.id] = Record(
            hash: Self.permissionsHash(of: manifest),
            decision: decision,
            decidedAt: date
        )
        persistLocked()
    }

    private func persistLocked() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(records).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("menubucket: failed to persist permission store: \(error)")
        }
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
