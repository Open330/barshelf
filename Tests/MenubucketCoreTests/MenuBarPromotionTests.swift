import XCTest
@testable import MenubucketCore

final class MenuBarPromotionTests: XCTestCase {
    private func entry(
        _ id: String,
        name: String? = nil,
        symbol: String? = nil,
        label: String? = "42%",
        isStale: Bool = false,
        separate: Bool = false
    ) -> MenuBarEntry {
        MenuBarEntry(
            widgetID: id,
            name: name ?? id,
            symbol: symbol,
            label: label,
            isStale: isStale,
            separate: separate
        )
    }

    // MARK: - Placement resolution

    func testPlacementFallsBackToTheAuthorMode() {
        XCTAssertFalse(
            MenuBarPolicy.resolvedPlacement(stored: nil, statusItem: nil).enabled
        )
        XCTAssertFalse(
            MenuBarPolicy.resolvedPlacement(
                stored: nil, statusItem: Manifest.StatusItem(mode: "none")
            ).enabled
        )
        for mode in ["icon", "text", "dynamic"] {
            XCTAssertTrue(
                MenuBarPolicy.resolvedPlacement(
                    stored: nil, statusItem: Manifest.StatusItem(mode: mode)
                ).enabled,
                "mode \(mode) should be promotable"
            )
        }
    }

    func testStoredPlacementOverridesTheAuthorMode() {
        // A user may promote a widget its author left out of the menu bar…
        XCTAssertTrue(MenuBarPolicy.resolvedPlacement(
            stored: MenuBarPlacement(enabled: true),
            statusItem: Manifest.StatusItem(mode: "none")
        ).enabled)
        // …and demote one the author opted in.
        XCTAssertFalse(MenuBarPolicy.resolvedPlacement(
            stored: MenuBarPlacement(enabled: false),
            statusItem: Manifest.StatusItem(mode: "text")
        ).enabled)
    }

    func testStatusItemModeMapsToIconAndLabelVisibility() {
        let icon = Manifest.StatusItem(mode: "icon")
        XCTAssertTrue(icon.showsIcon)
        XCTAssertFalse(icon.showsLabel)

        let text = Manifest.StatusItem(mode: "text")
        XCTAssertFalse(text.showsIcon)
        XCTAssertTrue(text.showsLabel)

        let dynamic = Manifest.StatusItem(mode: "dynamic")
        XCTAssertTrue(dynamic.showsIcon)
        XCTAssertTrue(dynamic.showsLabel)

        let none = Manifest.StatusItem(mode: "none")
        XCTAssertFalse(none.showsIcon)
        XCTAssertFalse(none.showsLabel)
        XCTAssertFalse(none.isPromotable)
    }

    // MARK: - Labels

    func testLabelIsCollapsedAndClipped() {
        XCTAssertEqual(MenuBarPolicy.normalizedLabel("  42 %\n"), "42 %")
        XCTAssertEqual(
            MenuBarPolicy.normalizedLabel("a very long status label indeed"),
            "a very long s…"
        )
        XCTAssertEqual(MenuBarPolicy.normalizedLabel("a very long status label indeed")?.count, 14)
    }

    func testBlankLabelsBecomeNilSoTheCellDisappears() {
        XCTAssertNil(MenuBarPolicy.normalizedLabel(nil))
        XCTAssertNil(MenuBarPolicy.normalizedLabel(""))
        XCTAssertNil(MenuBarPolicy.normalizedLabel("   \n "))
        XCTAssertTrue(entry("a", symbol: nil, label: "").isEmpty)
        XCTAssertFalse(entry("a", symbol: "cpu").isEmpty)
    }

    // MARK: - Staleness

    func testStalenessAllowsThreeMissedRefreshesWithAThirtySecondFloor() {
        XCTAssertEqual(MenuBarPolicy.stalenessThreshold(interval: 30), 90)
        // A fast cadence must not flicker between fresh and stale.
        XCTAssertEqual(MenuBarPolicy.stalenessThreshold(interval: 2), 30)
        // No configured interval: one minute before the value is doubted.
        XCTAssertEqual(MenuBarPolicy.stalenessThreshold(interval: nil), 60)
        XCTAssertEqual(MenuBarPolicy.stalenessThreshold(interval: 0), 60)
    }

