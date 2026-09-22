// See `SystemMetrics.swift` — `mach_task_self_` (used by `IOServiceOpen`) is a
// mutable Darwin global that older SDKs leave unannotated.
@preconcurrency import Darwin
import Foundation
import IOKit

/// Hardware sensor access: `AppleSMC` for temperatures / fans / power, with
/// `IOHIDEventSystem` as the named-sensor fallback on Apple Silicon Macs whose
/// SMC exposes no `T*` keys.
///
/// Both backends are read-only and need no entitlement, but neither is
/// reachable from a sandboxed process — every accessor degrades to `nil` /
/// empty rather than throwing, so a sensors widget renders "—" instead of an
/// error banner when the platform (or the App Store build) withholds them.

// MARK: - Readings

/// One hardware sensor sample.
public struct SensorReading: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case temperature, fan, power
    }

    /// SMC four-character key, or the HID service's product name.
    public var key: String
    /// Human label derived from the key (falls back to the key itself).
    public var name: String
    public var kind: Kind
    /// °C for `temperature`, rpm for `fan`, W for `power`.
    public var value: Double

    public init(key: String, name: String, kind: Kind, value: Double) {
        self.key = key
        self.name = name
        self.kind = kind
        self.value = value
    }

    public var unit: String {
        switch kind {
        case .temperature: return "°C"
        case .fan: return "rpm"
        case .power: return "W"
        }
    }
}

/// One fan, as reported by the SMC (`F<n>Ac` / `F<n>Mn` / `F<n>Mx`).
public struct FanReading: Equatable, Sendable {
    public var index: Int
    public var name: String
    public var rpm: Double
    public var minRPM: Double?
    public var maxRPM: Double?

    public init(
        index: Int, name: String, rpm: Double,
        minRPM: Double? = nil, maxRPM: Double? = nil
    ) {
        self.index = index
        self.name = name
        self.rpm = rpm
        self.minRPM = minRPM
        self.maxRPM = maxRPM
    }

    /// Position between the fan's min and max speed, 0–100. Nil when the SMC
    /// does not publish the bounds (or they are degenerate).
    public var usage: Double? {
        guard let minRPM, let maxRPM, maxRPM > minRPM else { return nil }
        return ((rpm - minRPM) / (maxRPM - minRPM)).clampedToUnitRange * 100
    }
}

/// A complete sensor sample. Every field is optional: a fanless Mac reports
/// `fans == []`, and a sandboxed process reports everything nil/empty.
public struct SensorSnapshot: Equatable, Sendable {
    /// Mean of the CPU core die sensors.
    public var cpu: Double?
    public var gpu: Double?
    public var battery: Double?
    /// Hottest temperature sensor on the machine.
    public var peak: Double?
    /// System total power draw, watts (`PSTR`).
    public var power: Double?
    public var fans: [FanReading]
    /// Every readable sensor — populated only when sampled with `detail`.
    public var list: [SensorReading]
    /// False when no sensor backend answered (sandbox, VM, unsupported Mac).
    public var available: Bool

    public init(
        cpu: Double? = nil,
        gpu: Double? = nil,
        battery: Double? = nil,
        peak: Double? = nil,
        power: Double? = nil,
        fans: [FanReading] = [],
        list: [SensorReading] = [],
        available: Bool = false
    ) {
        self.cpu = cpu
        self.gpu = gpu
        self.battery = battery
        self.peak = peak
        self.power = power
        self.fans = fans
        self.list = list
        self.available = available
    }
}

extension Double {
    var clampedToUnitRange: Double { Swift.min(Swift.max(self, 0), 1) }
}

// MARK: - Sampler

/// Samples the hardware sensors, caching the SMC key catalog (~2,400 keys,
/// ~20 ms to enumerate) for the process lifetime — the key set is fixed per
/// machine, so only the values are re-read per sample.
///
/// Thread-safe: every entry point takes the instance lock, so the menu-bar
/// cadence and a popup refresh can sample concurrently.
public final class SensorSampler: @unchecked Sendable {
    public static let shared = SensorSampler()

