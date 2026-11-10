import Foundation
import XCTest

@testable import MenubucketCore

/// Compiling an expression once may only make evaluation cheaper, never
/// different: same values, same errors, same laziness.
final class CompiledExpressionTests: XCTestCase {
    private func label(_ text: String, cpu: Double = 0) throws -> String? {
        let def = try WorkflowDefinition.decode(from: Data("""
        {"schemaVersion":1,"sources":{},"status":{"label":\(String(data: try JSONEncoder().encode(text), encoding: .utf8)!)},
         "view":{"type":"text","text":"x"}}
        """.utf8))
        return try WorkflowEngine.evaluate(
            def, sources: ["d": .object(["cpu": .number(cpu)])], settings: .object([:])
        ).statusLabel
    }

    func testRepeatedEvaluationGivesTheSameAnswers() throws {
        let text = "${concat(string(round(sources.d.cpu, 0)), if(gt(sources.d.cpu, 50), '!', ''))}"
        for _ in 0..<3 {
            XCTAssertEqual(try label(text, cpu: 12.4), "12")
            XCTAssertEqual(try label(text, cpu: 73.6), "74!")
        }
        XCTAssertEqual(try label("${concat('a, b', string(add(1, 2)))}"), "a, b3")
        XCTAssertEqual(try label("cpu ${sources.d.cpu}%", cpu: 7), "cpu 7%")
        XCTAssertEqual(try label("${$.sources.d.cpu}", cpu: 9), "9")
    }

    /// A broken argument in a branch that doesn't run must stay harmless,
    /// as it was when the text was read lazily.
    func testErrorsOnlyWhereEvaluationReaches() throws {
        XCTAssertEqual(try label("${if(true, 'ok', )}"), "ok")
        XCTAssertEqual(try label("${coalesce('x', nosuch.path)}"), "x")
        XCTAssertEqual(try label("${and(false, nofunc(1))}"), "false")
        XCTAssertThrowsError(try label("${if(false, 'ok', )}"))
        XCTAssertThrowsError(try label("${and(true, nofunc(1))}"))
        XCTAssertThrowsError(try label("a ${sources.d.cpu"))
        XCTAssertThrowsError(try label("${nosuch.path}"))
    }

    func testDeepNestingStillThrowsInsteadOfOverflowing() {
        let deep = String(repeating: "count(", count: 400) + "1" + String(repeating: ")", count: 400)
        XCTAssertThrowsError(try label("${\(deep)}"))
        // Deep but unreached: no error, as before.
        XCTAssertEqual(try label("${if(true, 'ok', \(deep))}"), "ok")
    }

    /// Canonically equal text with different bytes keeps its own bytes.
    func testCacheKeysAreExactBytes() throws {
        XCTAssertEqual(try label("${'\u{00E9}'}")?.unicodeScalars.map(\.value), [0xE9])
        XCTAssertEqual(try label("${'e\u{0301}'}")?.unicodeScalars.map(\.value), [0x65, 0x301])
    }

    func testPlainTextIsNotCached() {
        let cache = CompiledExpressionCache()
        for i in 0..<100 { _ = cache.template("plain \(i)") }
        XCTAssertEqual(cache.count, 0)
    }

    func testTheCacheIsBounded() {
        let cache = CompiledExpressionCache()
        for i in 0..<(CompiledExpressionCache.limit + 10) { _ = cache.expression("n\(i)") }
        XCTAssertLessThanOrEqual(cache.count, CompiledExpressionCache.limit)
        let big = String(repeating: "x", count: 1 << 20)
        for i in 0..<10 { _ = cache.expression("\(i)\(big)") }
        XCTAssertLessThan(cache.count, 10, "the byte budget empties it before 10 MB")
    }
}
