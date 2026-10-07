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
    /// `images/<widget id>/<name>.png`: thumbnails BarShelf exported.
    public static let imagesDirectoryName = "images"

    /// Where a widget's exported thumbnails live.
    public static func imagesDirectory(for widgetID: String, in container: URL) -> URL? {
        guard let name = snapshotFileName(for: widgetID) else { return nil }
        return container.appendingPathComponent(imagesDirectoryName, isDirectory: true)
            .appendingPathComponent(String(name.dropLast(5)), isDirectory: true)
    }

    /// When a reading refreshed every `interval` seconds should count as
    /// old: two intervals on, or `fallback` with no interval — never under
    /// half an hour, since WidgetKit redraws at most every 15 minutes anyway.
    public static func staleAfter(updatedAt: Date?, interval: Double?, fallback: TimeInterval = 3600) -> Date? {
        guard let updatedAt else { return nil }
        let window = max(interval.map { $0 * 2 } ?? fallback, 1800)
        return updatedAt.addingTimeInterval(window)
    }

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
        /// The short reading the widget shows in the menu bar ("42%") — the
        /// headline of a small desktop widget.
        public var statusLabel: String?
        public var statusTint: String?
        /// The pieces of `viewTree` a user can choose to show (`parts(of:)`).
        public var parts: [Part]
        /// The whole widget boiled down, for the big-value template when it
        /// has no items of its own (Codex Reset).
        public var summary: Summary?
        /// When this reading should be called out as old: about two refresh
        /// intervals after `updatedAt`. Until then a widget shows no time.
        public var staleAfter: Date?
        /// The author's layout for Style ▸ Automatic (`Template` raw value).
        public var preferredStyle: String?

        public init(
            widgetID: String, name: String, icon: String? = nil, accent: String? = nil,
            viewTree: UINode? = nil, updatedAt: Date? = nil, error: String? = nil,
            statusLabel: String? = nil, statusTint: String? = nil, parts: [Part]? = nil,
            staleAfter: Date? = nil, preferredStyle: String? = nil
        ) {
            self.widgetID = widgetID
            self.name = name
            self.icon = icon
            self.accent = accent
            self.viewTree = viewTree
            self.updatedAt = updatedAt
            self.error = error
            self.statusLabel = statusLabel
            self.statusTint = statusTint
            self.parts = parts ?? viewTree.map(SharedShelf.parts(of:)) ?? []
            self.summary = viewTree.map { SharedShelf.summarize($0, fallbackTitle: name) }
            self.staleAfter = staleAfter
            self.preferredStyle = preferredStyle
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            widgetID = try c.decode(String.self, forKey: .widgetID)
            name = try c.decode(String.self, forKey: .name)
            icon = try c.decodeIfPresent(String.self, forKey: .icon)
            accent = try c.decodeIfPresent(String.self, forKey: .accent)
            viewTree = try c.decodeIfPresent(UINode.self, forKey: .viewTree)
            updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
            error = try c.decodeIfPresent(String.self, forKey: .error)
            statusLabel = try c.decodeIfPresent(String.self, forKey: .statusLabel)
            statusTint = try c.decodeIfPresent(String.self, forKey: .statusTint)
            parts = try c.decodeIfPresent([Part].self, forKey: .parts) ?? []
            summary = try c.decodeIfPresent(Summary.self, forKey: .summary)
            staleAfter = try c.decodeIfPresent(Date.self, forKey: .staleAfter)
            preferredStyle = try c.decodeIfPresent(String.self, forKey: .preferredStyle)
        }
    }

    /// One piece of a widget's view a user can put on a desktop widget on
    /// its own: a card, a list row, or a section — an account's usage, one
    /// sensor, one file — instead of the whole popup view cut to fit.
    public struct Part: Codable, Equatable, Sendable, Identifiable {
        /// Stable across refreshes: the node's `id` when the widget gives
        /// one, else where it sits and what it is called.
        public var key: String
        public var title: String
        /// The section it belongs to, when there is one ("Codex").
        public var group: String?
        public var node: UINode
        /// A section whose own items are parts too. Offered for choosing
        /// whole, but left out when parts are picked automatically, so
        /// nothing shows twice.
        public var containsParts: Bool?
        /// What a widget template draws for it.
        public var summary: Summary?

        public var id: String { key }
        public var isGroup: Bool { containsParts == true }

        public init(
            key: String, title: String, group: String? = nil, node: UINode,
            containsParts: Bool? = nil, summary: Summary? = nil
        ) {
            self.key = key
            self.title = title
            self.group = group
            self.node = node
            self.containsParts = containsParts
            self.summary = summary ?? SharedShelf.summarize(node, fallbackTitle: title)
        }
    }

    /// Most parts offered for one widget; a long list is cut, not paged.
    public static let maximumParts = 40

    /// The choosable pieces of a view tree, in reading order.
    ///
    /// Structure first: every `card`, every titled `section` (whole), and
    /// every row of a `list` or `grid` — looking inside a row that itself
    /// holds cards or sections. A widget without any of those (System,
    /// Sensors) is split into its rows instead: each stacked block that
    /// pairs a label with a value or a meter ("CPU 15%" and its bar).
    /// Pieces without any text are skipped, having nothing to be named by.
    /// A node id as it may appear in the shared folder: kept when it is a
    /// plain name, hashed when it could carry a file path ("tile-/Users/…").
    public static func shareableID(_ id: String) -> String {
        guard id.contains("/") || id.count > 64 else { return id }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in id.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
        }
        return "h" + String(hash, radix: 16)
    }

    /// A tree with everything that points outside the widget taken out —
    /// file paths, actions, drag payloads, image URLs, path-like ids — for
    /// the shared folder, which the widget extension only draws from.
    public static func scrubbed(_ node: UINode) -> UINode {
        var node = node
        node.id = node.id.map(shareableID)
        // What a desktop widget must not show is not shared at all.
        if node.desktopRole == "hide" {
            return UINode(type: "none", hidden: true)
        }
        node.action = nil
        node.drag = nil
        node.source?.path = nil
        node.source?.url = nil
        node.children = node.children?.map(scrubbed)
        node.items = node.items?.map(scrubbed)
        if let child = node.child?.node {
            node.child = UINodeBox(scrubbed(child))
        }
        return node
    }

    public static func parts(of tree: UINode) -> [Part] {
        var parts: [Part] = []
        var seen: [String: Int] = [:]

        func add(_ node: UINode, group: String?) {
            guard parts.count < maximumParts, let title = displayTitle(of: node) else { return }
            var key = node.id.map { "id:" + shareableID($0) } ?? "\(group ?? "")/\(title)"
            if let count = seen[key] {
                seen[key] = count + 1
                key += "#\(count + 1)"
            } else {
                seen[key] = 1
            }
            parts.append(Part(key: key, title: title, group: group, node: node))
        }

        func walk(_ node: UINode, group: String?) {
            guard node.hidden != true, node.desktopRole != "hide", parts.count < maximumParts else { return }
            switch node.type {
            case "card":
                add(node, group: group)
            case "section":
                let title = node.title?.trimmingCharacters(in: .whitespacesAndNewlines)
                let named = (title?.isEmpty == false) ? title : nil
                let index = parts.count
                if named != nil { add(node, group: group) }
                for child in node.children ?? [] { walk(child, group: named ?? group) }
                if named != nil, parts.count > index + 1, parts.indices.contains(index) {
                    parts[index].containsParts = true
                }
            case "list", "grid":
                for item in node.items ?? node.children ?? [] where item.hidden != true {
                    if containsStructure(item) { walk(item, group: group) } else { add(item, group: group) }
                }
            case "scroll":
                if let child = node.child?.node { walk(child, group: group) }
            default:
                for child in node.children ?? [] { walk(child, group: group) }
            }
        }

        // The author named the items: those, in tree order, and nothing else.
        let marked = markedItems(in: tree)
        if !marked.isEmpty {
            for item in marked.prefix(maximumParts) { add(item.node, group: item.group) }
            return parts
        }
        walk(tree, group: nil)
        if parts.isEmpty {
            for row in rows(of: tree) { add(row, group: nil) }
        }
        return parts
    }

    /// Nodes marked `"desktopRole": "item"`, with the titled section each
    /// sits in.
    static func markedItems(in tree: UINode) -> [(node: UINode, group: String?)] {
        var found: [(UINode, String?)] = []
        func walk(_ node: UINode, group: String?) {
            guard node.hidden != true, node.desktopRole != "hide" else { return }
            if node.desktopRole == "item" {
                found.append((node, group))
                return
            }
            let title = node.type == "section" ? node.title?.trimmingCharacters(in: .whitespacesAndNewlines) : nil
            let inner = (title?.isEmpty == false) ? title : group
            for child in children(of: node) { walk(child, group: inner) }
        }
        walk(tree, group: nil)
        return found
    }

    /// Whether a node holds a card, a section, or a list somewhere inside.
    static func containsStructure(_ node: UINode) -> Bool {
        let inner = (node.children ?? []) + (node.items ?? []) + [node.child?.node].compactMap { $0 }
        return inner.contains { ["card", "section", "list", "grid"].contains($0.type) || containsStructure($0) }
    }

    /// The label-and-value rows of a plain stacked widget: the first stack,
    /// looking through single-child wrappers, with at least two such rows.
    static func rows(of tree: UINode) -> [UINode] {
        var node = tree
        while true {
            let children = (node.children ?? []).filter { $0.hidden != true }
            let rowLike = children.filter(isRow)
            if rowLike.count >= 2 { return rowLike }
            if node.type == "scroll", let child = node.child?.node { node = child; continue }
            guard children.count == 1 else { return [] }
            node = children[0]
        }
    }

    /// A block that reads as one reading: two pieces of text ("CPU" "15%"),
    /// or a text and a meter.
    static func isRow(_ node: UINode) -> Bool {
        guard ["hstack", "vstack", "zstack"].contains(node.type) else { return false }
        var texts = 0
        var meters = 0
        func count(_ node: UINode) {
            if node.type == "text", node.text?.trimmingCharacters(in: .whitespaces).isEmpty == false { texts += 1 }
            if node.type == "progress" { meters += 1 }
            for child in (node.children ?? []) + (node.items ?? []) { count(child) }
        }
        count(node)
        return texts >= 2 || (texts >= 1 && meters >= 1)
    }

    /// The name a piece goes by: its title, else its first line of text.
    static func displayTitle(of node: UINode) -> String? {
        func clean(_ text: String?) -> String? {
            let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (trimmed?.isEmpty == false) ? trimmed : nil
        }
        if let title = clean(node.title) { return title }
        if node.type == "text", let text = clean(node.text) { return text }
        for child in (node.children ?? []) + (node.items ?? []) + [node.child?.node].compactMap({ $0 }) {
            if let title = displayTitle(of: child) { return title }
        }
        return nil
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
        if let images = imagesDirectory(for: widgetID, in: container) {
            try? FileManager.default.removeItem(at: images)
        }
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
        let images = container.appendingPathComponent(imagesDirectoryName, isDirectory: true)
        let keepImages = Set(keep.map { String($0.dropLast(5)) })
        for folder in (try? FileManager.default.contentsOfDirectory(atPath: images.path)) ?? [] where !keepImages.contains(folder) {
            try? FileManager.default.removeItem(at: images.appendingPathComponent(folder))
        }
    }

    // MARK: - Refresh requests

    /// Posted (as a Darwin notification, which a sandboxed extension may
    /// send) after the widget extension asks for a refresh. It carries no
    /// data: BarShelf reads the request files, which only apps of this team
    /// can write.
    public static let refreshRequestNotification = appGroupID + ".refresh-request"
    static let requestsDirectoryName = "requests"
    /// How long a request shows as pending before the widget gives up on it.
    public static let refreshRequestLifetime: TimeInterval = 60

    /// The widget extension asks BarShelf to refresh one widget now.
    public static func requestRefresh(widgetID: String, in container: URL, now: Date = Date()) throws {
        guard let name = snapshotFileName(for: widgetID) else { return }
        try write(now, to: container
            .appendingPathComponent(requestsDirectoryName, isDirectory: true)
            .appendingPathComponent(name))
    }

    /// Widgets with a refresh asked for and not yet answered, with when.
    /// Requests older than `refreshRequestLifetime` are dropped.
    public static func pendingRefreshRequests(in container: URL, now: Date = Date()) -> [String: Date] {
        let directory = container.appendingPathComponent(requestsDirectoryName, isDirectory: true)
        var pending: [String: Date] = [:]
        for file in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [] where file.hasSuffix(".json") {
            let id = String(file.dropLast(5))
            let url = directory.appendingPathComponent(file)
            guard snapshotFileName(for: id) == file,
                  let asked = read(Date.self, from: url),
                  now.timeIntervalSince(asked) < refreshRequestLifetime
            else {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            pending[id] = asked
        }
        return pending
    }

    /// BarShelf has answered (or given up on) a widget's refresh request.
    public static func clearRefreshRequest(widgetID: String, in container: URL) {
        guard let name = snapshotFileName(for: widgetID) else { return }
        try? FileManager.default.removeItem(at: container
            .appendingPathComponent(requestsDirectoryName, isDirectory: true)
            .appendingPathComponent(name))
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
