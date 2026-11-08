// See `SystemMetrics.swift` for why Darwin is imported this way.
@preconcurrency import Darwin
import Foundation

/// The `processes` group of the `system` source: the busiest processes by
/// CPU, read with libproc — no `ps`/`top` subprocess.
///
/// CPU is the share of the **whole machine** over the window since the
/// previous sample, 0–100, the same scale as `cpu.usage` — so a process's
/// figure and the machine's add up. (Activity Monitor's "% CPU" column is a
/// share of *one* core; multiply by `cpu.coreCount` to get that.)
///
/// A process's CPU time is a counter since it started, so the figure is the
/// delta between two samples, kept here per pid. A cold sampler takes a
/// short baseline first, like the `cpu` group, so the first list is already
/// a real reading rather than all zeros. A process seen for the first time
/// on a later sample (it just started) reads its whole lifetime over the
/// window, which is what it did in it.
public enum ProcessMetrics {
    /// Rows a source may ask for.
    public static let maxCount = 10
    public static let defaultCount = 5

    /// One process, as a `system` source row.
    public struct ProcessUsage: Equatable, Sendable {
        public var pid: Int32
        public var name: String
        /// Share of total CPU capacity over the window, 0–100.
        public var cpu: Double
        /// Physical footprint in bytes (Activity Monitor's "Memory"), or the
        /// resident size where the footprint cannot be read.
        public var memory: Double
        public var bundleID: String?
        public var isApp: Bool

        public init(pid: Int32, name: String, cpu: Double, memory: Double, bundleID: String?, isApp: Bool) {
            self.pid = pid
            self.name = name
            self.cpu = cpu
            self.memory = memory
            self.bundleID = bundleID
            self.isApp = isApp
        }

        var json: JSONValue {
            .object([
                "pid": .number(Double(pid)),
                "name": .string(name),
                "cpu": .number(cpu),
                "memory": .number(memory),
                "bundleID": bundleID.map(JSONValue.string) ?? .null,
                "isApp": .bool(isApp),
            ])
        }
    }

    /// An app the host knows is running, to name a row and mark it `isApp`.
    public struct AppIdentity: Equatable, Sendable {
        public var name: String
        public var bundleID: String?

        public init(name: String, bundleID: String?) {
            self.name = name
            self.bundleID = bundleID
        }
    }

    /// The `processes` source option: `{ "count": N }`, 1…10, default 5.
    public static func count(from value: JSONValue?) -> Int {
        guard let raw = value?.objectValue?["count"]?.numberValue, raw.isFinite else {
            return defaultCount
        }
        return Swift.min(Swift.max(Int(raw.rounded()), 1), maxCount)
    }

    public static let shared = Sampler()

    public final class Sampler: @unchecked Sendable {
        static let baselineWindowMs: UInt32 = 200
        /// Two widgets sampling together share one measurement instead of
        /// cutting each other's window to noise.
        static let minWindowSec: TimeInterval = 0.25

        private let lock = NSLock()
        /// CPU time (ns) per pid at the previous sample.
        private var previous: [Int32: UInt64] = [:]
        private var previousAt: UInt64 = 0
        private var last: (rows: [Raw], at: Date)?
        private var bundleCache: [String: AppIdentity?] = [:]

        public init() {}

        struct Raw: Equatable {
            var pid: Int32
            var cpu: Double
        }

        /// The `count` busiest processes. `apps` maps the pids of running
        /// apps (from the host's app list) to their names; without it a row
        /// is an app when its executable is an `.app` bundle's main one.
        public func sample(
            count: Int = ProcessMetrics.defaultCount,
            apps: [Int32: AppIdentity]? = nil,
            now: Date = Date()
        ) -> [ProcessUsage] {
            let rows = topRaw(now: now)
            let limit = Swift.min(Swift.max(count, 1), ProcessMetrics.maxCount)
            return rows.prefix(limit).map { describe($0, apps: apps) }
        }

        public func reset() {
            lock.lock()
            previous = [:]
            previousAt = 0
            last = nil
            lock.unlock()
        }

        private func topRaw(now: Date) -> [Raw] {
            lock.lock()
            defer { lock.unlock() }
            if let last, now.timeIntervalSince(last.at) < Self.minWindowSec {
                return last.rows
            }
            if previous.isEmpty {
                previous = ProcessMetrics.cpuTimes()
                previousAt = ProcessMetrics.nanosecondsNow()
                usleep(Self.baselineWindowMs * 1000)
            }
            let current = ProcessMetrics.cpuTimes()
            let currentAt = ProcessMetrics.nanosecondsNow()
            let rows = ProcessMetrics.busiest(
                current: current,
                previous: previous,
                elapsedNs: currentAt &- previousAt,
                coreCount: ProcessInfo.processInfo.activeProcessorCount,
                limit: ProcessMetrics.maxCount
            )
            previous = current
            previousAt = currentAt
            last = (rows, now)
            return rows
        }

