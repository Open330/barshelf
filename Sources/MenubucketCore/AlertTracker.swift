import Foundation

/// Decides when a workflow alert notifies, and remembers what it saw.
///
/// An alert fires on a rising edge: its condition was false at the last
/// reading and is true now. Not on the first reading (BarShelf just started,
/// or the alert is new: "you are at 85 %" on every launch would be noise),
/// not while it stays true, not again within its cooldown, and not on a
/// reading it could not take (nil leaves the state as it was, so a failed
/// refresh neither fires nor re-arms). A changed definition starts over.
/// A rising edge inside the cooldown is used up, not postponed: the alert
/// has to fall and rise again after the cooldown. "Fired" means BarShelf
/// tried to notify; a notification macOS refuses still counts.
///
/// The state is the host's, never the widget's: a widget cannot write it
/// through `store`, so it cannot make itself fire.
public enum AlertTracker {
    public struct State: Codable, Equatable, Sendable {
        public var revision: String
        public var active: Bool
        public var firedAtMs: Double?

        public init(revision: String, active: Bool, firedAtMs: Double? = nil) {
            self.revision = revision
            self.active = active
            self.firedAtMs = firedAtMs
        }
    }

    public struct Decision: Equatable, Sendable {
        public var fire: Bool
        /// nil: keep the stored state as it is.
        public var next: State?
    }

    public static func decide(
        previous: State?, sample: WorkflowEngine.AlertSample, nowMs: Double
    ) -> Decision {
        guard let active = sample.active else { return Decision(fire: false, next: nil) }
        guard let previous, previous.revision == sample.revision else {
            return Decision(fire: false, next: State(revision: sample.revision, active: active))
        }
        var next = previous
        next.active = active
        let rising = active && !previous.active
        let cooled = previous.firedAtMs.map { nowMs - $0 >= sample.cooldownMs } ?? true
        if rising && cooled {
            next.firedAtMs = nowMs
            return Decision(fire: true, next: next)
        }
        return Decision(fire: false, next: next == previous ? nil : next)
    }
}

/// Alert state on disk (App Support), keyed by widget instance and alert id.
/// Written only when a state changes, which is rare.
public final class AlertStateStore: @unchecked Sendable {
    private let fileURL: URL
    private let lock = NSLock()
    private var states: [String: AlertTracker.State]

    public init(fileURL: URL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: AlertTracker.State].self, from: data) {
            states = decoded
        } else {
            states = [:]
        }
    }

    public static func key(widgetID: String, alertID: String) -> String { "\(widgetID)\u{1F}\(alertID)" }

    /// The alerts of one refresh, decided against the stored state and saved
    /// in one step: concurrent refreshes of the same widget cannot both see
    /// the old state and both fire.
    public func record(widgetID: String, samples: [WorkflowEngine.AlertSample], nowMs: Double) -> [WorkflowEngine.AlertSample] {
        lock.lock()
        defer { lock.unlock() }
        var firing: [WorkflowEngine.AlertSample] = []
        var changed = false
        for sample in samples {
            let key = Self.key(widgetID: widgetID, alertID: sample.id)
            let decision = AlertTracker.decide(previous: states[key], sample: sample, nowMs: nowMs)
            if let next = decision.next {
                states[key] = next
                changed = true
            }
            if decision.fire { firing.append(sample) }
        }
        if changed { persistLocked() }
        return firing
    }

    /// Drops a widget's state for alerts its workflow no longer declares, so
    /// removed alerts do not pile up and a re-added id starts over.
    public func reconcile(widgetID: String, alertIDs: Set<String>) {
        lock.lock()
        defer { lock.unlock() }
        let prefix = "\(widgetID)\u{1F}"
        let before = states.count
        states = states.filter { key, _ in
            !key.hasPrefix(prefix) || alertIDs.contains(String(key.dropFirst(prefix.count)))
        }
        if states.count != before { persistLocked() }
    }

    /// Forgets a widget's alerts (removed widget): a reinstall starts fresh.
    public func forget(widgetID: String) {
        lock.lock()
        defer { lock.unlock() }
        let prefix = "\(widgetID)\u{1F}"
        let before = states.count
        states = states.filter { !$0.key.hasPrefix(prefix) }
        if states.count != before { persistLocked() }
    }

    /// Keeps only these widget instances' state (hot-reload cleanup, for
    /// widgets removed outside the app).
    public func retain(widgetIDs: Set<String>) {
        lock.lock()
        defer { lock.unlock() }
        let before = states.count
        states = states.filter { key, _ in
            guard let widget = key.split(separator: "\u{1F}", maxSplits: 1).first else { return false }
            return widgetIDs.contains(String(widget))
        }
        if states.count != before { persistLocked() }
    }

    public func state(widgetID: String, alertID: String) -> AlertTracker.State? {
        lock.lock()
        defer { lock.unlock() }
        return states[Self.key(widgetID: widgetID, alertID: alertID)]
    }

    private func persistLocked() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(states).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("barshelf: failed to persist alert state: \(error)")
        }
    }
}
