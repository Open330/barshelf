import Foundation
import XCTest

@testable import MenubucketCore

/// Measurement harness: what a refresh costs *after* the data is in hand.
/// A widget promoted to the menu bar re-expands its whole card template on
/// every tick, for a card nobody is looking at.
final class WorkflowEvaluationCostTests: XCTestCase {
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func shipped(_ widget: String) throws -> WorkflowDefinition {
        try WorkflowDefinition.decode(from: try Data(
            contentsOf: Self.repoRoot.appendingPathComponent("widgets/\(widget)/workflow.json")
        ))
    }

    private func time(_ label: String, runs: Int = 200, _ body: () throws -> Void) rethrows {
        try body()
        var total: Double = 0
        for _ in 0..<runs {
            let start = DispatchTime.now().uptimeNanoseconds
            try body()
            total += Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        }
        print(String(format: "%@: %.3f ms", label, total / Double(runs)))
    }

    func testReportEvaluationCost() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["BARSHELF_BENCH"] == "1",
            "measurement harness; set BARSHELF_BENCH=1"
        )

        // What every refresh pays before it evaluates anything: the workflow
        // file is re-read and re-decoded from disk each time.
        for widget in ["system", "sensors"] {
            let url = Self.repoRoot.appendingPathComponent("widgets/\(widget)/workflow.json")
            let bytes = try Data(contentsOf: url).count
            try time("\(widget) read + decode workflow.json (\(bytes) bytes)") {
                _ = try WorkflowDefinition.decode(from: try Data(contentsOf: url))
            }
            let data = try Data(contentsOf: url)
            try time("\(widget) decode only") {
                _ = try WorkflowDefinition.decode(from: data)
            }
        }

        let system = try shipped("system")
        let systemSources: [String: JSONValue] = ["data": SystemMetrics.sample()]
        let systemSettings: JSONValue = .object(["menuBarMetric": .string("cpu")])
        try time("system evaluate") {
            _ = try WorkflowEngine.evaluate(
                system, sources: systemSources, settings: systemSettings
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
            try time("sensors evaluate (visible=\(visible))") {
                _ = try WorkflowEngine.evaluate(
                    sensors, sources: payload, settings: sensorSettings,
                    widget: .object(["size": .string("M"), "visible": .bool(visible)])
                )
            }
        }

        // Where the time goes inside evaluate(): the JSON round trip that
        // turns the expanded template into a UINode.
        let expandedView = try WorkflowEngine.evaluate(
            system, sources: systemSources, settings: systemSettings
        ).viewTree
        try time("system view JSON round trip") {
            let data = try JSONEncoder().encode(expandedView)
            _ = try JSONDecoder().decode(UINode.self, from: data)
        }
    }
}