        private func describe(_ raw: Raw, apps: [Int32: AppIdentity]?) -> ProcessUsage {
            let path = ProcessMetrics.executablePath(raw.pid)
            let identity: AppIdentity?
            if let apps {
                identity = apps[raw.pid]
            } else {
                identity = path.flatMap(bundleIdentity(forExecutable:))
            }
            let name = identity?.name
                ?? path.map { ($0 as NSString).lastPathComponent }
                ?? ProcessMetrics.shortName(raw.pid)
                ?? "pid \(raw.pid)"
            return ProcessUsage(
                pid: raw.pid,
                name: name,
                cpu: raw.cpu,
                memory: ProcessMetrics.memory(raw.pid),
                bundleID: identity?.bundleID,
                isApp: identity != nil
            )
        }

        /// `/X.app/Contents/MacOS/X` → that bundle's name and identifier.
        /// Cached per path: the Info.plist read is the expensive part.
        private func bundleIdentity(forExecutable path: String) -> AppIdentity? {
            lock.lock()
            if let cached = bundleCache[path] {
                lock.unlock()
                return cached
            }
            lock.unlock()
            var identity: AppIdentity?
            let macOS = (path as NSString).deletingLastPathComponent
            let contents = (macOS as NSString).deletingLastPathComponent
            let bundlePath = (contents as NSString).deletingLastPathComponent
            if (macOS as NSString).lastPathComponent == "MacOS",
               (contents as NSString).lastPathComponent == "Contents",
               bundlePath.hasSuffix(".app"),
               let bundle = Bundle(path: bundlePath),
               bundle.executablePath.map({ ($0 as NSString).standardizingPath })
                == (path as NSString).standardizingPath {
                let info = bundle.infoDictionary ?? [:]
                let name = (info["CFBundleDisplayName"] as? String)
                    ?? (info["CFBundleName"] as? String)
                    ?? ((bundlePath as NSString).lastPathComponent as NSString).deletingPathExtension
                identity = AppIdentity(name: name, bundleID: bundle.bundleIdentifier)
            }
            lock.lock()
            if bundleCache.count > 256 { bundleCache.removeAll() }
            bundleCache[path] = identity
            lock.unlock()
            return identity
        }
    }

    /// The `limit` busiest pids, by CPU time used since `previous`, as a
    /// share of `coreCount` cores over `elapsedNs`. A counter that went
    /// backwards (the pid was reused) counts as a new process.
    static func busiest(
        current: [Int32: UInt64],
        previous: [Int32: UInt64],
        elapsedNs: UInt64,
        coreCount: Int,
        limit: Int
    ) -> [Sampler.Raw] {
        let capacity = Double(Swift.max(elapsedNs, 1)) * Double(Swift.max(coreCount, 1))
        let rows = current.map { pid, time -> Sampler.Raw in
            let before = previous[pid] ?? 0
            let used = time >= before ? time - before : time
            return Sampler.Raw(pid: pid, cpu: Swift.min(Double(used) / capacity * 100, 100))
        }
        return Array(
            rows.sorted { $0.cpu != $1.cpu ? $0.cpu > $1.cpu : $0.pid < $1.pid }.prefix(limit)
        )
    }

    // MARK: - libproc

    /// Every pid's user + system CPU time in nanoseconds. Pids this user may
    /// not inspect (other users' and protected processes) are left out.
    static func cpuTimes() -> [Int32: UInt64] {
        var times: [Int32: UInt64] = [:]
        let timebase = Self.timebase
        for pid in allPIDs() where pid > 0 {
            var info = proc_taskinfo()
            let size = Int32(MemoryLayout<proc_taskinfo>.stride)
            guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { continue }
            // Task times are Mach absolute-time units (ns on Intel, 1/24 µs
            // ticks on Apple silicon).
            let ticks = info.pti_total_user &+ info.pti_total_system
            times[pid] = ticks.multipliedReportingOverflow(by: timebase.numer).partialValue / timebase.denom
        }
        return times
    }

    static func allPIDs() -> [Int32] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        // Room for processes started between the two calls.
        var pids = [Int32](repeating: 0, count: Int(estimate) + 64)
        let bytes = Int32(pids.count * MemoryLayout<Int32>.stride)
        let found = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, bytes) }
        guard found > 0 else { return [] }
        return Array(pids.prefix(Int(found)))
    }

    static func executablePath(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    static func shortName(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 2 * Int(MAXCOMLEN) + 1)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let name = String(cString: buffer)
        return name.isEmpty ? nil : name
    }

    /// Physical footprint, falling back to resident size.
    static func memory(_ pid: Int32) -> Double {
        var usage = rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
            }
        }
        if result == 0 { return Double(usage.ri_phys_footprint) }
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { return 0 }
        return Double(info.pti_resident_size)
    }

    static func nanosecondsNow() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    }

    private static let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        guard mach_timebase_info(&info) == KERN_SUCCESS, info.denom > 0 else { return (1, 1) }
        return (UInt64(info.numer), UInt64(info.denom))
    }()
}
