import Foundation
import XCTest
@testable import MenubucketCore

/// Renders every bundled workflow with fixed inputs and writes the results,
/// so two builds can be diffed. Off unless BARSHELF_DUMP_DIR is set.
final class WorkflowSnapshotDump: XCTestCase {
    func testDumpBundledWorkflows() throws {
        guard let out = ProcessInfo.processInfo.environment["BARSHELF_DUMP_DIR"] else { throw XCTSkip("set BARSHELF_DUMP_DIR") }
        let widgets = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("widgets")
        let fixture = JSONValue.object([
            "cpu": .object(["usage": .number(37.5), "cores": .number(8)]),
            "memory": .object(["used": .number(9e9), "total": .number(16e9), "usage": .number(56), "pressure": .string("normal")]),
            "disk": .object(["used": .number(3e11), "total": .number(5e11), "free": .number(2e11)]),
            "sensors": .object(["cpu": .number(52), "battery": .number(31)]),
            "items": .array([.object(["id": .string("a"), "name": .string("A"), "modifiedAt": .number(1.7e12)])]),
            "exists": .bool(true), "valid": .bool(true), "value": .object(["phase": .string("ac"), "version": .number(1)]),
        ])
        for dir in try FileManager.default.contentsOfDirectory(atPath: widgets.path).sorted() {
            let file = widgets.appendingPathComponent("\(dir)/workflow.json")
            guard let data = try? Data(contentsOf: file) else { continue }
            var result: String
            do {
                let def = try WorkflowDefinition.decode(from: data)
                let sources = Dictionary(uniqueKeysWithValues: def.sources.keys.map { ($0, fixture) })
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                result = ""
                for visible in [true, false] {
                    let output = try WorkflowEngine.evaluate(
                        def, sources: sources, settings: .object([:]),
                        widget: .object(["visible": .bool(visible), "locale": .string("en")]), nowMs: 1.8e12)
                    result += String(decoding: try encoder.encode(output.viewTree), as: UTF8.self)
                        + "\nlabel=\(output.statusLabel ?? "nil") icon=\(output.statusIcon ?? "nil") items=\(output.expandedItemCount)\n"
                }
            } catch {
                result = "error: \(error)"
            }
            try result.write(toFile: "\(out)/\(dir).txt", atomically: true, encoding: .utf8)
        }
    }
}
