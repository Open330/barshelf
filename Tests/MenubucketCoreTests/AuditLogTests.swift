import XCTest
@testable import MenubucketCore

final class AuditLogTests: XCTestCase {
    private var directory: URL!
    private var url: URL { directory.appendingPathComponent("audit.log") }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("barshelf-audit-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private final class Clock: @unchecked Sendable {
        var date = Date(timeIntervalSince1970: 1_800_000_000)
    }

    private func lines(_ file: URL? = nil) throws -> [[String: Any]] {
        try String(contentsOf: file ?? url, encoding: .utf8)
            .split(separator: "\n")
            .map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
    }

    /// A widget refreshing every few seconds used to add a line per run.
    func testRoutineRunsAreWrittenOncePerWindowWithACount() throws {
        let clock = Clock()
        let log = AuditLog(fileURL: url, routineWindow: 600, now: { clock.date })
        let run: [String: JSONValue] = ["command": .string("/bin/date +%s"), "trigger": .string("refresh")]
        for _ in 0..<100 {
            log.record("exec.run", widgetId: "clock", detail: run)
            clock.date += 2
        }
        XCTAssertEqual(try lines().count, 1)

        clock.date += 600
        log.record("exec.run", widgetId: "clock", detail: run)
        let written = try lines()
        XCTAssertEqual(written.count, 2)
        XCTAssertEqual(written[1]["repeats"] as? Double, 99)
    }

    /// Anything that differs, a click, or a non-routine event is written at once.
    func testDifferentRunsClicksAndDecisionsAreAlwaysWritten() throws {
        let log = AuditLog(fileURL: url)
        log.record("exec.run", widgetId: "w", detail: ["command": .string("a"), "trigger": .string("refresh")])
        log.record("exec.run", widgetId: "w", detail: ["command": .string("b"), "trigger": .string("refresh")])
        log.record("exec.run", widgetId: "other", detail: ["command": .string("a"), "trigger": .string("refresh")])
        log.record("exec.run", widgetId: "w", detail: ["command": .string("a"), "exitCode": .number(1)])
        log.record("exec.run", widgetId: "w", detail: ["command": .string("a"), "trigger": .string("run-action")])
        log.record("exec.run", widgetId: "w", detail: ["command": .string("a"), "trigger": .string("run-action")])
        log.record("network.fetch", widgetId: "w", detail: ["url": .string("https://a.example"), "trigger": .string("workflow")])
        log.record("network.fetch", widgetId: "w", detail: ["url": .string("https://b.example"), "trigger": .string("workflow")])
        log.record("permission.approved", widgetId: "w")
        log.record("permission.approved", widgetId: "w")
        XCTAssertEqual(try lines().count, 10)
    }

    func testRotatesAndKeepsTwoOldFiles() throws {
        let log = AuditLog(fileURL: url, rotateAtBytes: 200)
        for index in 0..<40 {
            log.record("permission.approved", widgetId: "w\(index)")
        }
        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: url.path))
        XCTAssertTrue(fm.fileExists(atPath: url.path + ".1"))
        XCTAssertTrue(fm.fileExists(atPath: url.path + ".2"))
        XCTAssertFalse(fm.fileExists(atPath: url.path + ".3"))
        let size = try XCTUnwrap(fm.attributesOfItem(atPath: url.path)[.size] as? Int)
        XCTAssertLessThan(size, 400)
        XCTAssertEqual(try lines().last?["widgetId"] as? String, "w39")
    }
}
