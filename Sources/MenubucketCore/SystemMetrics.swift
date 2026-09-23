// `mach_task_self_` is imported from Darwin as a mutable global: libSystem
// writes it once at process start and never again. SDKs new enough to annotate
// it `__swift_nonisolated_unsafe` say so, older ones do not — and CI builds
// this target with `-strict-concurrency=complete -warnings-as-errors`, where
// the unannotated form is an error. Vouching for the module here keeps the
// build identical across both SDKs.
@preconcurrency import Darwin
import Foundation

/// Native system telemetry for the `system` workflow source: CPU load, memory,
/// disk, network and hardware sensors, read straight from Mach / sysctl / IOKit.
///
/// This exists because the menu bar needs a *cheap* sample. The shell pipeline
/// it replaces (`top -l 1` + `memory_pressure`) costs ~1 s of CPU per reading,
/// which is fine for a 60 s popup widget and unusable at the 2 s cadence a
/// live status item wants. A full sample here costs well under 10 ms and
/// spawns no subprocess, so it also needs no `permissions.exec` entry.
///
/// Percentages are 0–100 (matching the convention the bundled widgets already
/// use), byte counts are bytes, and temperatures are °C. Anything the machine
/// does not publish is `null` rather than zero — a fanless Mac reports no fans,
/// and a sandboxed build reports no sensors at all.
public enum SystemMetrics {
    /// One requestable metric group. A widget must declare each group it reads
    /// in `permissions.system`.
    public enum Metric: String, CaseIterable, Sendable {
        case cpu, memory, disk, network, sensors
    }

    /// Parses the `metrics` source parameter. `nil` means the source named no
    /// groups, which reads as "everything this widget is permitted to read" —
    /// distinct from an explicit list, which is checked against the grant.
    public static func requestedMetrics(from value: JSONValue?) -> Set<Metric>? {
        guard let names = value?.arrayValue?.compactMap(\.stringValue), !names.isEmpty else {
            return nil
        }
        return Set(names.compactMap(Metric.init(rawValue:)))
    }

    /// Groups `permissions.system` grants.
    ///
    /// Declaring nothing grants nothing: a widget that reads system telemetry
    /// says so in its manifest, the same way an `exec` source declares its
    /// command and an `http` source its host.
    public static func granted(_ declared: [String]?) -> Set<Metric> {
        Set((declared ?? []).compactMap(Metric.init(rawValue:)))
    }

    /// Resolves what a source may actually sample.
    ///
    /// An unspecified request takes the whole grant, so `{ "use": "system" }`
    /// with `permissions.system: ["cpu"]` samples CPU rather than failing on
    /// the three groups it never asked for.
    public static func authorized(
        _ requested: Set<Metric>?,
        declared: [String]?
    ) -> (allowed: Set<Metric>, denied: Set<Metric>) {
        let grant = granted(declared)
        guard let requested else { return (grant, []) }
        return (requested.intersection(grant), requested.subtracting(grant))
    }

    /// Samples the requested groups into the shape a workflow template reads
    /// as `sources.<id>.cpu.usage`, `…memory.usage`, `…sensors.cpu`, etc.
    ///
    /// - Parameter detail: also emits `cpu.cores[]` and `sensors.list[]`. Off
    ///   by default because the sensor list costs roughly 3× a plain sample.
    /// - Parameter sensorGroups: narrows the temperature sensors read to the
    ///   components the caller displays (`nil` reads all of them). Each key is
    ///   its own IOKit round trip, so a widget showing one CPU reading saves
    ///   about two thirds of the sample by saying so.
    public static func sample(
        metrics: Set<Metric> = Set(Metric.allCases),
        detail: Bool = false,
        sensorGroups: Set<SensorSampler.SensorGroup>? = nil,
        sensorKeys: [String] = [],
        mountPoint: String = "/",
        networkInterface: String? = nil
    ) -> JSONValue {
        var object: [String: JSONValue] = [:]
        if metrics.contains(.cpu) {
            object["cpu"] = cpuSampler.sample(detail: detail).json
        }
        if metrics.contains(.memory) {
            object["memory"] = memory().json
        }
        if metrics.contains(.disk) {
            object["disk"] = disk(mountPoint: mountPoint)?.json ?? .null
        }
        if metrics.contains(.network) {
            object["network"] = NetworkMetrics.shared.sample(interface: networkInterface).json
        }
        if metrics.contains(.sensors) {
            object["sensors"] = json(
                for: SensorSampler.shared.sample(detail: detail, groups: sensorGroups, keys: sensorKeys),
                detail: detail
            )
        }
        object["sampledAt"] = .number(Date().timeIntervalSince1970 * 1000)
        return .object(object)
    }

