import XCTest
@testable import MenubucketCore

/// The bundled System widget's real tint expression, evaluated against a
/// stand-in for the system source.
final class SystemTintExpressionTests: XCTestCase {
    private func evaluate(tint: String, usage: Double) throws -> String? {
        let def = try JSONDecoder().decode(WorkflowDefinition.self, from: Data("""
        {"schemaVersion":1,"kind":"workflow","sources":{},
         "status":{"label":"x","tint":\(try! String(data: JSONEncoder().encode(tint), encoding: .utf8)!)},
         "view":{"type":"text","text":"hi"}}
        """.utf8))
        let sources: [String: JSONValue] = [
            "data": .object([
                "memory": .object(["usage": .number(usage)]),
                "disk": .object(["usage": .number(1)]),
                "cpu": .object(["usage": .number(1)]),
            ])
        ]
        return try WorkflowEngine.evaluate(
            def, sources: sources, settings: .object(["menuBarMetric": .string("memory")])
        ).statusTint
    }

    func testTheShippedExpressionColoursByThreshold() throws {
        let shipped = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("widgets/system/workflow.json"),
            encoding: .utf8
        )
        let json = try JSONSerialization.jsonObject(with: Data(shipped.utf8)) as? [String: Any]
        let status = json?["status"] as? [String: Any]
        let tint = try XCTUnwrap(status?["tint"] as? String, "the widget declares no tint")

        XCTAssertEqual(try evaluate(tint: tint, usage: 95), "danger")
        XCTAssertEqual(try evaluate(tint: tint, usage: 80), "warning")
        XCTAssertEqual(try evaluate(tint: tint, usage: 20), "")
    }
}
