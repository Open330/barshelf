import XCTest
@testable import MenubucketCore

/// The bundled System widget's real status, evaluated against a stand-in for
/// the system source.
final class SystemTintExpressionTests: XCTestCase {
    private func shipped() throws -> WorkflowDefinition {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("widgets/system/workflow.json")
        return try JSONDecoder().decode(WorkflowDefinition.self, from: Data(contentsOf: url))
    }

    private func evaluate(_ settings: [String: String], memory: Double = 50, pressure: String = "normal")
        throws -> WorkflowEngine.Output
    {
        let sources: [String: JSONValue] = [
            "data": .object([
                "memory": .object([
                    "usage": .number(memory), "used": .number(12e9), "free": .number(4e9),
                    "pressure": .string(pressure),
                    "swap": .object(["used": .number(1.5e9)]),
                ]),
                "disk": .object(["usage": .number(1), "free": .number(245e9),
                                 "read": .number(3_400_000), "write": .null]),
                "cpu": .object(["usage": .number(1), "user": .number(0.6), "system": .number(0.4),
                                "coreMax": .number(97)]),
            ])
        ]
        return try WorkflowEngine.evaluate(
            try shipped(), sources: sources, settings: .object(settings.mapValues(JSONValue.string))
        )
    }

    func testTheShippedExpressionColoursByThreshold() throws {
        XCTAssertEqual(try evaluate(["menuBarMetric": "memory"], memory: 95).statusTint, "danger")
        XCTAssertEqual(try evaluate(["menuBarMetric": "memory"], memory: 80).statusTint, "warning")
        XCTAssertEqual(try evaluate(["menuBarMetric": "memory"], memory: 20).statusTint, "")
        XCTAssertEqual(try evaluate(["menuBarMetric": "cpuCore"]).statusTint, "",
                       "only the machine-wide percentages carry the built-in colours")
        XCTAssertEqual(try evaluate(["menuBarMetric": "pressure"], pressure: "critical").statusTint, "danger")
        XCTAssertEqual(try evaluate(["menuBarMetric": "memory", "menuBarMemoryDisplay": "used"], memory: 95).statusTint,
                       "danger", "shown as bytes, memory is still judged by its usage")
        let second = try evaluate(["menuBarMetric": "cpu", "menuBarSecondary": "memory"], memory: 96)
        XCTAssertEqual(second.statusMetrics?.last?.tint, "danger", "the second slot colours like the first")
    }

    func testTheNewReadings() throws {
        func first(_ settings: [String: String]) throws -> StatusMetric? {
            MenuBarPolicy.normalizedMetrics(try evaluate(settings).statusMetrics ?? []).first
        }
        XCTAssertEqual(try first(["menuBarMetric": "cpuCore"])?.number, 97)
        XCTAssertEqual(try first(["menuBarMetric": "cpuUser"])?.label, "User")
        XCTAssertEqual(try first(["menuBarMetric": "swap"])?.format, "bytes")
        XCTAssertEqual(try first(["menuBarMetric": "diskFree"])?.number, 245e9)
        XCTAssertEqual(try first(["menuBarMetric": "diskRead"])?.format, "bytesPerSecond")
        XCTAssertNil(try first(["menuBarMetric": "diskWrite"])?.number, "no rate yet is —, not 0")

        let pressure = try first(["menuBarMetric": "pressure"])
        XCTAssertEqual(pressure?.value, "Normal")
        XCTAssertNil(pressure?.number)
        XCTAssertEqual(try evaluate(["menuBarMetric": "diskRead"]).statusLabel, "3.4 MB/s")
        XCTAssertEqual(try evaluate(["menuBarMetric": "diskFree"]).statusLabel, "245 GB")
        XCTAssertTrue(try XCTUnwrap(evaluate(["menuBarMetric": "diskRead"]).statusTooltip).hasPrefix("Disk read 3.4 MB/s"),
                      "the tooltip names what the item shows")
    }

    func testASecondReading() throws {
        let output = try evaluate(["menuBarMetric": "cpu", "menuBarSecondary": "memory"])
        let metrics = MenuBarPolicy.normalizedMetrics(output.statusMetrics ?? [])
        XCTAssertEqual(metrics.map(\.id), ["cpu", "memory"])
        XCTAssertEqual(metrics.map(\.label), ["CPU", "RAM"])
        XCTAssertEqual(MenuBarPolicy.normalizedMetrics(try evaluate([:]).statusMetrics ?? []).count, 1)
        let same = try evaluate(["menuBarMetric": "cpu", "menuBarSecondary": "cpu"])
        XCTAssertEqual(MenuBarPolicy.normalizedMetrics(same.statusMetrics ?? []).count, 1, "the same reading twice is shown once")
        let pending = try evaluate(["menuBarMetric": "cpu", "menuBarSecondary": "diskWrite"])
        let rows = MenuBarPolicy.normalizedMetrics(pending.statusMetrics ?? [])
        XCTAssertEqual(rows.count, 2, "a rate with no value yet keeps its place and shows —")
        XCTAssertEqual(MenuBarPolicy.formattedMetricValue(rows[1], presentation: .init()), "—")
    }

    func testDiskThroughputIsAskedForOnlyWhenShown() throws {
        func io(_ settings: [String: String]) throws -> JSONValue? {
            try WorkflowEngine.resolvedSourceParams(
                try shipped(), settings: .object(settings.mapValues(JSONValue.string))
            )["data"]?.objectValue?["io"]
        }
        XCTAssertEqual(try io(["menuBarMetric": "cpu"]), .bool(false))
        XCTAssertEqual(try io(["menuBarMetric": "diskRead"]), .bool(true))
        XCTAssertEqual(try io(["menuBarMetric": "cpu", "menuBarSecondary": "diskWrite"]), .bool(true))
    }
}