    static let cpuSampler = CPUSampler()

    // MARK: - CPU

    public struct CPUUsage: Equatable, Sendable {
        /// Non-idle share of the sampling window, 0–100.
        public var usage: Double
        public var user: Double
        public var system: Double
        public var nice: Double
        public var idle: Double
        public var coreCount: Int
        /// Per-core `usage`, only when sampled with `detail`.
        public var cores: [Double]
        public var loadAverage: [Double]

        var json: JSONValue {
            var object: [String: JSONValue] = [
                "usage": .number(usage),
                "user": .number(user),
                "system": .number(system),
                "nice": .number(nice),
                "idle": .number(idle),
                "coreCount": .number(Double(coreCount)),
                "loadAverage": .object([
                    "1m": .number(loadAverage.count > 0 ? loadAverage[0] : 0),
                    "5m": .number(loadAverage.count > 1 ? loadAverage[1] : 0),
                    "15m": .number(loadAverage.count > 2 ? loadAverage[2] : 0),
                ]),
            ]
            if !cores.isEmpty {
                object["cores"] = .array(cores.map(JSONValue.number))
            }
            return .object(object)
        }
    }

    /// Per-core CPU tick counters, differenced against the previous sample.
    ///
    /// The counters are monotonic since boot, so a single reading says nothing
    /// about current load — usage is always the delta between two samples. The
    /// very first sample therefore takes its own short baseline; every later
    /// one measures the whole interval since the previous refresh, which is
    /// what makes a 2 s menu-bar cadence a 2 s average.
    public final class CPUSampler: @unchecked Sendable {
        /// Window used to seed the first sample, when no previous ticks exist.
        static let baselineWindowMs: UInt32 = 200
        /// Shortest window a fresh delta is computed over. Two widgets both
        /// reading CPU would otherwise cut each other's window to milliseconds
        /// and report noise; inside this window they share one measurement.
        static let minWindowSec: TimeInterval = 0.25

        private let lock = NSLock()
        private var previous: [CPUTicks] = []
        private var last: (usage: CPUUsage, at: Date)?

        public init() {}

        public func sample(detail: Bool = false, now: Date = Date()) -> CPUUsage {
            lock.lock()
            defer { lock.unlock() }

            if let last, now.timeIntervalSince(last.at) < Self.minWindowSec,
               !detail || !last.usage.cores.isEmpty {
                return Self.presented(last.usage, detail: detail)
            }

            var current = Self.read()
            // `host_processor_info` can fail (VM, resource pressure). Without
            // tick counters there is no load to report, and — critically — no
            // baseline to index into further down.
            guard !current.isEmpty else { return Self.unavailable() }

            if previous.count != current.count {
                previous = current
                usleep(Self.baselineWindowMs * 1000)
                current = Self.read()
                // A re-read can come back empty or a different width (a core
                // parked between the two reads). Either way there is no
                // matching baseline to difference against this time round.
                guard current.count == previous.count else {
                    previous = current
                    return Self.unavailable()
                }
            }

            var cores: [Double] = []
            var totals = CPUTicks()
            var previousTotals = CPUTicks()
            for (index, ticks) in current.enumerated() {
                let before = previous[index]
                totals.add(ticks)
                previousTotals.add(before)
                if detail {
                    cores.append(ticks.usage(since: before))
                }
            }
            previous = current

            let delta = totals.delta(since: previousTotals)
            let total = max(delta.total, 1)

            let usage = CPUUsage(
                usage: Double(delta.user + delta.system + delta.nice) / Double(total) * 100,
                user: Double(delta.user) / Double(total) * 100,
                system: Double(delta.system) / Double(total) * 100,
                nice: Double(delta.nice) / Double(total) * 100,
                idle: Double(delta.idle) / Double(total) * 100,
                coreCount: current.count,
                cores: cores,
                loadAverage: Self.loadAverage()
            )
            last = (usage, now)
            return usage
        }

        /// A cached sample may carry per-core data a plain caller must not see
        /// — `cores[]` is contractually detail-only.
        static func presented(_ usage: CPUUsage, detail: Bool) -> CPUUsage {
            guard !detail, !usage.cores.isEmpty else { return usage }
            var stripped = usage
            stripped.cores = []
            return stripped
        }

        /// No tick counters this round. Reported as zero load with
        /// `coreCount: 0` — the signal a template can branch on — rather than
        /// a fabricated idle machine. Deliberately not cached, so the next
        /// sample retries immediately.
        static func unavailable() -> CPUUsage {
            CPUUsage(
                usage: 0, user: 0, system: 0, nice: 0, idle: 0,
                coreCount: 0, cores: [], loadAverage: loadAverage()
            )
        }

