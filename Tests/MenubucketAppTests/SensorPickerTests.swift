import XCTest
@testable import MenubucketCore
@testable import MenubucketApp

/// Picking a specific sensor, a second reading and the hottest-sensor
/// aggregate: the shipped Sensors workflow against a stand-in source, and the
/// host's parsing of the `sensors` param.
final class SensorPickerTests: XCTestCase {
    private func shipped() throws -> WorkflowDefinition {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("widgets/sensors/workflow.json")
        return try JSONDecoder().decode(WorkflowDefinition.self, from: Data(contentsOf: url))
    }

    private func reading(_ key: String, _ name: String, _ kind: String, _ value: Double, _ unit: String) -> JSONValue {
        .object(["key": .string(key), "name": .string(name), "kind": .string(kind),
                 "value": .number(value), "unit": .string(unit)])
    }

    private func source(picked: [JSONValue] = []) -> [String: JSONValue] {
        ["data": .object(["sensors": .object([
            "available": .bool(true),
            "cpu": .number(60), "cpuMax": .number(78), "gpu": .number(50), "gpuMax": .null,
            "battery": .number(30), "peak": .number(81), "power": .number(12.4),
            "fanCount": .number(1),
            "fans": .array([.object(["rpm": .number(2400), "usage": .number(40)])]),
            "picked": picked.first.flatMap { $0 == .null ? nil : $0 } ?? .null,
            "pickedList": .array(picked),
        ])])]
    }

    private func settings(_ values: [String: String]) -> JSONValue {
        var object: [String: JSONValue] = [
            "menuBarSensor": .string("cpu"), "menuBarSecondary": .string("none"),
            "aggregate": .string("average"), "unit": .string("celsius"),
        ]
        for (key, value) in values { object[key] = .string(value) }
        return .object(object)
    }

    private func metrics(_ values: [String: String], picked: [JSONValue] = []) throws -> [StatusMetric] {
        let output = try WorkflowEngine.evaluate(try shipped(), sources: source(picked: picked), settings: settings(values))
        return MenuBarPolicy.normalizedMetrics(output.statusMetrics ?? [])
    }

    func testDefaultIsOneCPUReading() throws {
        let shown = try metrics([:])
        XCTAssertEqual(shown.count, 1, "no second reading means no second metric")
        XCTAssertEqual(shown.first?.number, 60)
        XCTAssertEqual(shown.first?.unit, "°C")
        XCTAssertEqual(shown.first?.label, "CPU")
        XCTAssertEqual(shown.first?.accessibilityLabel, "CPU temperature 60 °C")
    }

    func testHottestAggregate() throws {
        XCTAssertEqual(try metrics(["aggregate": "hottest"]).first?.number, 78)
        XCTAssertEqual(try metrics(["aggregate": "hottest"]).first?.accessibilityLabel, "Hottest CPU 78 °C")
        XCTAssertEqual(try metrics(["aggregate": "hottest", "menuBarSensor": "gpu"]).first?.number, 50,
                       "a host without the max falls back to the average")
    }

    func testASpecificSensor() throws {
        let picked = [reading("Tp09", "CPU core (Tp09)", "temperature", 71.5, "°C")]
        let shown = try metrics(["menuBarSensor": "key:Tp09", "unit": "fahrenheit"], picked: picked)
        XCTAssertEqual(shown.first?.id, "key:Tp09")
        XCTAssertEqual(shown.first?.label, "Tp09")
        XCTAssertEqual(try XCTUnwrap(shown.first?.number), 71.5 * 1.8 + 32, accuracy: 0.001)
        XCTAssertEqual(shown.first?.unit, "°F")
        let output = try WorkflowEngine.evaluate(try shipped(), sources: source(picked: picked),
                                                 settings: settings(["menuBarSensor": "key:Tp09"]))
        XCTAssertEqual(output.statusPrefix, "Tp09")
    }

