import AppKit
import XCTest
import MenubucketCore
@testable import MenubucketApp

final class MenuBarControllerTests: XCTestCase {
    private func entry(
        _ id: String,
        label: String?,
        isStale: Bool = false
    ) -> MenuBarEntry {
        MenuBarEntry(widgetID: id, name: id, label: label, isStale: isStale)
    }

    func testStripJoinsLabelsWithTheSeparator() {
        let strip = MenuBarController.attributedStrip([
            entry("cpu", label: "42%"), entry("temp", label: "58°"),
        ])
        XCTAssertEqual(strip.string, "42% · 58°")
    }

    func testStripSkipsEntriesWithNoLabel() {
        let strip = MenuBarController.attributedStrip([
            entry("cpu", label: "42%"),
            entry("icononly", label: nil),
            entry("blank", label: ""),
            entry("temp", label: "58°"),
        ])
        // No dangling separators for the cells that draw nothing.
        XCTAssertEqual(strip.string, "42% · 58°")
    }

    func testStaleEntriesAreDimmedSoAFrozenValueIsNotMistakenForALiveOne() {
        let strip = MenuBarController.attributedStrip([
            entry("fresh", label: "42%"), entry("frozen", label: "58°", isStale: true),
        ])
        let fresh = strip.attribute(
            .foregroundColor, at: strip.string.distance(
                from: strip.string.startIndex, to: strip.string.startIndex
            ), effectiveRange: nil
        ) as? NSColor
        let frozenIndex = try? XCTUnwrap(strip.string.range(of: "58°")).lowerBound
        let frozenOffset = frozenIndex.map {
            strip.string.distance(from: strip.string.startIndex, to: $0)
        } ?? 0
        let frozen = strip.attribute(
            .foregroundColor, at: frozenOffset, effectiveRange: nil
        ) as? NSColor

        XCTAssertEqual(fresh, .labelColor)
        XCTAssertEqual(frozen, .tertiaryLabelColor)
        XCTAssertNotEqual(fresh, frozen)
    }

    func testStripUsesTheMenuBarFont() {
        let strip = MenuBarController.attributedStrip([entry("cpu", label: "42%")])
        let font = strip.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertEqual(font, MenuBarController.statusFont)
    }

    func testEmptyStripRendersNothing() {
        XCTAssertEqual(MenuBarController.attributedStrip([]).string, "")
        XCTAssertEqual(
            MenuBarController.attributedStrip([entry("icononly", label: nil)]).string, ""
        )
    }

    func testSeparateItemLayoutFollowsWhatTheEntryActuallyHas() {
        XCTAssertEqual(
            MenuBarController.imagePosition(hasImage: true, hasLabel: true), .imageLeading
        )
        XCTAssertEqual(
            MenuBarController.imagePosition(hasImage: true, hasLabel: false), .imageOnly
        )
        XCTAssertEqual(
            MenuBarController.imagePosition(hasImage: false, hasLabel: true), .noImage
        )
    }

    func testStatusStoreSuppressesPublishesForUnchangedEntries() {
        let store = MenuBarStatusStore()
        let entries = [entry("cpu", label: "42%")]
        store.apply(entries)
        XCTAssertEqual(store.promotedWidgetIDs, ["cpu"])

        var publishes = 0
        let cancellable = store.objectWillChange.sink { _ in publishes += 1 }
        store.apply(entries)
        XCTAssertEqual(publishes, 0, "an unchanged sample must not republish")
        store.apply([entry("cpu", label: "43%")])
        XCTAssertEqual(publishes, 1)
        cancellable.cancel()
    }
}
