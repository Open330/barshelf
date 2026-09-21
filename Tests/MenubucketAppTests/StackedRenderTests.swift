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
