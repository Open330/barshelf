import Foundation
import XCTest

@testable import MenubucketCore

/// Not an assertion of speed — a measurement harness. `detail` reads every
/// temperature key the SMC publishes; the menu bar only ever shows the
/// summary, so the difference is what an always-on `detail: true` costs.
final class SensorSampleCostTests: XCTestCase {
    func testReportSampleCost() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["BARSHELF_BENCH"] == "1",
            "measurement harness; set BARSHELF_BENCH=1"
        )
        let sampler = SensorSampler.shared
        _ = sampler.sample(detail: true)  // warm the catalog

        func measure(detail: Bool, runs: Int = 40) -> Double {
            var total: Double = 0
            for _ in 0..<runs {
                let start = DispatchTime.now().uptimeNanoseconds
                _ = sampler.sample(detail: detail)
                total += Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            }
            return total / Double(runs)
        }

        func measureGrouped(_ groups: Set<SensorSampler.SensorGroup>?, runs: Int = 40) -> Double {
            var total: Double = 0
            for _ in 0..<runs {
                let start = DispatchTime.now().uptimeNanoseconds
                _ = sampler.sample(detail: false, groups: groups)
                total += Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            }
            return total / Double(runs)
        }

        let plain = measure(detail: false)
        let full = measure(detail: true)
        print(String(
            format: "SENSOR SAMPLE: plain %.2f ms, detail %.2f ms (%.1fx)",
            plain, full, full / max(plain, 0.0001)
        ))
        let cpuOnly = measureGrouped([.cpu])
        let none = measureGrouped([])
        print(String(
            format: "SENSOR SAMPLE: cpu-only %.2f ms, no temperatures %.2f ms"
                + " — menu bar goes %.2f ms -> %.2f ms (%.1fx)",
            cpuOnly, none, full, cpuOnly, full / max(cpuOnly, 0.0001)
        ))

        let snapshot = sampler.sample(detail: true)
        print("SENSOR KEYS: list=\(snapshot.list.count) fans=\(snapshot.fans.count)")

        // Where the plain sample goes: one IOKit round trip per key.
        let client = SMCClient()
        let catalog = client?.catalog() ?? []
        let primary = catalog.filter {
            $0.key.hasPrefix("T") && $0.isFloatingPoint
                && SensorSampler.summarizedPrefixes.contains($0.key.prefix(2))
        }
        let extra = catalog.filter {
            $0.key.hasPrefix("T") && $0.isFloatingPoint
                && !SensorSampler.summarizedPrefixes.contains($0.key.prefix(2))
        }
        print("SMC CATALOG: total=\(catalog.count) primary=\(primary.count) extra=\(extra.count)")
        var byPrefix: [String: Int] = [:]
        for meta in primary {
            byPrefix[String(meta.key.prefix(2)), default: 0] += 1
        }
        print("PRIMARY BY PREFIX: \(byPrefix.sorted { $0.key < $1.key })")
        let snap = sampler.sample(detail: true)
        let cpuKeys = snap.list.filter { SensorSampler.isCPUSensor($0) }
        let gpuKeys = snap.list.filter { SensorSampler.isGPUSensor($0) }
        let batteryKeys = snap.list.filter { SensorSampler.isBatterySensor($0) }
        print("CLASSIFIED: cpu=\(cpuKeys.count) gpu=\(gpuKeys.count) battery=\(batteryKeys.count)")

        if let client, let meta = primary.first {
            var total: Double = 0
            let runs = 200
            for _ in 0..<runs {
                let start = DispatchTime.now().uptimeNanoseconds
                _ = client.value(meta)
                total += Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            }
            print(String(format: "SMC READ: %.4f ms per key", total / Double(runs)))
        }

        // CPU / memory / disk, for comparison with the sensor cost.
        func time(_ label: String, runs: Int = 50, _ body: () -> Void) {
            body()
            var total: Double = 0
            for _ in 0..<runs {
                let start = DispatchTime.now().uptimeNanoseconds
                body()
                total += Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            }
            print(String(format: "%@: %.3f ms", label, total / Double(runs)))
        }
        time("CPU") { _ = SystemMetrics.cpuSampler.sample(detail: false) }
        time("MEMORY") { _ = SystemMetrics.memory() }
        time("DISK") { _ = SystemMetrics.disk(mountPoint: "/") }
    }
}
