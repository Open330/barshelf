import XCTest
import MenubucketCore
@testable import MenubucketApp

/// What the widget settings pane's menu bar preview builds for a draft.
///
/// The preview is built by `MenuBarPolicy.buildEntry`, as the menu bar is.
/// Before that it was built by hand and disagreed with the bar in three
/// ways; each expectation that changed with the switch says which:
///
/// - (a) own item: the pane had no text-icon exception, so an icon-only
///   widget given an emoji was treated as an item of its own. On the bar an
///   emoji is text and the widget shares the strip.
/// - (b) style: the pane read the manifest's style as written; the bar reads
///   it through `effectiveStatusItem`, so the style of a status item the
///   author did not offer ("none") does not apply.
/// - (c) fields never set: `separate`, `iconSymbol`, `profiles` and
///   `profileMetrics` were left at their defaults; the bar sets them, and
///   the cluster's chips are drawn from them.
final class MenuBarPreviewEntryTests: XCTestCase {
    /// The fields of a preview that the menu bar and the pane's controls
    /// read, flat, so a change shows as a change to one line.
    private struct Pinned: Equatable {
        var symbol: String?
        var iconSymbol: String?
        var iconOverride: String?
        var prefix: String?
        var style: MenuBarStyle = .inline
        var label: String?
        var metrics: [String] = []
        var tooltip: String?
        var isStale = false
        var separate = false
        var profiles = false
        var profileMetrics: [String] = []
        var chart: MenuBarChart = .none
        var historyCount = 0
        var chartScale: Double?
        /// What the pane's controls go by: the "Item" choice, the graph
        /// and click hints.
        var usesOwnItem = false
        var layoutStyle: MenuBarStyle = .inline
    }

    private func widget(_ statusItem: Manifest.StatusItem?, icon: String? = "star") -> LoadedWidget {
        LoadedWidget(
            manifest: Manifest(
                schemaVersion: 1, id: "dev.test.preview", name: "Preview", icon: icon,
                entry: .init(kind: "workflow", main: "workflow.json"), statusItem: statusItem
            ),
            directory: URL(fileURLWithPath: "/nonexistent/preview")
        )
    }

    private func preview(
        _ widget: LoadedWidget, snapshot: WidgetSnapshot? = nil,
        draft: MenuBarPlacement = .init(enabled: true),
        global: MenuBarPresentation? = nil, history: MenuBarChartHistory? = nil
    ) -> (pinned: Pinned, entry: MenuBarEntry) {
        let entry = WidgetSettingsView.menuBarPreviewEntry(
            widget: widget, snapshot: snapshot, draft: draft, globalPresentation: global, history: history
        )
        let layout = WidgetSettingsView.menuBarPreviewLayout(widget: widget, draft: draft)
        XCTAssertEqual(entry.widgetID, widget.id)
        XCTAssertEqual(entry.name, "Preview")
        return (Pinned(
            symbol: entry.symbol, iconSymbol: entry.iconSymbol, iconOverride: entry.iconOverride,
            prefix: entry.prefix, style: entry.style, label: entry.label,
            metrics: entry.metrics.map { "\($0.label) \($0.value)" },
            tooltip: entry.tooltip, isStale: entry.isStale, separate: entry.separate,
            profiles: entry.profiles, profileMetrics: entry.profileMetrics.map { $0.id ?? "" },
            chart: entry.presentation.effectiveChart, historyCount: entry.history.count,
            chartScale: entry.chartScale,
            usesOwnItem: layout.separate, layoutStyle: layout.style
        ), entry)
    }

    private let accounts = WidgetSnapshot(
        widgetID: "dev.test.preview", updatedAt: Date(timeIntervalSinceReferenceDate: 0), error: "failed",
        statusMetrics: [
            StatusMetric(id: "a", label: "Work", number: 10, format: "percent"),
            StatusMetric(id: "b", label: "Home", number: 20, format: "percent"),
            StatusMetric(id: "c", label: "Lab", number: 30, format: "percent"),
        ],
        statusTooltip: "three accounts"
    )

    // MARK: - Pinned fixtures

