import XCTest
@testable import BarShelfKit

/// The packaged CLI prints its embedded copy of docs/AGENTS.md. It drifted
/// once (0.7.23 shipped without the Touch ID section); this keeps it equal.
final class AgentSpecEmbeddedTests: XCTestCase {
    func testEmbeddedSpecMatchesDocs() throws {
        let docs = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/AGENTS.md")
        let markdown = try String(contentsOf: docs, encoding: .utf8)
        XCTAssertEqual(AgentSpecEmbedded.markdown, markdown.trimmingCharacters(in: .newlines),
                       "run scripts/gen-agent-spec.py")
    }
}
