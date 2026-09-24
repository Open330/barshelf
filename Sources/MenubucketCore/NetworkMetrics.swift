@preconcurrency import Darwin
import Foundation

/// Native network-interface accounting for the `system` workflow source.
///
/// `getifaddrs` exposes the byte counters maintained by the kernel. A counter
/// is cumulative, so `NetworkSampler` keeps a baseline for every interface and
/// only reports a rate after it has seen that interface twice. This avoids a
/// bogus burst when an adapter appears, resets, or returns after disappearing.
public struct NetworkMetrics: Sendable {
    public struct Reading: Equatable, Sendable {
        public var available: Bool
        /// `"all"` for the sensible physical-interface aggregate.
        public var interface: String?
        /// Bytes per second, absent until a valid previous counter exists.
        public var download: Double?
        /// Bytes per second, absent until a valid previous counter exists.
        public var upload: Double?
        /// Cumulative OS-reported received bytes. Older compatibility paths
        /// can wrap; a wrap produces absent rates until a fresh baseline.
        public var received: Double
        /// Cumulative OS-reported sent bytes; see `received` for wrap behavior.
        public var sent: Double
        /// An address for an explicitly selected interface, when published.
        public var address: String?

        var json: JSONValue {
            .object([
                "available": .bool(available),
                "interface": interface.map(JSONValue.string) ?? .null,
                "download": download.map(JSONValue.number) ?? .null,
                "upload": upload.map(JSONValue.number) ?? .null,
                "received": .number(received),
                "sent": .number(sent),
                "address": address.map(JSONValue.string) ?? .null,
            ])
        }
    }

    struct Counters: Equatable, Sendable {
        var received: UInt64
        var sent: UInt64
    }

    struct InterfaceSample: Equatable, Sendable {
        var name: String
        var counters: Counters
        var isUp: Bool
        var isLoopback: Bool
        var isTunnel: Bool
        var address: String?

        /// The aggregate deliberately excludes virtual/tunnel and inactive
        /// interfaces. An explicit `with.interface` request can still inspect
        /// any interface that the kernel reports.
        var isAggregateEligible: Bool {
            // macOS gives Wi-Fi and wired adapters `en*`. Restricting the
            // aggregate to those physical interfaces avoids counting both a
            // bridge and its member, while still covering USB Ethernet.
            isUp && !isLoopback && !isTunnel && name.hasPrefix("en")
        }
    }

    /// Stateful, thread-safe differencer. The injected sampler makes its edge
    /// cases deterministic in tests; production uses `readInterfaces()`.
    public final class Sampler: @unchecked Sendable {
        static let minimumWindow: TimeInterval = 0.25
        /// Longest gap a rate is computed across. Menu bar items can refresh
        /// as slowly as once a minute, and the refresh multiplier and timer
        /// tolerance stretch that further; a 30 s window left such an item
        /// showing "—" forever. Fifteen minutes still refuses to average
        /// across a long sleep.
        static let maximumWindow: TimeInterval = 15 * 60

        private let lock = NSLock()
        private var previous: [String: (counters: Counters, at: TimeInterval)] = [:]
        private var current: [String: InterfaceSample] = [:]
        private var rates: [String: (download: Double, upload: Double)] = [:]
        private var lastSampleAt: TimeInterval?

        public init() {}

        public func sample(interface: String? = nil) -> Reading {
            let interface = Self.normalizedInterface(interface)
            lock.lock()
            defer { lock.unlock() }
            // Read after acquiring the lock so a queued caller cannot install
            // an older timestamp after a newer completed sample.
            // Sleep counts: a night asleep must exceed `maximumWindow` and
            // re-baseline, not pass for a few seconds of traffic.
            let now = SleepAwareClock.now()
            if let lastSampleAt, now - lastSampleAt < Self.minimumWindow {
                return presented(interface: interface)
            }
            return sampleLocked(interfaces: readInterfaces(), interface: interface, now: now)
        }

        func sample(
            interfaces: [InterfaceSample],
            interface requestedInterface: String? = nil,
            now: TimeInterval
        ) -> Reading {
            let requestedInterface = Self.normalizedInterface(requestedInterface)
            lock.lock()
            defer { lock.unlock() }
            if let lastSampleAt, now - lastSampleAt >= 0, now - lastSampleAt < Self.minimumWindow {
                return presented(interface: requestedInterface)
            }
            return sampleLocked(interfaces: interfaces, interface: requestedInterface, now: now)
        }