        static func loadAverage() -> [Double] {
            var loads = [Double](repeating: 0, count: 3)
            getloadavg(&loads, 3)
            return loads
        }

        /// Drops the baseline so the next sample re-seeds — used by tests and
        /// after a wake, where the tick delta would otherwise span the sleep.
        public func reset() {
            lock.lock()
            previous = []
            last = nil
            lock.unlock()
        }

        private static func read() -> [CPUTicks] {
            var processorCount: natural_t = 0
            var info: processor_info_array_t?
            var infoCount: mach_msg_type_number_t = 0
            let result = host_processor_info(
                mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                &processorCount, &info, &infoCount
            )
            guard result == KERN_SUCCESS, let info else { return [] }
            defer {
                vm_deallocate(
                    mach_task_self_,
                    vm_address_t(bitPattern: info),
                    vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
                )
            }
            let stride = Int(CPU_STATE_MAX)
            return (0..<Int(processorCount)).map { core in
                let base = core * stride
                return CPUTicks(
                    user: UInt64(max(info[base + Int(CPU_STATE_USER)], 0)),
                    system: UInt64(max(info[base + Int(CPU_STATE_SYSTEM)], 0)),
                    idle: UInt64(max(info[base + Int(CPU_STATE_IDLE)], 0)),
                    nice: UInt64(max(info[base + Int(CPU_STATE_NICE)], 0))
                )
            }
        }
    }

    struct CPUTicks: Equatable {
        var user: UInt64 = 0
        var system: UInt64 = 0
        var idle: UInt64 = 0
        var nice: UInt64 = 0

        var total: UInt64 { user &+ system &+ idle &+ nice }

        mutating func add(_ other: CPUTicks) {
            user &+= other.user
            system &+= other.system
            idle &+= other.idle
            nice &+= other.nice
        }

        /// Saturating difference — the counters reset when a core is parked and
        /// brought back, and a negative delta must read as "no work", not as a
        /// wrapped-around enormous number.
        func delta(since other: CPUTicks) -> CPUTicks {
            CPUTicks(
                user: user > other.user ? user - other.user : 0,
                system: system > other.system ? system - other.system : 0,
                idle: idle > other.idle ? idle - other.idle : 0,
                nice: nice > other.nice ? nice - other.nice : 0
            )
        }

        func usage(since other: CPUTicks) -> Double {
            let difference = delta(since: other)
            let total = max(difference.total, 1)
            return Double(difference.user + difference.system + difference.nice)
                / Double(total) * 100
        }
    }

    // MARK: - Memory

    public struct MemoryUsage: Equatable, Sendable {
        public var total: Double
        /// App + wired + compressed, the figure Activity Monitor calls
        /// "Memory Used".
        public var used: Double
        public var free: Double
        public var app: Double
        public var wired: Double
        public var compressed: Double
        public var cached: Double
        /// `used / total`, 0–100.
        public var usage: Double
        /// "normal" | "warning" | "critical" | "unknown".
        public var pressure: String
        public var swapTotal: Double
        public var swapUsed: Double

        var json: JSONValue {
            .object([
                "total": .number(total),
                "used": .number(used),
                "free": .number(free),
                "app": .number(app),
                "wired": .number(wired),
                "compressed": .number(compressed),
                "cached": .number(cached),
                "usage": .number(usage),
                "pressure": .string(pressure),
                "swap": .object([
                    "total": .number(swapTotal),
                    "used": .number(swapUsed),
                    "free": .number(max(swapTotal - swapUsed, 0)),
                    "usage": .number(swapTotal > 0 ? swapUsed / swapTotal * 100 : 0),
                ]),
            ])
        }
    }

    public static func memory() -> MemoryUsage {
        let total = Double(ProcessInfo.processInfo.physicalMemory)
        var statistics = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            return MemoryUsage(
                total: total, used: 0, free: total, app: 0, wired: 0, compressed: 0,
                cached: 0, usage: 0, pressure: pressureLevel(), swapTotal: 0, swapUsed: 0
            )
        }

        let pageSize = Double(Self.pageSize)
        let purgeable = Double(statistics.purgeable_count) * pageSize
        let app = max(Double(statistics.internal_page_count) * pageSize - purgeable, 0)
        let wired = Double(statistics.wire_count) * pageSize
        let compressed = Double(statistics.compressor_page_count) * pageSize
        let cached = Double(statistics.external_page_count) * pageSize + purgeable
        let used = app + wired + compressed
        let swap = swapUsage()

