import Darwin
import XCTest
@testable import MenubucketCore

final class ExecEnvironmentTests: XCTestCase {
    func testChildReceivesInjectedValueButNotUnrelatedParentSecret() throws {
        let secretName = "BARSHELF_TEST_PARENT_SECRET"
        setenv(secretName, "must-not-leak", 1)
        defer { unsetenv(secretName) }

        let result = ExecService.captureSync(
            command: ["/usr/bin/env"],
            discover: nil,
            timeoutMs: 2_000,
            workingDirectory: nil,
            extraEnvironment: ["BARSHELF_TEST_ALLOWED": "visible"]
        )
        let capture = try result.get()
        let output = String(decoding: capture.stdout, as: UTF8.self)
        XCTAssertTrue(output.contains("BARSHELF_TEST_ALLOWED=visible"))
        XCTAssertFalse(output.contains(secretName))
        XCTAssertFalse(output.contains("must-not-leak"))
    }
}
