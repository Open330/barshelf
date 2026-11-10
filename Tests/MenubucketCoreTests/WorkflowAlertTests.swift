import XCTest
@testable import MenubucketCore

final class WorkflowAlertTests: XCTestCase {
    private func sample(_ active: Bool?, revision: String = "r1", cooldownSec: Double = 3600) -> WorkflowEngine.AlertSample {
        .init(id: "a", active: active, title: "t", body: nil, cooldownMs: cooldownSec * 1000, revision: revision)
    }

    // MARK: - Tracker

    func testFiresOnlyOnARisingEdge() {
        var state: AlertTracker.State?
        var fired: [Bool] = []
        for (t, active) in [(0.0, false), (1, true), (2, true), (3, false), (4, true)] as [(Double, Bool)] {
            let decision = AlertTracker.decide(previous: state, sample: sample(active, cooldownSec: 0), nowMs: t * 1000)
            if let next = decision.next { state = next }
            fired.append(decision.fire)
        }
        XCTAssertEqual(fired, [false, true, false, false, true])
    }

    func testFirstReadingNeverFires() {
        let decision = AlertTracker.decide(previous: nil, sample: sample(true), nowMs: 0)
        XCTAssertFalse(decision.fire)
        XCTAssertEqual(decision.next, AlertTracker.State(revision: "r1", active: true))
    }

    func testUnreadableSamplesNeitherFireNorRearm() {
        let armed = AlertTracker.State(revision: "r1", active: true, firedAtMs: 0)
        let decision = AlertTracker.decide(previous: armed, sample: sample(nil), nowMs: 10_000_000)
        XCTAssertEqual(decision, .init(fire: false, next: nil))
    }

    func testCooldownHoldsASecondEdgeBack() {
        var state = AlertTracker.State(revision: "r1", active: false)
        var decision = AlertTracker.decide(previous: state, sample: sample(true, cooldownSec: 60), nowMs: 0)
        XCTAssertTrue(decision.fire)
        state = decision.next!
        state = AlertTracker.decide(previous: state, sample: sample(false, cooldownSec: 60), nowMs: 10_000).next!
        decision = AlertTracker.decide(previous: state, sample: sample(true, cooldownSec: 60), nowMs: 20_000)
        XCTAssertFalse(decision.fire, "within the cooldown")
        state = decision.next!
        state = AlertTracker.decide(previous: state, sample: sample(false, cooldownSec: 60), nowMs: 70_000).next!
        XCTAssertTrue(AlertTracker.decide(previous: state, sample: sample(true, cooldownSec: 60), nowMs: 80_000).fire)
    }

    func testAChangedDefinitionStartsOver() {
        let old = AlertTracker.State(revision: "r1", active: false)
        let decision = AlertTracker.decide(previous: old, sample: sample(true, revision: "r2"), nowMs: 0)
        XCTAssertFalse(decision.fire)
        XCTAssertEqual(decision.next?.revision, "r2")
    }

    func testStorePersistsAndForgets() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("alerts-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = AlertStateStore(fileURL: url)
        XCTAssertTrue(store.record(widgetID: "w", samples: [sample(false, cooldownSec: 0)], nowMs: 0).isEmpty)
        let reloaded = AlertStateStore(fileURL: url)
        XCTAssertEqual(reloaded.record(widgetID: "w", samples: [sample(true, cooldownSec: 0)], nowMs: 1).map(\.id), ["a"])
        reloaded.forget(widgetID: "w")
        XCTAssertNil(AlertStateStore(fileURL: url).state(widgetID: "w", alertID: "a"))
    }

