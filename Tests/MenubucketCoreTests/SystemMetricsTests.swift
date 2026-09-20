import XCTest
@testable import MenubucketCore

/// The sampler talks to Mach / sysctl / IOKit, so these assert the contract a
/// widget template depends on (shape, units, ranges) rather than fixed values.
final class SystemMetricsTests: XCTestCase {
    func testAbsentMetricsListReadsAsUnspecified() {
        XCTAssertNil(SystemMetrics.requestedMetrics(from: nil))
        XCTAssertNil(SystemMetrics.requestedMetrics(from: .array([])))
        XCTAssertEqual(
            SystemMetrics.requestedMetrics(from: .array([.string("cpu"), .string("sensors")])),
            [.cpu, .sensors]
        )
        // Unknown names are dropped, not treated as "everything".
        XCTAssertEqual(
            SystemMetrics.requestedMetrics(from: .array([.string("cpu"), .string("gpu")])),
            [.cpu]
        )
    }

    func testUnspecifiedMetricsTakeTheWholeGrantInsteadOfFailing() {
        // `{ "use": "system" }` with `permissions.system: ["cpu"]` samples CPU
        // — it never asked for the three groups it was not granted.
        let (allowed, denied) = SystemMetrics.authorized(nil, declared: ["cpu"])
        XCTAssertEqual(allowed, [.cpu])
        XCTAssertTrue(denied.isEmpty)

        // An explicit list is still checked against the grant.
        let explicit = SystemMetrics.authorized([.cpu, .sensors], declared: ["cpu"])
        XCTAssertEqual(explicit.allowed, [.cpu])
        XCTAssertEqual(explicit.denied, [.sensors])

        // Declaring nothing still grants nothing.
        XCTAssertTrue(SystemMetrics.authorized(nil, declared: nil).allowed.isEmpty)
        XCTAssertEqual(SystemMetrics.authorized([.cpu], declared: nil).denied, [.cpu])
    }

    func testSampleEmitsOnlyTheRequestedGroups() {
        let object = SystemMetrics.sample(metrics: [.cpu]).objectValue
        XCTAssertNotNil(object?["cpu"])
        XCTAssertNil(object?["memory"])
        XCTAssertNil(object?["disk"])
        XCTAssertNil(object?["sensors"])
        XCTAssertNotNil(object?["sampledAt"])
    }

    func testCPUUsagePercentagesAreInRangeAndSumToTotal() {
        let cpu = SystemMetrics.cpuSampler.sample(detail: true)
        XCTAssertGreaterThan(cpu.coreCount, 0)
        XCTAssertEqual(cpu.cores.count, cpu.coreCount)
        for percentage in [cpu.usage, cpu.user, cpu.system, cpu.nice, cpu.idle] {
            XCTAssertGreaterThanOrEqual(percentage, 0)
            XCTAssertLessThanOrEqual(percentage, 100.01)
        }
        XCTAssertEqual(cpu.usage + cpu.idle, 100, accuracy: 0.01)
        XCTAssertEqual(cpu.loadAverage.count, 3)
    }

    func testPerCoreUsageOnlyPresentWithDetail() {
        XCTAssertTrue(SystemMetrics.cpuSampler.sample(detail: false).cores.isEmpty)
        let plain = SystemMetrics.cpuSampler.sample(detail: false).json.objectValue
        XCTAssertNil(plain?["cores"])
    }

    func testTickDeltaSaturatesInsteadOfWrapping() {
        let older = SystemMetrics.CPUTicks(user: 100, system: 50, idle: 900, nice: 0)
        // A parked core's counters can come back lower than the last reading.
        let reset = SystemMetrics.CPUTicks(user: 10, system: 5, idle: 20, nice: 0)
        let delta = reset.delta(since: older)
        XCTAssertEqual(delta, SystemMetrics.CPUTicks(user: 0, system: 0, idle: 0, nice: 0))
        XCTAssertEqual(reset.usage(since: older), 0, accuracy: 0.0001)
    }

    func testMemoryUsageIsConsistent() {
        let memory = SystemMetrics.memory()
        XCTAssertGreaterThan(memory.total, 0)
        XCTAssertEqual(memory.used, memory.app + memory.wired + memory.compressed, accuracy: 1)
        XCTAssertEqual(memory.used + memory.free, memory.total, accuracy: 1)
        XCTAssertGreaterThanOrEqual(memory.usage, 0)
        XCTAssertLessThanOrEqual(memory.usage, 100)
        XCTAssertTrue(
            ["normal", "warning", "critical", "unknown"].contains(memory.pressure),
            "unexpected pressure level \(memory.pressure)"
        )
    }

