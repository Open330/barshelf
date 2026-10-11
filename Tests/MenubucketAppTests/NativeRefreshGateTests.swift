import XCTest
@testable import MenubucketApp

final class NativeRefreshGateTests: XCTestCase {
    func testReloadRejectsOldOutputButReleasesItsOwnedSlot() {
        var gate = NativeRefreshGate()
        let old = gate.begin("cpu")
        gate.reload(keeping: ["cpu"])
        XCTAssertFalse(gate.isCurrent("cpu", token: old))
        XCTAssertEqual(gate.finish("cpu", token: old), .staleConfiguration)
        let replacement = gate.begin("cpu")
        XCTAssertTrue(gate.isCurrent("cpu", token: replacement))
        XCTAssertEqual(gate.finish("cpu", token: replacement), .current)
    }

    func testLateCompletionCannotCancelTheReplacementAfterDisableAndReenable() {
        var gate = NativeRefreshGate()
        let old = gate.begin("w")
        gate.cancel("w")
        let replacement = gate.begin("w")
        XCTAssertEqual(gate.finish("w", token: old), .superseded)
        XCTAssertTrue(gate.isCurrent("w", token: replacement))
        XCTAssertEqual(gate.finish("w", token: replacement), .current)
        XCTAssertEqual(gate.finish("w", token: replacement), .superseded)
    }

    func testRemovingAndReinstallingSameIDDoesNotRestoreRemovedOutput() {
        var gate = NativeRefreshGate()
        let old = gate.begin("w")
        gate.reload(keeping: [])
        XCTAssertEqual(gate.finish("w", token: old), .superseded)
        let reinstalled = gate.begin("w")
        XCTAssertEqual(gate.finish("w", token: old), .superseded)
        XCTAssertEqual(gate.finish("w", token: reinstalled), .current)
    }
}
