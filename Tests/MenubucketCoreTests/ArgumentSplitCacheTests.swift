import Foundation
import XCTest

@testable import MenubucketCore

/// The split cache may only make evaluation cheaper, never different.
final class ArgumentSplitCacheTests: XCTestCase {
    private func evaluate(_ label: String, cpu: Double) throws -> String? {
        let def = try WorkflowDefinition.decode(from: Data("""
        {"schemaVersion":1,"sources":{},"status":{"label":\(String(data: try JSONEncoder().encode(label), encoding: .utf8)!)},
         "view":{"type":"text","text":"x"}}
        """.utf8))
        return try WorkflowEngine.evaluate(
            def, sources: ["d": .object(["cpu": .number(cpu)])], settings: .object([:])
        ).statusLabel
    }

    func testRepeatedEvaluationGivesTheSameAnswers() throws {
        let label = "${concat(string(round(sources.d.cpu, 0)), if(gt(sources.d.cpu, 50), '!', ''))}"
        for _ in 0..<3 {
            XCTAssertEqual(try evaluate(label, cpu: 12.4), "12")
            XCTAssertEqual(try evaluate(label, cpu: 73.6), "74!")
        }
        // Quoted commas and nested calls still split the same way when cached.
        let quoted = "${concat('a, b', string(add(1, 2)))}"
        XCTAssertEqual(try evaluate(quoted, cpu: 0), "a, b3")
        XCTAssertEqual(try evaluate(quoted, cpu: 0), "a, b3")
    }

    func testTheCacheIsBounded() {
        let cache = ArgumentSplitCache()
        for i in 0..<(ArgumentSplitCache.limit + 10) {
            cache.store(["\(i)"], for: "k\(i)")
        }
        XCTAssertLessThanOrEqual(cache.count, ArgumentSplitCache.limit)
        XCTAssertEqual(cache.lookup("k\(ArgumentSplitCache.limit + 9)"), ["\(ArgumentSplitCache.limit + 9)"])
    }
}
