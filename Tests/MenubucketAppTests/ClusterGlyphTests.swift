import AppKit
import XCTest
@testable import MenubucketApp
import MenubucketCore

/// A chip's symbol as it lands in the menu bar: how large the drawing is,
/// where its middle is, and which way up.
///
/// Measured on pixels, because that is where it went wrong: a symbol's image
/// is mostly margin (and uneven margin), so "8.5 pt, centred as an image"
/// was 7.5 pt of drawing up to half a point off centre, and the flipped
/// cluster image drew every symbol upside down.
@MainActor
final class ClusterGlyphTests: XCTestCase {
    private static let scale = 8
    private static let cell = 26, height = 24
    /// The disc is drawn in a blue no symbol has, so the two tell apart.
    private static let disc = NSColor(red: 0.1, green: 0.1, blue: 0.6, alpha: 1)

    private struct Box {
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        mutating func add(_ x: Int, _ y: Int) {
            minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
        }
        var width: Double { Double(maxX - minX + 1) / Double(ClusterGlyphTests.scale) }
        var height: Double { Double(maxY - minY + 1) / Double(ClusterGlyphTests.scale) }
        var midX: Double { Double(minX + maxX + 1) / 2 / Double(ClusterGlyphTests.scale) }
        var midY: Double { Double(minY + maxY + 1) / 2 / Double(ClusterGlyphTests.scale) }
    }

