import Foundation

/// What BarShelf shares with its macOS widget extension (R14).
///
/// The extension is sandboxed: it cannot run commands or read BarShelf's own
/// data folder. The app therefore writes, into an App Group container both
/// can open, the list of widgets a user may place and each one's last
/// rendered view tree. The extension only reads.
///
/// Layout of the container:
///
///     index.json               which widgets can be chosen
///     snapshots/<id>.json      a widget's last view tree
///
/// Sensitive widgets (one-time codes, clipboard history) are never written
/// here — not even a redacted tree — so nothing secret reaches a folder
/// another process reads.
public enum SharedShelf {
    /// Team-prefixed, which macOS 15+ requires for a Developer ID app to
    /// use a group container without a provisioning profile or a prompt.
    public static let appGroupID = "728FW73BS8.com.barshelf.shared"
    /// The widget kind. Placed widgets are bound to it: never rename.
    public static let widgetKind = "com.barshelf.app.shelf-widget"

    public static let indexFileName = "index.json"
    public static let snapshotsDirectoryName = "snapshots"

    /// One widget a user can choose for a desktop widget.
    public struct Entry: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var name: String
        public var icon: String?
        /// The widget's accent name (`WidgetAppearance.accent`), if any.
        public var accent: String?
        public var page: String?

        public init(id: String, name: String, icon: String? = nil, accent: String? = nil, page: String? = nil) {
            self.id = id
            self.name = name
            self.icon = icon
            self.accent = accent
            self.page = page
        }
    }

    public struct Index: Codable, Equatable, Sendable {
        public var entries: [Entry]

        public init(entries: [Entry]) {
            self.entries = entries
        }
    }

    /// A widget's last render, as the extension draws it.
    public struct Snapshot: Codable, Equatable, Sendable {
        public var widgetID: String
        public var name: String
        public var icon: String?
        public var accent: String?
        public var viewTree: UINode?
        public var updatedAt: Date?
        /// Why the last refresh failed, when it did.
        public var error: String?

        public init(
            widgetID: String, name: String, icon: String? = nil, accent: String? = nil,
            viewTree: UINode? = nil, updatedAt: Date? = nil, error: String? = nil
        ) {
            self.widgetID = widgetID
            self.name = name
            self.icon = icon
            self.accent = accent
            self.viewTree = viewTree
            self.updatedAt = updatedAt
            self.error = error
        }
    }

    // MARK: - Files

    /// A file name for a widget id, or nil for one that could escape the
    /// folder. Widget ids are reverse-DNS with an optional `--label`, so
    /// letters, digits, dot, dash, and underscore cover every real one.
    public static func snapshotFileName(for widgetID: String) -> String? {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard !widgetID.isEmpty, widgetID.count <= 200,
              widgetID.rangeOfCharacter(from: allowed.inverted) == nil,
              widgetID != ".", widgetID != "..", !widgetID.hasPrefix(".")
        else { return nil }
        return widgetID + ".json"
    }

    public static func writeIndex(_ index: Index, to container: URL) throws {
        try write(index, to: container.appendingPathComponent(indexFileName))
    }

    public static func readIndex(from container: URL) -> Index? {
        read(Index.self, from: container.appendingPathComponent(indexFileName))
    }

    public static func writeSnapshot(_ snapshot: Snapshot, to container: URL) throws {
        guard let name = snapshotFileName(for: snapshot.widgetID) else { return }
        let directory = container.appendingPathComponent(snapshotsDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try write(snapshot, to: directory.appendingPathComponent(name))
    }

    public static func readSnapshot(widgetID: String, from container: URL) -> Snapshot? {
        guard let name = snapshotFileName(for: widgetID) else { return nil }
        return read(Snapshot.self, from: container
            .appendingPathComponent(snapshotsDirectoryName, isDirectory: true)
            .appendingPathComponent(name))
    }

    public static func removeSnapshot(widgetID: String, from container: URL) {
        guard let name = snapshotFileName(for: widgetID) else { return }
        try? FileManager.default.removeItem(at: container
            .appendingPathComponent(snapshotsDirectoryName, isDirectory: true)
            .appendingPathComponent(name))
    }

    /// Removes snapshots of widgets no longer offered — uninstalled, or
    /// turned sensitive — so nothing stale lingers in the shared folder.
    public static func pruneSnapshots(keeping ids: Set<String>, in container: URL) {
        let directory = container.appendingPathComponent(snapshotsDirectoryName, isDirectory: true)
        let keep = Set(ids.compactMap(snapshotFileName(for:)))
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for file in files where file.hasSuffix(".json") && !keep.contains(file) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(file))
        }
    }

    private static func write<Value: Encodable>(_ value: Value, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    private static func read<Value: Decodable>(_ type: Value.Type, from url: URL) -> Value? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }
}