    /// Which families of temperature sensor a sample reads.
    ///
    /// Every key costs its own IOKit round trip (~0.16 ms), and a Mac
    /// publishes far more of them than any one widget shows: on an M-series
    /// laptop the summarized set is 46 keys, 23 of them GPU. A menu bar
    /// showing one CPU reading has no use for the other 28.
    public enum SensorGroup: String, CaseIterable, Sendable {
        case cpu, gpu, battery
        /// Keys that belong to no summarized component but still count
        /// towards `peak` (package and enclosure sensors).
        case other
    }

    /// Maps the snapshot field a widget says it displays onto the sensor
    /// groups that have to be read for it.
    ///
    /// `nil` means "everything", which is both the default and what an
    /// unrecognized name falls back to — a narrowing hint that the host does
    /// not understand must never silently blank a reading.
    public static func groups(forReading reading: String) -> Set<SensorGroup>? {
        switch reading.trimmingCharacters(in: .whitespaces).lowercased() {
        case "", "all", "peak", "list":
            return nil
        case "cpu":
            return [.cpu]
        case "gpu":
            return [.gpu]
        case "battery":
            return [.battery]
        // Fans and wattage come from their own keys, which are always read.
        case "none", "power", "fan", "fanusage", "fancount", "fans":
            return []
        default:
            return nil
        }
    }

    /// The group a key belongs to, decided by the same predicates that
    /// summarize a reading, so a filtered sample can never disagree with the
    /// averages computed from it.
    static func group(forSMCKey key: String) -> SensorGroup {
        let probe = SensorReading(
            key: key, name: label(forSMCKey: key), kind: .temperature, value: 0
        )
        if isCPUSensor(probe) { return .cpu }
        if isGPUSensor(probe) { return .gpu }
        if isBatterySensor(probe) { return .battery }
        return .other
    }

    private let lock = NSLock()
    private let smc: SMCClient?
    private lazy var hid = HIDSensorClient()

    /// Temperature keys whose prefix identifies a component the snapshot
    /// summarizes (CPU / GPU / battery / package). A plain sample reads only
    /// these — reading every `T*` key the SMC publishes costs roughly 4× as
    /// much, which a 2 s menu-bar cadence does not need.
    /// The summarized temperature keys, split by component so a sample that
    /// only needs one reading reads only that component's keys.
    private var primaryKeysByGroup: [SensorGroup: [SMCClient.KeyMeta]] = [:]
    /// The remaining temperature keys, read only for a `detail` sample.
    private var extraTemperatureKeys: [SMCClient.KeyMeta] = []
    private var fanKeys: [Int: (actual: SMCClient.KeyMeta, min: SMCClient.KeyMeta?, max: SMCClient.KeyMeta?)] = [:]
    private var powerKey: SMCClient.KeyMeta?
    private var catalogLoaded = false

    public init() {
        smc = SMCClient()
    }

