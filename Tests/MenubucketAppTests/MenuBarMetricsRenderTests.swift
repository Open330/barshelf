import AppKit
import XCTest
import MenubucketCore
@testable import MenubucketApp

@MainActor
final class MenuBarMetricsRenderTests: XCTestCase {
    private func entry(values: Bool = true) -> MenuBarEntry {
        MenuBarEntry(widgetID: "generic", name: "Transfers", style: .metrics, metrics: [
            StatusMetric(label: values ? "↑" : "", value: values ? "12 KB/s" : "",
                         tint: "warning", active: true, accessibilityLabel: "Upload 12 KB/s"),
            StatusMetric(label: values ? "↓" : "", value: values ? "1.2 MB/s" : "",
                         tint: "accent", active: false, accessibilityLabel: "Download idle"),
        ])
    }

    func testActivityOnlyFitsCompactlyAndRatesRemainBounded() throws {
        let dots = MenuBarController.metricsImage(entry(values: false), height: 22)
        let rates = MenuBarController.metricsImage(entry(), height: 22)
        XCTAssertLessThanOrEqual(dots.size.width, 22)
        XCTAssertGreaterThan(rates.size.width, dots.size.width)
        XCTAssertLessThan(rates.size.width, 150)
        for image in [dots, rates] {
            XCTAssertEqual(image.size.height, 22)
            XCTAssertFalse(image.isTemplate)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(image.tiffRepresentation)))
            XCTAssertGreaterThan(bitmap.pixelsWide, 0)
        }
    }

    func testGenericUntintedRowsAndOldWidgetFallback() {
        let generic = MenuBarEntry(widgetID: "queue", name: "Queue", style: .metrics, metrics: [
            StatusMetric(label: "Done", value: "120"), StatusMetric(label: "Waiting", value: "3"),
        ])
        XCTAssertTrue(MenuBarController.metricsImage(generic, height: 22).isTemplate)
        let legacy = MenuBarEntry(widgetID: "cpu", name: "CPU", style: .metrics, label: "12%")
        XCTAssertEqual(MenuBarController.metricsImage(legacy, height: 22).size,
                       MenuBarController.stackedImage(legacy, height: 22).size)
        XCTAssertEqual(MenuBarController.previewImage(for: generic, height: 22).size,
                       MenuBarController.metricsImage(generic, height: 22).size)
    }

    func testHiddenValuesDoNotTriggerBitmapRedrawButActivityDoes() {
        let original = entry(values: false)
        var changed = original
        changed.metrics[0].accessibilityLabel = "Upload 48 KB/s"
        changed.label = "48 KB/s"
        changed.tooltip = "Changed transfer rates"
        XCTAssertTrue(MenuBarController.drawsIdentically(original, changed))
        changed.metrics[0].active = false
        XCTAssertFalse(MenuBarController.drawsIdentically(original, changed))
        changed = original
        changed.isStale = true
        XCTAssertFalse(MenuBarController.drawsIdentically(original, changed))
    }

    func testMetricsRemainVisibleWhenSwitchingToLegacyLayouts() {
        var rates = entry()
        rates.style = .stacked
        XCTAssertFalse(MenuBarController.stackedLines(rates, glyph: nil).bottom.isEmpty)
        var dots = entry(values: false)
        dots.style = .inline
        XCTAssertEqual(MenuBarPolicy.entryText(dots), "● · ○")
        dots.prefix = "Traffic"
        XCTAssertEqual(MenuBarPolicy.entryText(dots), "Traffic ● · ○")
    }

    func testSmallRateChangesKeepColumnWidthStable() {
        var small = entry()
        var large = entry()
        small.metrics[0].value = "1 B/s"
        large.metrics[0].value = "987 KB/s"
        XCTAssertEqual(MenuBarController.metricsImage(small, height: 22).size.width,
                       MenuBarController.metricsImage(large, height: 22).size.width)
    }

    func testRenderContactSheetWhenRequested() throws {
        guard let path = ProcessInfo.processInfo.environment["BARSHELF_METRICS_SHOT"] else { return }
        var examples = [entry(values: false), entry(), MenuBarEntry(
            widgetID: "queue", name: "Queue", style: .metrics, metrics: [
                StatusMetric(label: "Done", value: "120"), StatusMetric(label: "Waiting", value: "3"),
            ])]
        for (id, label, number, format, unit) in [
            ("cpu", "CPU", 23.4, "percent", ""),
            ("ram", "RAM", 12_800_000_000.0, "bytes", ""),
            ("power", "Power", 18.7, "decimal", "W")
        ] {
            examples.append(MenuBarPolicy.applyingPresentation(.init(precision: 1), to:
                MenuBarEntry(widgetID: id, name: label, prefix: label, style: .stacked, metrics: [
                    StatusMetric(id: id, label: label, number: number, format: format, unit: unit)
                ])))
        }
        let sheet = NSImage(size: NSSize(width: 480, height: 160))
        sheet.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 480, height: 160).fill()
        var x: CGFloat = 15
        for (index, example) in examples.enumerated() {
            if index == 3 { x = 15 }
            let image = MenuBarController.previewImage(for: example, height: 22)
            image.draw(at: NSPoint(x: x, y: index < 3 ? 108 : 28), from: .zero, operation: .sourceOver, fraction: 1)
            x += image.size.width + 30
        }
        sheet.unlockFocus()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(sheet.tiffRepresentation)))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
    }

    func testNumericPresentationAcrossLayoutsAndRedraws() {
        let raw = MenuBarEntry(widgetID: "cpu", name: "System", prefix: "CPU", style: .stacked, metrics: [
            StatusMetric(id: "cpu", label: "CPU", number: 12.31, format: "percent", tint: "warning")
        ])
        let presentation = MenuBarPresentation(precision: 0, color: "monochrome")
        let first = MenuBarPolicy.applyingPresentation(presentation, to: raw)
        XCTAssertEqual(MenuBarController.stackedLines(first, glyph: nil).bottom, "12%")
        var changed = raw
        changed.metrics[0].number = 12.32
        let second = MenuBarPolicy.applyingPresentation(presentation, to: changed)
        XCTAssertTrue(MenuBarController.drawsIdentically(first, second))
        var narrow = first
        narrow.style = .metrics
        narrow.presentation.valueWidth = 32
        var wide = narrow
        wide.presentation.valueWidth = 120
        XCTAssertTrue(MenuBarController.metricsImage(narrow, height: 22).isTemplate)
        XCTAssertGreaterThan(MenuBarController.metricsImage(wide, height: 22).size.width,
                             MenuBarController.metricsImage(narrow, height: 22).size.width)
    }
}
