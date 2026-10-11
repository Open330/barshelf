import Foundation

/// Coalesces simultaneous widget requests without changing their refresh
/// cadence. Each key has its own short window and its own lock: concurrent
/// requests for one key collect once, while a slow key (a hung network
/// volume) never holds up another.
final class MetricSampleCache<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private let window: TimeInterval
    private var samples: [String: (value: Value, at: TimeInterval)] = [:]
    private var keyLocks: [String: NSLock] = [:]
    /// Mounts can be widget-controlled; keep retained state bounded.
    static var keyLimit: Int { 16 }

    init(window: TimeInterval = 0.25) { self.window = window }

    func sample(key: String = "", now: TimeInterval? = nil, collect: () -> Value) -> Value {
        let keyLock = lockFor(key)
        keyLock.lock()
        defer { keyLock.unlock() }
        let time = now ?? SleepAwareClock.now()
        if let sample = cached(key), time >= sample.at, time - sample.at < window { return sample.value }
        // Collected holding only this key's lock.
        let value = collect()
        lock.lock()
        if samples.count >= Self.keyLimit, samples[key] == nil { samples.removeAll(keepingCapacity: true) }
        samples[key] = (value, time)
        lock.unlock()
        return value
    }

    private func cached(_ key: String) -> (value: Value, at: TimeInterval)? {
        lock.lock()
        defer { lock.unlock() }
        return samples[key]
    }

    private func lockFor(_ key: String) -> NSLock {
        lock.lock()
        defer { lock.unlock() }
        if let existing = keyLocks[key] { return existing }
        if keyLocks.count >= Self.keyLimit * 4 {
            // Only locks nobody can be waiting on are dropped: a caller holds
            // its lock object, so removing the entry never breaks a waiter.
            keyLocks.removeAll(keepingCapacity: true)
        }
        let created = NSLock()
        keyLocks[key] = created
        return created
    }
}