    func testPlainLabelWidget() {
        let widget = widget(.init(mode: "text", label: "Temp"))
        let read = preview(widget, snapshot: WidgetSnapshot(widgetID: widget.id, statusLabel: " 71° "))
        // (c) iconSymbol: was nil. The widget's own icon, which a text-only
        // item does not show but its chip in the cluster does.
        XCTAssertEqual(read.pinned, Pinned(iconSymbol: "star", prefix: "Temp", label: "71°"))

        // Never run: the preview stands in for the reading. Deliberate.
        XCTAssertEqual(preview(widget).pinned, Pinned(iconSymbol: "star", prefix: "Temp", label: "42%"))
    }

    func testIconOnlyWidgetWithItsSymbol() {
        let widget = widget(.init(mode: "icon", icon: "cpu.fill"))
        let snapshot = WidgetSnapshot(
            widgetID: widget.id, statusLabel: "9",
            statusMetrics: [StatusMetric(id: "a", label: "CPU", number: 9, format: "percent")]
        )
        XCTAssertEqual(
            preview(widget, snapshot: snapshot, draft: .init(enabled: true, presentation: .init(chart: .line))).pinned,
            // (c) iconSymbol was nil; separate was false though the pane
            // itself said "its own item". The bar sets both.
            Pinned(symbol: "cpu.fill", iconSymbol: "cpu.fill", separate: true, chart: .line, usesOwnItem: true)
        )
        // Given another SF Symbol: still an image, still its own item.
        XCTAssertEqual(
            preview(widget, snapshot: snapshot, draft: .init(enabled: true, icon: "memorychip")).pinned,
            // (c) as above.
            Pinned(symbol: "cpu.fill", iconSymbol: "cpu.fill", iconOverride: "memorychip",
                   separate: true, usesOwnItem: true)
        )
    }

    func testIconOnlyWidgetGivenAnEmoji() {
        let widget = widget(.init(mode: "icon", icon: "cpu.fill"))
        XCTAssertEqual(
            preview(widget, draft: .init(enabled: true, icon: "🔥")).pinned,
            // (a) usesOwnItem: was true. An emoji is text, so on the bar the
            // widget shares the strip; the pane now says so, and no longer
            // describes a graph or clicks it would not get.
            // (c) iconSymbol was nil.
            Pinned(symbol: "cpu.fill", iconSymbol: "cpu.fill", iconOverride: "🔥", usesOwnItem: false)
        )
        XCTAssertEqual(
            preview(widget, draft: .init(enabled: true, separate: true, icon: "🔥")).pinned,
            // Split out by choice, as the bar allows. (c) iconSymbol was
            // nil, separate was false.
            Pinned(symbol: "cpu.fill", iconSymbol: "cpu.fill", iconOverride: "🔥", separate: true, usesOwnItem: true)
        )
    }

    func testWidgetWithMetricsAndProfiles() {
        let widget = widget(.init(mode: "dynamic", icon: "person.2", profiles: true))
        // (c) iconSymbol was nil, profiles false and profileMetrics empty in
        // all three below: the bar carries every profile's reading, so the
        // cluster preview draws a chip for each as the cluster does.
        XCTAssertEqual(
            preview(widget, snapshot: accounts).pinned,
            Pinned(symbol: "person.2", iconSymbol: "person.2", label: "42%", metrics: ["Work 10%", "Home 20%"],
                   profiles: true, profileMetrics: ["a", "b", "c"])
        )
        // On its own item with a chart: the example shape and the reading.
        let charted = MenuBarPlacement(enabled: true, separate: true, presentation: .init(chart: .line))
        XCTAssertEqual(
            preview(widget, snapshot: accounts, draft: charted).pinned,
            // (c) separate was false.
            Pinned(symbol: "person.2", iconSymbol: "person.2", label: "42%", metrics: ["Work 10%", "Home 20%"],
                   separate: true, profiles: true, profileMetrics: ["a", "b", "c"],
                   chart: .line, historyCount: WidgetSettingsView.exampleChart.count + 1, chartScale: 100,
                   usesOwnItem: true)
        )
        // Sharing the strip there is no chart to draw.
        XCTAssertEqual(
            preview(widget, snapshot: accounts, draft: .init(enabled: true, presentation: .init(chart: .line))).pinned,
            Pinned(symbol: "person.2", iconSymbol: "person.2", label: "42%", metrics: ["Work 10%", "Home 20%"],
                   profiles: true, profileMetrics: ["a", "b", "c"], chart: .line)
        )
    }

