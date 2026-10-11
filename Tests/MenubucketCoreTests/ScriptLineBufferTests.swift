import XCTest
@testable import MenubucketCore

final class ScriptLineBufferTests: XCTestCase {
    func testOversizedNewlineTerminatedMessagesAreRejectedToo() {
        let buffer = RuntimeSupervisor.LineBuffer()
        let result = buffer.append(Data("123456\nok\n".utf8), maxBytes: 4)
        XCTAssertTrue(result.overflow)
        XCTAssertEqual(result.lines.map { String(decoding: $0, as: UTF8.self) }, ["ok"])
        XCTAssertTrue(buffer.drain().isEmpty)
    }

    func testNewlineFreeStderrCannotAccumulateWithoutBound() {
        let buffer = RuntimeSupervisor.LineBuffer()
        for _ in 0..<100 {
            _ = buffer.append(Data(repeating: 65, count: 1024), maxBytes: 4096)
        }
        XCTAssertLessThanOrEqual(buffer.drain().count, 4096)
        let result = buffer.append(Data("recovered\n".utf8), maxBytes: 4096)
        XCTAssertFalse(result.overflow)
        XCTAssertEqual(result.lines, [Data("recovered".utf8)])
    }
}
