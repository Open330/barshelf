import AppKit
import XCTest
@testable import MenubucketApp
import MenubucketCore

/// The chips in every look, as pictures to look at. Skipped unless
/// `CHIP_RENDER_DIR` names a directory:
///
///     CHIP_RENDER_DIR=/tmp/chips swift test --filter ChipRenderDumpTests
///
/// Writes, for a dark and a light bar, at 8x and at 2x:
/// - `grid-<bar>@<n>x.png`: style (rows) by colour strength (columns); each
///   cell is the five-chip cluster folded apart, folded stacked, and with
///   its first chip in focus as a pill (apart, then stacked).
/// - `glyphs-<bar>@<n>x.png`: every simple glyph over the SF Symbol it
///   replaces, each in a disc, in the three sizes.
@MainActor
final class ChipRenderDumpTests: XCTestCase {
    private static let chips = [
        ClusterChip(id: "system#cpu", widgetID: "system", name: "CPU", symbol: "cpu", initial: "C", value: "23%"),
        ClusterChip(id: "system#ram", widgetID: "system", name: "RAM", symbol: "memorychip", initial: "R", value: "61%"),
        ClusterChip(widgetID: "power", name: "Power", symbol: "bolt.fill", initial: "P", value: "12W"),
        ClusterChip(widgetID: "temp", name: "Temp", symbol: "thermometer.medium", initial: "T", value: "54°"),
        ClusterChip(widgetID: "battery", name: "Battery", symbol: "battery.75percent", initial: "B", value: "82%"),
    ]

    private static func base(_ widgetID: String) -> NSColor {
        switch widgetID {
        case "system": return .systemPurple
        case "power": return .systemOrange
        case "temp": return .systemBlue
        default: return .systemGreen
        }
    }

    private static let height: CGFloat = 24
    private static let rowGap: CGFloat = 6
    private static let cellWidth: CGFloat = 196
    private static let cellGap: CGFloat = 14
    private static let margin: CGFloat = 12

    private func cluster(_ look: ChipAppearance, focus: Int?, appearance: NSAppearance) -> NSImage {
        let chips = Self.chips
        let colors = MenuBarController.clusterColors(chips, look: look, base: Self.base)
        let mark = BarShelfStatusIcon.image(
            for: AppPreferences.defaultMenuBarSymbol, fallback: AppPreferences.defaultMenuBarSymbol
        )
        return MenuBarController.clusterImage(
            chips, positions: MenuBarController.clusterTargets(chips, focus: focus, look: look), focus: focus,
            pill: focus == nil ? nil : MenuBarController.pillWidth(chips),
            lead: focus == nil ? 0 : MenuBarController.clusterLead(for: chips, look: look),
            markAlpha: focus == nil ? 1 : 0, mark: mark, badged: false,
            color: { colors[$0.id] ?? .controlAccentColor }, look: look, appearance: appearance, height: Self.height
        )
    }

