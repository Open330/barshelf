import Foundation

/// Coalesces simultaneous widget requests without changing their refresh
/// cadence. Each key has its own short window; unrelated mounts never share
/// values. The lock covers collection so concurrent requests collect once.
final class MetricSampleCache<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private let window: TimeInterval
    private var samples: [String: (value: Value, at: TimeInterval)] = [:]

    init(window: TimeInterval = 0.25) { self.window = window }

    func sample(key: String = "", now: TimeInterval? = nil, collect: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        let time = now ?? SleepAwareClock.now()
        if let sample = samples[key], time >= sample.at, time - sample.at < window { return sample.value }
        let value = collect()
        // Mounts can be widget-controlled; keep retained state bounded.
        if samples.count >= 16, samples[key] == nil { samples.removeAll(keepingCapacity: true) }
        samples[key] = (value, time)
        return value
    }
}
