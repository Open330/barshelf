import Foundation
import XCTest

@testable import MenubucketCore

/// Measurement harnesses for what a refresh costs, not assertions about it.
///
/// A menu bar reading refreshes every few seconds forever, so its cost while
/// nobody is looking at the card *is* the app's steady-state cost. These
/// printed numbers are how the sensor narrowing in `SensorSampler` and
/// `widget.visible` were chosen, and they are kept so the next change to this
/// path can be measured the same way rather than guessed at.
///
///     BARSHELF_BENCH=1 swift test --filter RefreshCostBenchmarks
///
/// Numbers are hardware-dependent (they count IOKit round trips on the Mac
/// running them), which is why nothing here asserts a threshold.
final class RefreshCostBenchmarks: XCTestCase {
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // MenubucketCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
    }

    override func setUpWithError() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["BARSHELF_BENCH"] == "1",
            "measurement harness; set BARSHELF_BENCH=1"
        )
    }

    /// `%-44@` does not pad on Apple platforms, so the column is built here.
    private static func line(_ label: String, _ ms: Double) -> String {
        let padded = label.padding(toLength: max(label.count, 40), withPad: " ", startingAt: 0)
        return "  " + padded + String(format: " %7.3f ms", ms)
    }

    private func shipped(_ widget: String) throws -> WorkflowDefinition {
        try WorkflowDefinition.decode(from: try Data(
            contentsOf: Self.repoRoot.appendingPathComponent("widgets/\(widget)/workflow.json")
        ))
    }

    private func report(_ label: String, runs: Int = 50, _ body: () throws -> Void) rethrows {
        try body()  // warm
        var total: Double = 0
        for _ in 0..<runs {
            let start = DispatchTime.now().uptimeNanoseconds
            try body()
            total += Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        }
        print(Self.line(label, total / Double(runs)))
    }

    // MARK: Sensors

    /// Every SMC key is its own IOKit round trip, so the sensor sample is
    /// priced in keys. This is the measurement the `sensors` source parameter
    /// exists for.
    func testSensorSampleCost() throws {
        print("SENSORS — what one sample reads")
        let sampler = SensorSampler.shared
        _ = sampler.sample(detail: true)  // warm the key catalog

        let client = SMCClient()
        let catalog = client?.catalog() ?? []
        let temperatures = catalog.filter { $0.key.hasPrefix("T") && $0.isFloatingPoint }
        let summarized = temperatures.filter {
            SensorSampler.summarizedPrefixes.contains($0.key.prefix(2))
        }
        var byGroup: [SensorSampler.SensorGroup: Int] = [:]
        for meta in summarized {
            byGroup[SensorSampler.group(forSMCKey: meta.key), default: 0] += 1
        }
        print("  catalog \(catalog.count) keys, "
            + "\(summarized.count) summarized + \(temperatures.count - summarized.count) extra")
        print("  summarized by group: "
            + byGroup.sorted { $0.key.rawValue < $1.key.rawValue }
                .map { "\($0.key.rawValue)=\($0.value)" }.joined(separator: " "))

        if let client, let meta = summarized.first {
            report("one SMC key", runs: 200) { _ = client.value(meta) }
        }
        report("card open (detail, every group)") { _ = sampler.sample(detail: true) }
        report("menu bar, every group") { _ = sampler.sample(detail: false) }
        report("menu bar, cpu only") { _ = sampler.sample(detail: false, groups: [.cpu]) }
        report("menu bar, no temperatures") { _ = sampler.sample(detail: false, groups: []) }
    }

    /// The same sampling through `Task.detached`, which is how the runtime
    /// calls it — so the harness and the shipped path cannot drift apart.
    func testRuntimeSamplingPathCost() async throws {
        print("SENSORS — through the runtime's detached task")
        _ = SystemMetrics.sample(metrics: [.sensors], detail: true)  // warm

        func measure(
            _ label: String, detail: Bool, groups: Set<SensorSampler.SensorGroup>?
        ) async {
            var total: Double = 0
            for _ in 0..<30 {
                let start = DispatchTime.now().uptimeNanoseconds
                _ = await Task.detached(priority: .userInitiated) {
                    SystemMetrics.sample(
                        metrics: [.sensors], detail: detail, sensorGroups: groups
                    )
                }.value
                total += Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            }
            print(Self.line(label, total / 30))
        }

        await measure("card open (detail, every group)", detail: true, groups: nil)
        await measure("menu bar, every group", detail: false, groups: nil)
        await measure("menu bar, cpu only", detail: false, groups: [.cpu])
        await measure("menu bar, no temperatures", detail: false, groups: [])
    }

    // MARK: Cheap metrics, for comparison

    /// CPU / memory / disk cost roughly nothing next to the sensors — worth
    /// re-checking before optimizing anything on this side of the source.
    func testOtherSystemMetricCost() throws {
        print("SYSTEM — the other metric groups")
        report("cpu (cached sampler)") { _ = SystemMetrics.cpuSampler.sample() }
        report("memory") { _ = SystemMetrics.memory() }
        report("disk") { _ = SystemMetrics.disk(mountPoint: "/") }
    }

    // MARK: Workflow

    /// What a refresh pays after the data is in hand: the workflow file is
    /// re-read and re-decoded every time, then the template is expanded.
    func testWorkflowEvaluationCost() throws {
        print("WORKFLOW — decode and evaluate")
        for name in ["system", "sensors"] {
            let url = Self.repoRoot.appendingPathComponent("widgets/\(name)/workflow.json")
            let data = try Data(contentsOf: url)
            try report("\(name) read + decode (\(data.count) bytes)") {
                _ = try WorkflowDefinition.decode(from: try Data(contentsOf: url))
            }
            try report("\(name) decode only") {
                _ = try WorkflowDefinition.decode(from: data)
            }
        }

        let system = try shipped("system")
        let systemSources: [String: JSONValue] = ["data": SystemMetrics.sample()]
        try report("system evaluate") {
            _ = try WorkflowEngine.evaluate(
                system,
                sources: systemSources,
                settings: .object(["menuBarMetric": .string("cpu")])
            )
        }

        let sensors = try shipped("sensors")
        let sensorSettings: JSONValue = .object([
            "menuBarSensor": .string("cpu"), "unit": .string("celsius"),
        ])
        for visible in [false, true] {
            let payload: [String: JSONValue] = [
                "data": SystemMetrics.sample(metrics: [.sensors], detail: visible)
            ]
            try report("sensors evaluate (visible=\(visible))") {
                _ = try WorkflowEngine.evaluate(
                    sensors, sources: payload, settings: sensorSettings,
                    widget: .object(["size": .string("M"), "visible": .bool(visible)])
                )
            }
        }
    }
}
