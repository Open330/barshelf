import XCTest
@testable import MenubucketCore

/// `MenuBarPolicy.buildEntry`: the one place a widget's menu bar entry is
/// put together, for the bar, the settings preview and the landing media.
final class MenuBarEntryBuilderTests: XCTestCase {
    /// Stands in for AppKit's lookup: these names are SF Symbols, nothing
    /// else is.
    private static let symbols: Set<String> = ["cpu.fill", "bolt.fill", "memorychip", "star"]

    private func inputs(
        statusItem: Manifest.StatusItem? = .init(mode: "text"),
        placement: MenuBarPlacement = .init(enabled: true),
        manifestIcon: String? = nil,
        global: MenuBarPresentation? = nil,
        snapshot: WidgetSnapshot? = nil,
        isStale: Bool = false,
        tooltip: String? = nil,
        placeholder: String? = nil
    ) -> MenuBarEntryInputs {
        MenuBarEntryInputs(
            widgetID: "w", name: "Widget", manifestIcon: manifestIcon, statusItem: statusItem,
            placement: placement, globalPresentation: global, snapshot: snapshot,
            isStale: isStale, tooltip: tooltip, placeholderLabel: placeholder,
            isSymbolName: { Self.symbols.contains($0) }
        )
    }

    private func build(_ inputs: MenuBarEntryInputs) -> BuiltMenuBarEntry {
        MenuBarPolicy.buildEntry(inputs)
    }

    private func layout(
        _ statusItem: Manifest.StatusItem?, _ placement: MenuBarPlacement = .init(enabled: true)
    ) -> MenuBarEntryLayout {
        MenuBarPolicy.entryLayout(statusItem: statusItem, placement: placement) { Self.symbols.contains($0) }
    }

    private let reading = WidgetSnapshot(
        widgetID: "w", statusLabel: "  23 %  ",
        statusMetrics: [StatusMetric(id: "cpu", label: "CPU", number: 23, format: "percent")],
        statusPrefix: "Live", statusIcon: "bolt.fill", statusTint: "warning"
    )

    // MARK: - Modes

    func testTextModeShowsTheLabelAndMetricsAndNoSymbol() {
        let built = build(inputs(
            statusItem: .init(mode: "text", icon: "cpu.fill"), manifestIcon: "star", snapshot: reading
        ))
        XCTAssertNil(built.entry.symbol, "text mode draws no icon")
        XCTAssertEqual(built.entry.iconSymbol, "bolt.fill", "but the widget's icon is still known, live first")
        XCTAssertEqual(built.entry.metrics.map(\.value), ["23%"])
        XCTAssertEqual(built.entry.label, "23%", "one metric is also the label")
        XCTAssertEqual(built.entry.prefix, "Live")
        XCTAssertEqual(built.entry.tint, .warning)
        XCTAssertEqual(built.entry.style, .inline)
        XCTAssertFalse(built.separate)
        XCTAssertFalse(built.entry.separate)
    }

    func testIconModeShowsTheSymbolAndNeitherLabelNorMetrics() {
        let built = build(inputs(
            statusItem: .init(mode: "icon", icon: "cpu.fill"), manifestIcon: "star", snapshot: reading
        ))
        XCTAssertEqual(built.entry.symbol, "bolt.fill", "the live icon is tried first")
        XCTAssertEqual(built.entry.iconSymbol, "bolt.fill")
        XCTAssertNil(built.entry.label)
        XCTAssertEqual(built.entry.metrics, [], "an icon-only widget's readings never reach the bar")
        XCTAssertTrue(built.separate, "an icon cannot join the shared strip")
        XCTAssertTrue(built.entry.separate)
    }

