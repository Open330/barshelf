import Foundation
import IOKit

/// Disk throughput for the `system` source: the byte counters every
/// `IOBlockStorageDriver` keeps in its `Statistics`, differenced into bytes
/// per second.
///
/// Read only when a source asks for it (`"io": true`): walking the storage
/// drivers is an IOKit registry query per sample, which a CPU item on a 2 s
/// cadence has no use for.
public enum DiskIOMetrics {
    public struct Counters: Equatable, Sendable {
        public var read: UInt64
        public var written: UInt64

        public init(read: UInt64, written: UInt64) {
            self.read = read
            self.written = written
        }
    }

    public struct Rates: Equatable, Sendable {
        /// Bytes per second, nil until two samples exist.
        public var read: Double?
        public var write: Double?
    }

    /// Stateful differencer, like the network sampler: a rate needs a
    /// previous counter, a counter that went backwards (a disk ejected, a
    /// driver restarted) re-baselines instead of reporting a negative burst,
    /// and a gap longer than `maximumWindow` (a long sleep) re-baselines too.
    public final class Sampler: @unchecked Sendable {
        public static let shared = Sampler()
        static let minimumWindow: TimeInterval = 0.25
        static let maximumWindow: TimeInterval = 15 * 60

        private let lock = NSLock()
        private let read: () -> Counters?
        private var previous: (counters: Counters, at: TimeInterval)?
        private var last: Rates = Rates()

        public static func clock() -> TimeInterval {
            TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000_000
        }

        public init(read: @escaping () -> Counters? = DiskIOMetrics.readCounters) {
            self.read = read
        }

        /// `now` counts sleep (`CLOCK_MONOTONIC` on Darwin; `systemUptime`
        /// does not), so a night's sleep is a gap `maximumWindow` refuses
        /// rather than a few seconds that dark-wake I/O gets divided by.
        public func sample(now: TimeInterval = Sampler.clock()) -> Rates {
            lock.lock()
            defer { lock.unlock() }
            // Two widgets reading at once share one measurement rather than
            // cutting each other's window to noise.
            if let previous, now - previous.at < Self.minimumWindow { return last }
            guard let counters = read() else {
                previous = nil
                last = Rates()
                return last
            }
            defer { previous = (counters, now) }
            guard let previous,
                  counters.read >= previous.counters.read,
                  counters.written >= previous.counters.written,
                  now - previous.at <= Self.maximumWindow
            else {
                last = Rates()
                return last
            }
            let window = now - previous.at
            last = Rates(
                read: Double(counters.read - previous.counters.read) / window,
                write: Double(counters.written - previous.counters.written) / window
            )
            return last
        }
    }

    /// The summed byte counters of every block storage driver but a disk
    /// image's — an image's reads are also its host disk's, and counting both
    /// doubled a copy out of a mounted .dmg. nil when there is none to read
    /// (a sandbox, a VM without one).
    public static func readCounters() -> Counters? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator
        ) == kIOReturnSuccess else { return nil }
        defer { IOObjectRelease(iterator) }

        var total = Counters(read: 0, written: 0)
        var found = false
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard !isDiskImage(service) else { continue }
            guard let property = IORegistryEntryCreateCFProperty(
                service, "Statistics" as CFString, kCFAllocatorDefault, 0
            )?.takeRetainedValue() as? [String: Any] else { continue }
            let read = (property["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            let written = (property["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
            total.read &+= read
            total.written &+= written
            found = true
        }
        return found ? total : nil
    }

    /// Whether a storage driver sits on a mounted disk image (the
    /// `IOHDIXHDDrive…` family `hdiutil` attaches).
    static func isDiskImage(_ driver: io_object_t) -> Bool {
        var parent: io_registry_entry_t = 0
        guard IORegistryEntryGetParentEntry(driver, kIOServicePlane, &parent) == KERN_SUCCESS else { return false }
        defer { IOObjectRelease(parent) }
        var name = [CChar](repeating: 0, count: 128)
        guard IOObjectGetClass(parent, &name) == KERN_SUCCESS else { return false }
        return String(cString: name).contains("HDIX")
    }
}
