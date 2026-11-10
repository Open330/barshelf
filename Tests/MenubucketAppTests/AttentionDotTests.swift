import AppKit
import XCTest
@testable import MenubucketApp

/// The attention dot on the main menu bar item has to read as an alert:
/// red, whatever the menu bar's appearance, with the mark beside it still
/// drawn in the menu bar's own ink.
final class AttentionDotTests: XCTestCase {
    private func render(_ image: NSImage, in name: NSAppearance.Name, scale: CGFloat = 2) -> NSBitmapImageRep {
        let width = Int(image.size.width * scale), height = Int(image.size.height * scale)
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        )!
        rep.size = image.size
        NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            image.draw(in: NSRect(origin: .zero, size: image.size))
            NSGraphicsContext.restoreGraphicsState()
        }
        if let dir = ProcessInfo.processInfo.environment["BARSHELF_DUMP_DIR"] {
            let file = URL(fileURLWithPath: dir).appendingPathComponent("attention-dot-\(name.rawValue).png")
            try? rep.representation(using: .png, properties: [:])?.write(to: file)
        }
        return rep
    }

    /// The colour at a point given in image points from the bottom-left.
    private func color(_ rep: NSBitmapImageRep, at point: NSPoint) -> NSColor {
        let scale = CGFloat(rep.pixelsWide) / rep.size.width
        let x = Int(point.x * scale), y = rep.pixelsHigh - 1 - Int(point.y * scale)
        return rep.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
    }

    func testDotIsRedAndMarkFollowsAppearance() {
        let base = BarShelfStatusIcon.logoImage()
        let badged = BarShelfStatusIcon.badgedImage(base)
        XCTAssertFalse(badged.isTemplate, "a template image cannot carry the red")
        let dot = BarShelfStatusIcon.badgeRect(in: NSRect(origin: .zero, size: base.size))
        // The bar at the foot of the mark.
        let bar = NSPoint(x: 12, y: 3.4)
        for (name, dark) in [(NSAppearance.Name.aqua, false), (.darkAqua, true)] {
            let rep = render(badged, in: name)
            let center = color(rep, at: NSPoint(x: dot.midX, y: dot.midY))
            XCTAssertGreaterThan(center.redComponent, 0.8, "\(name.rawValue)")
            XCTAssertLessThan(center.greenComponent, 0.45, "\(name.rawValue)")
            XCTAssertGreaterThan(center.alphaComponent, 0.9, "\(name.rawValue)")
            let ink = color(rep, at: bar)
            XCTAssertGreaterThan(ink.alphaComponent, 0.5, "\(name.rawValue)")
            if dark {
                XCTAssertGreaterThan(ink.brightnessComponent, 0.7, "dark menu bar: light mark")
            } else {
                XCTAssertLessThan(ink.brightnessComponent, 0.3, "light menu bar: dark mark")
            }
        }
    }

    func testDotIsARoundCircleCutFromTheMark() {
        let rect = NSRect(x: 0, y: 0, width: 24, height: 18)
        let dot = BarShelfStatusIcon.badgeRect(in: rect)
        XCTAssertEqual(dot.width, dot.height)
        XCTAssertGreaterThanOrEqual(dot.width, 6)
        XCTAssertEqual(dot.maxX, rect.maxX)
        XCTAssertEqual(dot.maxY, rect.maxY)
    }
}