    func testDynamicModeShowsBoth() {
        var snapshot = reading
        snapshot.statusIcon = nil
        let withStatusIcon = build(inputs(
            statusItem: .init(mode: "dynamic", icon: "cpu.fill"), manifestIcon: "star", snapshot: snapshot
        ))
        XCTAssertEqual(withStatusIcon.entry.symbol, "cpu.fill", "then the status item's icon")
        XCTAssertEqual(withStatusIcon.entry.label, "23%")
        XCTAssertFalse(withStatusIcon.separate)

        let manifestOnly = build(inputs(
            statusItem: .init(mode: "dynamic"), manifestIcon: "star", snapshot: snapshot
        ))
        XCTAssertEqual(manifestOnly.entry.symbol, "star", "then the widget's own")
        XCTAssertEqual(manifestOnly.entry.iconSymbol, "star")
    }

    func testWidgetWithoutAPromotableModeIsBuiltAsPlainText() {
        // The author's status item is not on offer ("none", or no mode), so
        // none of it applies: not its icon, its label, its style, its
        // presentation or its profiles.
        let unpromotable = Manifest.StatusItem(
            mode: "none", icon: "cpu.fill", label: "Author", style: "stacked",
            presentation: .init(chart: .line), profiles: true
        )
        for statusItem in [unpromotable, nil] {
            let built = build(inputs(statusItem: statusItem, manifestIcon: "star", snapshot: reading))
            XCTAssertNil(built.entry.symbol)
            XCTAssertEqual(built.entry.iconSymbol, "bolt.fill")
            XCTAssertEqual(built.entry.label, "23%")
            XCTAssertEqual(built.entry.prefix, "Live")
            XCTAssertEqual(built.entry.style, .inline)
            XCTAssertFalse(built.entry.profiles)
            XCTAssertEqual(built.entry.presentation.effectiveChart, MenuBarChart.none)
            XCTAssertFalse(built.separate)
            XCTAssertFalse(built.wantsChart)
        }
        var noLive = reading
        noLive.statusPrefix = nil
        noLive.statusIcon = nil
        let built = build(inputs(statusItem: unpromotable, manifestIcon: "star", snapshot: noLive))
        XCTAssertNil(built.entry.prefix, "the unpromotable item's label is not used")
        XCTAssertEqual(built.entry.iconSymbol, "star", "nor its icon")
    }

    func testLabelIsNormalizedAndUsedWhenThereAreNoMetrics() {
        let built = build(inputs(snapshot: WidgetSnapshot(widgetID: "w", statusLabel: "  a   label that runs long ")))
        XCTAssertEqual(built.entry.label, "a label that …")
        XCTAssertEqual(built.entry.metrics, [])
    }

    // MARK: - Styles

    func testStyleIsTheUsersThenTheManifestsThenInline() {
        XCTAssertEqual(layout(.init(mode: "text")).style, .inline)
        XCTAssertEqual(layout(.init(mode: "text", style: "stacked")).style, .stacked)
        XCTAssertEqual(layout(.init(mode: "text", style: "metrics")).style, .metrics)
        XCTAssertEqual(layout(.init(mode: "text", style: "sideways")).style, .inline, "an unknown style is inline")
        XCTAssertEqual(
            layout(.init(mode: "text", style: "stacked"), .init(enabled: true, style: .inline)).style, .inline,
            "the user's choice wins"
        )
        XCTAssertEqual(layout(.init(mode: "text"), .init(enabled: true, style: .metrics)).style, .metrics)
        for style in MenuBarStyle.allCases {
            let built = build(inputs(placement: .init(enabled: true, style: style), snapshot: reading))
            XCTAssertEqual(built.entry.style, style)
        }
    }

    func testStackedAndMetricsStylesTakeTheirOwnItem() {
        XCTAssertFalse(layout(.init(mode: "text")).separate)
        for style in ["stacked", "metrics"] {
            let authored = layout(.init(mode: "text", style: style))
            XCTAssertTrue(authored.separate, "\(style) cannot be drawn into a shared run of text")
            XCTAssertTrue(authored.canShareStrip, "though the widget has text")
        }
        for style in [MenuBarStyle.stacked, .metrics] {
            let built = build(inputs(placement: .init(enabled: true, style: style), snapshot: reading))
            XCTAssertTrue(built.separate)
            XCTAssertTrue(built.entry.separate)
        }
        let backInline = layout(.init(mode: "text", style: "stacked"), .init(enabled: true, style: .inline))
        XCTAssertFalse(backInline.separate, "the user's inline over the author's stacked shares again")
    }

