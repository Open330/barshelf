import AppKit
import XCTest
import MenubucketCore
@testable import MenubucketApp

/// Charts beside a reading: the history kept for them, and how they draw.
@MainActor
final class MenuBarChartTests: XCTestCase {
    private func entry(_ chart: MenuBarChart, history: [Double], style: MenuBarStyle = .stacked,
                       tint: MenuBarTint? = nil, scale: Double? = 100) -> MenuBarEntry {
        var entry = MenuBarEntry(
            widgetID: "w", name: "CPU", prefix: "CPU", style: style, tint: tint, label: "42%",
            metrics: [StatusMetric(id: "cpu", label: "CPU", value: "42%", number: 42, format: "percent")],
            separate: true, presentation: MenuBarPresentation(chart: chart)
        )
        entry.history = history
        entry.chartScale = scale
        return entry
    }

    func testTheChartFollowsTheFirstNumericReading() {
        let sample = MenuBarPolicy.chartSample(entry(.line, history: []))
        XCTAssertEqual(sample?.key, "cpu")
        XCTAssertEqual(sample?.value, 42)
        XCTAssertEqual(sample?.scale, 100)
        let rpm = MenuBarEntry(widgetID: "f", name: "Fan", metrics: [
            StatusMetric(label: "Fan", value: "up"),
            StatusMetric(label: "Fan", number: 1800, unit: "rpm"),
        ])
        XCTAssertEqual(MenuBarPolicy.chartSample(rpm)?.value, 1800)
        XCTAssertNil(MenuBarPolicy.chartSample(rpm)?.scale, "a non-percentage scales to its own peak")
        XCTAssertNil(MenuBarPolicy.chartSample(MenuBarEntry(widgetID: "t", name: "T", label: "hi")))
    }

    func testHistoryKeepsTheNewestUpToTheLimit() {
        var history: MenuBarChartHistory?
        for value in 0..<(MenuBarPolicy.chartHistoryLimit + 5) {
            history = MenuBarPolicy.recordingChart(history, ("cpu", Double(value), 100))
        }
        XCTAssertEqual(history?.values.count, MenuBarPolicy.chartHistoryLimit)
        XCTAssertEqual(history?.values.first, 5)
        XCTAssertEqual(history?.values.last, Double(MenuBarPolicy.chartHistoryLimit + 4))
    }

    func testAnotherReadingStartsANewSeries() {
        var history = MenuBarPolicy.recordingChart(nil, ("cpu", 10, 100))
        history = MenuBarPolicy.recordingChart(history, ("cpu", 20, 100))
        XCTAssertEqual(history.values, [10, 20])
        let moved = MenuBarPolicy.recordingChart(history, ("memory", 60, 100))
        XCTAssertEqual(moved.values, [60], "memory is not joined onto CPU")
        let rescaled = MenuBarPolicy.recordingChart(history, ("cpu", 1800, nil))
        XCTAssertEqual(rescaled.values, [1800])
        XCTAssertNil(rescaled.scale)

        // A refresh without a reading keeps the scale the points were drawn on.
        let applied = MenuBarPolicy.applyingChart(entry(.line, history: [], scale: nil), history: history)
        XCTAssertEqual(applied.chartScale, 100)
        XCTAssertEqual(applied.history, [10, 20])
    }