    /// Alerts a workflow no longer declares are dropped, so a re-added id
    /// starts over instead of reusing an old edge.
    func testReconcileDropsUndeclaredAlerts() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("alerts-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = AlertStateStore(fileURL: url)
        _ = store.record(widgetID: "w", samples: [sample(false)], nowMs: 0)
        store.reconcile(widgetID: "w", alertIDs: ["a"])
        XCTAssertNotNil(store.state(widgetID: "w", alertID: "a"))
        store.reconcile(widgetID: "w", alertIDs: [])
        XCTAssertNil(store.state(widgetID: "w", alertID: "a"))
        XCTAssertTrue(store.record(widgetID: "w", samples: [sample(true)], nowMs: 1).isEmpty, "back to a first reading")
    }

    // MARK: - Engine

    private func evaluate(_ alerts: [String: WorkflowDefinition.AlertDef], level: JSONValue) throws -> [WorkflowEngine.AlertSample] {
        let definition = WorkflowDefinition(
            sources: ["battery": .init(use: "value", with: .object(["level": level]))],
            view: .object(["type": .string("text"), "text": .string("x")]),
            alerts: alerts
        )
        return try WorkflowEngine.evaluate(definition, sources: ["battery": .object(["level": level])], settings: .object([:])).alerts
    }

    func testEngineReadsConditionsAndTexts() throws {
        let alerts = ["low": WorkflowDefinition.AlertDef(
            when: "${lt(sources.battery.level, 20)}", title: "Battery at ${sources.battery.level}%",
            body: "Plug in soon.", cooldownSec: 600
        )]
        let low = try XCTUnwrap(evaluate(alerts, level: .number(15)).first)
        XCTAssertEqual(low.active, true)
        XCTAssertEqual(low.title, "Battery at 15%")
        XCTAssertEqual(low.body, "Plug in soon.")
        XCTAssertEqual(low.cooldownMs, 600_000)
        XCTAssertEqual(try evaluate(alerts, level: .number(80)).first?.active, false)
    }

    /// Only explicit booleans count: a number, a missing value or an error
    /// is no reading, which the tracker leaves alone.
    func testNonBooleanConditionsAreNoReading() throws {
        let number = ["n": WorkflowDefinition.AlertDef(when: "${sources.battery.level}", title: "x")]
        XCTAssertNil(try evaluate(number, level: .number(1)).first?.active)
        let missing = ["m": WorkflowDefinition.AlertDef(when: "${sources.battery.nope}", title: "x")]
        XCTAssertNil(try evaluate(missing, level: .number(1)).first?.active)
        let broken = ["b": WorkflowDefinition.AlertDef(when: "${nosuchfn(1)}", title: "x")]
        XCTAssertNil(try evaluate(broken, level: .number(1)).first?.active)
    }

    /// The app's language translates an alert's text; that must not look
    /// like a new rule and reset what the alert has seen.
    func testWordingDoesNotChangeTheRule() throws {
        let english = ["low": WorkflowDefinition.AlertDef(when: "${lt(sources.battery.level, 20)}", title: "Low", body: "Charge")]
        let korean = ["low": WorkflowDefinition.AlertDef(when: "${lt(sources.battery.level, 20)}", title: "낮음", body: "충전")]
        XCTAssertEqual(try evaluate(english, level: .number(5)).first?.revision,
                       try evaluate(korean, level: .number(5)).first?.revision)
        let stricter = ["low": WorkflowDefinition.AlertDef(when: "${lt(sources.battery.level, 10)}", title: "Low")]
        XCTAssertNotEqual(try evaluate(english, level: .number(5)).first?.revision,
                          try evaluate(stricter, level: .number(5)).first?.revision)
    }

    func testAlertsDecodeFromWorkflowJSON() throws {
        let json = #"{"schemaVersion":1,"sources":{},"view":{"type":"text","text":"x"},"alerts":{"hot":{"when":"${true}","title":"Hot","cooldownSec":120}}}"#
        let definition = try WorkflowDefinition.decode(from: Data(json.utf8))
        XCTAssertEqual(definition.alerts?["hot"], .init(when: "${true}", title: "Hot", cooldownSec: 120))
    }
}