    func testUserCanSplitAnInlineWidgetOut() {
        let built = build(inputs(placement: .init(enabled: true, separate: true), snapshot: reading))
        XCTAssertTrue(built.separate)
        XCTAssertTrue(built.entry.separate)
        XCTAssertEqual(built.entry.style, .inline)
    }

    // MARK: - Symbol and text icons

    func testSymbolOverrideLeavesAnIconOnlyWidgetOnItsOwnItem() {
        let placement = MenuBarPlacement(enabled: true, icon: " memorychip ")
        let built = build(inputs(statusItem: .init(mode: "icon", icon: "cpu.fill"), placement: placement))
        XCTAssertEqual(built.entry.iconOverride, "memorychip")
        XCTAssertEqual(built.entry.symbol, "cpu.fill", "the widget's own icon is kept beside the override")
        XCTAssertTrue(built.separate, "an SF Symbol is an image, and the strip is text")
        XCTAssertFalse(layout(.init(mode: "icon"), placement).canShareStrip)
        let parts = MenuBarPolicy.partition([built.entry])
        XCTAssertEqual(parts.strip, [])
        XCTAssertEqual(parts.separate.map(\.widgetID), ["w"])
    }

    func testEmojiOverrideLetsAnIconOnlyWidgetShareTheStrip() {
        let placement = MenuBarPlacement(enabled: true, icon: "🔥")
        let built = build(inputs(statusItem: .init(mode: "icon", icon: "cpu.fill"), placement: placement))
        XCTAssertEqual(built.entry.iconOverride, "🔥")
        XCTAssertFalse(built.separate, "an emoji is text and sits in the strip like any other")
        XCTAssertFalse(built.entry.separate)
        XCTAssertTrue(layout(.init(mode: "icon"), placement).canShareStrip)
        let parts = MenuBarPolicy.partition([built.entry])
        XCTAssertEqual(parts.strip.map(\.widgetID), ["w"])
        XCTAssertEqual(parts.separate, [])

        var split = placement
        split.separate = true
        XCTAssertTrue(build(inputs(statusItem: .init(mode: "icon"), placement: split)).separate,
                      "it can still be given its own item")
        var stacked = placement
        stacked.style = .stacked
        XCTAssertTrue(build(inputs(statusItem: .init(mode: "icon"), placement: stacked)).separate,
                      "and two rows still need one")
    }

    func testEmptyOverrideMeansNoIconAndIsNotText() {
        let placement = MenuBarPlacement(enabled: true, icon: "  ")
        let iconOnly = build(inputs(statusItem: .init(mode: "icon", icon: "cpu.fill"), placement: placement))
        XCTAssertEqual(iconOnly.entry.iconOverride, "")
        XCTAssertTrue(iconOnly.separate, "no icon is not a text icon")
        let noOverride = build(inputs(statusItem: .init(mode: "icon", icon: "cpu.fill")))
        XCTAssertNil(noOverride.entry.iconOverride)
        XCTAssertTrue(noOverride.separate)
    }

    func testSymbolLookupIsOnlyAskedAboutAnOverride() {
        var asked: [String] = []
        var inputs = inputs(statusItem: .init(mode: "dynamic", icon: "cpu.fill"), manifestIcon: "star", snapshot: reading)
        inputs.isSymbolName = { asked.append($0); return true }
        _ = build(inputs)
        XCTAssertEqual(asked, [], "the widget's own icons are not looked up")
        inputs.placement.icon = ""
        _ = build(inputs)
        XCTAssertEqual(asked, [], "nor is an empty override")
        inputs.placement.icon = "star"
        _ = build(inputs)
        XCTAssertEqual(asked, ["star"])
    }