    /// Samples every backend. `detail` additionally reads every temperature
    /// key the machine publishes and returns them as `list` (~25 ms on an
    /// Apple Silicon laptop, against ~9 ms for a plain sample).
    ///
    /// `groups` narrows the summarized temperatures to the components the
    /// caller actually displays; `nil` reads all of them, which is what a
    /// widget showing `peak` or the full list needs. Reading one component
    /// instead of all four takes a plain sample from ~9 ms to ~3 ms, which is
    /// what a 3 s menu-bar cadence spends its time on. `detail` implies every
    /// group — the list is the whole point of it.
    ///
    /// `peak` is the hottest of the sensors this sample actually read, so a
    /// widget that narrows the groups gets the peak of what it asked for.
    public func sample(
        detail: Bool = false, groups: Set<SensorGroup>? = nil
    ) -> SensorSnapshot {
        lock.lock()
        defer { lock.unlock() }

        loadCatalogIfNeeded()

        let wanted = detail ? nil : groups
        var readings: [SensorReading] = []
        for meta in Self.keys(primaryKeysByGroup, limitedTo: wanted) {
            guard let value = smc?.value(meta), Self.isPlausibleTemperature(value) else { continue }
            readings.append(SensorReading(
                key: meta.key,
                name: Self.label(forSMCKey: meta.key),
                kind: .temperature,
                value: value
            ))
        }

        // Apple Silicon Macs that publish no SMC temperatures still answer
        // through the HID sensor plane (same source Stats falls back to).
        // A caller that asked for no temperatures at all is not missing data.
        if readings.isEmpty, wanted.map({ !$0.isEmpty }) ?? true {
            readings = hid.temperatures()
        }
        let summarized = readings

        var extras: [SensorReading] = []
        if detail {
            for meta in extraTemperatureKeys {
                guard let value = smc?.value(meta), Self.isPlausibleTemperature(value) else { continue }
                extras.append(SensorReading(
                    key: meta.key,
                    name: Self.label(forSMCKey: meta.key),
                    kind: .temperature,
                    value: value
                ))
            }
        }

        var fans: [FanReading] = []
        for (index, keys) in fanKeys.sorted(by: { $0.key < $1.key }) {
            guard let rpm = smc?.value(keys.actual) else { continue }
            fans.append(FanReading(
                index: index,
                name: "Fan \(index + 1)",
                rpm: rpm,
                minRPM: keys.min.flatMap { smc?.value($0) },
                maxRPM: keys.max.flatMap { smc?.value($0) }
            ))
        }

        let power = powerKey.flatMap { smc?.value($0) }

        var list: [SensorReading] = []
        if detail {
            list = (summarized + extras).sorted { $0.key < $1.key }
            list += fans.map {
                SensorReading(key: "F\($0.index)Ac", name: $0.name, kind: .fan, value: $0.rpm)
            }
            if let power {
                list.append(SensorReading(
                    key: "PSTR", name: "System total", kind: .power, value: power
                ))
            }
        }

        return SensorSnapshot(
            cpu: Self.mean(of: summarized, matching: Self.isCPUSensor),
            gpu: Self.mean(of: summarized, matching: Self.isGPUSensor),
            battery: Self.mean(of: summarized, matching: Self.isBatterySensor),
            peak: summarized.map(\.value).max(),
            power: power,
            fans: fans,
            list: list,
            available: !summarized.isEmpty || !fans.isEmpty || power != nil
        )
    }

    /// Discovers which sensor keys this Mac publishes. Called once; a machine
    /// never gains or loses SMC keys while the process runs.
    private func loadCatalogIfNeeded() {
        guard !catalogLoaded, let smc else { return }
        catalogLoaded = true

        for meta in smc.catalog() {
            if meta.key.hasPrefix("T"), meta.isFloatingPoint {
                if Self.summarizedPrefixes.contains(meta.key.prefix(2)) {
                    primaryKeysByGroup[Self.group(forSMCKey: meta.key), default: []]
                        .append(meta)
                } else {
                    extraTemperatureKeys.append(meta)
                }
            } else if meta.key.hasPrefix("F"), meta.key.count == 4 {
                // F<n>Ac / F<n>Mn / F<n>Mx — the index is a hex-ish digit.
                let middle = meta.key.dropFirst().prefix(1)
                guard let index = Int(middle, radix: 16) else { continue }
                let suffix = String(meta.key.suffix(2))
                var entry = fanKeys[index] ?? (actual: meta, min: nil, max: nil)
                switch suffix {
                case "Ac": entry.actual = meta
                case "Mn": entry.min = meta
                case "Mx": entry.max = meta
                default: continue
                }
                fanKeys[index] = entry
            } else if meta.key == "PSTR" {
                powerKey = meta
            }
        }
        // Drop indices that only had bounds and never an "actual speed" key.
        fanKeys = fanKeys.filter { $0.value.actual.key.hasSuffix("Ac") }
    }

    /// The keys for `groups`, in catalog order. `nil` means every group.
    private static func keys(
        _ buckets: [SensorGroup: [SMCClient.KeyMeta]], limitedTo groups: Set<SensorGroup>?
    ) -> [SMCClient.KeyMeta] {
        guard let groups else { return SensorGroup.allCases.flatMap { buckets[$0] ?? [] } }
        return SensorGroup.allCases
            .filter(groups.contains)
            .flatMap { buckets[$0] ?? [] }
    }

    // MARK: Classification

    /// SMC key prefixes that map onto a component the snapshot summarizes.
    static let summarizedPrefixes: Set<Substring> = ["Tp", "Te", "Tg", "TB", "TC"]

