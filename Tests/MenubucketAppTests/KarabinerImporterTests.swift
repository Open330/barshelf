import CoreGraphics
import XCTest
@testable import MenubucketApp

final class KarabinerImporterTests: XCTestCase {
    private let fnRule = #"""
    {"description":"Fn navigation","manipulators":[
      {"type":"basic","from":{"key_code":"i","modifiers":{"mandatory":["fn"],"optional":["any"]}},"to":[{"key_code":"up_arrow"}]}
    ]}
    """#

    func testExportedRulePreservesFnSelectionRepeatAndKeyUpAfterModifierRelease() throws {
        let result = try KarabinerImporter.convert(fnRule)
        let script = try AutomationScript(source: result.script)
        let rule = try XCTUnwrap(script.keyRemaps.first)
        XCTAssertEqual(rule.from, 34)
        XCTAssertEqual(rule.to, 126)
        let flags = CGEventFlags.maskSecondaryFn.rawValue | CGEventFlags.maskShift.rawValue
        var state = AutomationKeyRemapState()
        XCTAssertEqual(state.target(code: 34, keyboard: 91, down: true, flags: flags, rules: script.keyRemaps), rule)
        XCTAssertEqual(flags & ~rule.mandatory, CGEventFlags.maskShift.rawValue)
        // Releasing Fn while holding the letter must not turn repeat or key-up back into I.
        XCTAssertEqual(state.target(code: 34, keyboard: 91, down: true, flags: 0, rules: script.keyRemaps), rule)
        XCTAssertNil(state.target(code: 34, keyboard: 40, down: false, flags: 0, rules: script.keyRemaps))
        XCTAssertEqual(state.target(code: 34, keyboard: 91, down: false, flags: 0, rules: script.keyRemaps), rule)
        XCTAssertTrue(state.held.isEmpty)
        XCTAssertNil(state.target(code: 34, keyboard: 91, down: true, flags: 0, rules: script.keyRemaps))
    }

    func testSelectedProfileImportsSimpleAndComplexMappingsOnlyFromSelectedProfile() throws {
        let source = #"""
        {"global":{"show_in_menu_bar":true},"profiles":[
          {"name":"Other","selected":false,"complex_modifications":{"rules":[{"invalid":true}]}},
          {"name":"Daily","selected":true,"simple_modifications":[
            {"from":{"key_code":"escape"},"to":[{"key_code":"tab"}]}
          ],"complex_modifications":{"rules":[RULE]}}
        ]}
        """#.replacingOccurrences(of: "RULE", with: fnRule)
        let result = try KarabinerImporter.convert(source)
        let script = try AutomationScript(source: result.script)
        XCTAssertEqual(script.keyRemaps.count, 2)
        XCTAssertTrue(script.keyRemaps[0].matches(code: 53, flags: CGEventFlags.maskCommand.rawValue))
        XCTAssertTrue(result.summary.contains("Daily"))
        XCTAssertTrue(result.summary.contains("all keyboards"))
    }

    func testComplexMappingWithoutOptionalModifiersDoesNotConsumeOtherShortcuts() throws {
        let source = #"""
        {"rules":[{"description":"Control H","manipulators":[{
          "type":"basic","from":{"key_code":"h","modifiers":{"mandatory":["control"]}},
          "to":[{"key_code":"delete_or_backspace"}]
        }]}]}
        """#
        let script = try AutomationScript(source: KarabinerImporter.convert(source).script)
        let rule = try XCTUnwrap(script.keyRemaps.first)
        XCTAssertTrue(rule.matches(code: 4, flags: CGEventFlags.maskControl.rawValue))
        XCTAssertFalse(rule.matches(code: 4, flags: 0))
        XCTAssertFalse(rule.matches(code: 4, flags: CGEventFlags.maskControl.rawValue | CGEventFlags.maskShift.rawValue))
        XCTAssertFalse(rule.matches(code: 4, flags: CGEventFlags.maskControl.rawValue | CGEventFlags.maskAlphaShift.rawValue))
    }

    func testUnsupportedBehaviorRejectsEntireImport() throws {
        for source in [
            fnRule.replacingOccurrences(of: "\"type\":\"basic\"", with: "\"type\":\"basic\",\"conditions\":[{\"type\":\"device_if\"}]"),
            fnRule.replacingOccurrences(of: "\"up_arrow\"", with: "\"left_command\""),
            fnRule.replacingOccurrences(of: "\"fn\"", with: "\"left_shift\""),
            fnRule.replacingOccurrences(of: "\"to\":[{\"key_code\":\"up_arrow\"}]", with: "\"to\":[{\"shell_command\":\"echo dangerous\"}]"),
            fnRule.replacingOccurrences(of: "\"type\":\"basic\"", with: "\"type\":\"basic\",\"to_if_alone\":[{\"key_code\":\"escape\"}]"),
            fnRule.replacingOccurrences(of: "\"key_code\":\"up_arrow\"", with: "\"key_code\":\"up_arrow\",\"repeat\":false"),
            #"{"profiles":[{"selected":true,"devices":[{"identifiers":{"is_keyboard":true}}]}]}"#,
            #"{"profiles":[{"selected":true,"fn_function_keys":[{"from":{"key_code":"f1"},"to":[{"key_code":"f2"}]}]}]}"#,
            #"{"profiles":[{"selected":true},{"selected":true}]}"#,
            #"{"rules":[]}"#,
            fnRule.replacingOccurrences(of: "\"up_arrow\"", with: "\"i\"")
        ] {
            XCTAssertThrowsError(try KarabinerImporter.convert(source), source)
        }
    }

    func testKeyRemapAPIRejectsMixedFnRulesUnknownFieldsAndExcessRules() {
        for source in [
            "barshelf.remapKeys([{from:'i',to:'up_arrow',conditions:[]}]);",
            "barshelf.remapKeys([{from:'i',to:'up_arrow',mandatory:['fn'],optional:['fn']}]);",
            "barshelf.remapKeys([{from:'i',to:'up_arrow'}]); barshelf.remapFn({keyboardTypes:[91],keys:{j:'left'}});",
            "barshelf.remapKeys(Array.from({length:129}, () => ({from:'i',to:'up_arrow'})));"
        ] { XCTAssertThrowsError(try AutomationScript(source: source), source) }
    }

    func testJSONImportRemainsDraftAndFailedImportPreservesSavedConfiguration() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("karabiner.json")
        try fnRule.write(to: url, atomically: true, encoding: .utf8)
        let controller = AutomationController(fileURL: directory.appendingPathComponent("automation.json"))
        XCTAssertTrue(controller.apply(source: AutomationScript.example, enabled: false))
        let saved = controller.source
        XCTAssertNotNil(controller.importFile(url))
        XCTAssertEqual(controller.source, saved)
        XCTAssertFalse(controller.isRunning)
        try "{\"rules\":[]}".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertNil(controller.importFile(url))
        XCTAssertNil(controller.importSummary)
        XCTAssertEqual(controller.source, saved)
        XCTAssertEqual(AutomationController(fileURL: directory.appendingPathComponent("automation.json")).source, saved)
    }
}
