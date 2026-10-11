import XCTest
@testable import MenubucketCore

final class ExecPipeDeadlineTests: XCTestCase {
    func testRepeatedFailedExecLaunchesReleasePipeHandles() throws {
        let executable = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data(repeating: 0, count: 32).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        defer { try? FileManager.default.removeItem(at: executable) }
        let initialHandles = try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
        for _ in 0..<64 {
            let result = ExecService.captureSync(command: [executable.path], discover: nil,
                                                 timeoutMs: 1000, workingDirectory: nil)
            guard case .failure(.launchFailed) = result else {
                return XCTFail("Expected executable launch failure, got \(result)")
            }
        }
        let finalHandles = try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
        XCTAssertLessThanOrEqual(finalHandles, initialHandles + 4)
    }

    func testOutputLimitKillsCommandIgnoringTerminationBeforeItsLongTimeout() {
        let start = DispatchTime.now().uptimeNanoseconds
        let result = ExecService.captureSync(
            command: ["/bin/sh", "-c", "trap '' TERM; printf overflow; exec /bin/sleep 30"],
            discover: nil, timeoutMs: 8000, workingDirectory: nil, stdoutLimit: 1
        )
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
        guard case .failure(.outputTooLarge(limit: 1)) = result else {
            return XCTFail("Expected output-limit failure, got \(result)")
        }
        XCTAssertLessThan(elapsed, 4, "output overflow must escalate to SIGKILL without waiting for timeout")
    }

    func testExitedParentDoesNotWaitForInheritedPipePastDeadline() {
        let start = DispatchTime.now().uptimeNanoseconds
        let result = ExecService.captureSync(command: ["/bin/sh", "-c", "sleep 2 & exit 0"], discover: nil,
                                             timeoutMs: 200, workingDirectory: nil)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
        guard case .failure(.timeout) = result else { return XCTFail("Expected inherited-pipe timeout, got \(result)") }
        XCTAssertLessThan(elapsed, 1.5, "must not wait for the 2-second descendant to close stdout/stderr")
    }

    func testNormalOutputStillDrainsBothPipesBeforeReturning() throws {
        let result = ExecService.captureSync(command: ["/bin/sh", "-c", "printf output; printf diagnostic >&2"],
                                             discover: nil, timeoutMs: 2000, workingDirectory: nil)
        let captured = try result.get()
        XCTAssertEqual(String(decoding: captured.stdout, as: UTF8.self), "output")
        XCTAssertEqual(String(decoding: captured.stderr, as: UTF8.self), "diagnostic")
    }
}