    func testTextIconDoesNotChangeAWidgetThatAlreadyHasText() {
        for icon in ["🔥", "star"] {
            let built = build(inputs(placement: .init(enabled: true, icon: icon), snapshot: reading))
            XCTAssertFalse(built.separate)
            XCTAssertEqual(built.entry.iconOverride, icon)
        }
    }

    // MARK: - Prefix

    func testPrefixIsTheUsersThenTheLiveOneThenTheManifests() {
        let statusItem = Manifest.StatusItem(mode: "text", label: "Author")
        XCTAssertEqual(build(inputs(statusItem: statusItem)).entry.prefix, "Author")
        XCTAssertEqual(build(inputs(statusItem: statusItem, snapshot: reading)).entry.prefix, "Live")
        XCTAssertEqual(
            build(inputs(statusItem: statusItem, placement: .init(enabled: true, label: "Mine"), snapshot: reading))
                .entry.prefix, "Mine"
        )
        XCTAssertEqual(
            build(inputs(statusItem: statusItem, placement: .init(enabled: true, label: " "), snapshot: reading))
                .entry.prefix, "", "an empty label is the user asking for none"
        )
    }

    // MARK: - Profiles

    func testProfilesKeepEveryReadingForTheCluster() {
        let metrics = (1...10).map { StatusMetric(id: "p\($0)", label: "P\($0)", number: Double($0 + 10), format: "percent") }
        let snapshot = WidgetSnapshot(widgetID: "w", statusMetrics: metrics)
        let built = build(inputs(statusItem: .init(mode: "text", profiles: true), snapshot: snapshot))
        XCTAssertTrue(built.entry.profiles)
        XCTAssertEqual(built.entry.metrics.map(\.id), ["p1", "p2"], "the item has room for two")
        XCTAssertEqual(built.entry.profileMetrics.map(\.id), (1...MenuBarClusterPolicy.maxChips).map { "p\($0)" })
        XCTAssertEqual(built.entry.profileMetrics.first?.value, "", "as read: presentation is not applied to them")
        XCTAssertEqual(built.entry.metrics.first?.value, "11%")

        let plain = build(inputs(statusItem: .init(mode: "text"), snapshot: snapshot))
        XCTAssertFalse(plain.entry.profiles)
        XCTAssertEqual(plain.entry.profileMetrics, [])

        let iconOnly = build(inputs(statusItem: .init(mode: "icon", icon: "cpu.fill", profiles: true), snapshot: snapshot))
        XCTAssertTrue(iconOnly.entry.profiles)
        XCTAssertEqual(iconOnly.entry.profileMetrics, [], "an icon-only widget shows no readings, profiles or not")
    }

    // MARK: - Passed through

    func testTooltipAndStalenessAreTheCallers() {
        var snapshot = reading
        snapshot.statusTooltip = "from the widget"
        snapshot.error = "failed"
        let quiet = build(inputs(snapshot: snapshot))
        XCTAssertNil(quiet.entry.tooltip, "the builder does not pick a tooltip from the snapshot")
        XCTAssertFalse(quiet.entry.isStale)
        let told = build(inputs(snapshot: snapshot, isStale: true, tooltip: "what happened\nwhat to do"))
        XCTAssertEqual(told.entry.tooltip, "what happened\nwhat to do")
        XCTAssertTrue(told.entry.isStale)
    }

    // MARK: - Placeholder

    func testPlaceholderStandsInOnlyForAMissingLabel() {
        XCTAssertNil(build(inputs()).entry.label, "the menu bar has no placeholder")
        XCTAssertEqual(build(inputs(placeholder: "42%")).entry.label, "42%")
        XCTAssertEqual(
            build(inputs(snapshot: WidgetSnapshot(widgetID: "w", statusLabel: "   "), placeholder: "42%")).entry.label,
            "42%", "a blank label is no label"
        )
        XCTAssertEqual(
            build(inputs(snapshot: WidgetSnapshot(widgetID: "w", statusLabel: "idle"), placeholder: "42%")).entry.label,
            "idle"
        )
        XCTAssertEqual(build(inputs(snapshot: reading, placeholder: "42%")).entry.label, "23%")
        XCTAssertNil(
            build(inputs(statusItem: .init(mode: "icon", icon: "cpu.fill"), placeholder: "42%")).entry.label,
            "an icon-only widget has no label to stand in for"
        )
    }