        return MemoryUsage(
            total: total,
            used: used,
            free: max(total - used, 0),
            app: app,
            wired: wired,
            compressed: compressed,
            cached: cached,
            usage: total > 0 ? used / total * 100 : 0,
            pressure: pressureLevel(),
            swapTotal: swap.total,
            swapUsed: swap.used
        )
    }

    /// The unit `host_statistics64` counts pages in. Asked of the kernel rather
    /// than read from `vm_kernel_page_size`, which is a mutable global and so
    /// not concurrency-safe; `sysconf` is the fallback if the Mach call fails.
    static var pageSize: Int {
        var size: vm_size_t = 0
        guard host_page_size(mach_host_self(), &size) == KERN_SUCCESS, size > 0 else {
            return sysconf(_SC_PAGESIZE)
        }
        return Int(size)
    }

    /// `kern.memorystatus_vm_pressure_level`: 1 normal, 2 warning, 4 critical.
    static func pressureLevel() -> String {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0
        else { return "unknown" }
        switch level {
        case 1: return "normal"
        case 2: return "warning"
        case 4: return "critical"
        default: return "unknown"
        }
    }

    static func swapUsage() -> (total: Double, used: Double) {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return (0, 0) }
        return (Double(usage.xsu_total), Double(usage.xsu_used))
    }

    // MARK: - Disk

    public struct DiskUsage: Equatable, Sendable {
        public var mount: String
        public var total: Double
        public var used: Double
        public var free: Double
        /// `used / total`, 0–100.
        public var usage: Double

        var json: JSONValue {
            .object([
                "mount": .string(mount),
                "total": .number(total),
                "used": .number(used),
                "free": .number(free),
                "usage": .number(usage),
            ])
        }
    }

    /// Capacity of the volume backing `mountPoint`, matching what `df` reports:
    /// free space is the user-available figure, so the reserved blocks count as
    /// used rather than silently inflating the free number.
    public static func disk(mountPoint: String = "/") -> DiskUsage? {
        var stats = statfs()
        guard statfs(mountPoint, &stats) == 0 else { return nil }
        let blockSize = Double(stats.f_bsize)
        let total = Double(stats.f_blocks) * blockSize
        let free = Double(stats.f_bavail) * blockSize
        let used = max(total - free, 0)
        guard total > 0 else { return nil }
        return DiskUsage(
            mount: mountPoint, total: total, used: used, free: free,
            usage: used / total * 100
        )
    }

    // MARK: - Sensors

    static func json(for snapshot: SensorSnapshot, detail: Bool) -> JSONValue {
        var object: [String: JSONValue] = [
            "available": .bool(snapshot.available),
            "cpu": snapshot.cpu.map(JSONValue.number) ?? .null,
            "gpu": snapshot.gpu.map(JSONValue.number) ?? .null,
            "battery": snapshot.battery.map(JSONValue.number) ?? .null,
            "peak": snapshot.peak.map(JSONValue.number) ?? .null,
            "cpuMax": snapshot.cpuMax.map(JSONValue.number) ?? .null,
            "gpuMax": snapshot.gpuMax.map(JSONValue.number) ?? .null,
            "batteryMax": snapshot.batteryMax.map(JSONValue.number) ?? .null,
            // The sensors asked for by key, one slot per key (null where
            // missing); `picked` is the first, for the common one-sensor case.
            "pickedList": .array(snapshot.picked.map { $0.map(json(for:)) ?? .null }),
            "picked": snapshot.picked.first.flatMap { $0 }.map(json(for:)) ?? .null,
            "power": snapshot.power.map(JSONValue.number) ?? .null,
            "fanCount": .number(Double(snapshot.fans.count)),
            "fans": .array(snapshot.fans.map { fan in
                .object([
                    "index": .number(Double(fan.index)),
                    "name": .string(fan.name),
                    "rpm": .number(fan.rpm),
                    "min": fan.minRPM.map(JSONValue.number) ?? .null,
                    "max": fan.maxRPM.map(JSONValue.number) ?? .null,
                    "usage": fan.usage.map(JSONValue.number) ?? .null,
                ])
            }),
        ]
        if detail {
            object["list"] = .array(snapshot.list.map(json(for:)))
        }
        return .object(object)
    }

    static func json(for reading: SensorReading) -> JSONValue {
        .object([
            "key": .string(reading.key),
            "name": .string(reading.name),
            "kind": .string(reading.kind.rawValue),
            "value": .number(reading.value),
            "unit": .string(reading.unit),
        ])
    }
}
