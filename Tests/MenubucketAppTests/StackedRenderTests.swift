import XCTest
import AppKit
import MenubucketCore
@testable import MenubucketApp

/// The stacked item is drawn, not typed, so the only honest check is to draw
/// it and look at the pixels.
@MainActor
final class StackedRenderTests: XCTestCase {
    private func entry(
        prefix: String?, value: String?, stale: Bool = false, tint: MenuBarTint? = nil
    ) -> MenuBarEntry {
        MenuBarEntry(
            widgetID: "w", name: "System", prefix: prefix,
            style: .stacked, tint: tint, label: value, isStale: stale
        )
    }

    /// Without a tint the art is a template and the status item colours it for
    /// the bar; with one the colour is baked in, so it must stop being a
    /// template or the system would paint over it.
    func testATintGivesUpTemplateBehaviourAndAnUntintedOneKeepsIt() {
        XCTAssertTrue(
            MenuBarController.stackedImage(entry(prefix: "CPU", value: "23%")).isTemplate
        )
        XCTAssertFalse(
            MenuBarController.stackedImage(
                entry(prefix: "CPU", value: "99%", tint: .danger)
            ).isTemplate
        )
    }

    func testATintedItemIsActuallyDrawnInThatColour() throws {
        let image = MenuBarController.stackedImage(
            entry(prefix: "CPU", value: "99%", tint: .danger), height: 22
        )
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: image.tiffRepresentation ?? Data()))
        var reddest: NSColor?
        for x in 0..<bitmap.pixelsWide {
            for y in 0..<bitmap.pixelsHigh {
                guard let px = bitmap.colorAt(x: x, y: y), px.alphaComponent > 0.8 else { continue }
                let converted = px.usingColorSpace(.deviceRGB)
                if converted?.redComponent ?? 0 > (reddest?.redComponent ?? 0) {
                    reddest = converted
                }
            }
        }
        let ink = try XCTUnwrap(reddest, "nothing was drawn opaquely")
        XCTAssertGreaterThan(ink.redComponent, ink.blueComponent + 0.2, "not drawn red")
    }

    /// A tinted symbol has the same trade: colour instead of template.
    func testATintedSymbolIsColouredAndNotATemplate() throws {
        let plain = try XCTUnwrap(
            MenuBarController.symbolImage(named: "cpu.fill", describedAs: "cpu")
        )
        XCTAssertTrue(plain.isTemplate)
        let tinted = try XCTUnwrap(
            MenuBarController.symbolImage(
                named: "cpu.fill", describedAs: "cpu", tint: .systemRed
            )
        )
        XCTAssertFalse(tinted.isTemplate)
        XCTAssertEqual(tinted.size, plain.size)
    }

    /// Nothing may touch the top or bottom edge: that is what "the top of
    /// Power is cut off" looked like as pixels.
    func testNeitherRowTouchesTheEdges() throws {
        let image = MenuBarController.stackedImage(
            entry(prefix: "Power", value: "6.6 W"), height: 22
        )
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: image.tiffRepresentation ?? Data()))
        XCTAssertEqual(bitmap.pixelsHigh > 0, true)

        func rowIsBlank(_ y: Int) -> Bool {
            (0..<bitmap.pixelsWide).allSatisfy { x in
                (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) < 0.02
            }
        }
        XCTAssertTrue(rowIsBlank(0), "ink on the very top row means the label is clipped")
        XCTAssertTrue(
            rowIsBlank(bitmap.pixelsHigh - 1),
            "ink on the very bottom row means the value is clipped"
        )
    }

    /// Both rows start at the same x — the request was left alignment, and a
    /// centred short label over a wide value is what it replaced.
    func testBothRowsStartAtTheSameLeftEdge() throws {
        let image = MenuBarController.stackedImage(
            entry(prefix: "RAM", value: "100%"), height: 22
        )
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: image.tiffRepresentation ?? Data()))

        func firstInkedColumn(rows: Range<Int>) -> Int? {
            for x in 0..<bitmap.pixelsWide {
                for y in rows where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.15 {
                    return x
                }
            }
            return nil
        }
        let half = bitmap.pixelsHigh / 2
        let top = try XCTUnwrap(firstInkedColumn(rows: 0..<half))
        let bottom = try XCTUnwrap(firstInkedColumn(rows: half..<bitmap.pixelsHigh))
        XCTAssertLessThanOrEqual(
            abs(top - bottom), 2,
            "rows start at x=\(top) and x=\(bottom); they should share a left edge"
        )
    }

    /// The rows have to *fill* the bar, not sit politely in the middle of it.
    ///
    /// The first version reserved each row's line box, which carries about a
    /// quarter of its height in leading the glyphs never use — so the digits
    /// came out visibly smaller than a system monitor's. Packing by cap height
    /// instead is what buys that back, and this is the assertion that stops it
    /// being given away again.
    func testTheRowsFillMostOfTheBarHeight() throws {
        let height: CGFloat = 22
        let image = MenuBarController.stackedImage(
            entry(prefix: "RAM", value: "67%"), height: height
        )
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: image.tiffRepresentation ?? Data()))

        var top: Int?
        var bottom: Int?
        for y in 0..<bitmap.pixelsHigh {
            let inked = (0..<bitmap.pixelsWide).contains {
                (bitmap.colorAt(x: $0, y: y)?.alphaComponent ?? 0) > 0.15
            }
            if inked {
                if top == nil { top = y }
                bottom = y
            }
        }
        let first = try XCTUnwrap(top)
        let last = try XCTUnwrap(bottom)
        let covered = CGFloat(last - first + 1) / CGFloat(bitmap.pixelsHigh)
        XCTAssertGreaterThan(
            covered, 0.75,
            "the two rows only cover \(Int(covered * 100))% of the bar; they should fill it"
        )
    }

    /// The fitted value size has to grow with the bar rather than staying at
    /// whatever suits 22 points, and stop before it reads as another app's.
    func testTheTypeIsFittedToTheBarAndCapped() {
        let small = MenuBarController.stackedFonts(for: 18).value.pointSize
        let normal = MenuBarController.stackedFonts(for: 22).value.pointSize
        let tall = MenuBarController.stackedFonts(for: 40).value.pointSize
        XCTAssertLessThan(small, normal)
        XCTAssertGreaterThan(normal, 11, "the value should fill a 22pt bar, not hide in it")
        XCTAssertLessThanOrEqual(tall, MenuBarController.stackedMaxValuePointSize)
    }

    /// Cap height plus descender, not the line box — the difference is the
    /// leading, and reserving it is what made the type small.
    func testARowIsMeasuredByItsInkNotItsLineBox() {
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let lineBox = NSAttributedString(string: "CPU", attributes: [.font: font]).size().height
        XCTAssertLessThan(MenuBarController.inkHeight(of: font), lineBox * 0.85)
    }

    /// A template image is tinted by the status item, which is what makes it
    /// follow a light or dark menu bar instead of staying black.
    func testTheImageIsATemplateSoTheMenuBarTintsIt() {
        XCTAssertTrue(
            MenuBarController.stackedImage(entry(prefix: "CPU", value: "23%")).isTemplate
        )
    }

    func testAStaleEntryIsDrawnFainter() throws {
        func ink(_ stale: Bool) -> CGFloat {
            let image = MenuBarController.stackedImage(
                entry(prefix: "CPU", value: "23%", stale: stale), height: 22
            )
            guard let bitmap = NSBitmapImageRep(data: image.tiffRepresentation ?? Data())
            else { return 0 }
            var total: CGFloat = 0
            for x in 0..<bitmap.pixelsWide {
                for y in 0..<bitmap.pixelsHigh {
                    total += bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0
                }
            }
            return total
        }
        XCTAssertLessThan(ink(true), ink(false) * 0.8)
    }

    /// The bar is not always 22 points, so the rows are centred in whatever it
    /// actually is rather than in an assumed height.
    func testItFitsWhateverHeightTheBarHas() throws {
        for height in [18.0, 22.0, 26.0] as [CGFloat] {
            let image = MenuBarController.stackedImage(
                entry(prefix: "Power", value: "6.6 W"), height: height
            )
            XCTAssertEqual(image.size.height, height)
            XCTAssertGreaterThan(image.size.width, 10)
        }
    }
}

