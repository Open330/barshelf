import XCTest
@testable import MenubucketCore

final class MetricSampleCacheTests: XCTestCase {
    func testAlignedWidgetsShareCollectionButOtherMountsAndExpiredSamplesDoNot() {
        let cache = MetricSampleCache<Int>()
        var reads = 0
        func read(_ key: String, at time: TimeInterval) -> Int {
            cache.sample(key: key, now: time) { reads += 1; return reads }
        }
        XCTAssertEqual(read("/", at: 10), 1)
        XCTAssertEqual(read("/", at: 10.2), 1)
        XCTAssertEqual(read("/Volumes/External", at: 10.2), 2)
        XCTAssertEqual(read("/", at: 10.25), 3)
        XCTAssertEqual(read("/", at: 9), 4, "a clock discontinuity must not retain old readings")
        XCTAssertEqual(reads, 4)
    }

    func testConcurrentRequestsCollectOnlyOnce() {
        let cache = MetricSampleCache<Int>()
        var reads = 0
        DispatchQueue.concurrentPerform(iterations: 50) { _ in
            _ = cache.sample(now: 10) { reads += 1; return reads }
        }
        XCTAssertEqual(reads, 1)
    }

    /// A slow key does not hold up another: before, one lock covered every
    /// collection, so a hung volume stalled every disk sample.
    func testASlowKeyDoesNotBlockAnotherKey() {
        let cache = MetricSampleCache<Int>()
        let slowStarted = DispatchSemaphore(value: 0)
        let releaseSlow = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = cache.sample(key: "/Volumes/hung") {
                slowStarted.signal()
                releaseSlow.wait()
                return 1
            }
        }
        slowStarted.wait()
        let started = Date()
        XCTAssertEqual(cache.sample(key: "/") { 2 }, 2)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
        releaseSlow.signal()
    }
}
