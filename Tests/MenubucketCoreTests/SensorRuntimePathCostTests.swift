import Foundation
import XCTest

@testable import MenubucketCore

/// Times the exact call the runtime makes for a menu-bar sensors refresh, so
/// the microbenchmark and the shipped path cannot drift apart.
final class SensorRuntimePathCostTests: XCTestCase {
    func testReportRuntimePathCost() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["BARSHELF_BENCH"] == "1",
            "measurement harness; set BARSHELF_BENCH=1"
        )
        _ = SystemMetrics.sample(metrics: [.sensors], detail: true)  // warm

        func measure(
            _ label: String, detail: Bool, groups: Set<SensorSampler.SensorGroup>?,
            runs: Int = 30
        ) async {
            var total: Double = 0
            for _ in 0..<runs {
                let start = DispatchTime.now().uptimeNanoseconds
                _ = await Task.detached(priority: .userInitiated) {
                    SystemMetrics.sample(
                        metrics: [.sensors], detail: detail, sensorGroups: groups
                    )
                }.value
                total += Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            }
            print(String(format: "RUNTIME PATH %@: %.2f ms", label, total / Double(runs)))
        }

        await measure("card open (detail, all)", detail: true, groups: nil)
        await measure("menu bar, all groups", detail: false, groups: nil)
        await measure("menu bar, cpu only", detail: false, groups: [.cpu])
        await measure("menu bar, no temperatures", detail: false, groups: [])
    }
}
