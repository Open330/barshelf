import Foundation
import XCTest

@testable import MenubucketCore

/// `widget.visible` — the context flag that lets a workflow do less while
/// nothing is on screen, and the shipped Sensors widget that uses it.
final class WidgetVisibilityTests: XCTestCase {
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // MenubucketCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
    }

    private func loadShippedWorkflow(_ widget: String) throws -> WorkflowDefinition {
        let url = Self.repoRoot
            .appendingPathComponent("widgets/\(widget)/workflow.json")
        return try WorkflowDefinition.decode(from: try Data(contentsOf: url))
    }

    private func definition(_ json: String) throws -> WorkflowDefinition {
        try WorkflowDefinition.decode(from: Data(json.utf8))
    }

    // MARK: Detecting the flag

    func testReadsWidgetVisibilityFindsTheFlagWhereverItAppears() throws {
        let inSource = try definition("""
        {"schemaVersion":1,"sources":{"d":{"use":"system",
          "with":{"metrics":["sensors"],"detail":"${widget.visible}"}}},
         "view":{"type":"text","text":"hi"}}
        """)
        XCTAssertTrue(inSource.readsWidgetVisibility)

        let inTransform = try definition("""
        {"schemaVersion":1,"sources":{},
         "transforms":{"t":{"use":"assign","from":"if(widget.visible, 8, 0)"}},
         "view":{"type":"text","text":"hi"}}
        """)
        XCTAssertTrue(inTransform.readsWidgetVisibility)

        let inView = try definition("""
        {"schemaVersion":1,"sources":{},
         "view":{"type":"text","text":"${string(widget.visible)}"}}
        """)
        XCTAssertTrue(inView.readsWidgetVisibility)

        let inStatus = try definition("""
        {"schemaVersion":1,"sources":{},
         "status":{"label":"x","tooltip":"${string(widget.visible)}"},
         "view":{"type":"text","text":"hi"}}
        """)
        XCTAssertTrue(inStatus.readsWidgetVisibility)
    }

    func testAMetricPrecisionTemplateCountsAsReadingVisibility() throws {
        let definition = try definition("""
        {"schemaVersion":1,"sources":{},
         "status":{"label":"x","metrics":[{"label":"CPU","value":"1",
           "precision":"${if(widget.visible, 2, 0)}"}]},
         "view":{"type":"text","text":"hi"}}
        """)
        XCTAssertTrue(definition.readsWidgetVisibility)
    }

    func testReadsWidgetVisibilityIsFalseForAWorkflowThatIgnoresIt() throws {
        let plain = try definition("""
        {"schemaVersion":1,"sources":{"d":{"use":"system",
          "with":{"metrics":["cpu"],"detail":true}}},
         "transforms":{"t":{"use":"assign","from":"widget.size"}},
         "view":{"type":"text","text":"${sources.d.cpu.usage}"}}
        """)
        XCTAssertFalse(plain.readsWidgetVisibility)
        XCTAssertFalse(try loadShippedWorkflow("system").readsWidgetVisibility)
    }

    // MARK: The flag resolves to a real boolean

    func testVisibilityResolvesToABooleanSourceParameter() throws {
        let definition = try loadShippedWorkflow("sensors")
        XCTAssertTrue(definition.readsWidgetVisibility)

        func detail(visible: Bool) throws -> JSONValue? {
            try WorkflowEngine.resolvedSourceParams(
                definition,
                settings: .object([:]),
                widget: .object([
                    "size": .string("M"), "visible": .bool(visible),
                ])
            )["data"]?.objectValue?["detail"]
        }

        // Not "true"/"false" strings — the source handler reads a Bool.
        XCTAssertEqual(try detail(visible: true), .bool(true))
        XCTAssertEqual(try detail(visible: false), .bool(false))
    }

    /// Closed, the shipped widget asks for exactly the reading it shows;
    /// open, it asks for everything the card needs. This pair is what takes a
    /// sensors refresh from ~27 ms to ~4 ms.
    func testSensorsWidgetNarrowsItsSampleWhileTheCardIsClosed() throws {
        let definition = try loadShippedWorkflow("sensors")

        func requested(visible: Bool, reading: String) throws -> JSONValue? {
            try WorkflowEngine.resolvedSourceParams(
                definition,
                settings: .object(["menuBarSensor": .string(reading)]),
                widget: .object([
                    "size": .string("M"), "visible": .bool(visible),
                ])
            )["data"]?.objectValue?["sensors"]
        }

        // The reading itself, then the user's two picks (which only matter
        // when they name a sensor by `key:`); "none" reads nothing.
        func list(_ items: String...) -> JSONValue { .array(items.map(JSONValue.string)) }
        XCTAssertEqual(try requested(visible: false, reading: "cpu"), list("cpu", "cpu", "none"))
        XCTAssertEqual(try requested(visible: false, reading: "power"), list("power", "power", "none"))
        XCTAssertEqual(try requested(visible: false, reading: "peak"), list("peak", "peak", "none"))
        // The card shows CPU, GPU and battery at once.
        XCTAssertEqual(try requested(visible: true, reading: "cpu"), list("all", "cpu", "none"))
    }

    /// A widget installed onto an older BarShelf gets no `widget.visible` at
    /// all. It has to fall back to the broad sample it always took, not to a
    /// silently empty one — the coalesce defaults in the shipped workflow are
    /// what make it portable.
    func testSensorsWidgetSamplesEverythingOnAHostWithoutVisibility() throws {
        let definition = try loadShippedWorkflow("sensors")
        let params = try WorkflowEngine.resolvedSourceParams(
            definition,
            settings: .object(["menuBarSensor": .string("cpu")]),
            widget: .object(["size": .string("M")])
        )["data"]?.objectValue

        XCTAssertEqual(params?["detail"], .bool(true))
        XCTAssertEqual(params?["sensors"]?.arrayValue?.first, .string("all"))
    }

    /// Menu bar readings are whole numbers — the power reading had kept a
    /// decimal ("3.6 W") after every other reading lost it.
    func testSensorsMenuBarReadingsHaveNoDecimal() throws {
        let definition = try loadShippedWorkflow("sensors")
        for sensor in ["power", "cpu", "fan"] {
            let output = try WorkflowEngine.evaluate(
                definition,
                sources: ["data": .object(["sensors": .object([
                    "available": .bool(true), "cpu": .number(48.6), "peak": .number(51.2),
                    "power": .number(3.64), "fanCount": .number(1),
                    "fans": .array([.object(["rpm": .number(1234.5), "usage": .number(0.42)])]),
                ])])],
                settings: .object(["menuBarSensor": .string(sensor), "unit": .string("celsius")])
            )
            let entry = MenuBarPolicy.applyingPresentation(
                MenuBarPresentation(),
                to: MenuBarEntry(widgetID: "s", name: "Sensors", style: .stacked,
                                 label: output.statusLabel, metrics: output.statusMetrics ?? [])
            )
            let shown = entry.metrics.first?.value ?? entry.label ?? ""
            XCTAssertFalse(shown.contains("."), "\(sensor): \(shown)")
        }
    }

    // MARK: The shipped widget still renders with the cheap sample

    /// With the card closed the sensor source omits `list` entirely. The
    /// menu bar reading and the card body both have to survive that, or a
    /// closed shelf would break the status line it is meant to make cheaper.
    func testSensorsWidgetRendersWithoutTheDetailList() throws {
        let definition = try loadShippedWorkflow("sensors")
        let settings: JSONValue = .object([
            "menuBarSensor": .string("cpu"), "unit": .string("celsius"),
        ])

        var plain: [String: JSONValue] = [
            "available": .bool(true),
            "cpu": .number(48.6),
            "gpu": .number(41.0),
            "battery": .number(30.0),
            "peak": .number(51.2),
            "power": .number(15.5),
            "fanCount": .number(0),
            "fans": .array([]),
        ]

        let closed = try WorkflowEngine.evaluate(
            definition,
            sources: ["data": .object(["sensors": .object(plain)])],
            settings: settings
        )
        XCTAssertEqual(closed.statusLabel, "49°")
        XCTAssertEqual(closed.statusPrefix, "CPU")

        // …and the list appears when the card is open.
        plain["list"] = .array([
            .object([
                "key": .string("Tp01"), "name": .string("CPU core (Tp01)"),
                "kind": .string("temperature"), "value": .number(50.0),
                "unit": .string("°C"),
            ])
        ])
        let open = try WorkflowEngine.evaluate(
            definition,
            sources: ["data": .object(["sensors": .object(plain)])],
            settings: settings
        )
        XCTAssertEqual(open.statusLabel, "49°")
        XCTAssertTrue(
            Self.renderedText(open.viewTree).contains { $0.contains("1 readings") },
            "the card lists the detail readings when it is visible"
        )
        XCTAssertFalse(
            Self.renderedText(closed.viewTree).contains { $0.contains("readings") },
            "the closed card has no sensor list to show"
        )
    }

    private static func renderedText(_ node: UINode) -> [String] {
        var out: [String] = []
        if let text = node.text { out.append(text) }
        for child in node.children ?? [] { out += renderedText(child) }
        for item in node.items ?? [] { out += renderedText(item) }
        return out
    }
}
