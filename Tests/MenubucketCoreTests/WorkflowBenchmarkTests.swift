import Foundation
import XCTest
@testable import MenubucketCore

/// How long the menu bar workflows take to evaluate, in process.
///
/// Off by default (it measures, it doesn't check). Run with
/// `BARSHELF_BENCH=1 swift test -c release --filter WorkflowBenchmarkTests`.
final class WorkflowBenchmarkTests: XCTestCase {
    private let widgets = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("widgets")

    func testMenuBarWorkflowEvaluation() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BARSHELF_BENCH"] == "1", "set BARSHELF_BENCH=1")
        let sample = SystemMetrics.sample(metrics: [.cpu, .memory, .disk, .sensors])
        let context: JSONValue = .object(["visible": .bool(false), "locale": .string("en")])
        for name in ["system", "sensors"] {
            let definition = try JSONDecoder().decode(
                WorkflowDefinition.self, from: Data(contentsOf: widgets.appendingPathComponent("\(name)/workflow.json")))
            let sources = Dictionary(uniqueKeysWithValues: definition.sources.keys.map { ($0, sample) })
            let runs = 2000
            _ = try WorkflowEngine.evaluate(definition, sources: sources, settings: .object([:]), widget: context)
            let start = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<runs {
                _ = try WorkflowEngine.evaluate(definition, sources: sources, settings: .object([:]), widget: context)
            }
            let perRun = Double(DispatchTime.now().uptimeNanoseconds - start) / Double(runs) / 1000
            print("bench \(name): \(String(format: "%.1f", perRun)) µs per evaluation")
        }
    }
}
