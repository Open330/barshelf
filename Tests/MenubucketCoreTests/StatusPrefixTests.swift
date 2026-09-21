import XCTest
@testable import MenubucketCore

/// A widget whose metric the user picks cannot name its own label at authoring
/// time, so it emits one per refresh. The first attempt at this computed the
/// value and then dropped it: the `Output` initialiser defaults it to nil, so
/// leaving it off the call site compiled cleanly and produced nothing.
final class StatusPrefixTests: XCTestCase {
    private func definition(_ json: String) throws -> WorkflowDefinition {
        try JSONDecoder().decode(WorkflowDefinition.self, from: Data(json.utf8))
    }

    func testAWorkflowEmitsTheMenuBarPrefixItComputes() throws {
        let def = try definition("""
        {"schemaVersion":1,"kind":"workflow","sources":{},
         "status":{"label":"67%","prefix":"${if(eq(settings.metric,'memory'),'RAM','CPU')}"},
         "view":{"type":"text","text":"hi"}}
        """)
        XCTAssertNotNil(def.status?.prefix, "the prefix must survive decoding")

        let output = try WorkflowEngine.evaluate(
            def, sources: [:], settings: .object(["metric": .string("memory")])
        )
        XCTAssertEqual(output.statusLabel, "67%")
        XCTAssertEqual(output.statusPrefix, "RAM")
    }

    func testTheSameWorkflowSaysSomethingElseForAnotherSetting() throws {
        let def = try definition("""
        {"schemaVersion":1,"kind":"workflow","sources":{},
         "status":{"label":"12%","prefix":"${if(eq(settings.metric,'memory'),'RAM','CPU')}"},
         "view":{"type":"text","text":"hi"}}
        """)
        let output = try WorkflowEngine.evaluate(
            def, sources: [:], settings: .object(["metric": .string("cpu")])
        )
        XCTAssertEqual(output.statusPrefix, "CPU")
    }

    func testAWorkflowWithoutAPrefixEmitsNone() throws {
        let def = try definition("""
        {"schemaVersion":1,"kind":"workflow","sources":{},
         "status":{"label":"9%"},"view":{"type":"text","text":"hi"}}
        """)
        let output = try WorkflowEngine.evaluate(def, sources: [:], settings: .object([:]))
        XCTAssertNil(output.statusPrefix)
    }
}