        private func sampleLocked(
            interfaces: [InterfaceSample],
            interface requestedInterface: String?,
            now: TimeInterval
        ) -> Reading {
            current = Dictionary(uniqueKeysWithValues: interfaces.map { ($0.name, $0) })
            rates = [:]

            for (name, item) in current where item.isUp {
                if let before = previous[name], now > before.at,
                   now - before.at <= Self.maximumWindow,
                   item.counters.received >= before.counters.received,
                   item.counters.sent >= before.counters.sent {
                    let interval = now - before.at
                    rates[name] = (
                        Double(item.counters.received - before.counters.received) / interval,
                        Double(item.counters.sent - before.counters.sent) / interval
                    )
                }
            }
            // Discard vanished interfaces. If one returns later it must earn a
            // fresh baseline instead of being differenced across an absence.
            previous = Dictionary(uniqueKeysWithValues: current.filter { $0.value.isUp }.map { name, item in
                (name, (item.counters, now))
            })
            lastSampleAt = now
            return presented(interface: requestedInterface)
        }

        private func presented(interface requestedInterface: String?) -> Reading {
            let selection: [InterfaceSample]
            let label: String?
            let address: String?
            if let requestedInterface, requestedInterface != "all" {
                selection = current[requestedInterface].flatMap { $0.isUp ? [$0] : [] } ?? []
                label = requestedInterface
                address = selection.first?.address
            } else {
                selection = current.values.filter(\.isAggregateEligible)
                label = "all"
                // An aggregate cannot claim a single interface, but a stable
                // representative local address is useful in a compact widget.
                address = selection.sorted { $0.name < $1.name }.compactMap(\.address).first
            }

            let received = selection.reduce(UInt64(0)) { $0 &+ $1.counters.received }
            let sent = selection.reduce(UInt64(0)) { $0 &+ $1.counters.sent }
            let selectedRates = selection.compactMap { rates[$0.name] }
            return Reading(
                available: !selection.isEmpty,
                interface: label,
                download: selectedRates.isEmpty ? nil : selectedRates.reduce(0) { $0 + $1.download },
                upload: selectedRates.isEmpty ? nil : selectedRates.reduce(0) { $0 + $1.upload },
                received: Double(received),
                sent: Double(sent),
                address: address
            )
        }

        public func reset() {
            lock.lock()
            previous = [:]
            current = [:]
            rates = [:]
            lastSampleAt = nil
            lock.unlock()
        }

