import AppKit
@testable import MenubucketApp
import MenubucketCore
import XCTest

/// The folded cluster with a chip in trouble. Set CLUSTER_RENDER_DIR to keep
/// the images for a look.
final class ClusterAlertDotTests: XCTestCase {
    private let chips = [
        ClusterChip(widgetID: "a", name: "CPU", symbol: "cpu", initial: "C", value: "23%"),
        ClusterChip(widgetID: "b", name: "Memory", symbol: "memorychip", initial: "M", alert: true, value: "91%"),
        ClusterChip(widgetID: "c", name: "Power", symbol: "bolt.fill", initial: "P", value: "6W"),
        ClusterChip(widgetID: "d", name: "Awake", symbol: "cup.and.saucer.fill", initial: "A", alert: true, value: "1:42"),
    ]
    private let palette: [String: NSColor] = ["a": .systemPurple, "b": .systemPink, "c": .systemOrange, "d": .systemTeal]

    private func render(focus: Int? = nil, pill: CGFloat? = nil, appearance: NSAppearance.Name) -> NSImage {
        MenuBarController.clusterImage(
            chips, focus: focus, pill: pill,
            mark: NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: nil)!,
            badged: false,
            color: { self.palette[$0.widgetID] ?? .systemBlue },
            appearance: NSAppearance(named: appearance)!,
            height: 24
        )
    }

    /// The alert dot of the second chip is in view at its own top-trailing
    /// corner: folded chips lie over the chip to their right.
    func testAFoldedChipsAlertDotIsOnItsVisibleSide() throws {
        let image = render(appearance: .darkAqua)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        let scale = CGFloat(rep.pixelsWide) / image.size.width
        // Chip 1 centre (folded), then its top-trailing dot.
        let center = CGFloat(ClusterGeometry.collapsedStep) + CGFloat(ClusterGeometry.slot) / 2
        let m = MenuBarController.ChipMetrics.self
        // Folded, the chip lies over the next one, so its top-trailing dot
        // is in view.
        let dot = CGPoint(x: center + m.face / 2 - m.badge / 3, y: 12 - m.face / 2 + m.badge / 3)
        let color = try XCTUnwrap(rep.colorAt(x: Int(dot.x * scale), y: Int(dot.y * scale))?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(color.redComponent, 0.8)
        XCTAssertLessThan(color.greenComponent, 0.4)

        if let dir = ProcessInfo.processInfo.environment["CLUSTER_RENDER_DIR"] {
            for (name, img) in [
                ("folded-dark", image),
                ("folded-light", render(appearance: .aqua)),
                ("focus-alert-pill", render(focus: 1, pill: MenuBarController.pillWidth(chips[1]), appearance: .darkAqua)),
            ] {
                let big = NSImage(size: NSSize(width: img.size.width * 4, height: img.size.height * 4))
                big.lockFocus(); NSGraphicsContext.current?.imageInterpolation = .high
                NSColor(white: name.contains("light") ? 0.92 : 0.16, alpha: 1).setFill()
                NSRect(origin: .zero, size: big.size).fill()
                img.draw(in: NSRect(origin: .zero, size: big.size)); big.unlockFocus()
                try NSBitmapImageRep(data: big.tiffRepresentation!)!.representation(using: .png, properties: [:])!
                    .write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
            }
        }
    }
}
