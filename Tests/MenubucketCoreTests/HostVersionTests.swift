import Foundation
import XCTest

@testable import MenubucketCore

/// `minHostVersion`, and the expression functions it exists to protect.
final class HostVersionTests: XCTestCase {
    private func manifest(_ min: String?) -> Manifest {
        Manifest(schemaVersion: 1, id: "t", name: "T", entry: .init(kind: "workflow"),
                 minHostVersion: min)
    }

    func testIncompatibility() {
        XCTAssertNil(manifest(nil).incompatibility(hostVersion: "0.3.10"))
        XCTAssertNil(manifest("0.3.11").incompatibility(hostVersion: "0.3.11"))
        XCTAssertNil(manifest("0.3.11").incompatibility(hostVersion: "0.4.0"))
        XCTAssertNil(manifest("0.3.11").incompatibility(hostVersion: nil), "a development build runs everything")
        let reason = manifest("0.3.12").incompatibility(hostVersion: "0.3.11")
        XCTAssertEqual(reason, "Needs BarShelf 0.3.12 or later (this is 0.3.11). Update BarShelf to use it.")
        XCTAssertNotNil(manifest("0.10.0").incompatibility(hostVersion: "0.9.9"), "compared as numbers, not text")
    }

    func testTheFieldDecodes() throws {
        let json = #"{"schemaVersion":1,"id":"t","name":"T","minHostVersion":"0.3.11","entry":{"kind":"workflow"}}"#
        XCTAssertEqual(try JSONDecoder().decode(Manifest.self, from: Data(json.utf8)).minHostVersion, "0.3.11")
    }

    private func label(_ expression: String) throws -> String? {
        let json = """
        {"schemaVersion":1,"kind":"workflow","sources":{"d":{"use":"value","with":{"a":1,"b":{"c":"deep"},"list":[10,20]}}},
         "status":{"label":"${\(expression)}"},"view":{"type":"text","text":"x"}}
        """
        let def = try JSONDecoder().decode(WorkflowDefinition.self, from: Data(json.utf8))
        let sources = try WorkflowEngine.resolvedSourceParams(def, settings: .object([:]))
        return try WorkflowEngine.evaluate(def, sources: sources, settings: .object(["pick": .string("b")])).statusLabel
    }

    func testSwitch() throws {
        XCTAssertEqual(try label("switch('b', 'a', 'one', 'b', 'two', 'other')"), "two")
        XCTAssertEqual(try label("switch('z', 'a', 'one', 'b', 'two', 'other')"), "other")
        XCTAssertEqual(try label("string(switch('z', 'a', 'one'))"), "", "no fallback is null")
        XCTAssertEqual(try label("switch('a', 'a', 'one', 'b', transforms.missing)"), "one",
                       "cases after the match are not evaluated")
    }

    func testGet() throws {
        XCTAssertEqual(try label("string(get(sources.d, 'a'))"), "1")
        XCTAssertEqual(try label("get(get(sources.d, settings.pick), 'c')"), "deep")
        XCTAssertEqual(try label("string(get(sources.d.list, 1))"), "20")
        XCTAssertEqual(try label("string(get(sources.d, 'missing'))"), "")
        XCTAssertEqual(try label("string(get(sources.d.list, 9))"), "")
    }

    /// A bundled widget that uses a function newer hosts introduced must say
    /// so, or an older BarShelf would run it and show "—".
    func testWidgetsUsingNewFunctionsDeclareTheirHost() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("widgets")
        let introduced = ["switch(": "0.3.11", "get(": "0.3.11"]
        for dir in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            guard let workflow = try? String(contentsOf: dir.appendingPathComponent("workflow.json"), encoding: .utf8),
                  let manifestData = try? Data(contentsOf: dir.appendingPathComponent("widget.json"))
            else { continue }
            let manifest = try JSONDecoder().decode(Manifest.self, from: manifestData)
            for (function, version) in introduced where workflow.range(of: "[^a-zA-Z_.]" + NSRegularExpression.escapedPattern(for: function), options: .regularExpression) != nil {
                XCTAssertNotNil(manifest.minHostVersion, "\(dir.lastPathComponent) uses \(function) but declares no minHostVersion")
                XCTAssertFalse(SemanticVersionOrder.isNewer(version, than: manifest.minHostVersion),
                               "\(dir.lastPathComponent) uses \(function), which needs \(version)")
            }
        }
    }
}