    func testDiskUsageIsConsistent() throws {
        let disk = try XCTUnwrap(SystemMetrics.disk())
        XCTAssertEqual(disk.mount, "/")
        XCTAssertGreaterThan(disk.total, 0)
        XCTAssertEqual(disk.used + disk.free, disk.total, accuracy: 1)
        XCTAssertGreaterThanOrEqual(disk.usage, 0)
        XCTAssertLessThanOrEqual(disk.usage, 100)
        XCTAssertNil(SystemMetrics.disk(mountPoint: "/nonexistent-volume-\(UUID().uuidString)"))
    }

    func testSensorJSONKeepsUnavailableFieldsNullRatherThanZero() {
        let empty = SystemMetrics.json(for: SensorSnapshot(), detail: false)
        let object = empty.objectValue
        XCTAssertEqual(object?["available"], .bool(false))
        XCTAssertEqual(object?["cpu"], .null)
        XCTAssertEqual(object?["power"], .null)
        XCTAssertEqual(object?["fans"], .array([]))
        XCTAssertEqual(object?["fanCount"], .number(0))
        XCTAssertNil(object?["list"], "the sensor list is detail-only")
    }

    func testSensorJSONCarriesFanBoundsAndDetailList() {
        let snapshot = SensorSnapshot(
            cpu: 43.5,
            peak: 47.8,
            fans: [FanReading(index: 0, name: "Fan 1", rpm: 2000, minRPM: 1000, maxRPM: 3000)],
            list: [SensorReading(key: "Tp00", name: "CPU core (Tp00)", kind: .temperature, value: 43.5)],
            available: true
        )
        let object = try? XCTUnwrap(SystemMetrics.json(for: snapshot, detail: true).objectValue)
        XCTAssertEqual(object?["cpu"], .number(43.5))
        XCTAssertEqual(object?["gpu"], .null)
        let fan = object?["fans"]?.arrayValue?.first?.objectValue
        XCTAssertEqual(fan?["rpm"], .number(2000))
        XCTAssertEqual(fan?["usage"], .number(50))
        XCTAssertEqual(object?["list"]?.arrayValue?.count, 1)
        XCTAssertEqual(object?["list"]?.arrayValue?.first?.objectValue?["unit"], .string("°C"))
    }

    func testFanUsageNeedsBothBounds() {
        XCTAssertNil(FanReading(index: 0, name: "Fan 1", rpm: 2000).usage)
        XCTAssertNil(
            FanReading(index: 0, name: "Fan 1", rpm: 2000, minRPM: 1000, maxRPM: 1000).usage
        )
        // A reading outside the reported bounds clamps instead of exceeding 100.
        XCTAssertEqual(
            FanReading(index: 0, name: "Fan 1", rpm: 9000, minRPM: 1000, maxRPM: 3000).usage,
            100
        )
    }

    func testImplausibleTemperaturesAreRejected() {
        // The HID plane reports -22.25 °C for channels that are not populated.
        XCTAssertFalse(SensorSampler.isPlausibleTemperature(-22.25))
        XCTAssertFalse(SensorSampler.isPlausibleTemperature(0))
        XCTAssertFalse(SensorSampler.isPlausibleTemperature(500))
        XCTAssertTrue(SensorSampler.isPlausibleTemperature(43.2))
    }

    func testSensorClassificationCoversSMCKeysAndHIDNames() {
        func reading(_ key: String, _ name: String? = nil) -> SensorReading {
            SensorReading(
                key: key,
                name: name ?? SensorSampler.label(forSMCKey: key),
                kind: .temperature,
                value: 40
            )
        }
        XCTAssertTrue(SensorSampler.isCPUSensor(reading("Tp01")))
        XCTAssertTrue(SensorSampler.isCPUSensor(reading("Te05")))
        XCTAssertTrue(SensorSampler.isCPUSensor(reading("SOC MTR Temp Sensor1", "SOC MTR Temp Sensor1")))
        XCTAssertFalse(SensorSampler.isCPUSensor(reading("Tg0j")))
        XCTAssertTrue(SensorSampler.isGPUSensor(reading("Tg0j")))
        XCTAssertTrue(SensorSampler.isBatterySensor(reading("TB0T")))
        XCTAssertTrue(SensorSampler.isBatterySensor(reading("gas gauge battery", "gas gauge battery")))
    }

    func testSMCValueDecoding() {
        // flt is little-endian IEEE 754; 43.5 == 0x422E0000.
        XCTAssertEqual(
            SMCClient.decode(bytes: [0x00, 0x00, 0x2E, 0x42], type: "flt "),
            43.5
        )
        // sp78 is a signed 8.8 fixed-point big-endian value.
        XCTAssertEqual(SMCClient.decode(bytes: [0x2B, 0x80], type: "sp78"), 43.5)
        XCTAssertEqual(SMCClient.decode(bytes: [0xFF, 0x80], type: "sp78"), -0.5)
        XCTAssertEqual(SMCClient.decode(bytes: [0x0B, 0xB8], type: "fpe2"), 750)
        XCTAssertEqual(SMCClient.decode(bytes: [0x07, 0xD0], type: "ui16"), 2000)
        XCTAssertEqual(SMCClient.decode(bytes: [0x2A], type: "ui8 "), 42)
        XCTAssertNil(SMCClient.decode(bytes: [0x00], type: "ch8*"))
        XCTAssertNil(SMCClient.decode(bytes: [], type: "flt "))
    }

