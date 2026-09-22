import Foundation
import XCTest

@testable import MenubucketCore

/// A script widget that exits before the host's next message must cost that
/// widget a failed send — not the host process. Without F_SETNOSIGPIPE this
/// test does not fail; it kills the test runner with SIGPIPE, which is
/// exactly how CI reported it.
final class StdinPipeSignalTests: XCTestCase {
    func testWritingToAnExitedChildThrowsInsteadOfRaisingSIGPIPE() throws {
        let pipe = RuntimeSupervisor.makeStdinPipe()
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        child.standardInput = pipe
        try child.run()
        child.waitUntilExit()
        // The child held the only read end; drop ours too so the pipe has
        // no reader at all.
        try pipe.fileHandleForReading.close()

        XCTAssertThrowsError(
            try pipe.fileHandleForWriting.write(contentsOf: Data("{}\n".utf8))
        ) { error in
            // Foundation wraps it: NSCocoaError 512 over POSIX EPIPE.
            let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError
            XCTAssertEqual(underlying?.code ?? (error as NSError).code, Int(EPIPE), "\(error)")
        }
    }
}
