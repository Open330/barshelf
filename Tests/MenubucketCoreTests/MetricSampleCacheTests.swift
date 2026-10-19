import XCTest
@testable import MenubucketCore

final class MetricSampleCacheTests: XCTestCase {
    func testSlowCollectionStillHasAReuseWindowAfterItCompletes() {
        let cache = MetricSampleCache<Int>(window: 0.03)
        var reads = 0
        XCTAssertEqual(cache.sample {
            reads += 1
            Thread.sleep(forTimeInterval: 0.05)
            return 1
        }, 1)
        XCTAssertEqual(cache.sample { reads += 1; return 2 }, 1)
        XCTAssertEqual(reads, 1, "slow collection must not expire its own freshly completed sample")
    }

    func testLockCacheChurnCannotStartASecondCollectionForAnActiveKey() {
        let cache = MetricSampleCache<Int>()
        let firstStarted = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let duplicate = expectation(description: "active key must retain its original lock")
        duplicate.isInverted = true
        let completed = expectation(description: "both callers receive the shared result")
        completed.expectedFulfillmentCount = 2
        DispatchQueue.global().async {
            let result = cache.sample(key: "active", now: 10) {
                firstStarted.signal()
                releaseFirst.wait()
                return 1
            }
            XCTAssertEqual(result, 1)
            completed.fulfill()
        }
        XCTAssertEqual(firstStarted.wait(timeout: .now() + 1), .success)
        // Force eviction pressure while the first collection owns its lock.
        for index in 0..<(MetricSampleCache<Int>.keyLimit * 4 + 1) {
            _ = cache.sample(key: "other-\(index)", now: 10) { index }
        }
        DispatchQueue.global().async {
            let result = cache.sample(key: "active", now: 10) {
                duplicate.fulfill()
                return 2
            }
            XCTAssertEqual(result, 1)
            completed.fulfill()
        }
        wait(for: [duplicate], timeout: 0.15)
        releaseFirst.signal()
        wait(for: [completed], timeout: 1)
    }

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
