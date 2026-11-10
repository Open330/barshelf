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

    /// The two files exactly as the widget's `fs.json` sources read them.
    private func guardSources() throws -> [String: JSONValue] {
        let directory = try FileSource.openAuthorizedDirectory(path: guardDir.path, readPaths: [guardDir.path])
        return [
            "status": try FileSource.readJSON(named: "status.json", in: directory,
                                              displayPath: "status.json", maxBytes: 262_144),
            "pending": try FileSource.readJSON(named: "override.json", in: directory,
                                               displayPath: "override.json", maxBytes: 65_536),
        ]
    }

    private func evaluate(lidClosed: Bool = false) throws -> WorkflowEngine.Output {
        let definition = try JSONDecoder().decode(
            WorkflowDefinition.self, from: Data(contentsOf: widgetDir.appendingPathComponent("workflow.json"))
        )
        return try WorkflowEngine.evaluate(
            definition, sources: try guardSources(),
            settings: .object(["lidClosed": .bool(lidClosed), "untilTime": .string("18:00")])
        )
    }

    private func render(lidClosed: Bool = false) throws -> Rendered {
        let output = try evaluate(lidClosed: lidClosed)
        let tree = String(decoding: try JSONEncoder().encode(output.viewTree), as: UTF8.self)
        return Rendered(text: tree, label: output.statusLabel, icon: output.statusIcon)
    }

    /// `transforms.guard`, the object the view reads, pulled out of the
    /// workflow by rendering a view that is only that object.
    private func normalized() throws -> [String: JSONValue] {
        var definition = try JSONSerialization.jsonObject(
            with: Data(contentsOf: widgetDir.appendingPathComponent("workflow.json"))) as! [String: Any]
        definition["view"] = ["type": "text", "text": "${string(transforms.guard)}"]
        definition.removeValue(forKey: "status")
        let decoded = try JSONDecoder().decode(
            WorkflowDefinition.self, from: JSONSerialization.data(withJSONObject: definition))
        let output = try WorkflowEngine.evaluate(
            decoded, sources: try guardSources(),
            settings: .object(["lidClosed": .bool(false), "untilTime": .string("18:00")]))
        let tree = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(output.viewTree))
        let text = try XCTUnwrap(tree.objectValue?["text"]?.stringValue)
        return try XCTUnwrap(JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)).objectValue)
    }

    // MARK: - Phases

    /// The guard rewrites status.json every few seconds, so an fs trigger on
    /// its folder ran an osascript every five seconds around the clock
    /// (175k runs in two weeks on one Mac). Poll instead.
    func testDoesNotRunOnEveryGuardHeartbeat() throws {
        // Reading status is no longer a process at all (fs.json), but an fs
        // trigger would still re-render every five seconds for nothing.
        let manifest = try Manifest.decode(from: Data(contentsOf: widgetDir.appendingPathComponent("widget.json")))
        let refresh = try XCTUnwrap(manifest.refresh)
        XCTAssertFalse(refresh.triggers?.contains { if case .fs = $0 { return true } else { return false } } ?? false)
        XCTAssertGreaterThanOrEqual(refresh.interval ?? 0, 60)
    }

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

    // MARK: - Same reading as the old helper

    /// Status used to come from `keep-awake.js status` through osascript.
    /// The workflow now derives it from the files. For every phase, a stale
    /// guard, a pending request and a missing guard, each field must match
    /// what the helper says (the helper keeps `status` as this reference;
    /// the manifest no longer lets the widget run it).
    func testWorkflowReadsTheSameAsTheHelper() throws {
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/PowerDisplayGuard")
        var cases: [(String, () throws -> Void)] = [("missing", {})]
        for name in ["ac", "grace", "battery", "override", "override-capped", "override-lid-ignored"] {
            cases.append((name, {
                var status = try XCTUnwrap(JSONSerialization.jsonObject(
                    with: Data(contentsOf: fixtures.appendingPathComponent("status-\(name).json"))) as? [String: Any])
                status.removeValue(forKey: "updatedAt")
                try self.writeStatus(status)
            }))
        }
        cases.append(("stale", { try self.writeStatus(["onAC": true, "phase": "ac", "blockers": []], updatedSecondsAgo: 60) }))
        cases.append(("bad-created", {
            // Off the minute boundary: the helper and the workflow read the
            // clock a moment apart, and 3600 s exactly read "1:00" or "59m".
            let until = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600 - 30))
            try self.writeStatus(["onAC": true, "phase": "override", "blockers": [],
                                  "override": ["id": "A", "until": until, "createdAt": "", "lidClosed": false,
                                               "lidClosedEffective": true]])
        }))
        cases.append(("invalid", { try Data("{".utf8).write(to: self.guardDir.appendingPathComponent("status.json")) }))
        cases.append(("pending", {
            try self.writeStatus(["onAC": true, "phase": "ac", "blockers": [
                ["pid": 7, "type": "PreventSystemSleep"], ["pid": 8, "process": "caffeinate"]]])
            try self.helper("set", "3600", "false")
        }))
        for (name, setUp) in cases {
            try? FileManager.default.removeItem(at: guardDir)
            try FileManager.default.createDirectory(at: guardDir, withIntermediateDirectories: true)
            try setUp()
            let (code, json) = try helper("status")
            XCTAssertEqual(code, 0, name)
            let expected = try XCTUnwrap(JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)).objectValue)
            let actual = try normalized()
            for (key, value) in expected {
                // Ages derive from "now", which the two read a moment apart.
                if key == "ageSeconds", let a = actual[key]?.numberValue, let e = value.numberValue {
                    XCTAssertLessThanOrEqual(abs(a - e), 1, "\(name).\(key)")
                    continue
                }
                XCTAssertEqual(actual[key], value, "\(name).\(key)")
            }
        }
    }

    /// A status without `lidClosedEffective` (or with null) must not claim
    /// the Mac stays awake with the lid closed. The helper fell back to the
    /// request's `lidClosed`; the workflow says what is safe instead. The
    /// guard always writes the field, so this only guards a bad file.
    func testUnknownLidStateIsNotReportedAsAwake() throws {
        let until = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))
        try writeStatus(["onAC": true, "phase": "override", "blockers": [],
                         "override": ["id": "A", "until": until, "lidClosed": true, "lidClosedEffective": NSNull()]])
        XCTAssertTrue(try render().text.contains("Closing the lid still sleeps."))
        XCTAssertEqual(try normalized()["lidClosedEffective"], .bool(false))
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