    func testFourCharCodeRoundTrips() {
        XCTAssertEqual(SMCClient.fourCharString(SMCClient.fourCharCode("Tp01")), "Tp01")
        XCTAssertEqual(SMCClient.fourCharString(SMCClient.fourCharCode("#KEY")), "#KEY")
    }

    /// Sampling must stay cheap enough for a 2 s menu-bar cadence — that is the
    /// whole reason this source exists instead of the `top`/`memory_pressure`
    /// shell pipeline it replaces.
    func testFullSampleIsFastEnoughForTheMenuBarCadence() {
        _ = SystemMetrics.sample() // warm the SMC key catalog
        let started = Date()
        for _ in 0..<5 { _ = SystemMetrics.sample() }
        let perSample = -started.timeIntervalSinceNow / 5
        XCTAssertLessThan(perSample, 0.2, "a full sample took \(perSample * 1000) ms")
    }

    func testRapidSamplesShareOneMeasurementInsteadOfSplittingTheWindow() {
        let sampler = SystemMetrics.CPUSampler()
        let start = Date()
        let first = sampler.sample(now: start)
        // A second widget reading 10 ms later must not get a delta computed
        // over 10 ms of ticks — that is noise, not a CPU load.
        let second = sampler.sample(now: start.addingTimeInterval(0.01))
        XCTAssertEqual(first, second)

        let later = sampler.sample(now: start.addingTimeInterval(1))
        XCTAssertEqual(later.coreCount, first.coreCount)
    }

    func testDetailIsNotServedFromAPlainCachedSample() {
        let sampler = SystemMetrics.CPUSampler()
        let start = Date()
        _ = sampler.sample(detail: false, now: start)
        // The cached sample has no per-core data, so a detail request inside
        // the window still has to measure.
        let detailed = sampler.sample(detail: true, now: start.addingTimeInterval(0.01))
        XCTAssertEqual(detailed.cores.count, detailed.coreCount)
    }

    func testAPlainCallerNeverSeesPerCoreDataFromACachedDetailSample() {
        let sampler = SystemMetrics.CPUSampler()
        let start = Date()
        let detailed = sampler.sample(detail: true, now: start)
        XCTAssertFalse(detailed.cores.isEmpty)
        // Sharing one sampler must not leak detail-only data into a plain
        // sample — `cores[]` is contractually detail-only.
        let plain = sampler.sample(detail: false, now: start.addingTimeInterval(0.01))
        XCTAssertTrue(plain.cores.isEmpty)
        XCTAssertNil(plain.json.objectValue?["cores"])
        XCTAssertEqual(plain.usage, detailed.usage, accuracy: 0.0001)
    }

    func testAMissingTickReadingReportsNoDataRatherThanTrapping() {
        // `host_processor_info` can fail; the sampler must not index a
        // baseline that does not line up with the reading.
        let empty = SystemMetrics.CPUSampler.unavailable()
        XCTAssertEqual(empty.coreCount, 0)
        XCTAssertTrue(empty.cores.isEmpty)
        XCTAssertEqual(empty.usage, 0)
        XCTAssertEqual(empty.loadAverage.count, 3)
        XCTAssertNil(empty.json.objectValue?["cores"])
    }

    func testPresentedStripsDetailOnlyFieldsForPlainCallers() {
        let detailed = SystemMetrics.CPUUsage(
            usage: 20, user: 15, system: 5, nice: 0, idle: 80,
            coreCount: 2, cores: [10, 30], loadAverage: [1, 1, 1]
        )
        XCTAssertEqual(
            SystemMetrics.CPUSampler.presented(detailed, detail: true).cores, [10, 30]
        )
        XCTAssertTrue(
            SystemMetrics.CPUSampler.presented(detailed, detail: false).cores.isEmpty
        )
    }

    func testResetDropsTheCachedSample() {
        let sampler = SystemMetrics.CPUSampler()
        let start = Date()
        _ = sampler.sample(now: start)
        sampler.reset()
        // After a reset the sampler re-seeds rather than replaying the cache,
        // which is what a wake needs (the old delta spans the sleep).
        let fresh = sampler.sample(now: start.addingTimeInterval(0.01))
        XCTAssertGreaterThan(fresh.coreCount, 0)
    }

}
