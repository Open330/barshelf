import XCTest
@testable import MenubucketApp

final class AlertDeliveryGateTests: XCTestCase {
    /// Disable, removal, reload and revoke all invalidate: a permit taken
    /// before stops being current, and pending deliveries are cancelled.
    func testInvalidationEndsPermitsAndPendingDeliveries() async throws {
        let gate = AlertDeliveryGate()
        let permit = gate.permit("w")
        XCTAssertTrue(gate.isCurrent("w", permit))
        let started = expectation(description: "started")
        let task = Task {
            started.fulfill()
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
        gate.track("w", UUID(), task)
        await fulfillment(of: [started], timeout: 2)
        gate.invalidate("w")
        XCTAssertFalse(gate.isCurrent("w", permit))
        XCTAssertTrue(task.isCancelled)
        XCTAssertEqual(gate.pendingCount, 0)
        XCTAssertTrue(gate.isCurrent("w", gate.permit("w")), "a new permit after invalidation is current")
        XCTAssertTrue(gate.isCurrent("other", gate.permit("other")), "other instances are untouched")
    }
}