    /// Rejects the placeholder values an unpopulated sensor reports (the HID
    /// plane returns −22.25 °C for absent channels).
    static func isPlausibleTemperature(_ value: Double) -> Bool {
        value > 0 && value < 130
    }

    static func isCPUSensor(_ reading: SensorReading) -> Bool {
        let key = reading.key
        if key.hasPrefix("Tp") || key.hasPrefix("Te") { return true }
        let name = reading.name.lowercased()
        return name.contains("acc") || name.contains("soc") || name.contains("tdie")
    }

    static func isGPUSensor(_ reading: SensorReading) -> Bool {
        reading.key.hasPrefix("Tg") || reading.name.lowercased().contains("gpu")
    }

    static func isBatterySensor(_ reading: SensorReading) -> Bool {
        if reading.key.hasPrefix("TB") { return true }
        return reading.name.lowercased().contains("battery")
    }

    static func mean(
        of readings: [SensorReading],
        matching predicate: (SensorReading) -> Bool
    ) -> Double? {
        let values = readings.filter(predicate).map(\.value)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    /// Best-effort human label for an SMC key. Apple ships no public key
    /// dictionary and the naming shifts per chip generation, so this covers
    /// the stable prefixes and leaves everything else as the raw key.
    static func label(forSMCKey key: String) -> String {
        switch key.prefix(2) {
        case "Tp": return "CPU core (\(key))"
        case "Te": return "CPU efficiency core (\(key))"
        case "Tg": return "GPU (\(key))"
        case "Tm": return "Memory (\(key))"
        case "TB": return "Battery (\(key))"
        case "Ts": return "Enclosure (\(key))"
        case "TA": return "Ambient (\(key))"
        case "TC": return "CPU package (\(key))"
        default: return key
        }
    }
}

// MARK: - AppleSMC

/// Minimal read-only `AppleSMC` user client.
///
/// The struct layout and the `kSMCHandleYPCEvent` selector are the long-stable
/// public-ish SMC ABI every open-source monitor uses; unknown data types decode
/// to `nil` rather than misreporting a value.
final class SMCClient {
    /// A key plus the size/type the SMC reported for it, cached so a sample
    /// costs one `IOConnectCallStructMethod` per key instead of two.
    struct KeyMeta: Equatable, Sendable {
        var key: String
        var size: UInt32
        var type: String

        var isFloatingPoint: Bool { type == "flt " || type == "sp78" }
    }

    private var connection: io_connect_t = 0

    init?() {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching("AppleSMC")
        )
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == kIOReturnSuccess,
              connection != 0
        else { return nil }
    }

    deinit {
        if connection != 0 { IOServiceClose(connection) }
    }

    /// Every key the SMC publishes, with its type. ~20 ms — call once.
    func catalog() -> [KeyMeta] {
        guard let countBytes = read(key: "#KEY", size: UInt32(4)), countBytes.count >= 4 else {
            return []
        }
        let count = Int(
            UInt32(countBytes[0]) << 24 | UInt32(countBytes[1]) << 16
                | UInt32(countBytes[2]) << 8 | UInt32(countBytes[3])
        )
        // Guard against a nonsense count from an unexpected firmware.
        guard count > 0, count < 100_000 else { return [] }

        var metas: [KeyMeta] = []
        metas.reserveCapacity(count)
        for index in 0..<count {
            guard let key = key(at: index), !key.isEmpty, let meta = keyInfo(key) else { continue }
            metas.append(meta)
        }
        return metas
    }

    func value(_ meta: KeyMeta) -> Double? {
        guard let bytes = read(key: meta.key, size: meta.size) else { return nil }
        return Self.decode(bytes: bytes, type: meta.type)
    }

    func keyInfo(_ key: String) -> KeyMeta? {
        var input = SMCParamStruct()
        input.key = Self.fourCharCode(key)
        input.data8 = Self.kSMCGetKeyInfo
        guard let output = call(&input) else { return nil }
        let size = UInt32(output.keyInfo.dataSize)
        guard size > 0, size <= 32 else { return nil }
        return KeyMeta(key: key, size: size, type: Self.fourCharString(output.keyInfo.dataType))
    }

    private func key(at index: Int) -> String? {
        var input = SMCParamStruct()
        input.data8 = Self.kSMCGetKeyFromIndex
        input.data32 = UInt32(index)
        guard let output = call(&input) else { return nil }
        return Self.fourCharString(output.key)
    }

