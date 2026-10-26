import Foundation
import XCTest
@testable import MenubucketCore

/// The bundled Keep Awake widget end to end: PowerDisplayGuard's status.json
/// for each phase of the contract → the widget's own helper (run through
/// osascript, as BarShelf runs it) → the workflow → what the popup and the
/// menu bar show. Also the requests it writes: atomic, private, capped.
final class KeepAwakeWidgetTests: XCTestCase {
    private var guardDir: URL!
    private let widgetDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("widgets/keep-awake")

    override func setUpWithError() throws {
        guardDir = FileManager.default.temporaryDirectory.appendingPathComponent("guard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: guardDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: guardDir)
    }

    // MARK: - Helpers

    @discardableResult
    private func helper(_ arguments: String...) throws -> (status: Int32, stdout: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-l", "JavaScript", widgetDir.appendingPathComponent("keep-awake.js").path] + arguments
        process.environment = ["KEEP_AWAKE_GUARD_DIR": guardDir.path, "HOME": NSHomeDirectory()]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return (process.terminationStatus, text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func writeStatus(_ body: [String: Any], updatedSecondsAgo: Double = 1) throws {
        var status = body
        status["version"] = status["version"] ?? 1
        status["updatedAt"] = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-updatedSecondsAgo))
        let data = try JSONSerialization.data(withJSONObject: status)
        try data.write(to: guardDir.appendingPathComponent("status.json"))
    }

    private struct Rendered {
        let text: String
        let label: String?
        let icon: String?
    }

    private func render(lidClosed: Bool = false) throws -> Rendered {
        let (status, json) = try helper("status")
        XCTAssertEqual(status, 0)
        let source = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        let definition = try JSONDecoder().decode(
            WorkflowDefinition.self, from: Data(contentsOf: widgetDir.appendingPathComponent("workflow.json"))
        )
        let output = try WorkflowEngine.evaluate(
            definition, sources: ["guard": source],
            settings: .object(["lidClosed": .bool(lidClosed), "untilTime": .string("18:00")])
        )
        let tree = String(decoding: try JSONEncoder().encode(output.viewTree), as: UTF8.self)
        return Rendered(text: tree, label: output.statusLabel, icon: output.statusIcon)
    }

    // MARK: - Phases

    func testOnPowerShowsAwakeAndTheBlockers() throws {
        try writeStatus(["onAC": true, "phase": "ac", "holding": true, "sleepDisabled": true, "override": NSNull(),
                         "blockers": [["pid": 4242, "process": "caffeinate", "type": "PreventUserIdleSystemSleep",
                                       "assertionName": "caffeinate command-line tool"]]])
        let r = try render()
        XCTAssertTrue(r.text.contains("Awake on power"))
        XCTAssertTrue(r.text.contains("Also keeping it awake"))
        XCTAssertTrue(r.text.contains("caffeinate"))
        XCTAssertEqual(r.label, "", "nothing to count down on power: the item shows its icon only")
        XCTAssertEqual(r.icon, "bolt.fill")
        XCTAssertFalse(r.text.contains("Stop"), "no override, nothing to stop")
    }

    func testGraceCountsDownInTheMenuBar() throws {
        try writeStatus(["onAC": false, "phase": "grace", "graceRemaining": 42, "blockers": []])
        let r = try render()
        XCTAssertTrue(r.text.contains("On battery: sleep in 42s"))
        XCTAssertEqual(r.label, "42s")
        XCTAssertEqual(r.icon, "timer")
        XCTAssertFalse(r.text.contains("Also keeping it awake"), "no blockers, no section")
    }

    func testBatterySaysSleepIsAllowed() throws {
        try writeStatus(["onAC": false, "phase": "battery", "blockers": []])
        let r = try render()
        XCTAssertTrue(r.text.contains("On battery: sleep allowed"))
        XCTAssertEqual(r.icon, "moon.zzz")
    }

    func testOverrideShowsTimeLeftWhatIsEffectiveAndStop() throws {
        let until = ISO8601DateFormatter().string(from: Date().addingTimeInterval(2 * 3600 - 30))
        try writeStatus(["onAC": false, "phase": "override", "holding": true, "blockers": [],
                         "override": ["id": "A", "until": until, "lidClosed": true, "lidClosedEffective": false,
                                      "note": "battery ≤ 20 %: lid-closed ignored", "source": "barshelf"]])
        let r = try render()
        XCTAssertTrue(r.text.contains("Awake for 1:59"))
        XCTAssertTrue(r.text.contains("Closing the lid still sleeps."), "shows what is effective, not what was asked")
        XCTAssertTrue(r.text.contains("lid-closed ignored"))
        XCTAssertTrue(r.text.contains("Stop"))
        XCTAssertEqual(r.label, "1:59")
        XCTAssertEqual(r.icon, "cup.and.saucer.fill")
    }

    func testAStaleOrMissingGuardIsAWarningNotAPhase() throws {
        var r = try render()
        XCTAssertTrue(r.text.contains("isn’t running"))
        XCTAssertEqual(r.label, "!")
        try writeStatus(["onAC": true, "phase": "ac", "blockers": []], updatedSecondsAgo: 60)
        r = try render()
        XCTAssertTrue(r.text.contains("stopped answering"), r.text)
        XCTAssertEqual(r.icon, "exclamationmark.triangle")
    }

    // MARK: - The guard's own samples

    /// The files PowerDisplayGuard itself writes (`power-display-guard
    /// --write-samples`): optional keys omitted, dates without fractions.
    /// Each must render its phase, so a change on either side of the
    /// contract shows up here.
    func testEveryPhaseTheGuardWritesRenders() throws {
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/PowerDisplayGuard")
        let expected: [String: String] = [
            "ac": "Awake on power",
            "grace": "On battery: sleep in",
            "battery": "On battery: sleep allowed",
            "override": "Stays awake with the lid closed.",
            "override-capped": "capped at 12 h",
            "override-lid-ignored": "lid-closed ignored",
        ]
        for (name, text) in expected {
            var status = try XCTUnwrap(JSONSerialization.jsonObject(
                with: Data(contentsOf: fixtures.appendingPathComponent("status-\(name).json"))) as? [String: Any])
            status.removeValue(forKey: "updatedAt")
            try writeStatus(status)
            let rendered = try render()
            XCTAssertTrue(rendered.text.contains(text), "\(name): expected “\(text)”")
            XCTAssertFalse(rendered.text.contains("isn’t running"), name)
        }
    }

    // MARK: - Requests

    func testRequestsAreAtomicPrivateAndCappedAtTwelveHours() throws {
        XCTAssertEqual(try helper("set", "72000", "true").status, 0)
        let url = guardDir.appendingPathComponent("override.json")
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(body["source"] as? String, "barshelf")
        XCTAssertEqual(body["lidClosed"] as? Bool, true)
        XCTAssertNotNil(body["id"]); XCTAssertNotNil(body["createdAt"])
        let until = try XCTUnwrap(ISO8601DateFormatter.withFractions.date(from: body["until"] as? String ?? ""))
        XCTAssertLessThanOrEqual(until.timeIntervalSinceNow, 12 * 3600 + 5)
        XCTAssertGreaterThan(until.timeIntervalSinceNow, 12 * 3600 - 60)
        // Nothing left behind but the request itself.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: guardDir.path), ["override.json"])
        XCTAssertEqual(try helper("cancel").status, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testThereIsNoIndefiniteOrMalformedRequest() throws {
        XCTAssertNotEqual(try helper("until", "25:00", "false").status, 0)
        XCTAssertNotEqual(try helper("forever").status, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: guardDir.appendingPathComponent("override.json").path))
    }

    func testARequestTheGuardHasNotEchoedIsShownAsPending() throws {
        try writeStatus(["onAC": true, "phase": "ac", "blockers": []])
        try helper("set", "3600", "false")
        XCTAssertTrue(try render().text.contains("Waiting for PowerDisplayGuard"))
    }
}

private extension ISO8601DateFormatter {
    static let withFractions: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
