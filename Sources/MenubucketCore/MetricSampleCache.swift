import Foundation

/// Coalesces simultaneous widget requests without changing their refresh
/// cadence. Each key has its own short window and its own lock: concurrent
/// requests for one key collect once, while a slow key (a hung network
/// volume) never holds up another.
final class MetricSampleCache<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private let window: TimeInterval
    private var samples: [String: (value: Value, at: TimeInterval)] = [:]
    private final class KeyLock {
        let lock = NSLock()
        // Includes owners and waiters. Guarded by the cache-wide lock.
        var users = 0
    }
    private var keyLocks: [String: KeyLock] = [:]
    /// Mounts can be widget-controlled; keep retained state bounded.
    static var keyLimit: Int { 16 }

    init(window: TimeInterval = 0.25) { self.window = window }

    func sample(key: String = "", now: TimeInterval? = nil, collect: () -> Value) -> Value {
        let keyLock = lockFor(key)
        keyLock.lock.lock()
        defer {
            keyLock.lock.unlock()
            lock.lock()
            keyLock.users -= 1
            if keyLocks.count > Self.keyLimit * 4, keyLock.users == 0 {
                keyLocks.removeValue(forKey: key)
            }
            lock.unlock()
        }
        let time = now ?? SleepAwareClock.now()
        if let sample = cached(key), time >= sample.at, time - sample.at < window { return sample.value }
        // Collected holding only this key's lock.
        let value = collect()
        lock.lock()
        if samples.count >= Self.keyLimit, samples[key] == nil { samples.removeAll(keepingCapacity: true) }
        // A slow volume can take longer than the reuse window to respond.
        // Its freshly completed sample must not already be expired when the
        // next waiter acquires the key lock. Explicit test clocks stay fixed.
        samples[key] = (value, now ?? SleepAwareClock.now())
        lock.unlock()
        return value
    }

    private func cached(_ key: String) -> (value: Value, at: TimeInterval)? {
        lock.lock()
        defer { lock.unlock() }
        return samples[key]
    }

    private func lockFor(_ key: String) -> KeyLock {
        lock.lock()
        defer { lock.unlock() }
        if let existing = keyLocks[key] {
            existing.users += 1
            return existing
        }
        if keyLocks.count >= Self.keyLimit * 4 {
            // Keeping the object alive is not enough: a subsequent caller
            // must find that same lock while a collection or waiter exists.
            // Idle entries are bounded; live entries retire when released.
            keyLocks = keyLocks.filter { $0.value.users > 0 }
        }
        let created = KeyLock()
        created.users = 1
        keyLocks[key] = created
        return created
    }
}