/// The settings pane draws its preview with the menu bar's own renderer, so a
/// described-but-wrong preview cannot drift into existence.
@MainActor
final class MenuBarPreviewTests: XCTestCase {
    private func entry(_ style: MenuBarStyle, tint: MenuBarTint? = nil) -> MenuBarEntry {
        MenuBarEntry(
            widgetID: "w", name: "System", symbol: "cpu.fill",
            prefix: "CPU", style: style, tint: tint, label: "23%"
        )
    }

    func testBothLayoutsPreviewAsSomethingVisible() {
        for style in MenuBarStyle.allCases {
            let image = MenuBarController.previewImage(for: entry(style), height: 22)
            XCTAssertEqual(image.size.height, 22, "\(style)")
            XCTAssertGreaterThan(image.size.width, 12, "\(style) previewed as a sliver")
        }
    }

    /// The preview has to carry the same template/tint trade the real item
    /// makes, or a coloured item would preview in the pane's own colour.
    func testThePreviewKeepsTheTemplateRule() {
        XCTAssertTrue(MenuBarController.previewImage(for: entry(.inline)).isTemplate)
        XCTAssertFalse(
            MenuBarController.previewImage(for: entry(.inline, tint: .danger)).isTemplate
        )
    }

    /// The stacked preview is the stacked renderer, not a lookalike.
    func testTheStackedPreviewIsTheStackedRenderer() {
        let direct = MenuBarController.stackedImage(
            entry(.stacked),
            symbol: MenuBarController.symbolImage(named: "cpu.fill", describedAs: "System"),
            height: 22
        )
        let preview = MenuBarController.previewImage(for: entry(.stacked), height: 22)
        XCTAssertEqual(preview.size, direct.size)
    }
}
