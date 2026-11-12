import CoreGraphics
import XCTest
@testable import BarShelfAutomation

/// The remap decision without a real event tap (which needs Accessibility):
/// events are made by hand and passed through `apply`.
final class AutomationKeyTapTests: XCTestCase {
    private func key(_ code: CGKeyCode, down: Bool, flags: CGEventFlags = [], keyboard: Int64 = 91) throws -> CGEvent {
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down))
        event.flags = flags
        event.setIntegerValueField(.keyboardEventKeyboardType, value: keyboard)
        return event
    }

    private func makeTap(released: @escaping (Int64) -> Void = { _ in }) -> AutomationKeyTap {
        AutomationKeyTap(remap: .init(keyboardTypes: [91], keys: [34: 126]), keyRemaps: [], postKeyUp: released)
    }

    private func code(_ event: CGEvent) -> Int64 { event.getIntegerValueField(.keyboardEventKeycode) }

    func testFnRemapRewritesTheKeyAndKeepsItUntilKeyUp() throws {
        // i (34) → up arrow (126) while fn is held, on keyboard type 91.
        let tap = makeTap()
        let down = try key(34, down: true, flags: .maskSecondaryFn)
        tap.apply(type: .keyDown, to: down)
        XCTAssertEqual(code(down), 126)
        XCTAssertFalse(down.flags.contains(.maskSecondaryFn))

        // fn released first: the key-up still has to be the arrow's.
        let up = try key(34, down: false)
        tap.apply(type: .keyUp, to: up)
        XCTAssertEqual(code(up), 126)

        let plain = try key(34, down: true)
        tap.apply(type: .keyDown, to: plain)
        XCTAssertEqual(code(plain), 34, "without fn the key is left alone")
    }

    func testOtherKeyboardTypesAreLeftAlone() throws {
        let tap = makeTap()
        let event = try key(34, down: true, flags: .maskSecondaryFn, keyboard: 40)
        tap.apply(type: .keyDown, to: event)
        XCTAssertEqual(code(event), 34)
    }

    func testReleasingHeldKeysForgetsThem() throws {
        var released: [Int64] = []
        let tap = makeTap { released.append($0) }
        tap.apply(type: .keyDown, to: try key(34, down: true, flags: .maskSecondaryFn))
        tap.releaseHeldKeys()
        XCTAssertEqual(released, [126], "the arrow that was sent down is sent up")
        let up = try key(34, down: false)
        tap.apply(type: .keyUp, to: up)
        XCTAssertEqual(code(up), 34, "a released key is no longer tracked")
    }

    /// The tap thread and the main thread both reach the held-key state.
    func testApplyAndReleaseFromTwoThreadsDoNotRace() throws {
        let tap = makeTap()
        let events = try (0..<2_000).map { try key(34, down: $0.isMultiple(of: 2), flags: .maskSecondaryFn) }
        let group = DispatchGroup()
        DispatchQueue.global().async(group: group) {
            for (index, event) in events.enumerated() {
                tap.apply(type: index.isMultiple(of: 2) ? .keyDown : .keyUp, to: event)
            }
        }
        DispatchQueue.global().async(group: group) {
            for _ in 0..<500 { tap.releaseHeldKeys() }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 20), .success)
    }

    func testRemovingATapThatWasNeverInstalledIsHarmless() {
        let tap = AutomationKeyTap(remap: nil, keyRemaps: [], postKeyUp: { _ in })
        tap.remove()
        tap.remove()
        XCTAssertFalse(tap.isValid)
        XCTAssertFalse(tap.isEnabled)
    }
}