    // MARK: - Presentation and charts

    func testPresentationIsResolvedUserThenGlobalThenLiveThenManifestAndApplied() {
        var snapshot = reading
        snapshot.statusPresentation = MenuBarPresentation(precision: 1, weight: .bold)
        let statusItem = Manifest.StatusItem(
            mode: "text", presentation: .init(precision: 3, size: .small, chart: .bars)
        )
        let built = build(inputs(
            statusItem: statusItem,
            placement: .init(enabled: true, presentation: .init(precision: 2)),
            global: .init(weight: .regular), snapshot: snapshot
        ))
        XCTAssertEqual(built.entry.presentation.precision, 2)
        XCTAssertEqual(built.entry.presentation.weight, .regular)
        XCTAssertEqual(built.entry.presentation.size, .small)
        XCTAssertEqual(built.entry.presentation.chart, .bars)
        XCTAssertEqual(built.entry.metrics.map(\.value), ["23.00%"], "and applied to the readings")
        XCTAssertEqual(built.entry.label, "23.00%")
    }

    func testWantsChartOnlyForAnItemOfItsOwnWithAChart() {
        let chart = MenuBarPresentation(chart: .line)
        let shared = build(inputs(placement: .init(enabled: true, presentation: chart), snapshot: reading))
        XCTAssertFalse(shared.wantsChart, "the strip is text")
        XCTAssertEqual(shared.entry.presentation.chart, .line)

        let own = build(inputs(placement: .init(enabled: true, separate: true, presentation: chart), snapshot: reading))
        XCTAssertTrue(own.wantsChart)
        XCTAssertEqual(own.entry.history, [], "the history is the caller's to add")
        XCTAssertNil(own.entry.chartScale)

        let stacked = build(inputs(
            statusItem: .init(mode: "text", style: "stacked", presentation: chart), snapshot: reading
        ))
        XCTAssertTrue(stacked.wantsChart, "an author's chart on an item its style splits out")

        let noChart = build(inputs(placement: .init(enabled: true, separate: true), snapshot: reading))
        XCTAssertFalse(noChart.wantsChart)
        let off = build(inputs(
            statusItem: .init(mode: "text", presentation: chart),
            placement: .init(enabled: true, separate: true, presentation: .init(chart: MenuBarChart.none)),
            snapshot: reading
        ))
        XCTAssertFalse(off.wantsChart, "the user turned the author's chart off")

        let emoji = build(inputs(
            statusItem: .init(mode: "icon", icon: "cpu.fill"),
            placement: .init(enabled: true, icon: "🔥", presentation: chart)
        ))
        XCTAssertFalse(emoji.wantsChart, "an emoji in the strip draws no chart")
    }

    func testBuiltEntryMatchesTheLayout() {
        let cases: [(Manifest.StatusItem?, MenuBarPlacement)] = [
            (.init(mode: "text"), .init(enabled: true)),
            (.init(mode: "icon"), .init(enabled: true, icon: "🔥")),
            (.init(mode: "icon"), .init(enabled: true, icon: "star")),
            (.init(mode: "dynamic", style: "metrics"), .init(enabled: true)),
            (nil, .init(enabled: true, separate: true, style: .stacked)),
        ]
        for (statusItem, placement) in cases {
            let built = build(inputs(statusItem: statusItem, placement: placement, snapshot: reading))
            let expected = layout(statusItem, placement)
            XCTAssertEqual(built.separate, expected.separate)
            XCTAssertEqual(built.entry.separate, expected.separate)
            XCTAssertEqual(built.entry.style, expected.style)
        }
    }
}
