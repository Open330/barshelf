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

    func testANoLabelChoiceDropsTheStackedTopRow() {
        var noLabel = entry("42°")
        noLabel.prefix = ""
        XCTAssertEqual(MenuBarController.stackedLines(noLabel, glyph: nil).top, "")
        var unset = entry("42°")
        unset.prefix = nil
        XCTAssertEqual(MenuBarController.stackedLines(unset, glyph: nil).top, "Sensors")
    }

    func testFixedWithoutAWidthUsesTheSameDefaultAsTheStepper() {
        let fixed = MenuBarPresentation(width: .fixed)
        let explicit = MenuBarPresentation(valueWidth: MenuBarPresentation.defaultFixedWidth, width: .fixed)
        XCTAssertEqual(stackedWidth("9°", fixed), stackedWidth("9°", explicit))
    }

    /// The four looks people asked to choose between, each reachable from the
    /// two settings, and each holding the item's width.
    func testEveryAlignmentCombinationHoldsTheWidth() {
        let combos: [MenuBarPresentation] = [
            MenuBarPresentation(),                                              // A
            MenuBarPresentation(numberAlignment: .left),                        // B
            MenuBarPresentation(alignment: .trailing),                          // C
            MenuBarPresentation(alignment: .center),                            // D
        ]
        for p in combos {
            // To a hundredth of a point: text layout sums glyph advances and
            // can differ in the last bit; the item's length is rounded up anyway.
            XCTAssertEqual(stackedWidth("4 W", p), stackedWidth("15 W", p), accuracy: 0.01, "\(p)")
        }
        XCTAssertFalse(MenuBarController.drawsIdentically(
            entry("4 W"), entry("4 W", MenuBarPresentation(numberAlignment: .left))
        ))
    }

    /// The user's three items — CPU, RAM, and power relabelled PWR — come out
    /// the same width. The space in "12 W" had made power 3 pt wider; W is
    /// exactly as wide as %.
    func testPowerLinesUpWithCPUAndRAM() {
        func item(_ label: String, _ metric: StatusMetric) -> CGFloat {
            let entry = MenuBarPolicy.applyingPresentation(
                MenuBarPresentation(),
                to: MenuBarEntry(widgetID: label, name: label, prefix: label, style: .stacked, metrics: [metric])
            )
            return MenuBarController.stackedImage(entry, symbol: nil, glyph: nil).size.width
        }
        let cpu = item("CPU", StatusMetric(id: "cpu", label: "CPU", value: "", number: 23, format: "percent"))
        let ram = item("RAM", StatusMetric(id: "memory", label: "RAM", value: "", number: 70, format: "percent"))
        for watts in [5.0, 12.0] {
            let pwr = item("PWR", StatusMetric(id: "power", label: "Power", value: "", number: watts,
                                               format: "decimal", unit: "W", precision: 0))
            // Compared as the bar sizes items, in whole points: W and % differ
            // in the third decimal place, which no length can show.
            XCTAssertEqual(ceil(pwr), ceil(cpu), "\(watts) W")
        }
        XCTAssertEqual(ceil(cpu), ceil(ram))
    }

    // MARK: Kept widths expire

    /// One 100% CPU reading used to leave the item three digits wide for the
    /// rest of the session. It keeps that width for a minute after readings
    /// come back down — so one hovering at 99/100 does not shove the bar every
    /// tick — then lets go.
    func testAKeptWidthIsHeldForAMinuteAfterTheDropThenReleased() {
        let layout = MenuBarController.layoutSignature(entry("12%"))
        let t0 = Date(timeIntervalSinceReferenceDate: 1000)
        let spiked = MenuBarController.nextFloor(nil, layout: layout, natural: 44, now: t0)
        XCTAssertEqual(MenuBarController.activeFloor(spiked, layout: layout, now: t0), 44)

        // Back down at t0+30: held, and the minute starts now.
        let t30 = t0.addingTimeInterval(30)
        let dropped = MenuBarController.nextFloor(spiked, layout: layout, natural: 36, now: t30)
        XCTAssertEqual(dropped.width, 44)
        XCTAssertEqual(dropped.releasedAt, t30)
        XCTAssertEqual(MenuBarController.activeFloor(dropped, layout: layout, now: t30), 44)

        // Further narrow readings do not restart the minute.
        let t50 = t0.addingTimeInterval(50)
        XCTAssertEqual(MenuBarController.nextFloor(dropped, layout: layout, natural: 36, now: t50).releasedAt, t30)

        // Still held 59 s after the drop, released at 61.
        XCTAssertEqual(MenuBarController.activeFloor(dropped, layout: layout, now: t30.addingTimeInterval(59)), 44)
        XCTAssertEqual(MenuBarController.activeFloor(dropped, layout: layout, now: t30.addingTimeInterval(61)), 0)

        // Needing the width again cancels the countdown.
        let again = MenuBarController.nextFloor(dropped, layout: layout, natural: 44, now: t50)
        XCTAssertNil(again.releasedAt)
    }

    /// The live bug: CPU pinned at 100% for minutes is never redrawn (the
    /// entry does not change), so nothing renews a timestamp. The hold must
    /// still apply when it finally comes down.
    func testALongPlateauStillHoldsWhenTheReadingComesDown() {
        let layout = MenuBarController.layoutSignature(entry("12%"))
        let t0 = Date(timeIntervalSinceReferenceDate: 1000)
        let spiked = MenuBarController.nextFloor(nil, layout: layout, natural: 44, now: t0)
        // Five minutes at 100% with no draws, then 97%.
        let later = t0.addingTimeInterval(300)
        XCTAssertEqual(MenuBarController.activeFloor(spiked, layout: layout, now: later), 44)
        let dropped = MenuBarController.nextFloor(spiked, layout: layout, natural: 36, now: later)
        XCTAssertEqual(MenuBarController.activeFloor(dropped, layout: layout, now: later), 44)
    }

    func testAKeptWidthDoesNotOutliveALayoutChange() {
        let layout = MenuBarController.layoutSignature(entry("12%"))
        let other = MenuBarController.layoutSignature(entry("12%", MenuBarPresentation(alignment: .trailing)))
        let floor = MenuBarController.nextFloor(nil, layout: layout, natural: 44, now: Date())
        XCTAssertEqual(MenuBarController.activeFloor(floor, layout: other, now: Date()), 0)
    }

    func testTheImageCarriesOnlyOnePointEitherSide() {
        let value = MenuBarPolicy.applyingPresentation(
            MenuBarPresentation(width: .fit),
            to: MenuBarEntry(widgetID: "x", name: "x", prefix: "C", style: .stacked, label: "23%")
        )
        let (labelFont, valueFont) = MenuBarController.stackedFonts(for: NSStatusBar.system.thickness)
        _ = labelFont
        let text = ("23%" as NSString).size(withAttributes: [.font: valueFont]).width
        let image = MenuBarController.stackedImage(value, symbol: nil, glyph: nil).size.width
        XCTAssertEqual(image - text, 2, accuracy: 0.01)
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