    /// A canvas `size` points drawn at `scale`, on the bar's colour; `draw`
    /// runs in a flipped context (y down).
    private func canvas(
        _ size: NSSize, scale: Int, dark: Bool, to url: URL, draw: (NSAppearance) -> Void
    ) throws {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale, pixelsHigh: Int(size.height) * scale,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        rep.size = size
        let appearance = try XCTUnwrap(NSAppearance(named: dark ? .darkAqua : .aqua))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.translateBy(x: 0, y: size.height)
        context.cgContext.scaleBy(x: 1, y: -1)
        let flipped = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
        NSGraphicsContext.current = flipped
        NSColor(white: dark ? 0.16 : 0.92, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        appearance.performAsCurrentDrawingAppearance { draw(appearance) }
        NSGraphicsContext.restoreGraphicsState()
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
    }

    private func label(_ text: String, at point: NSPoint, dark: Bool) {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 7, weight: .medium),
            .foregroundColor: NSColor(white: dark ? 0.7 : 0.35, alpha: 1),
        ]).draw(at: point)
    }

    private func place(_ image: NSImage, at point: NSPoint) {
        image.draw(
            in: NSRect(origin: point, size: image.size), from: .zero, operation: .sourceOver, fraction: 1,
            respectFlipped: true, hints: nil
        )
    }

    func testDumpEveryLook() throws {
        guard let directory = ProcessInfo.processInfo.environment["CHIP_RENDER_DIR"], !directory.isEmpty else {
            throw XCTSkip("set CHIP_RENDER_DIR to write the pictures")
        }
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { GlyphCache.shared.scalesForTesting = nil }
        for scale in [8, 2] {
            // Glyphs cached for the density drawn at, as on a display of it.
            GlyphCache.shared.scalesForTesting = [CGFloat(scale)]
            for dark in [true, false] {
                let bar = dark ? "dark" : "light"
                try grid(scale: scale, dark: dark, to: folder.appendingPathComponent("grid-\(bar)@\(scale)x.png"))
                try glyphs(scale: scale, dark: dark, to: folder.appendingPathComponent("glyphs-\(bar)@\(scale)x.png"))
            }
        }
    }

    private func grid(scale: Int, dark: Bool, to url: URL) throws {
        let styles = ChipAppearance.Style.allCases, tones = ChipAppearance.Tone.allCases
        let rows: [(String, ChipAppearance.Spacing, Int?)] = [
            ("apart", .apart, nil), ("stacked", .stacked, nil), ("apart, pointed at", .apart, 0),
            ("stacked, pointed at", .stacked, 0),
        ]
        let cellHeight = 10 + CGFloat(rows.count) * (Self.height + Self.rowGap)
        let size = NSSize(
            width: Self.margin * 2 + CGFloat(tones.count) * Self.cellWidth + CGFloat(tones.count - 1) * Self.cellGap,
            height: Self.margin * 2 + CGFloat(styles.count) * cellHeight + CGFloat(styles.count - 1) * Self.cellGap
        )
        try canvas(size, scale: scale, dark: dark, to: url) { appearance in
            for (row, style) in styles.enumerated() {
                for (column, tone) in tones.enumerated() {
                    let origin = NSPoint(
                        x: Self.margin + CGFloat(column) * (Self.cellWidth + Self.cellGap),
                        y: Self.margin + CGFloat(row) * (cellHeight + Self.cellGap)
                    )
                    label("\(style.rawValue) · \(tone.rawValue)", at: origin, dark: dark)
                    for (index, (_, spacing, focus)) in rows.enumerated() {
                        let look = ChipAppearance(style: style, tone: tone, spacing: spacing)
                        place(
                            cluster(look, focus: focus, appearance: appearance),
                            at: NSPoint(x: origin.x, y: origin.y + 10 + CGFloat(index) * (Self.height + Self.rowGap))
                        )
                    }
                }
            }
        }
    }

    /// Every simple glyph over its SF original, small, medium and large.
    private func glyphs(scale: Int, dark: Bool, to url: URL) throws {
        let symbols = [
            "cpu", "memorychip", "bolt.fill", "thermometer.medium", "battery.75percent", "fan", "internaldrive",
            "network", "arrow.down", "arrow.up", "square.grid.3x3.fill", "arrow.left.arrow.right",
        ]
        let sizes = ChipAppearance.GlyphSize.allCases
        let step: CGFloat = 24
        let block = 10 + 2 * (Self.height + 2)
        let size = NSSize(
            width: Self.margin * 2 + CGFloat(symbols.count) * step,
            height: Self.margin * 2 + CGFloat(sizes.count) * block + CGFloat(sizes.count - 1) * Self.rowGap
        )
        try canvas(size, scale: scale, dark: dark, to: url) { appearance in
            guard let context = NSGraphicsContext.current else { return }
            // On a layer, as in the cluster: a chip clears a ring around
            // itself, which must not punch through the bar.
            context.cgContext.beginTransparencyLayer(auxiliaryInfo: nil)
            defer { context.cgContext.endTransparencyLayer() }
            for (row, glyphSize) in sizes.enumerated() {
                let top = Self.margin + CGFloat(row) * (block + Self.rowGap)
                label("\(glyphSize.rawValue): simple over SF Symbols", at: NSPoint(x: Self.margin, y: top), dark: dark)
                for (line, set) in ChipAppearance.GlyphSet.allCases.enumerated() {
                    let look = ChipAppearance(glyphSet: set, glyphSize: glyphSize)
                    for (index, symbol) in symbols.enumerated() {
                        let chip = ClusterChip(widgetID: symbol, name: symbol, symbol: symbol, initial: "X")
                        MenuBarController.drawChip(
                            chip,
                            at: NSPoint(
                                x: Self.margin + CGFloat(index) * step + step / 2,
                                y: top + 10 + CGFloat(line) * (Self.height + 2) + Self.height / 2
                            ),
                            color: MenuBarController.chipFace(.systemBlue), context: context, look: look,
                            dark: MenuBarController.isDark(appearance)
                        )
                    }
                }
            }
        }
    }
}