    func testChartIsLenientAndLayered() throws {
        let decoded = try JSONDecoder().decode(MenuBarPresentation.self, from: Data(#"{"chart":"spiral"}"#.utf8))
        XCTAssertNil(decoded.chart)
        let resolved = MenuBarPolicy.resolvedPresentation(
            user: nil, live: nil, manifest: MenuBarPresentation(chart: .bars)
        )
        XCTAssertEqual(resolved.chart, .bars, "a widget can ask for a chart by default")
        XCTAssertNil(MenuBarPolicy.globalStyle(MenuBarPresentation(chart: .line)), "not an app-wide style")
    }

    func testTheChartWidensTheItemByAFixedAmount() {
        let height: CGFloat = 22
        let plain = MenuBarController.drawnImage(entry(.none, history: [10, 20]), symbol: nil, glyph: nil, height: height)
        for chart in [MenuBarChart.line, .bars, .gauge] {
            let charted = MenuBarController.drawnImage(entry(chart, history: [10, 20, 30]), symbol: nil, glyph: nil, height: height)
            let chrome = MenuBarController.stackedHorizontalPadding
                + MenuBarController.chartSize(chart, height: height).width + MenuBarController.chartGap
            XCTAssertEqual(charted.size.width, ceil(plain.size.width + chrome), accuracy: 1, "\(chart)")
            // A kept floor is the whole item's: drawing at it must not add
            // the chart on top again, or the item widens on every redraw.
            let again = MenuBarController.drawnImage(
                entry(chart, history: [10, 20, 30]), symbol: nil, glyph: nil, height: height,
                minimumWidth: charted.size.width
            )
            XCTAssertEqual(again.size.width, charted.size.width, accuracy: 1, "\(chart)")
        }
        let empty = MenuBarController.drawnImage(entry(.line, history: []), symbol: nil, glyph: nil, height: height)
        XCTAssertEqual(empty.size.width, plain.size.width, "nothing to draw yet takes no room")
    }

    func testTemplateMatchesTheRows() {
        let plain = MenuBarController.drawnImage(entry(.line, history: [1, 2]), symbol: nil, glyph: nil)
        XCTAssertTrue(plain.isTemplate, "an untinted item stays a template, so the bar tints it")
        let tinted = MenuBarController.drawnImage(entry(.line, history: [1, 2], tint: .danger), symbol: nil, glyph: nil)
        XCTAssertFalse(tinted.isTemplate)
    }

    func testRedrawAndLayout() {
        let a = entry(.line, history: [1, 2])
        var b = a
        b.history = [1, 2, 3]
        XCTAssertFalse(MenuBarController.drawsIdentically(a, b), "a new point is drawn")
        XCTAssertEqual(MenuBarController.layoutSignature(a), MenuBarController.layoutSignature(b),
                       "but it is not a layout change")
        var c = a
        c.presentation.chart = .bars
        XCTAssertFalse(MenuBarController.drawsIdentically(a, c))
    }

    /// `BARSHELF_SHOT_DIR=… swift test --filter MenuBarChartTests` writes each
    /// chart, light and tinted, for a look.
    func testWriteChartShots() throws {
        guard let dir = ProcessInfo.processInfo.environment["BARSHELF_SHOT_DIR"] else {
            throw XCTSkip("set BARSHELF_SHOT_DIR to write chart images")
        }
        let history = WidgetSettingsView.exampleChart.map { $0 * 100 }
        var rows: [NSImage] = []
        for style in [MenuBarStyle.stacked, .metrics, .inline] {
            for chart in [MenuBarChart.line, .bars, .gauge] {
                for tint in [nil, MenuBarTint.warning] {
                    rows.append(MenuBarController.previewImage(for: entry(chart, history: history, style: style, tint: tint)))
                }
            }
        }
        let scale: CGFloat = 4
        let width = (rows.map(\.size.width).max() ?? 1) + 8
        let height = rows.reduce(0) { $0 + $1.size.height + 4 }
        let canvas = NSImage(size: NSSize(width: width * scale, height: height * scale), flipped: true) { _ in
            NSColor(white: 0.93, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: width * scale, height: height * scale).fill()
            var y: CGFloat = 0
            for image in rows {
                let drawn: NSImage = image.isTemplate ? {
                    let copy = NSImage(size: image.size, flipped: false) { rect in
                        NSColor.black.set(); rect.fill()
                        image.draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1)
                        return true
                    }
                    return copy
                }() : image
                drawn.draw(in: NSRect(x: 4 * scale, y: y * scale, width: image.size.width * scale, height: image.size.height * scale))
                y += image.size.height + 4
            }
            return true
        }
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(canvas.tiffRepresentation)))
        try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: dir).appendingPathComponent("charts.png"))
    }
}