    private func read(key: String, size: UInt32) -> [UInt8]? {
        var input = SMCParamStruct()
        input.key = Self.fourCharCode(key)
        input.keyInfo.dataSize = IOByteCount32(size)
        input.data8 = Self.kSMCReadKey
        guard let output = call(&input) else { return nil }
        let bytes = withUnsafeBytes(of: output.bytes) { Array($0) }
        return Array(bytes.prefix(Int(min(size, 32))))
    }

    private func call(_ input: inout SMCParamStruct) -> SMCParamStruct? {
        var output = SMCParamStruct()
        var outputSize = MemoryLayout<SMCParamStruct>.stride
        let result = IOConnectCallStructMethod(
            connection,
            Self.kSMCHandleYPCEvent,
            &input,
            MemoryLayout<SMCParamStruct>.stride,
            &output,
            &outputSize
        )
        guard result == kIOReturnSuccess, output.result == 0 else { return nil }
        return output
    }

    // MARK: Encoding

    static func fourCharCode(_ string: String) -> UInt32 {
        var result: UInt32 = 0
        for byte in string.utf8.prefix(4) { result = (result << 8) | UInt32(byte) }
        return result
    }

    static func fourCharString(_ code: UInt32) -> String {
        let bytes = [
            UInt8((code >> 24) & 0xff), UInt8((code >> 16) & 0xff),
            UInt8((code >> 8) & 0xff), UInt8(code & 0xff),
        ]
        return String(bytes: bytes, encoding: .ascii) ?? ""
    }

    /// Decodes the SMC data types this client reads. Unknown types return nil
    /// so a widget shows "—" instead of a number with the wrong scale.
    static func decode(bytes: [UInt8], type: String) -> Double? {
        switch type {
        case "flt ":
            guard bytes.count >= 4 else { return nil }
            let raw = UInt32(bytes[0]) | UInt32(bytes[1]) << 8
                | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            let value = Double(Float(bitPattern: raw))
            return value.isFinite ? value : nil
        case "sp78":
            guard bytes.count >= 2 else { return nil }
            return Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256
        case "fpe2":
            guard bytes.count >= 2 else { return nil }
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4
        case "ui8 ", "ui8":
            guard let first = bytes.first else { return nil }
            return Double(first)
        case "ui16":
            guard bytes.count >= 2 else { return nil }
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        case "ui32":
            guard bytes.count >= 4 else { return nil }
            return Double(
                UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16
                    | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
            )
        default:
            return nil
        }
    }

    // MARK: SMC ABI

    private static let kSMCHandleYPCEvent: UInt32 = 2
    private static let kSMCReadKey: UInt8 = 5
    private static let kSMCGetKeyFromIndex: UInt8 = 8
    private static let kSMCGetKeyInfo: UInt8 = 9

    private struct SMCVersion {
        var major: CUnsignedChar = 0
        var minor: CUnsignedChar = 0
        var build: CUnsignedChar = 0
        var reserved: CUnsignedChar = 0
        var release: CUnsignedShort = 0
    }

    private struct SMCPLimitData {
        var version: UInt16 = 0
        var length: UInt16 = 0
        var cpuPLimit: UInt32 = 0
        var gpuPLimit: UInt32 = 0
        var memPLimit: UInt32 = 0
    }

    private struct SMCKeyInfoData {
        var dataSize: IOByteCount32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
    }

    private struct SMCParamStruct {
        var key: UInt32 = 0
        var vers = SMCVersion()
        var pLimitData = SMCPLimitData()
        var keyInfo = SMCKeyInfoData()
        var padding: UInt16 = 0
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: (
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
        ) = (
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        )
    }
}

// MARK: - IOHIDEventSystem (Apple Silicon named sensors)