    func testNeverRefreshedCountsAsStale() {
        let now = Date()
        XCTAssertTrue(MenuBarPolicy.isStale(updatedAt: nil, interval: 2, now: now))
        XCTAssertFalse(MenuBarPolicy.isStale(
            updatedAt: now.addingTimeInterval(-10), interval: 2, now: now
        ))
        XCTAssertTrue(MenuBarPolicy.isStale(
            updatedAt: now.addingTimeInterval(-31), interval: 2, now: now
        ))
    }

    // MARK: - Ordering and partitioning

    func testOrderedPutsExplicitKeysFirstThenSortsByName() {
        let ordered = MenuBarPolicy.ordered([
            (entry("zulu", name: "Zulu"), nil),
            (entry("alpha", name: "Alpha"), nil),
            (entry("last", name: "Last"), 2),
            (entry("first", name: "First"), 1),
        ])
        XCTAssertEqual(ordered.map(\.widgetID), ["first", "last", "alpha", "zulu"])
    }

    func testPartitionSplitsTheStripFromTheSeparateItems() {
        let (strip, separate) = MenuBarPolicy.partition([
            entry("a"), entry("b", separate: true), entry("c"),
        ])
        XCTAssertEqual(strip.map(\.widgetID), ["a", "c"])
        XCTAssertEqual(separate.map(\.widgetID), ["b"])
    }

    func testPartitionDropsEmptyEntriesAndCapsTheTotal() {
        var entries = (0..<8).map { entry("w\($0)") }
        entries.insert(entry("blank", symbol: nil, label: nil), at: 0)
        let (strip, separate) = MenuBarPolicy.partition(entries)
        XCTAssertEqual(strip.count + separate.count, MenuBarPolicy.maxEntries)
        XCTAssertFalse(strip.contains { $0.widgetID == "blank" })
    }

    // MARK: - Rendered text

    func testStripTextJoinsLabelsAndSkipsEmptyOnes() {
        XCTAssertEqual(
            MenuBarPolicy.stripText([entry("a", label: "42%"), entry("b", label: "58°")]),
            "42% · 58°"
        )
        XCTAssertEqual(
            MenuBarPolicy.stripText([entry("a", label: "42%"), entry("b", label: nil)]),
            "42%"
        )
        XCTAssertEqual(MenuBarPolicy.stripText([]), "")
    }

    func testTooltipPrefersTheWidgetTooltipThenTheLabel() {
        var detailed = entry("cpu", name: "System", label: "42%")
        detailed.tooltip = "CPU 42% · Memory 61%"
        let bare = entry("temp", name: "Sensors", label: "58°")
        var silent = entry("quiet", name: "Quiet", label: nil)
        silent.symbol = "bell"

        XCTAssertEqual(
            MenuBarPolicy.tooltip(for: [detailed, bare, silent]),
            "System — CPU 42% · Memory 61%\nSensors — 58°\nQuiet"
        )
        XCTAssertNil(MenuBarPolicy.tooltip(for: []))
    }

    // MARK: - Persistence

    func testPlacementDecodesPartialAndLegacyJSON() throws {
        let decoder = JSONDecoder()
        let full = try decoder.decode(
            MenuBarPlacement.self,
            from: Data(#"{"enabled":true,"separate":true,"order":2}"#.utf8)
        )
        XCTAssertEqual(full, MenuBarPlacement(enabled: true, separate: true, order: 2))

        // Fields a newer build writes are optional in both directions.
        let partial = try decoder.decode(
            MenuBarPlacement.self, from: Data(#"{"enabled":false}"#.utf8)
        )
        XCTAssertEqual(partial, MenuBarPlacement(enabled: false, separate: false, order: nil))

        let bare = try decoder.decode(MenuBarPlacement.self, from: Data("{}".utf8))
        XCTAssertTrue(bare.enabled)
    }

    func testPlacementRoundTrips() throws {
        let placement = MenuBarPlacement(enabled: true, separate: true, order: 1.5)
        let data = try JSONEncoder().encode(placement)
        XCTAssertEqual(try JSONDecoder().decode(MenuBarPlacement.self, from: data), placement)
    }
}
