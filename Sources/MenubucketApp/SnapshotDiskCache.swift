import Foundation
import MenubucketCore

/// The on-disk render cache: one `<id>.json` per widget, so a relaunched
/// popup shows the last render at once.
///
/// Snapshot cache writes are throttled per widget and performed off the
/// main thread (R05 perf).
///
/// The cache exists so a relaunched popup shows the last render at once;
/// a render half a minute old serves that just as well as one two seconds
/// old. It used to be a 0.5 s *debounce* — cancel and reschedule on every
/// snapshot — which for a widget refreshing every two seconds meant a
/// JSON encode, an atomic write and a rename on every single refresh:
/// ~11% of a promoted widget's CPU, profiled. A debounce is the wrong
/// shape for a periodic stream (it either fires every tick or, if the
/// period is shorter than the delay, never). This is a throttle: the first
/// unwritten change opens a window, and when it closes the *latest*
/// snapshot is written once. Quitting flushes whatever is still held.
///
/// Main-actor isolated: the throttle state is only ever touched from the
/// runtime's main-actor code and from work items scheduled on the main
/// queue. Only the encode-and-write itself hops to `writeQueue`.
@MainActor
final class SnapshotDiskCache {
    /// Resolved once: `FileManager.urls(for:in:)` is not free, and it was being
    /// asked on every snapshot write.
    nonisolated static let defaultDirectory: URL? = {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else { return nil }
        return appSupport
            .appendingPathComponent("barshelf", isDirectory: true)
            .appendingPathComponent("cache", isDirectory: true)
    }()
    nonisolated static let defaultThrottleInterval: TimeInterval = 30

    private static let writeQueue = DispatchQueue(
        label: "dev.barshelf.snapshot-cache", qos: .utility
    )

    private let directory: URL?
    private let throttleInterval: TimeInterval
    /// A scheduled write per widget (on the main queue), and the snapshot it
    /// will write — replaced by every newer snapshot until it fires.
    private var pendingPersists: [String: DispatchWorkItem] = [:]
    private var unpersistedSnapshots: [String: WidgetSnapshot] = [:]

    /// Called on the main actor with each snapshot the throttle lets go of —
    /// when its window closes, and for everything still held at `flush()`.
    /// Whatever rides the cache's throttle (the desktop-widget mirror) hooks
    /// in here; `writeNow` does not call it.
    var onThrottledWrite: ((WidgetSnapshot) -> Void)?

    init(
        directory: URL? = SnapshotDiskCache.defaultDirectory,
        throttleInterval: TimeInterval = SnapshotDiskCache.defaultThrottleInterval
    ) {
        self.directory = directory
        self.throttleInterval = throttleInterval
    }

    nonisolated func fileURL(for widgetID: String) -> URL? {
        let sanitized = widgetID.map { character -> Character in
            character.isLetter || character.isNumber || character == "." || character == "-"
                ? character : "_"
        }
        return directory?.appendingPathComponent(String(sanitized) + ".json")
    }

    func load(widgetID: String) -> WidgetSnapshot? {
        guard let url = fileURL(for: widgetID),
              let data = try? Data(contentsOf: url)
        else { return nil }
        return try? WidgetSnapshot.deserialize(data)
    }

    /// Holds `snapshot` as the widget's latest and, if no window is open for
    /// it, opens one; the write happens when the window closes.
    func writeThrottled(_ snapshot: WidgetSnapshot) {
        let id = snapshot.widgetID
        unpersistedSnapshots[id] = snapshot
        guard pendingPersists[id] == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingPersists[id] = nil
            guard let latest = self.unpersistedSnapshots.removeValue(forKey: id)
            else { return }
            self.enqueueWrite(latest)
            self.onThrottledWrite?(latest)
        }
        pendingPersists[id] = item
        DispatchQueue.main.asyncAfter(
            deadline: .now() + throttleInterval, execute: item
        )
    }

    /// Writes `snapshot` without waiting for the throttle, dropping whatever
    /// the throttle was holding for the widget.
    func writeNow(_ snapshot: WidgetSnapshot) {
        cancelPending(snapshot.widgetID)
        enqueueWrite(snapshot)
    }

    /// Drops a scheduled write *and* the snapshot it held. The sensitive
    /// path depends on the second half: a live tree that must stay in memory
    /// can never be written by a throttle that fires after it arrived.
    func cancelPending(_ id: String) {
        pendingPersists.removeValue(forKey: id)?.cancel()
        unpersistedSnapshots.removeValue(forKey: id)
    }

    /// `cancelPending` for every widget with a scheduled write that is not in
    /// `liveIDs`.
    func cancelPending(notIn liveIDs: Set<String>) {
        for id in Array(pendingPersists.keys) where !liveIDs.contains(id) {
            cancelPending(id)
        }
    }

    /// On the write queue, behind every write already enqueued: a write that
    /// was on its way when the widget went (an immediate one, or a window
    /// that had just closed) would otherwise land after the removal and put
    /// the file back.
    func removeFile(widgetID: String) {
        guard let url = fileURL(for: widgetID) else { return }
        Self.writeQueue.sync { try? FileManager.default.removeItem(at: url) }
    }

    /// A removed widget: no queued write may re-create the cache.
    func forget(widgetID: String) {
        cancelPending(widgetID)
        removeFile(widgetID: widgetID)
    }

    /// Writes every snapshot the throttle is still holding. Called on quit, so
    /// a normal exit loses nothing to the longer window.
    func flush() {
        for item in pendingPersists.values { item.cancel() }
        pendingPersists.removeAll()
        let held = Array(unpersistedSnapshots.values)
        unpersistedSnapshots.removeAll()
        // Nothing held still leaves writes that were enqueued a moment ago;
        // quitting waits for those too.
        guard !held.isEmpty else {
            waitForWrites()
            return
        }
        for snapshot in held { onThrottledWrite?(snapshot) }
        let directory = directory
        let targets = held.map { ($0, fileURL(for: $0.widgetID)) }
        Self.writeQueue.sync {
            for (snapshot, url) in targets {
                Self.write(snapshot, to: url, in: directory)
            }
        }
    }

    /// Blocks until every write enqueued so far has reached the disk. Writes
    /// still inside a throttle window are not waited for — `flush()` those.
    func waitForWrites() {
        Self.writeQueue.sync {}
    }

    private func enqueueWrite(_ snapshot: WidgetSnapshot) {
        let directory = directory
        let url = fileURL(for: snapshot.widgetID)
        Self.writeQueue.async { Self.write(snapshot, to: url, in: directory) }
    }

    nonisolated private static func write(
        _ snapshot: WidgetSnapshot, to url: URL?, in directory: URL?
    ) {
        guard let directory, let url else { return }
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
            try snapshot.serialized().write(to: url, options: .atomic)
        } catch {
            NSLog("barshelf: failed to cache snapshot for \(snapshot.widgetID): \(error)")
        }
    }
}