    func testWidgetWhoseAuthorDidNotOfferTheMenuBar() {
        // Promoted by hand: "none" behaves as "text", and nothing else the
        // author wrote under it applies.
        let widget = widget(.init(mode: "none", icon: "cpu.fill", label: "Author", style: "stacked"))
        let snapshot = WidgetSnapshot(widgetID: widget.id, statusLabel: "idle")
        XCTAssertEqual(
            preview(widget, snapshot: snapshot).pinned,
            // (b) style and layoutStyle: were .stacked, and usesOwnItem true
            // because of it. The bar ignores the style of a status item that
            // was not offered, draws the widget inline and lets it share.
            // (c) iconSymbol was nil; it is the manifest's icon, not the
            // unoffered status item's.
            Pinned(iconSymbol: "star", style: .inline, label: "idle", usesOwnItem: false, layoutStyle: .inline)
        )
        XCTAssertEqual(
            preview(widget, snapshot: snapshot, draft: .init(enabled: true, style: .metrics)).pinned,
            // The user's own style still applies. (c) iconSymbol was nil,
            // separate was false.
            Pinned(iconSymbol: "star", style: .metrics, label: "idle", separate: true,
                   usesOwnItem: true, layoutStyle: .metrics)
        )
    }

    // MARK: - Deliberate differences from the bar

    func testExampleChartScalesToTheReadingAndEndsOnIt() {
        let widget = widget(.init(mode: "text"))
        let snapshot = WidgetSnapshot(
            widgetID: widget.id, statusMetrics: [StatusMetric(id: "w", label: "Power", number: 12, unit: "W")]
        )
        let draft = MenuBarPlacement(enabled: true, separate: true, presentation: .init(chart: .bars))
        let entry = preview(widget, snapshot: snapshot, draft: draft).entry
        XCTAssertEqual(entry.history, WidgetSettingsView.exampleChart.map { $0 * 18 } + [12])
        XCTAssertNil(entry.chartScale, "not a percentage: scaled to its own peak")
    }

    func testOwnHistoryReplacesTheExampleShape() {
        let widget = widget(.init(mode: "dynamic", icon: "person.2", profiles: true))
        let draft = MenuBarPlacement(enabled: true, separate: true, presentation: .init(chart: .line))
        let own = MenuBarChartHistory(series: "a", scale: 100, values: [1, 2, 3])
        XCTAssertEqual(preview(widget, snapshot: accounts, draft: draft, history: own).entry.history, [1, 2, 3])

        let other = MenuBarChartHistory(series: "b", scale: 100, values: [1, 2, 3])
        XCTAssertEqual(
            preview(widget, snapshot: accounts, draft: draft, history: other).entry.history.count,
            WidgetSettingsView.exampleChart.count + 1, "another reading's history is not this one's"
        )
        let short = MenuBarChartHistory(series: "a", scale: 100, values: [1])
        XCTAssertEqual(
            preview(widget, snapshot: accounts, draft: draft, history: short).entry.history.count,
            WidgetSettingsView.exampleChart.count + 1, "one point is no shape yet"
        )
    }

    func testPresentationIsResolvedAsTheBarDoes() {
        let widget = widget(.init(mode: "text", presentation: .init(precision: 3, size: .small)))
        let draft = MenuBarPlacement(enabled: true, presentation: .init(precision: 1))
        let entry = preview(widget, snapshot: accounts, draft: draft, global: .init(weight: .bold)).entry
        XCTAssertEqual(entry.metrics.map(\.value), ["10.0%", "20.0%"])
        XCTAssertEqual(entry.presentation.weight, .bold)
        XCTAssertEqual(entry.presentation.size, .small)
    }
}