    func testTwoReadings() throws {
        let shown = try metrics(["menuBarSecondary": "power"])
        XCTAssertEqual(shown.map(\.id), ["cpu", "power"])
        XCTAssertEqual(shown.last?.number, 12.4)
        XCTAssertEqual(shown.last?.unit, "W")

        let fanKey = reading("F0Ac", "Fan 1", "fan", 2400, "rpm")
        let temp = reading("Tp09", "CPU core (Tp09)", "temperature", 70, "°C")
        let both = try metrics(["menuBarSensor": "key:Tp09", "menuBarSecondary": "key:F0Ac"], picked: [temp, fanKey])
        XCTAssertEqual(both.map(\.number), [70, 2400], "the second key is the second picked reading")
        XCTAssertEqual(both.last?.unit, "rpm")
        XCTAssertEqual(both.map(\.label), ["Tp09", "Fan"], "a fan or power key is named by what it is")
        let secondOnly = try metrics(["menuBarSecondary": "key:F0Ac"], picked: [fanKey])
        XCTAssertEqual(secondOnly.last?.number, 2400, "with a plain first reading the key is the first picked")
    }

    func testAMissingFirstKeyDoesNotShiftTheSecond() throws {
        // Synced from another Mac: the first sensor is not here, the second is.
        let gpu = reading("Tg0f", "GPU (Tg0f)", "temperature", 44, "°C")
        let shown = try metrics(["menuBarSensor": "key:Tp1F", "menuBarSecondary": "key:Tg0f"], picked: [.null, gpu])
        XCTAssertEqual(shown.first?.id, "key:Tp1F")
        XCTAssertNil(shown.first?.number, "the missing sensor shows —, not the GPU's value")
        XCTAssertEqual(shown.last?.number, 44)
    }

    func testAMissingPickedSensorShowsNothingRatherThanFailing() throws {
        let output = try WorkflowEngine.evaluate(try shipped(), sources: source(),
                                                 settings: settings(["menuBarSensor": "key:ZZZZ"]))
        XCTAssertEqual(output.statusLabel, "")
        XCTAssertEqual(output.statusTooltip, "Sensor unavailable")
    }

    func testTheSourceIsAskedForTheKeys() throws {
        let params = try WorkflowEngine.resolvedSourceParams(
            try shipped(), settings: settings(["menuBarSensor": "key:Tp09", "menuBarSecondary": "power"]),
            widget: .object(["visible": .bool(false)])
        )
        let sensors = params["data"]?.objectValue?["sensors"]
        XCTAssertEqual(WidgetRuntime.sensorKeys(from: sensors), ["Tp09"])
        XCTAssertEqual(WidgetRuntime.sensorGroups(from: sensors), [], "a key and power need no temperature group")
    }

    func testSensorKeyParsing() {
        XCTAssertEqual(SensorSampler.pickedKey("key:TC0P"), "TC0P")
        XCTAssertEqual(SensorSampler.pickedKey("key:PMU tdie1"), "PMU tdie1")
        XCTAssertNil(SensorSampler.pickedKey("KEY:Tp09"), "exactly the prefix the workflow tests for")
        XCTAssertNil(SensorSampler.pickedKey("key:"))
        XCTAssertNil(SensorSampler.pickedKey("cpu"))
        XCTAssertEqual(SensorSampler.groups(forReading: "key:Tp09"), [])
        let many = JSONValue.array((0..<12).map { .string("key:K\($0)") } + [.string("key:K1")])
        XCTAssertEqual(WidgetRuntime.sensorKeys(from: many).count, 8)
    }
}

/// The real sampler, on a Mac that has sensors (skipped in a VM).
final class SensorSamplerPickTests: XCTestCase {
    func testPickingReadsExactlyTheAskedKeys() throws {
        let list = SensorSampler.shared.sample(detail: true).list
        guard list.count >= 2 else { throw XCTSkip("no readable sensors here") }
        let keys = [list[1].key, list[0].key, "ZZZZ"]
        let sample = SensorSampler.shared.sample(groups: [], keys: keys)
        XCTAssertEqual(sample.picked.map { $0?.key }, [keys[0], keys[1], nil], "one slot per key, in the order asked")
        XCTAssertEqual(sample.picked.first??.name, list[1].name, "named the way the list names it")
        XCTAssertTrue(sample.available)
    }
}
