import AppKit
import os
import XCTest
@testable import MenubucketApp

/// The menu bar cluster is redrawn when the bar turns light or dark; this is
/// the observation that tells it.
@MainActor
final class AppearanceObservationTests: XCTestCase {
    func testReportsTheNewLookWhenTheViewsAppearanceChanges() {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        view.appearance = NSAppearance(named: .aqua)
        let looks = OSAllocatedUnfairLock(initialState: [NSAppearance.Name?]())
        let observation = AppearanceObservation(of: view) { look in looks.withLock { $0.append(look) } }

        view.appearance = NSAppearance(named: .darkAqua)
        XCTAssertEqual(looks.withLock { $0 }.last, .some(.darkAqua))
        view.appearance = NSAppearance(named: .aqua)
        XCTAssertEqual(looks.withLock { $0 }.last, .some(.aqua))
        _ = observation
    }

    func testStopsReportingOnceReleased() {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        view.appearance = NSAppearance(named: .aqua)
        let looks = OSAllocatedUnfairLock(initialState: [NSAppearance.Name?]())
        var observation: AppearanceObservation? = AppearanceObservation(of: view) { look in
            looks.withLock { $0.append(look) }
        }
        XCTAssertNotNil(observation)
        observation = nil

        view.appearance = NSAppearance(named: .darkAqua)
        XCTAssertTrue(looks.withLock { $0 }.isEmpty)
    }
}
