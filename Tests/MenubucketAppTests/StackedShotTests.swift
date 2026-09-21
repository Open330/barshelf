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
        let cases: [(String?, String?, NSImage?)] = [
            ("RAM", "67%", nil),
            ("Power", "6.6 W", nil),
            ("CPU", "23%", MenuBarController.symbolImage(named: "cpu.fill", describedAs: "cpu")),
            ("Peak", "100°", nil),
            (nil, "42%", nil),
        ]
        let height: CGFloat = 22
        let images = cases.map { prefix, value, symbol in
            MenuBarController.stackedImage(
                MenuBarEntry(
                    widgetID: "w", name: "System", prefix: prefix,
                    style: .stacked, label: value
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
            let tinted = NSImage(size: image.size)
            tinted.lockFocus()
            NSColor.white.set()
            NSRect(origin: .zero, size: image.size).fill(using: .sourceOver)
            image.draw(at: .zero, from: .zero, operation: .destinationIn, fraction: 1)
            tinted.unlockFocus()
            tinted.draw(at: NSPoint(x: x, y: 0), from: .zero, operation: .sourceOver, fraction: 1)
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
