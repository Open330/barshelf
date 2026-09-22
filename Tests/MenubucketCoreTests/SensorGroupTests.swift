import Foundation
import XCTest

@testable import MenubucketCore

/// Narrowing a sensor sample to the components a widget displays. Every SMC
/// key is its own IOKit round trip, so this is where a menu-bar cadence
/// spends its time — but a hint the host misreads must never blank a reading.
final class SensorGroupTests: XCTestCase {
    func testReadingNamesMapOntoTheGroupsThatFeedThem() {
        XCTAssertEqual(SensorSampler.groups(forReading: "cpu"), [.cpu])
        XCTAssertEqual(SensorSampler.groups(forReading: "gpu"), [.gpu])
        XCTAssertEqual(SensorSampler.groups(forReading: "battery"), [.battery])
        // Case and padding come from a settings value, not a literal.
        XCTAssertEqual(SensorSampler.groups(forReading: "  CPU "), [.cpu])
    }

    func testPeakAndTheFullListNeedEveryGroup() {
        // `peak` is the hottest of everything, so narrowing would change it.
        XCTAssertNil(SensorSampler.groups(forReading: "peak"))
        XCTAssertNil(SensorSampler.groups(forReading: "all"))
        XCTAssertNil(SensorSampler.groups(forReading: "list"))
    }

    func testFanAndPowerReadingsNeedNoTemperatures() {
        // Fans and wattage have their own keys, which are always read.
        XCTAssertEqual(SensorSampler.groups(forReading: "power"), [])
        XCTAssertEqual(SensorSampler.groups(forReading: "fan"), [])
        XCTAssertEqual(SensorSampler.groups(forReading: "fanUsage"), [])
        XCTAssertEqual(SensorSampler.groups(forReading: "none"), [])
    }

    func testAnUnrecognizedHintFallsBackToReadingEverything() {
        // A widget written against a newer field name must degrade to a
        // correct (merely slower) sample, never to a missing one.
        XCTAssertNil(SensorSampler.groups(forReading: "neuralEngine"))
        XCTAssertNil(SensorSampler.groups(forReading: ""))
    }

    func testKeysAreGroupedByTheSamePredicatesThatSummarizeThem() {
        // If these disagreed, a filtered sample could read keys that the
        // averages then ignore — or miss keys they expect.
        for key in ["Tp01", "Tp3h", "Te05"] {
            XCTAssertEqual(SensorSampler.group(forSMCKey: key), .cpu, key)
        }
        for key in ["Tg0f", "Tg1a"] {
            XCTAssertEqual(SensorSampler.group(forSMCKey: key), .gpu, key)
        }
        XCTAssertEqual(SensorSampler.group(forSMCKey: "TB1T"), .battery)
        // Enclosure/package keys summarize nothing but still count for peak.
        XCTAssertEqual(SensorSampler.group(forSMCKey: "TCHP"), .other)
    }

    func testEveryGroupIsReachableFromAReadingName() {
        // `other` has no name of its own — it only ever arrives via "all".
        let named = Set(
            ["cpu", "gpu", "battery"].compactMap { SensorSampler.groups(forReading: $0) }
                .flatMap { $0 }
        )
        XCTAssertEqual(named, [.cpu, .gpu, .battery])
        XCTAssertTrue(SensorSampler.SensorGroup.allCases.contains(.other))
    }

    /// The sampler is hardware-dependent, so this only asserts the shape the
    /// filter guarantees: asking for nothing reads no temperatures.
    func testEmptyGroupSetReadsNoTemperatures() {
        let snapshot = SensorSampler.shared.sample(detail: false, groups: [])
        XCTAssertNil(snapshot.cpu)
        XCTAssertNil(snapshot.gpu)
        XCTAssertNil(snapshot.battery)
        XCTAssertNil(snapshot.peak)
        XCTAssertTrue(snapshot.list.isEmpty)
    }

    /// `detail` is the card's full sensor list, so it overrides a narrower
    /// request rather than returning a filtered list.
    func testDetailOverridesTheGroupFilter() {
        let filtered = SensorSampler.shared.sample(detail: true, groups: [.cpu])
        let everything = SensorSampler.shared.sample(detail: true, groups: nil)
        XCTAssertEqual(filtered.list.count, everything.list.count)
    }
}