        private static func normalizedInterface(_ value: String?) -> String? {
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    static let shared = Sampler()

    private static func readInterfaces() -> [InterfaceSample] {
        let counters = readCounters()
        guard !counters.isEmpty else { return [] }
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let head else { return [] }
        defer { freeifaddrs(head) }

        var flags: [String: UInt32] = [:]
        var ipv4: [String: String] = [:]
        var ipv6: [String: String] = [:]
        var cursor: UnsafeMutablePointer<ifaddrs>? = head
        while let node = cursor {
            let item = node.pointee
            cursor = item.ifa_next
            guard let namePointer = item.ifa_name, let address = item.ifa_addr else { continue }
            let name = String(cString: namePointer)
            flags[name] = item.ifa_flags
            switch Int32(address.pointee.sa_family) {
            case AF_LINK:
                continue
            case AF_INET:
                if ipv4[name] == nil { ipv4[name] = numericAddress(address, family: AF_INET) }
            case AF_INET6:
                if ipv6[name] == nil { ipv6[name] = numericAddress(address, family: AF_INET6) }
            default:
                continue
            }
        }

        return counters.map { name, bytes in
            let interfaceFlags = flags[name] ?? 0
            return InterfaceSample(
                name: name,
                counters: bytes,
                isUp: interfaceFlags & UInt32(IFF_UP) != 0
                    && interfaceFlags & UInt32(IFF_RUNNING) != 0,
                isLoopback: interfaceFlags & UInt32(IFF_LOOPBACK) != 0,
                isTunnel: Self.isTunnel(name: name, flags: interfaceFlags),
                address: ipv4[name] ?? ipv6[name]
            )
        }
    }

    /// Enumerate interface indices through routing messages, then request
    /// their 64-bit accounting data. `getifaddrs` supplies flags and addresses.
    private static func readCounters() -> [String: Counters] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        let maximumBufferSize = 16 * 1024 * 1024
        var byteCount = 0
        let sizeResult = mib.withUnsafeMutableBufferPointer {
            sysctl($0.baseAddress, u_int($0.count), nil, &byteCount, nil, 0)
        }
        guard sizeResult == 0, byteCount > 0, byteCount <= maximumBufferSize else { return [:] }
        var buffer = [UInt8](repeating: 0, count: byteCount)
        let readResult = buffer.withUnsafeMutableBytes { bytes in
            mib.withUnsafeMutableBufferPointer {
                sysctl($0.baseAddress, u_int($0.count), bytes.baseAddress, &byteCount, nil, 0)
            }
        }
        guard readResult == 0 else { return [:] }

        var result: [String: Counters] = [:]
        buffer.withUnsafeBytes { bytes in
            var offset = 0
            while offset < byteCount {
                // Every routing message starts with msglen/version/type. Do
                // not decode a full `if_msghdr2` until this is an IFINFO2
                // record: address and route records between interfaces are
                // much smaller.
                guard offset + 4 <= byteCount else { break }
                let messageLength = Int(bytes.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
                let messageType = bytes.load(fromByteOffset: offset + 3, as: UInt8.self)
                guard messageLength > 0, offset + messageLength <= byteCount else { break }
                guard messageType == UInt8(RTM_IFINFO2) else {
                    offset += messageLength
                    continue
                }
                guard messageLength >= MemoryLayout<if_msghdr2>.size else { break }
                let header = bytes.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                // The routing payload may omit/redact the AF_LINK name. The
                // header index is authoritative and works for such records.
                var nameBuffer = [CChar](repeating: 0, count: Int(IFNAMSIZ))
                guard if_indextoname(UInt32(header.ifm_index), &nameBuffer) != nil else {
                    offset += messageLength
                    continue
                }
                let name = String(cString: nameBuffer)
                // Older systems can reject IFMIB_IFDATA. Preserve a useful
                // (but potentially wrapped) compatibility fallback there.
                result[name] = readCounters(interfaceIndex: header.ifm_index) ?? Counters(
                    received: header.ifm_data.ifi_ibytes,
                    sent: header.ifm_data.ifi_obytes
                )
                offset += messageLength
            }
        }
        return result
    }

    /// `NET_RT_IFLIST2` can expose 32-bit-wrapped fields on compatibility paths. `IFMIB_IFDATA` returns the per-interface native
    /// 64-bit `if_data64` values, including when this app is built with an
    /// older deployment target. Its unavailable fallback is the OS-reported
    /// routing counter, which may wrap on older compatibility paths.
    private static func readCounters(interfaceIndex: UInt16) -> Counters? {
        var mib: [Int32] = [
            CTL_NET, PF_LINK, NETLINK_GENERIC, IFMIB_IFDATA,
            Int32(interfaceIndex), IFDATA_GENERAL,
        ]
        var data = ifmibdata()
        var byteCount = MemoryLayout<ifmibdata>.size
        let result = mib.withUnsafeMutableBufferPointer {
            sysctl($0.baseAddress, u_int($0.count), &data, &byteCount, nil, 0)
        }
        guard result == 0, byteCount >= MemoryLayout<ifmibdata>.size else { return nil }
        return Counters(received: data.ifmd_data.ifi_ibytes, sent: data.ifmd_data.ifi_obytes)
    }

    private static func isTunnel(name: String, flags: UInt32) -> Bool {
        if flags & UInt32(IFF_POINTOPOINT) != 0 { return true }
        return ["utun", "ipsec", "gif", "stf", "ppp"].contains { name.hasPrefix($0) }
    }

    private static func numericAddress(_ address: UnsafeMutablePointer<sockaddr>, family: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result: UnsafePointer<CChar>?
        if family == AF_INET {
            var socketAddress = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            result = withUnsafePointer(to: &socketAddress.sin_addr) {
                inet_ntop(family, $0, &buffer, socklen_t(buffer.count))
            }
        } else {
            var socketAddress = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee }
            result = withUnsafePointer(to: &socketAddress.sin6_addr) {
                inet_ntop(family, $0, &buffer, socklen_t(buffer.count))
            }
        }
        return result.map { String(cString: $0) }
    }
}
