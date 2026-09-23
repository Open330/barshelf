import XCTest
@testable import MenubucketCore

final class StatusMetricWidgetTests: XCTestCase {
    private func workflow(_ name: String) throws -> WorkflowDefinition {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try WorkflowDefinition.decode(
            from: Data(contentsOf: root.appendingPathComponent("widgets/\(name)/workflow.json"))
        )
    }

    func testSystemPublishesTheSelectedMetricAsANumber() throws {
        let source: [String: JSONValue] = ["data": .object([
            "cpu": .object(["usage": .number(23.4), "loadAverage": .object(["1m": .number(1)])]),
            "memory": .object(["usage": .number(62), "used": .number(12_345_678_901), "free": .number(3_000_000_000)]),
            "disk": .object(["usage": .number(81.2)]),
        ])]

        func metric(_ settings: [String: JSONValue]) throws -> StatusMetric? {
            try WorkflowEngine.evaluate(try workflow("system"), sources: source, settings: .object(settings))
                .statusMetrics?.first
        }

        let cpu = try XCTUnwrap(metric([:]))
        XCTAssertEqual(cpu.id, "cpu")
        XCTAssertEqual(cpu.label, "CPU")
        XCTAssertEqual(cpu.number, 23.4)
        XCTAssertEqual(cpu.format, "percent")
        XCTAssertEqual(cpu.precision, 0)

        let ram = try XCTUnwrap(metric(["menuBarMetric": .string("memory"), "menuBarMemoryDisplay": .string("used")]))
        XCTAssertEqual(ram.id, "memory")
        XCTAssertEqual(ram.label, "RAM")
        XCTAssertEqual(ram.number, 12_345_678_901)
        XCTAssertEqual(ram.format, "bytes")
        let ramOutput = try WorkflowEngine.evaluate(
            try workflow("system"), sources: source,
            settings: .object(["menuBarMetric": .string("memory"), "menuBarMemoryDisplay": .string("used")])
        )
        XCTAssertEqual(ramOutput.statusLabel, "12.3 GB")

        let disk = try XCTUnwrap(metric(["menuBarMetric": .string("disk")]))
        XCTAssertEqual(disk.id, "disk")
        XCTAssertEqual(disk.label, "Disk")
        XCTAssertEqual(disk.number, 81.2)
        XCTAssertEqual(disk.format, "percent")
    }

    func testSensorMetricCarriesTheSelectedReadingAndNeverTurnsMissingPowerIntoZero() throws {
        let sensors: JSONValue = .object([
            "available": .bool(true), "cpu": .number(51.8), "gpu": .number(46),
            "battery": .number(34), "peak": .number(57), "power": .null,
            "fans": .array([.object(["rpm": .number(2100), "usage": .number(42)])]),
        ])
        func output(_ settings: [String: JSONValue]) throws -> WorkflowEngine.Output {
            try WorkflowEngine.evaluate(try workflow("sensors"),
                                        sources: ["data": .object(["sensors": sensors])],
                                        settings: .object(settings))
        }

        let cpu = try XCTUnwrap(try output([:]).statusMetrics?.first)
        XCTAssertEqual(cpu.id, "cpu")
        XCTAssertEqual(cpu.number, 51.8)
        XCTAssertEqual(cpu.format, "decimal")
        XCTAssertEqual(cpu.unit, "°C")
        XCTAssertEqual(cpu.precision, 0)

        let power = try output(["menuBarSensor": .string("power")])
        XCTAssertNil(power.statusMetrics?.first?.number)
        XCTAssertEqual(power.statusTooltip, "Power unavailable")

        let fan = try XCTUnwrap(try output(["menuBarSensor": .string("fan")]).statusMetrics?.first)
        XCTAssertEqual(fan.number, 2100)
        XCTAssertEqual(fan.unit, "rpm")
        XCTAssertEqual(fan.precision, 0)
    }

    func testNetworkKeepsLegacySpeedTextWhilePublishingRawRates() throws {
        let output = try WorkflowEngine.evaluate(
            try workflow("network"),
            sources: ["data": .object(["network": .object([
                "available": .bool(true), "interface": .string("en0"), "address": .string("192.168.0.4"),
                "download": .number(1_250_000), "upload": .number(500),
                "received": .number(0), "sent": .number(0),
            ])])],
            settings: .object(["menuBarDisplay": .string("speed"), "interface": .string("all")])
        )
        XCTAssertEqual(output.statusPresentation?.showValues, true)
        XCTAssertEqual(output.statusMetrics?.map(\.id), ["download", "upload"])
        XCTAssertEqual(output.statusMetrics?.map(\.number), [1_250_000, 500])
        XCTAssertEqual(output.statusMetrics?.map(\.format), ["bytesPerSecond", "bytesPerSecond"])
        XCTAssertEqual(output.statusMetrics?.map(\.value), ["1.3 MB/s", "500 B/s"])
    }
}
