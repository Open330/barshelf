import XCTest
@testable import MenubucketApp

final class PointerWatcherTests: XCTestCase {
    /// Without the event tap the pointer is read by a timer: fast only
    /// where the cluster follows it, a few times a second elsewhere.
    func testFallbackPollsFastOnlyWhereThePointerMatters() {
        XCTAssertEqual(PointerWatcher.interval(hot: true), 1.0 / 30, accuracy: 0.0001)
        XCTAssertEqual(PointerWatcher.interval(hot: false), 0.25, accuracy: 0.0001)
        XCTAssertGreaterThan(PointerWatcher.idlePollInterval / PointerWatcher.pollInterval, 5)
    }
}
