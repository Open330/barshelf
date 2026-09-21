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

    func testAuthorEligibilityDoesNotEnableTheMenuBarByItself() {
        // An update that starts declaring `statusItem` must not take over
        // someone's menu bar, nor start polling with the popup closed.
        for statusItem in [nil, Manifest.StatusItem(mode: "none"),
                           Manifest.StatusItem(mode: "icon"),
                           Manifest.StatusItem(mode: "text"),
                           Manifest.StatusItem(mode: "dynamic")] {
            XCTAssertFalse(
                MenuBarPolicy.resolvedPlacement(stored: nil, statusItem: statusItem).enabled,
                "mode \(statusItem?.mode ?? "nil") should stay off until the user asks"
            )
        }
        // Eligibility is still what the picker offers.
        XCTAssertTrue(Manifest.StatusItem(mode: "text").isPromotable)
        XCTAssertFalse(Manifest.StatusItem(mode: "none").isPromotable)
    }

    func testEffectiveStatusItemGivesAHandPromotedWidgetALabel() {
        // A widget the user promoted from settings has no author mode to
        // follow; it behaves as "text" so it can join the shared strip.
        XCTAssertTrue(MenuBarPolicy.effectiveStatusItem(nil).showsLabel)
        XCTAssertTrue(
            MenuBarPolicy.effectiveStatusItem(Manifest.StatusItem(mode: "none")).showsLabel
        )
        // A declared mode is honored as-is.
        XCTAssertFalse(
            MenuBarPolicy.effectiveStatusItem(Manifest.StatusItem(mode: "icon")).showsLabel
        )
        XCTAssertTrue(
            MenuBarPolicy.effectiveStatusItem(Manifest.StatusItem(mode: "icon")).showsIcon
        )
    }

    func testStoredPlacementIsAuthoritative() {
        // A user may promote a widget its author left out of the menu bar…
        XCTAssertTrue(MenuBarPolicy.resolvedPlacement(
            stored: MenuBarPlacement(enabled: true),
            statusItem: Manifest.StatusItem(mode: "none")
        ).enabled)
        // …and demote one the author marked promotable.
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

    func testAWidgetWithNoIntervalIsNeverStale() {
        // An event-driven or manual-refresh widget has no timer that could
        // ever refresh it, so dimming its value would be permanent and wrong.
        let now = Date()
        XCTAssertNil(MenuBarPolicy.stalenessThreshold(interval: nil))
        XCTAssertNil(MenuBarPolicy.stalenessThreshold(interval: 0))
        XCTAssertFalse(MenuBarPolicy.isStale(
            updatedAt: now.addingTimeInterval(-86_400), interval: nil, now: now
        ))
        // It is still stale before it has ever rendered.
        XCTAssertTrue(MenuBarPolicy.isStale(updatedAt: nil, interval: nil, now: now))
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

    func testPromotionIsCappedBeforeAnythingIsDrawn() {
        let entries = (0..<8).map { entry("w\($0)") }
        // The cap is what the scheduler polls, so it must bite here and not
        // only at draw time.
        XCTAssertEqual(
            MenuBarPolicy.promoted(entries).map(\.widgetID),
            (0..<MenuBarPolicy.maxEntries).map { "w\($0)" }
        )
        let (strip, separate) = MenuBarPolicy.partition(entries)
        XCTAssertEqual(strip.count + separate.count, MenuBarPolicy.maxEntries)
    }

    func testAnEntryWithNothingToDrawStaysPromotedButIsNotDrawn() {
        // It has to keep its refresh to ever produce a first label — dropping
        // it from the promoted set would strand it permanently blank.
        let entries = [entry("blank", symbol: nil, label: nil), entry("cpu")]
        XCTAssertEqual(MenuBarPolicy.promoted(entries).count, 2)
        let (strip, separate) = MenuBarPolicy.partition(entries)
        XCTAssertEqual(strip.map(\.widgetID), ["cpu"])
        XCTAssertTrue(separate.isEmpty)
    }

    // MARK: - Reordering

    func testMovingAWidgetRewritesTheWholeRun() {
        let ids = ["a", "b", "c"]
        // Every id gets a key, not just the moved one: the stored keys may be
        // absent or stale, so one move has to re-derive the order.
        let moved = MenuBarPolicy.reordered(ids, moving: "c", by: -1)
        XCTAssertEqual(moved, ["a": 0, "c": 1, "b": 2])
        XCTAssertEqual(
            MenuBarPolicy.ordered(ids.map { (entry($0), moved[$0]) }).map(\.widgetID),
            ["a", "c", "b"]
        )
    }

    func testMovingClampsAtTheEdgesInsteadOfWrapping() {
        let ids = ["a", "b", "c"]
        XCTAssertEqual(MenuBarPolicy.reordered(ids, moving: "a", by: -1), ["a": 0, "b": 1, "c": 2])
        XCTAssertEqual(MenuBarPolicy.reordered(ids, moving: "c", by: 1), ["a": 0, "b": 1, "c": 2])
        XCTAssertFalse(MenuBarPolicy.canMove("a", by: -1, within: ids))
        XCTAssertFalse(MenuBarPolicy.canMove("c", by: 1, within: ids))
        XCTAssertTrue(MenuBarPolicy.canMove("b", by: -1, within: ids))
        XCTAssertTrue(MenuBarPolicy.canMove("b", by: 1, within: ids))
    }

    func testReorderingAnUnknownOrUnmovedWidgetNormalisesWithoutMoving() {
        let ids = ["a", "b", "c"]
        let expected: [String: Double] = ["a": 0, "b": 1, "c": 2]
        XCTAssertEqual(MenuBarPolicy.reordered(ids, moving: "zzz", by: -1), expected)
        XCTAssertEqual(MenuBarPolicy.reordered(ids, moving: "b", by: 0), expected)
        XCTAssertFalse(MenuBarPolicy.canMove("zzz", by: 1, within: ids))
    }

    func testAMoveSurvivesWidgetsThatHadNoOrderAtAll() {
        // Everything promoted before ordering existed has a nil key; the run is
        // still ordered by name, and one move must produce a stable result.
        let ids = MenuBarPolicy.ordered([
            (entry("beta", name: "Beta"), nil),
            (entry("alpha", name: "Alpha"), nil),
            (entry("gamma", name: "Gamma"), nil),
        ]).map(\.widgetID)
        XCTAssertEqual(ids, ["alpha", "beta", "gamma"])
        XCTAssertEqual(
            MenuBarPolicy.reordered(ids, moving: "gamma", by: -2),
            ["gamma": 0, "alpha": 1, "beta": 2]
        )
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

/// Per-widget presentation the user controls: the text before the value and
/// the glyph in front of it.
final class MenuBarCustomisationTests: XCTestCase {
    func testAPrefixIsTrimmedAndCapped() {
        XCTAssertEqual(MenuBarPolicy.normalizedPrefix("  CPU  "), "CPU")
        XCTAssertNil(MenuBarPolicy.normalizedPrefix(nil))
        XCTAssertNil(MenuBarPolicy.normalizedPrefix(""))
        XCTAssertNil(MenuBarPolicy.normalizedPrefix("   "))
        // One widget must not crowd its neighbours off a shared strip.
        XCTAssertEqual(
            MenuBarPolicy.normalizedPrefix("Temperature")?.count,
            MenuBarPolicy.maxPrefixCharacters
        )
    }

    /// "" and nil mean different things — no icon at all, versus the widget's
    /// own — so normalization must not collapse one into the other.
    func testAnEmptyIconMeansNoIconAndNilMeansTheWidgetsOwn() {
        XCTAssertNil(MenuBarPolicy.normalizedIcon(nil))
        XCTAssertEqual(MenuBarPolicy.normalizedIcon(""), "")
        XCTAssertEqual(MenuBarPolicy.normalizedIcon("   "), "")
    }

    /// SF Symbol names are long and hyphenated, so they pass through whole;
    /// only free text is capped, to stop a pasted sentence reaching the bar.
    func testASymbolNameSurvivesWhileFreeTextIsCapped() {
        XCTAssertEqual(
            MenuBarPolicy.normalizedIcon("thermometer.medium"), "thermometer.medium"
        )
        XCTAssertEqual(MenuBarPolicy.normalizedIcon("🌡️"), "🌡️")
        XCTAssertEqual(
            MenuBarPolicy.normalizedIcon("a very long sentence")?.count,
            MenuBarPolicy.maxIconCharacters
        )
    }

    func testTheEntryTextJoinsThePrefixToTheValue() {
        let entry = MenuBarEntry(widgetID: "w", name: "System", prefix: "CPU", label: "23%")
        XCTAssertEqual(MenuBarPolicy.entryText(entry), "CPU 23%")

        var valueOnly = entry
        valueOnly.prefix = nil
        XCTAssertEqual(MenuBarPolicy.entryText(valueOnly), "23%")

        // A prefix with nothing to prefix still says which widget it is.
        var noValue = entry
        noValue.label = nil
        XCTAssertEqual(MenuBarPolicy.entryText(noValue), "CPU")
    }

    /// The strip can only draw text, so an emoji joins it and a symbol does
    /// not — the status item layer decides which kind it has.
    func testTheStripTakesAGlyphOnlyWhenItIsText() {
        let entry = MenuBarEntry(widgetID: "w", name: "Sensors", prefix: "Temp", label: "39°")
        XCTAssertEqual(MenuBarPolicy.stripCell(entry, glyph: "🌡️"), "🌡️ Temp 39°")
        XCTAssertEqual(MenuBarPolicy.stripCell(entry, glyph: nil), "Temp 39°")
        XCTAssertEqual(MenuBarPolicy.stripCell(entry, glyph: ""), "Temp 39°")
    }

    func testAnEntryIsEmptyOnlyWhenItWouldDrawNothing() {
        let blank = MenuBarEntry(widgetID: "w", name: "W")
        XCTAssertTrue(blank.isEmpty)

        // An icon the user asked for is something to draw.
        var withGlyph = blank
        withGlyph.iconOverride = "🌡️"
        XCTAssertFalse(withGlyph.isEmpty)

        // Turning the icon off with nothing else leaves nothing.
        var iconOff = MenuBarEntry(widgetID: "w", name: "W", symbol: "cpu.fill")
        XCTAssertFalse(iconOff.isEmpty)
        iconOff.iconOverride = ""
        XCTAssertTrue(iconOff.isEmpty)

        // A prefix alone is still worth drawing.
        var prefixOnly = blank
        prefixOnly.prefix = "CPU"
        XCTAssertFalse(prefixOnly.isEmpty)
    }

    /// A prefs file written before these existed must still load.
    func testPlacementsWithoutTheNewKeysStillDecode() throws {
        let json = Data(#"{"enabled":true,"separate":true,"order":2}"#.utf8)
        let placement = try JSONDecoder().decode(MenuBarPlacement.self, from: json)
        XCTAssertTrue(placement.enabled)
        XCTAssertTrue(placement.separate)
        XCTAssertEqual(placement.order, 2)
        XCTAssertNil(placement.icon)
        XCTAssertNil(placement.label)
    }
}

/// Where the menu bar label comes from, and how the two-row layout is chosen.
final class MenuBarStyleAndPrefixTests: XCTestCase {
    /// Most specific wins: what the user typed, then what this refresh
    /// produced, then what the author declared.
    func testThePrefixPrefersTheUserThenTheWidgetThenTheManifest() {
        XCTAssertEqual(
            MenuBarPolicy.resolvedPrefix(user: "Mine", live: "Live", manifest: "Author"),
            "Mine"
        )
        XCTAssertEqual(
            MenuBarPolicy.resolvedPrefix(user: nil, live: "Live", manifest: "Author"), "Live"
        )
        XCTAssertEqual(
            MenuBarPolicy.resolvedPrefix(user: nil, live: nil, manifest: "Author"), "Author"
        )
        XCTAssertNil(MenuBarPolicy.resolvedPrefix(user: nil, live: nil, manifest: nil))
    }

    /// An empty override is the user saying "no label", which is a decision —
    /// it must not fall through to the widget's suggestion.
    func testAnEmptyUserPrefixSilencesTheWidgetsOwn() {
        XCTAssertNil(MenuBarPolicy.resolvedPrefix(user: "", live: "Live", manifest: "Author"))
        XCTAssertNil(MenuBarPolicy.resolvedPrefix(user: "   ", live: "Live", manifest: "Author"))
    }

    func testTheStyleFallsBackFromUserToManifestToInline() {
        XCTAssertEqual(
            MenuBarPolicy.resolvedStyle(user: .stacked, manifest: "inline"), .stacked
        )
        XCTAssertEqual(MenuBarPolicy.resolvedStyle(user: nil, manifest: "stacked"), .stacked)
        XCTAssertEqual(MenuBarPolicy.resolvedStyle(user: nil, manifest: nil), .inline)
        // A style from a newer build is not a reason to draw nothing.
        XCTAssertEqual(MenuBarPolicy.resolvedStyle(user: nil, manifest: "hexagonal"), .inline)
    }

    func testEveryStyleHasSomethingToShowInAPicker() {
        for style in MenuBarStyle.allCases {
            XCTAssertFalse(style.title.isEmpty, "\(style) has no title")
        }
        XCTAssertEqual(MenuBarStyle.allCases.count, 2)
    }

    /// A prefs file from before the style existed must still load, and an
    /// unknown one must not take the rest of the file down with it.
    func testPlacementStyleDecodesLenientlyOrNotAtAll() throws {
        let missing = try JSONDecoder().decode(
            MenuBarPlacement.self, from: Data(#"{"enabled":true}"#.utf8)
        )
        XCTAssertNil(missing.style)

        let unknown = try JSONDecoder().decode(
            MenuBarPlacement.self, from: Data(#"{"enabled":true,"style":"spiral"}"#.utf8)
        )
        XCTAssertTrue(unknown.enabled)
        XCTAssertNil(unknown.style)

        let stacked = try JSONDecoder().decode(
            MenuBarPlacement.self, from: Data(#"{"enabled":true,"style":"stacked"}"#.utf8)
        )
        XCTAssertEqual(stacked.style, .stacked)
    }

    /// The author-facing shorthand the manifest exposes.
    func testAManifestCanDeclareTheStackedLayout() {
        XCTAssertTrue(Manifest.StatusItem(mode: "text", style: "stacked").isStacked)
        XCTAssertFalse(Manifest.StatusItem(mode: "text", style: "inline").isStacked)
        XCTAssertFalse(Manifest.StatusItem(mode: "text").isStacked)
    }
}
