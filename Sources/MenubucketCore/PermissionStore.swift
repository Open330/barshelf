import CryptoKit
import Foundation

/// Persistent per-widget permission approvals (App Support JSON).
///
/// A record stores a SHA-256 hash of the widget's declared permissions; when
/// the manifest's permissions change, the stored hash no longer matches and
/// the widget returns to `.pending` (re-approval required) — unless the new
/// set only drops grants from an approved one (`PermissionNarrowing`), which
/// the approval then covers. No widget may execute anything until
/// its current permission set is `.approved`.
public final class PermissionStore: @unchecked Sendable {
    public enum Status: Equatable, Sendable {
        case pending
        case approved
        case denied
    }

    /// Categories of gated capability a manifest may declare. Approval is still
    /// per-widget (the whole declared set is hashed and approved at once); a
    /// kind only matters when a runtime feature must confirm the manifest opted
    /// in before using it — e.g. an `http` workflow source requires `.network`.
    public enum PermissionKind: String, Sendable, CaseIterable {
        case exec
        case network
        case readPaths
        case keychain
        case notifications
        case quitApps
    }

    /// True when the manifest declares the given permission kind. Used to gate
    /// runtime features (`.network` → `http` sources) before the shared
    /// approval flow runs; deny-until-approved is still enforced by `status`.
    public static func manifestDeclares(_ kind: PermissionKind, in manifest: Manifest) -> Bool {
        let permissions = manifest.permissions
        switch kind {
        case .exec:
            return !(permissions?.exec ?? []).isEmpty
        case .network:
            return !(permissions?.network ?? []).isEmpty
        case .readPaths:
            return !(permissions?.readPaths ?? []).isEmpty
        case .keychain:
            return permissions?.keychain == true
        case .notifications:
            return permissions?.notifications == true
        case .quitApps:
            return permissions?.quitApps == true
        }
    }

    public struct Record: Codable, Equatable, Sendable {
        public var hash: String
        /// "approved" | "denied"
        public var decision: String
        public var decidedAt: Date
        /// The permissions the decision was made on, so an update that only
        /// drops some of them keeps the approval (`PermissionNarrowing`).
        /// Absent in records written before it was kept; filled in the next
        /// time the hash shows the manifest still asks for exactly those.
        public var permissions: Manifest.Permissions?

        public init(hash: String, decision: String, decidedAt: Date, permissions: Manifest.Permissions? = nil) {
            self.hash = hash
            self.decision = decision
            self.decidedAt = decidedAt
            self.permissions = permissions
        }
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

    /// The hash of `manifest`'s permissions, remembered per widget while
    /// they stay the same: the menu bar asks for every widget's status on
    /// each update, and encoding and hashing them each time was a visible
    /// share of the app's idle work. Keyed by the permissions themselves, so
    /// a reloaded manifest that changed them is hashed afresh.
    private var hashes: [String: (permissions: Manifest.Permissions?, hash: String)] = [:]

    /// Whether a changed set is covered by its widget's approval, worked out
    /// once per pair of sets: status is asked for on every menu bar update.
    private struct CoverageKey: Hashable {
        let widgetId: String
        let approvedHash: String
        let hash: String
    }
    private var coverage: [CoverageKey: Bool] = [:]

    private func hashLocked(of manifest: Manifest) -> String {
        if let cached = hashes[manifest.id], cached.permissions == manifest.permissions { return cached.hash }
        let hash = Self.permissionsHash(of: manifest)
        hashes[manifest.id] = (manifest.permissions, hash)
        return hash
    }

    // MARK: - API

    /// Permission-free widgets do not need a meaningless approval click. Any
    /// capability that can execute code, access user data, persist data, or
    /// contact another process/service makes the widget approval-gated.
    public static func requiresApproval(for manifest: Manifest) -> Bool {
        let permissions = manifest.permissions
        return !(permissions?.exec ?? []).isEmpty
            || !(permissions?.network ?? []).isEmpty
            || !(permissions?.readPaths ?? []).isEmpty
            || !(permissions?.env ?? []).isEmpty
            || permissions?.keychain == true
            || permissions?.notifications == true
            || permissions?.storage?.granted == true
    }

    /// Told the first time an approval is found to cover a changed, narrower
    /// permission set without asking (widget id, new hash), so the host can
    /// say so in its audit log. Called outside the store's lock. Set once,
    /// before the store is used.
    public var onApprovalCarried: (@Sendable (_ widgetId: String, _ hash: String) -> Void)?

    public func status(for manifest: Manifest) -> Status {
        guard Self.requiresApproval(for: manifest) else { return .approved }
        var carried: String?
        let status = statusLocked(for: manifest, carried: &carried)
        if let carried { onApprovalCarried?(manifest.id, carried) }
        return status
    }

    private func statusLocked(for manifest: Manifest, carried: inout String?) -> Status {
        lock.lock()
        defer { lock.unlock() }
        guard var record = records[manifest.id] else { return .pending }
        let hash = hashLocked(of: manifest)
        guard record.hash == hash else {
            // Permissions changed. An approval covers the new set only when
            // it asks for nothing beyond what was approved; anything added
            // or widened asks again, and a denial always does.
            //
            // The record is left as it is: copies of a widget (`<id>` and
            // `<id>--<label>`) share it and may declare different sets, so
            // moving it to this one would take it from the others.
            guard record.decision == "approved", let approved = record.permissions else { return .pending }
            let key = CoverageKey(widgetId: manifest.id, approvedHash: record.hash, hash: hash)
            if let known = coverage[key] { return known ? .approved : .pending }
            let covered = PermissionNarrowing.isCovered(manifest.permissions, by: approved)
            coverage[key] = covered
            if covered { carried = hash }
            return covered ? .approved : .pending
        }
        if record.permissions == nil, manifest.permissions != nil {
            // The hash vouches that these are the permissions decided on.
            record.permissions = manifest.permissions
            records[manifest.id] = record
            persistLocked()
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
            decidedAt: date,
            permissions: manifest.permissions
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
            NSLog("barshelf: failed to persist permission store: \(error)")
        }
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
