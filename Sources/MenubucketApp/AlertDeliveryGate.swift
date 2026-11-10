import Foundation

/// Keeps a workflow alert from outliving the widget instance that raised
/// it. Delivery waits on macOS (the notification prompt); meanwhile the
/// instance may be disabled, removed, reloaded with other code, or have its
/// permission revoked and given back. Each of those bumps the instance's
/// generation and cancels what it had pending, so an old alert cannot go
/// out under a newer decision.
final class AlertDeliveryGate: @unchecked Sendable {
    private let lock = NSLock()
    private var generations: [String: Int] = [:]
    private var pending: [String: [UUID: Task<Void, Never>]] = [:]

    /// The instance's current generation, to check against later.
    func permit(_ widgetID: String) -> Int {
        lock.withLock { generations[widgetID, default: 0] }
    }

    func isCurrent(_ widgetID: String, _ generation: Int) -> Bool {
        lock.withLock { generations[widgetID, default: 0] == generation }
    }

    /// Ends everything the instance had in flight.
    func invalidate(_ widgetID: String) {
        let tasks: [Task<Void, Never>] = lock.withLock {
            generations[widgetID, default: 0] &+= 1
            return Array(pending.removeValue(forKey: widgetID)?.values ?? [:].values)
        }
        for task in tasks { task.cancel() }
    }

    func track(_ widgetID: String, _ key: UUID, _ task: Task<Void, Never>) {
        lock.withLock { pending[widgetID, default: [:]][key] = task }
    }

    func finish(_ widgetID: String, _ key: UUID) {
        lock.withLock { _ = pending[widgetID]?.removeValue(forKey: key) }
    }

    var pendingCount: Int { lock.withLock { pending.values.reduce(0) { $0 + $1.count } } }
}
