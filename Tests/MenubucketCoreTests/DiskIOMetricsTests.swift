import XCTest
@testable import MenubucketCore

final class DiskIOMetricsTests: XCTestCase {
    func testRatesNeedTwoSamplesAndRebaselineOnAReset() {
        var next: DiskIOMetrics.Counters? = .init(read: 1_000, written: 0)
        let sampler = DiskIOMetrics.Sampler(read: { next })
        XCTAssertNil(sampler.sample(now: 10).read, "the first sample has nothing to difference")
        next = .init(read: 3_000, written: 500)
        XCTAssertEqual(sampler.sample(now: 12).read, 1_000)
        XCTAssertEqual(sampler.sample(now: 12.1).write, 250, "inside the minimum window the last rate is shared")
        next = .init(read: 10, written: 0)
        XCTAssertNil(sampler.sample(now: 14).read, "a counter going backwards re-baselines")
        next = .init(read: 110, written: 0)
        XCTAssertEqual(sampler.sample(now: 15).read, 100)
        XCTAssertNil(sampler.sample(now: 15 + 16 * 60).read, "a long sleep is not averaged across")
        next = nil
        XCTAssertNil(sampler.sample(now: 2_000).read)
    }

    func testTheRealCountersRead() throws {
        guard let counters = DiskIOMetrics.readCounters() else { throw XCTSkip("no block storage here") }
        XCTAssertGreaterThan(counters.read, 0)
    }
}
