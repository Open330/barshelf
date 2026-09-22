import Foundation
import MenubucketCore
import XCTest

@testable import MenubucketApp

/// `"sensors"` on a `system` source — the hint that lets a widget say which
/// reading it displays so the sampler can skip the rest. Parsing it wrong in
/// the narrowing direction would blank a menu bar reading, so everything the
/// host does not recognise falls back to sampling everything.
final class SystemSourceSensorParamTests: XCTestCase {
    private func groups(_ value: JSONValue?) -> Set<SensorSampler.SensorGroup>? {
        WidgetRuntime.sensorGroups(from: value)
    }

    func testAbsentParameterReadsEverything() {
        XCTAssertNil(groups(nil))
        XCTAssertNil(groups(.null))
        // A workflow that writes `"sensors": true` meant nothing sensible;
        // reading everything is the safe interpretation.
        XCTAssertNil(groups(.bool(true)))
    }

    func testASingleReadingNameNarrowsTheSample() {
        XCTAssertEqual(groups(.string("cpu")), [.cpu])
        XCTAssertEqual(groups(.string("battery")), [.battery])
        XCTAssertEqual(groups(.string("power")), [])
        XCTAssertNil(groups(.string("all")))
    }

    func testAListOfNamesUnionsTheirGroups() {
        XCTAssertEqual(groups(.array([.string("cpu"), .string("gpu")])), [.cpu, .gpu])
        // "power" contributes no temperature keys but does not widen either.
        XCTAssertEqual(groups(.array([.string("cpu"), .string("power")])), [.cpu])
        XCTAssertEqual(groups(.array([])), [])
    }

    func testAListContainingAnythingBroadReadsEverything() {
        // One entry that needs every group makes the whole request broad.
        XCTAssertNil(groups(.array([.string("cpu"), .string("peak")])))
        XCTAssertNil(groups(.array([.string("cpu"), .string("neuralEngine")])))
        XCTAssertNil(groups(.array([.string("cpu"), .number(3)])))
    }
}