    /// One chip, drawn eight times life size (or at `scale`). Rows run top
    /// to bottom.
    private func render(_ symbol: String, scale: Int = ClusterGlyphTests.scale) throws -> NSBitmapImageRep {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Self.cell * scale, pixelsHigh: Self.height * scale,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        rep.size = NSSize(width: Self.cell, height: Self.height)
        let chip = ClusterChip(widgetID: symbol, name: symbol, symbol: symbol, initial: "X")
        let image = MenuBarController.clusterImage(
            [chip], mark: NSImage(size: NSSize(width: 1, height: 1)), badged: false,
            color: { _ in Self.disc }, appearance: try XCTUnwrap(NSAppearance(named: .darkAqua)), height: CGFloat(Self.height)
        )
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(
            in: NSRect(x: 0, y: 0, width: Self.cell, height: Self.height),
            from: NSRect(x: 0, y: 0, width: Self.cell, height: Self.height), operation: .sourceOver, fraction: 1
        )
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    /// The symbol's and the disc's boxes, and how much of the symbol is in
    /// each row.
    private func measure(_ rep: NSBitmapImageRep) -> (ink: Box, disc: Box, rows: [Int]) {
        var ink = Box(), disc = Box()
        var rows = [Int](repeating: 0, count: rep.pixelsHigh)
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let color = rep.colorAt(x: x, y: y) else { continue }
                if color.blueComponent > 0.4 { disc.add(x, y) }
                if color.redComponent > 0.55, color.greenComponent > 0.55 {
                    ink.add(x, y)
                    rows[y] += 1
                }
            }
        }
        return (ink, disc, rows)
    }

    private func withFreshGlyphs<T>(_ body: () throws -> T) rethrows -> T {
        GlyphCache.shared.isEnabled = false
        defer { GlyphCache.shared.isEnabled = true }
        return try body()
    }

    private static let symbols = [
        "cpu", "memorychip", "bolt.fill", "thermometer.medium", "battery.75percent", "fan",
        "internaldrive", "network", "arrow.down", "lock.shield.fill", "cup.and.saucer.fill",
    ]

    /// Square, tall and wide symbols alike: the drawing's middle is the
    /// disc's middle.
    func testASymbolsDrawingIsInTheMiddleOfItsDisc() throws {
        try withFreshGlyphs {
            for symbol in Self.symbols {
                let (ink, disc, _) = measure(try render(symbol))
                XCTAssertEqual(disc.width, Double(MenuBarController.ChipMetrics.face), accuracy: 0.3, symbol)
                XCTAssertEqual(ink.midX, disc.midX, accuracy: 0.25, "\(symbol) is off centre sideways")
                XCTAssertEqual(ink.midY, disc.midY, accuracy: 0.25, "\(symbol) is off centre up or down")
            }
        }
    }

    /// The size is the drawing's, not the font's: every symbol's longer
    /// side is well over half the disc, none reaches the rim.
    func testASymbolsDrawingFillsMostOfItsDisc() throws {
        let face = Double(MenuBarController.ChipMetrics.face)
        try withFreshGlyphs {
            for symbol in Self.symbols {
                let (ink, _, _) = measure(try render(symbol))
                let longer = max(ink.width, ink.height)
                XCTAssertGreaterThan(longer, face * 0.55, "\(symbol) is too small: \(ink.width)x\(ink.height)")
                XCTAssertLessThanOrEqual(longer, Double(MenuBarController.ChipMetrics.glyphSize) + 0.3, symbol)
                XCTAssertLessThan(
                    (ink.width * ink.width + ink.height * ink.height).squareRoot(), face - 2,
                    "\(symbol) reaches the rim"
                )
            }
        }
    }

    /// The cluster is a flipped image. A down arrow's head (its widest
    /// rows) is in its lower half, and a cup's saucer is at the bottom.
    func testSymbolsAreTheRightWayUp() throws {
        GlyphCache.shared.scalesForTesting = [2]
        defer { GlyphCache.shared.scalesForTesting = nil }
        for cached in [false, true] {
            GlyphCache.shared.isEnabled = cached
            defer { GlyphCache.shared.isEnabled = true }
            for symbol in ["arrow.down", "cup.and.saucer.fill"] {
                let (ink, _, rows) = measure(try render(symbol))
                let middle = (ink.minY + ink.maxY) / 2
                let upper = rows[ink.minY...middle].max() ?? 0
                let lower = rows[(middle + 1)...ink.maxY].max() ?? 0
                XCTAssertGreaterThan(lower, upper, "\(symbol) is upside down (cached: \(cached))")
            }
        }
    }

    /// Where the symbol's weight is, in points: the mean position of what
    /// is lighter than the disc, each pixel counted by how much lighter.
    /// No threshold, so a faint stroke on a 1x display still counts.
    private func weight(_ rep: NSBitmapImageRep, scale: Int) -> (x: Double, y: Double, total: Double) {
        var sumX = 0.0, sumY = 0.0, total = 0.0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let color = rep.colorAt(x: x, y: y) else { continue }
                let light = max(0, Double(color.redComponent) - 0.25)
                sumX += light * (Double(x) + 0.5)
                sumY += light * (Double(y) + 0.5)
                total += light
            }
        }
        guard total > 0 else { return (0, 0, 0) }
        return (sumX / total / Double(scale), sumY / total / Double(scale), total / Double(scale * scale))
    }

    /// A cached glyph is the same drawing as a fresh one, in the same
    /// place, on a Retina display and on a 1x one: each drawn at that
    /// display's own density and compared there. (The cache is keyed by
    /// the display's density; the test names it, so the result is the same
    /// on a Mac with either kind of screen.)
    func testACachedGlyphSitsWhereAFreshOneDoes() throws {
        defer { GlyphCache.shared.scalesForTesting = nil }
        for density in [2, 1] {
            GlyphCache.shared.scalesForTesting = [CGFloat(density)]
            for symbol in ["thermometer.medium", "memorychip", "bolt.fill", "battery.75percent", "arrow.down"] {
                let fresh = try withFreshGlyphs { weight(try render(symbol, scale: density), scale: density) }
                let cached = weight(try render(symbol, scale: density), scale: density)
                XCTAssertGreaterThan(fresh.total, 5, "\(symbol) drew nothing")
                XCTAssertEqual(cached.x, fresh.x, accuracy: 0.1, "\(symbol) at \(density)x moved sideways")
                XCTAssertEqual(cached.y, fresh.y, accuracy: 0.1, "\(symbol) at \(density)x moved up or down")
                XCTAssertEqual(cached.total, fresh.total, accuracy: fresh.total * 0.05, "\(symbol) at \(density)x is fainter or bolder")
            }
        }
    }

    /// A glyph's image is an even number of points each way, so centred
    /// on a chip it starts on a whole point: a pixel on any display.
    func testAGlyphsImageStartsOnAPixelOnAnyDisplay() throws {
        GlyphCache.shared.scalesForTesting = [1, 2]
        defer { GlyphCache.shared.scalesForTesting = nil }
        for symbol in Self.symbols {
            let size = try XCTUnwrap(GlyphCache.shared.glyph(symbol, side: MenuBarController.ChipMetrics.glyphSize)).size
            XCTAssertEqual(size.width.truncatingRemainder(dividingBy: 2), 0, "\(symbol) \(size)")
            XCTAssertEqual(size.height.truncatingRemainder(dividingBy: 2), 0, "\(symbol) \(size)")
        }
    }
}
