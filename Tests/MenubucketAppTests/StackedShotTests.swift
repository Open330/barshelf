import XCTest
import AppKit
import MenubucketCore
@testable import MenubucketApp

/// Writes the stacked items to a PNG so a human can look at them.
/// `BARSHELF_SHOT_DIR=/tmp swift test --filter StackedShot`
@MainActor
final class StackedShotTests: XCTestCase {
    func testWriteAContactSheet() throws {
        guard let dir = ProcessInfo.processInfo.environment["BARSHELF_SHOT_DIR"] else {
            throw XCTSkip("set BARSHELF_SHOT_DIR to write a contact sheet")
        }
        let cases: [(String?, String?, NSImage?, MenuBarTint?)] = [
            ("RAM", "67%", nil, nil),
            ("Power", "6.6 W", nil, nil),
            ("CPU", "23%", MenuBarController.symbolImage(named: "cpu.fill", describedAs: "cpu"), nil),
            ("CPU", "82%", nil, .warning),
            ("CPU", "97%", nil, .danger),
            ("Net", "OK", nil, .good),
        ]
        let height: CGFloat = 22
        let images = cases.map { prefix, value, symbol, tint in
            MenuBarController.stackedImage(
                MenuBarEntry(
                    widgetID: "w", name: "System", prefix: prefix,
                    style: .stacked, tint: tint, label: value
                ),
                symbol: symbol, height: height
            )
        }
        let gap: CGFloat = 10
        let width = images.reduce(0) { $0 + $1.size.width + gap }
        let sheet = NSImage(size: NSSize(width: width, height: height))
        sheet.lockFocus()
        // Dark, like a dark menu bar, with the template art drawn white.
        NSColor(white: 0.18, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        var x: CGFloat = 0
        for image in images {
            if image.isTemplate {
                // What the status item does for a template: paint it in the
                // bar's own colour. Drawn white here, as on a dark bar.
                let masked = NSImage(size: image.size)
                masked.lockFocus()
                NSColor.white.set()
                NSRect(origin: .zero, size: image.size).fill(using: .sourceOver)
                image.draw(at: .zero, from: .zero, operation: .destinationIn, fraction: 1)
                masked.unlockFocus()
                masked.draw(at: NSPoint(x: x, y: 0), from: .zero, operation: .sourceOver, fraction: 1)
            } else {
                // A tinted item carries its own colour and is drawn as-is.
                image.draw(at: NSPoint(x: x, y: 0), from: .zero, operation: .sourceOver, fraction: 1)
            }
            x += image.size.width + gap
        }
        sheet.unlockFocus()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: sheet.tiffRepresentation ?? Data()))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let url = URL(fileURLWithPath: dir).appendingPathComponent("stacked.png")
        try png.write(to: url)
        print("wrote \(url.path) (\(Int(width))x\(Int(height)))")
    }
}
