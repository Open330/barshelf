import Foundation

/// Decoded workflow definitions, reused across refreshes while the file is
/// unchanged.
///
/// Every workflow refresh used to read `workflow.json` from disk and decode it
/// into a `JSONValue` tree before doing anything else — for a widget promoted
/// to the menu bar, that is a full decode every two seconds of a file that
/// changes when someone edits it. Profiled, JSON decoding was ~12% of such a
/// widget's CPU. The cache keys on the file and validates each hit against
/// its modification date and size, so an edited workflow (and hot reload)
/// takes effect on the very next refresh without any invalidation hook.
///
/// Thread-safe: refreshes of different widgets run concurrently off the main
/// actor.
public final class WorkflowDefinitionCache: @unchecked Sendable {
    public struct Entry: Sendable {
        public let definition: WorkflowDefinition
        /// Computed once per decode — it walks every template in the workflow.
        public let readsWidgetVisibility: Bool
    }

    private struct Stamp: Equatable {
        let modified: Date?
        let size: Int?
    }

    private let lock = NSLock()
    private var entries: [URL: (stamp: Stamp, entry: Entry)] = [:]
    private var decodes = 0

    public init() {}

    public func load(_ url: URL) throws -> Entry {
        var key = url.standardizedFileURL
        // A URL caches the resource values it has fetched; a stale cached date
        // would make an edited file look unchanged.
        key.removeAllCachedResourceValues()
        let values = try key.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let stamp = Stamp(modified: values.contentModificationDate, size: values.fileSize)

        lock.lock()
        if let hit = entries[key], hit.stamp == stamp {
            lock.unlock()
            return hit.entry
        }
        lock.unlock()

        let definition = try WorkflowDefinition.decode(from: Data(contentsOf: key))
        lock.lock()
        decodes += 1
        lock.unlock()
        let entry = Entry(
            definition: definition,
            readsWidgetVisibility: definition.readsWidgetVisibility
        )
        lock.lock()
        entries[key] = (stamp, entry)
        lock.unlock()
        return entry
    }

    /// Number of cached definitions, and of decodes performed (tests).
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    var decodeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return decodes
    }
}