/// Reads the Apple Silicon HID sensor plane.
///
/// `IOHIDEventSystemClient*` is not in the public IOKit headers, so the
/// symbols are resolved with `dlsym` at first use: on a build or an OS where
/// they are missing (or blocked, as under the App Store sandbox) the client
/// simply reports no sensors instead of failing to link or crashing.
final class HIDSensorClient {
    private typealias CreateFn = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
    private typealias SetMatchingFn = @convention(c) (AnyObject?, CFDictionary?) -> Int32
    private typealias CopyServicesFn = @convention(c) (AnyObject?) -> Unmanaged<CFArray>?
    private typealias CopyPropertyFn = @convention(c) (AnyObject?, CFString) -> Unmanaged<CFTypeRef>?
    private typealias CopyEventFn = @convention(c) (AnyObject?, Int64, Int32, UInt64) -> Unmanaged<AnyObject>?
    private typealias EventFloatValueFn = @convention(c) (AnyObject?, Int32) -> Double

    private struct Symbols {
        var create: CreateFn
        var setMatching: SetMatchingFn
        var copyServices: CopyServicesFn
        var copyProperty: CopyPropertyFn
        var copyEvent: CopyEventFn
        var floatValue: EventFloatValueFn
    }

    /// `kIOHIDEventTypeTemperature`, and its level field (`type << 16`).
    private static let temperatureEventType: Int64 = 15
    private static let temperatureField: Int32 = 15 << 16
    /// `kHIDPage_AppleVendor` / `kHIDUsage_AppleVendor_TemperatureSensor`.
    private static let sensorUsagePage = 0xff00
    private static let sensorUsage = 0x0005

    private lazy var symbols: Symbols? = Self.resolveSymbols()
    private var client: AnyObject?
    private var services: [AnyObject]?

    func temperatures() -> [SensorReading] {
        guard let symbols, let services = matchingServices(symbols) else { return [] }
        var readings: [SensorReading] = []
        for service in services {
            guard let event = symbols.copyEvent(
                service, Self.temperatureEventType, 0, 0
            )?.takeRetainedValue() else { continue }
            let value = symbols.floatValue(event, Self.temperatureField)
            guard SensorSampler.isPlausibleTemperature(value) else { continue }
            let name = symbols.copyProperty(service, "Product" as CFString)?
                .takeRetainedValue() as? String ?? "HID sensor"
            readings.append(SensorReading(
                key: name, name: name, kind: .temperature, value: value
            ))
        }
        return readings
    }

    /// The matched service set is stable for the machine, so it is resolved
    /// once and reused — `IOHIDEventSystemClientCopyServices` is the expensive
    /// half of a HID sample.
    private func matchingServices(_ symbols: Symbols) -> [AnyObject]? {
        if let services { return services }
        let client = self.client ?? symbols.create(kCFAllocatorDefault)?.takeRetainedValue()
        guard let client else { return nil }
        self.client = client
        let matching = [
            "PrimaryUsagePage": Self.sensorUsagePage,
            "PrimaryUsage": Self.sensorUsage,
        ] as CFDictionary
        _ = symbols.setMatching(client, matching)
        guard let matched = symbols.copyServices(client)?.takeRetainedValue() as? [AnyObject],
              !matched.isEmpty
        else { return nil }
        // Only a non-empty match is worth keeping: the client can come back
        // empty while IOKit is still matching at launch, and caching that
        // would report "no sensors" for the rest of the process lifetime.
        services = matched
        return matched
    }

    private static func resolveSymbols() -> Symbols? {
        guard let handle = dlopen(
            "/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY
        ) else { return nil }
        func symbol<T>(_ name: String, _ type: T.Type) -> T? {
            guard let pointer = dlsym(handle, name) else { return nil }
            return unsafeBitCast(pointer, to: type)
        }
        guard let create = symbol("IOHIDEventSystemClientCreate", CreateFn.self),
              let setMatching = symbol("IOHIDEventSystemClientSetMatching", SetMatchingFn.self),
              let copyServices = symbol("IOHIDEventSystemClientCopyServices", CopyServicesFn.self),
              let copyProperty = symbol("IOHIDServiceClientCopyProperty", CopyPropertyFn.self),
              let copyEvent = symbol("IOHIDServiceClientCopyEvent", CopyEventFn.self),
              let floatValue = symbol("IOHIDEventGetFloatValue", EventFloatValueFn.self)
        else { return nil }
        return Symbols(
            create: create, setMatching: setMatching, copyServices: copyServices,
            copyProperty: copyProperty, copyEvent: copyEvent, floatValue: floatValue
        )
    }
}
