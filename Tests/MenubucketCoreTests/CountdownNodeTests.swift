import XCTest
@testable import MenubucketCore

final class CountdownNodeTests: XCTestCase {
    /// The exact contract example from the M1 task sheet.
    private let contractJSON = Data("""
    { "type": "progress", "style": "ring",
      "countdown": { "from": 1783442400000, "until": 1783442430000 },
      "labelFrom": "remainingSeconds",
      "tintRules": [{ "whenRemainingLtSeconds": 10, "tint": "danger" }] }
    """.utf8)

    func testDecodesContractExample() throws {
        let node = try JSONDecoder().decode(UINode.self, from: contractJSON)
        XCTAssertEqual(node.type, "progress")
        XCTAssertEqual(node.style, "ring")
        XCTAssertEqual(node.countdown?.from, 1_783_442_400_000)
        XCTAssertEqual(node.countdown?.until, 1_783_442_430_000)
        XCTAssertEqual(node.labelFrom, "remainingSeconds")
        XCTAssertEqual(node.tintRules?.count, 1)
        XCTAssertEqual(node.tintRules?.first?.whenRemainingLtSeconds, 10)
        XCTAssertEqual(node.tintRules?.first?.tint, "danger")
    }

    func testRoundTripPreservesCountdownFields() throws {
        let node = try JSONDecoder().decode(UINode.self, from: contractJSON)
        let encoded = try JSONEncoder().encode(node)
        let decoded = try JSONDecoder().decode(UINode.self, from: encoded)
        XCTAssertEqual(decoded, node)
    }

    func testRemainingAndFraction() throws {
        let node = try JSONDecoder().decode(UINode.self, from: contractJSON)
        let from = 1_783_442_400_000.0
        let until = 1_783_442_430_000.0

        XCTAssertEqual(node.countdownRemainingSeconds(nowMs: from), 30)
        XCTAssertEqual(node.countdownFraction(nowMs: from), 1)

        let midpoint = (from + until) / 2
        XCTAssertEqual(node.countdownRemainingSeconds(nowMs: midpoint), 15)
        XCTAssertEqual(node.countdownFraction(nowMs: midpoint) ?? -1, 0.5, accuracy: 0.0001)

        // Past the deadline both clamp at zero.
        XCTAssertEqual(node.countdownRemainingSeconds(nowMs: until + 5000), 0)
        XCTAssertEqual(node.countdownFraction(nowMs: until + 5000), 0)
    }

    func testTintRuleAppliesOnlyBelowThreshold() throws {
        var node = try JSONDecoder().decode(UINode.self, from: contractJSON)
        node.tint = "accent"
        let until = 1_783_442_430_000.0

        XCTAssertEqual(node.countdownTint(nowMs: until - 15_000), "accent", "15s left → base tint")
        XCTAssertEqual(node.countdownTint(nowMs: until - 9_000), "danger", "9s left → rule tint")
        XCTAssertEqual(node.countdownTint(nowMs: until + 1_000), "danger", "expired → still danger")
    }

    func testNodeWithoutCountdownReturnsNilHelpers() {
        let node = UINode(type: "progress", value: 0.4)
        XCTAssertNil(node.countdownRemainingSeconds(nowMs: 0))
        XCTAssertNil(node.countdownFraction(nowMs: 0))
        XCTAssertEqual(node.countdownTint(nowMs: 0), node.tint)
    }

    func testActionDecodesRunAndClearAfterSec() throws {
        let json = Data("""
        [
          { "type": "run", "command": ["aas", "switch", "work"], "thenRefresh": true },
          { "type": "copyText", "value": "728419", "clearAfterSec": 30 }
        ]
        """.utf8)
        let actions = try JSONDecoder().decode([NodeAction].self, from: json)
        XCTAssertEqual(actions[0].type, "run")
        XCTAssertEqual(actions[0].command, ["aas", "switch", "work"])
        XCTAssertEqual(actions[0].thenRefresh, true)
        XCTAssertEqual(actions[1].clearAfterSec, 30)
    }
}
