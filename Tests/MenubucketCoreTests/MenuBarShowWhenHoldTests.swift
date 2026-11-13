import Foundation
import XCTest

@testable import MenubucketCore

/// The hold that keeps a "show only when" item in the menu bar a while
/// after its reading stopped qualifying.
final class MenuBarShowWhenHoldTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)

    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    /// An entry reading `value` percent, shown only at or past `showWhen`.
    private func entry(_ id: String = "w", reading value: Double? = 90, showWhen: Double? = 80) -> MenuBarEntry {
        MenuBarEntry(
            widgetID: id, name: id,
            metrics: value.map { [StatusMetric(id: "load", label: "Load", number: $0, format: "percent")] } ?? [],
            presentation: MenuBarPresentation(showWhen: showWhen)
        )
    }

    func testHoldIsSixtySecondsUnlessGiven() {
        XCTAssertEqual(MenuBarShowWhenHold().hold, 60)
        XCTAssertEqual(MenuBarShowWhenHold(hold: 5).hold, 5)
        XCTAssertEqual(MenuBarShowWhenHold().metAt, [:])
    }

    func testWidgetWithNoShowWhenRuleIsNeverDormant() {
        var hold = MenuBarShowWhenHold()
        for seconds in [0.0, 60, 3600] {
            XCTAssertEqual(hold.dormant(among: [entry(reading: 1, showWhen: nil)], now: at(seconds)), [])
        }
        XCTAssertEqual(hold.metAt, [:], "no rule: nothing starts the hold")
    }

    func testEntryWithNoReadingToJudgeIsNeitherDormantNorStamped() {
        var hold = MenuBarShowWhenHold()
        XCTAssertEqual(hold.dormant(among: [entry(reading: nil)], now: t0), [])
        XCTAssertEqual(hold.metAt, [:])
    }

    func testQualifyingReadingIsShownAndStamped() {
        var hold = MenuBarShowWhenHold()
        XCTAssertEqual(hold.dormant(among: [entry(reading: 90)], now: t0), [])
        XCTAssertEqual(hold.metAt, ["w": t0])
    }

    func testNotQualifyingWithNoStampIsDormantAtOnce() {
        var hold = MenuBarShowWhenHold()
        XCTAssertEqual(hold.dormant(among: [entry(reading: 10)], now: t0), ["w"])
        XCTAssertEqual(hold.metAt, [:], "a reading short of the limit stamps nothing")
    }

    func testNotQualifyingIsHeldUntilExactlyTheHoldAfterTheStamp() {
        var hold = MenuBarShowWhenHold()
        _ = hold.dormant(among: [entry(reading: 90)], now: t0)
        XCTAssertEqual(hold.dormant(among: [entry(reading: 10)], now: at(59.9)), [])
        XCTAssertEqual(hold.dormant(among: [entry(reading: 10)], now: at(60)), ["w"], "the comparison is strict")
        XCTAssertEqual(hold.dormant(among: [entry(reading: 10)], now: at(61)), ["w"])
        XCTAssertEqual(hold.metAt, ["w": t0], "going dormant keeps the stamp")
        XCTAssertEqual(hold.dormant(among: [entry(reading: 10)], now: at(59.9)), [])
    }

    func testHoldLengthIsTheOneGiven() {
        var hold = MenuBarShowWhenHold(hold: 5)
        _ = hold.dormant(among: [entry(reading: 90)], now: t0)
        XCTAssertEqual(hold.dormant(among: [entry(reading: 10)], now: at(4.5)), [])
        XCTAssertEqual(hold.dormant(among: [entry(reading: 10)], now: at(5)), ["w"])
    }

    func testReadingThatKeepsQualifyingKeepsRestamping() {
        var hold = MenuBarShowWhenHold()
        for seconds in [0.0, 30, 50] {
            XCTAssertEqual(hold.dormant(among: [entry(reading: 90)], now: at(seconds)), [])
            XCTAssertEqual(hold.metAt, ["w": at(seconds)])
        }
        XCTAssertEqual(hold.dormant(among: [entry(reading: 10)], now: at(109.9)), [],
                       "held from the last qualifying reading, not the first")
        XCTAssertEqual(hold.dormant(among: [entry(reading: 10)], now: at(110)), ["w"])
    }

    func testStampsOfIdsNoLongerOwnedAreForgotten() {
        var hold = MenuBarShowWhenHold()
        _ = hold.dormant(among: [entry("a", reading: 90), entry("b", reading: 90)], now: t0)
        XCTAssertEqual(hold.metAt, ["a": t0, "b": t0])

        XCTAssertEqual(hold.dormant(among: [entry("b", reading: 10)], now: at(1)), [])
        XCTAssertEqual(hold.metAt, ["b": t0])
        XCTAssertEqual(hold.dormant(among: [entry("a", reading: 10), entry("b", reading: 10)], now: at(2)), ["a"],
                       "back within what its old stamp would have covered, and hidden at once")

        XCTAssertEqual(hold.dormant(among: [], now: at(3)), [])
        XCTAssertEqual(hold.metAt, [:])
    }

    func testEachEntryIsJudgedOnItsOwn() {
        var hold = MenuBarShowWhenHold()
        let dormant = hold.dormant(among: [
            entry("met", reading: 90), entry("unmet", reading: 10),
            entry("free", reading: 10, showWhen: nil), entry("blank", reading: nil),
        ], now: t0)
        XCTAssertEqual(dormant, ["unmet"])
        XCTAssertEqual(hold.metAt, ["met": t0])
    }
}
