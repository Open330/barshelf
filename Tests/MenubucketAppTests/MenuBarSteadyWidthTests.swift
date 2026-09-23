import AppKit
import MenubucketCore
import XCTest

@testable import MenubucketApp

/// The promise behind the default width mode, checked with the real
/// renderers: a reading that gains a digit does not move the bar.
final class MenuBarSteadyWidthTests: XCTestCase {
    private func entry(
        _ value: String, style: MenuBarStyle = .stacked,
        _ presentation: MenuBarPresentation = MenuBarPresentation()
    ) -> MenuBarEntry {
        // Through the production presentation step, which is where padding
        // happens — the same path the runtime takes.
        MenuBarPolicy.applyingPresentation(
            presentation,
            to: MenuBarEntry(
                widgetID: "dev.barshelf.sensors", name: "Sensors",
                // A short label, so the value — not the label row — decides
                // the width and the test measures what it claims to.
                prefix: "T", style: style,
                metrics: [StatusMetric(id: "cpu", label: "CPU", value: value)]
            )
        )
    }

    private func stackedWidth(_ value: String, _ p: MenuBarPresentation = MenuBarPresentation()) -> CGFloat {
        MenuBarController.stackedImage(entry(value, p), height: 22).size.width
    }

    func testStackedWidthHoldsAcrossADigit() {
        XCTAssertEqual(stackedWidth("9°"), stackedWidth("10°"))
        XCTAssertEqual(stackedWidth("5%"), stackedWidth("42%"))
    }

    func testFitStillFollowsTheText() {
        let fit = MenuBarPresentation(width: .fit)
        XCTAssertLessThan(stackedWidth("9°", fit), stackedWidth("10°", fit))
    }

    func testMoreReservedDigitsHoldAWiderRange() {
        let three = MenuBarPresentation(digits: 3)
        XCTAssertEqual(stackedWidth("9%", three), stackedWidth("100%", three))
    }

    func testFixedWidthIsAFloorThatStillFitsContent() {
        let narrow = MenuBarPresentation(valueWidth: 32, width: .fixed)
        let wide = MenuBarPresentation(valueWidth: 90, width: .fixed)
        XCTAssertEqual(stackedWidth("9°", wide), stackedWidth("10°", wide))
        XCTAssertGreaterThan(stackedWidth("9°", wide), stackedWidth("9°", narrow))
    }

    func testAKeptFloorWidensTheImage() {
        let plain = MenuBarController.stackedImage(entry("9°"), height: 22).size.width
        let floored = MenuBarController.stackedImage(entry("9°"), height: 22, minimumWidth: plain + 20)
        XCTAssertEqual(floored.size.width, plain + 20, accuracy: 0.5)
    }

    func testMetricsLayoutHoldsToo() {
        let a = MenuBarController.metricsImage(entry("9°", style: .metrics), height: 22).size.width
        let b = MenuBarController.metricsImage(entry("10°", style: .metrics), height: 22).size.width
        XCTAssertEqual(a, b)
    }

    func testWeightAndSizeReachTheValueFont() {
        let bold = MenuBarController.stackedFonts(for: 22, presentation: MenuBarPresentation(weight: .bold)).value
        let regular = MenuBarController.stackedFonts(for: 22, presentation: MenuBarPresentation(weight: .regular)).value
        XCTAssertNotEqual(bold.fontName, regular.fontName)

        let small = MenuBarController.stackedFonts(for: 22, presentation: MenuBarPresentation(size: .small)).value
        let large = MenuBarController.stackedFonts(for: 22, presentation: MenuBarPresentation(size: .large)).value
        XCTAssertLessThan(small.pointSize, large.pointSize)
        // Large never pushes the pair past the bar.
        let fonts = MenuBarController.stackedFonts(for: 22, presentation: MenuBarPresentation(size: .large))
        XCTAssertLessThanOrEqual(
            MenuBarController.inkHeight(of: fonts.label) + MenuBarController.inkHeight(of: fonts.value),
            22
        )
    }

    /// A picture of the promise: the same readings under Steady and Fit,
    /// left-aligned in columns, so a moving right edge is visible at a glance.
    func testWriteSteadyWidthSheet() throws {
        guard let dir = ProcessInfo.processInfo.environment["BARSHELF_SHOT_DIR"] else {
            throw XCTSkip("set BARSHELF_SHOT_DIR to write the steady-width sheet")
        }
        let readings = ["7°", "9°", "10°", "42°", "100°"]
        let modes: [(String, MenuBarPresentation)] = [
            ("Steady", MenuBarPresentation()),
            ("Fit", MenuBarPresentation(width: .fit)),
        ]
        let rowHeight: CGFloat = 30
        let sheet = NSImage(size: NSSize(width: 150 * CGFloat(modes.count) + 20, height: rowHeight * CGFloat(readings.count) + 30), flipped: true) { rect in
            NSColor.white.setFill()
            rect.fill()
            for (column, (name, presentation)) in modes.enumerated() {
                let x = 10 + CGFloat(column) * 150
                (name as NSString).draw(at: NSPoint(x: x, y: 4), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 11)])
                for (row, value) in readings.enumerated() {
                    let image = MenuBarController.stackedImage(self.entry(value, presentation), height: 22)
                    let y = 24 + CGFloat(row) * rowHeight
                    NSColor(white: 0.9, alpha: 1).setFill()
                    NSRect(x: x, y: y, width: image.size.width, height: 22).fill()
                    image.draw(in: NSRect(x: x, y: y, width: image.size.width, height: 22))
                    ("\(Int(image.size.width)) pt" as NSString).draw(
                        at: NSPoint(x: x + 90, y: y + 4),
                        withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)]
                    )
                }
            }
            return true
        }
        let rep = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(sheet.tiffRepresentation)))
        try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: dir).appendingPathComponent("steady-width.png"))
    }

    // MARK: Redraw decisions

    func testLayoutSignatureIgnoresReadingsButNotLayout() {
        XCTAssertEqual(
            MenuBarController.layoutSignature(entry("9°")),
            MenuBarController.layoutSignature(entry("42°"))
        )
        XCTAssertNotEqual(
            MenuBarController.layoutSignature(entry("9°")),
            MenuBarController.layoutSignature(entry("9°", MenuBarPresentation(width: .fit)))
        )
    }

    func testAPresentationChangeRedraws() {
        XCTAssertFalse(MenuBarController.drawsIdentically(
            entry("9°"), entry("9°", MenuBarPresentation(alignment: .trailing))
        ))
        XCTAssertFalse(MenuBarController.drawsIdentically(
            entry("9°"), entry("9°", MenuBarPresentation(size: .large))
        ))
    }

    // MARK: Cadence

    func testTimerTicksLandOnMultiplesOfTheirInterval() {
        let now = Date(timeIntervalSinceReferenceDate: 1000.4)
        XCTAssertEqual(Scheduler.alignedFireDate(interval: 2, now: now).timeIntervalSinceReferenceDate, 1002)
        XCTAssertEqual(Scheduler.alignedFireDate(interval: 3, now: now).timeIntervalSinceReferenceDate, 1002)
        // Exactly on a boundary: the next one, never now.
        let onBoundary = Date(timeIntervalSinceReferenceDate: 1002)
        XCTAssertEqual(Scheduler.alignedFireDate(interval: 2, now: onBoundary).timeIntervalSinceReferenceDate, 1004)
    }

    func testIntervalTitles() {
        XCTAssertEqual(WidgetSettingsView.intervalTitle(2), "Every 2 s")
        XCTAssertEqual(WidgetSettingsView.intervalTitle(60), "Every 1 min")
    }
}
