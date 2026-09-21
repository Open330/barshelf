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

/// The two things a manifest cannot express because they follow a value: the
/// symbol and the colour.
final class StatusIconAndTintTests: XCTestCase {
    private func evaluate(_ status: String, settings: JSONValue) throws -> WorkflowEngine.Output {
        let def = try JSONDecoder().decode(WorkflowDefinition.self, from: Data("""
        {"schemaVersion":1,"kind":"workflow","sources":{},
         "status":\(status),
         "view":{"type":"text","text":"hi"}}
        """.utf8))
        return try WorkflowEngine.evaluate(def, sources: [:], settings: settings)
    }

    /// A battery icon has to track its level; a manifest field cannot.
    func testTheIconFollowsTheValue() throws {
        let status = """
        {"label":"${settings.pct}%",
         "icon":"${if(gt(number(settings.pct), 50), 'battery.100', 'battery.25')}"}
        """
        XCTAssertEqual(
            try evaluate(status, settings: .object(["pct": .number(90)])).statusIcon,
            "battery.100"
        )
        XCTAssertEqual(
            try evaluate(status, settings: .object(["pct": .number(10)])).statusIcon,
            "battery.25"
        )
    }

    func testTheTintFollowsTheValue() throws {
        let status = """
        {"label":"${settings.load}%",
         "tint":"${if(gt(number(settings.load), 90), 'danger', 'good')}"}
        """
        XCTAssertEqual(
            try evaluate(status, settings: .object(["load": .number(95)])).statusTint, "danger"
        )
        XCTAssertEqual(
            try evaluate(status, settings: .object(["load": .number(5)])).statusTint, "good"
        )
    }

    func testAWorkflowThatAsksForNeitherGetsNeither() throws {
        let output = try evaluate(#"{"label":"9%"}"#, settings: .object([:]))
        XCTAssertNil(output.statusIcon)
        XCTAssertNil(output.statusTint)
    }

    // MARK: - Vocabulary

    /// A widget written against a later vocabulary should lose its colour, not
    /// its reading.
    func testAnUnknownTintNameIsIgnoredRatherThanFatal() {
        XCTAssertNil(MenuBarTint.named("chartreuse"))
        XCTAssertNil(MenuBarTint.named(""))
        XCTAssertNil(MenuBarTint.named(nil))
        XCTAssertEqual(MenuBarTint.named("danger"), .danger)
    }

    /// The menu bar's vocabulary has to stay the view layer's, or one widget
    /// would need two words for the same idea.
    func testTheTintVocabularyMatchesTheViewLayer() {
        XCTAssertEqual(
            Set(MenuBarTint.allCases.map(\.rawValue)),
            ["accent", "good", "warning", "danger", "secondary"]
        )
    }

    // MARK: - Layering

    func testTheIconPrefersTheUserThenTheRefreshThenTheManifest() {
        XCTAssertEqual(
            MenuBarPolicy.resolvedIcon(
                user: "star.fill", live: "b", statusItem: "c", manifest: "d"
            ),
            "star.fill"
        )
        XCTAssertEqual(
            MenuBarPolicy.resolvedIcon(user: nil, live: "b", statusItem: "c", manifest: "d"), "b"
        )
        XCTAssertEqual(
            MenuBarPolicy.resolvedIcon(user: nil, live: nil, statusItem: "c", manifest: "d"), "c"
        )
        XCTAssertEqual(
            MenuBarPolicy.resolvedIcon(user: nil, live: nil, statusItem: nil, manifest: "d"), "d"
        )
        XCTAssertNil(
            MenuBarPolicy.resolvedIcon(user: nil, live: nil, statusItem: nil, manifest: nil)
        )
    }

    /// Turning the icon off is a decision, so it stops the search instead of
    /// falling through to what the widget suggests.
    func testAnIconTurnedOffStaysOff() {
        XCTAssertNil(
            MenuBarPolicy.resolvedIcon(user: "", live: "b", statusItem: "c", manifest: "d")
        )
    }
}
