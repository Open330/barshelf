import AppKit
import MenubucketCore

/// Everything the menu bar cluster's image depends on, to tell when a new
/// image would look the same as the one on the button.
///
/// Folded chips show a widget's glyph, colour and alert dot, not its
/// reading, so most refreshes change nothing on screen. Only the chip in
/// focus shows its words, so only its words count.
struct ClusterPixels: Equatable {
    struct Face: Equatable {
        var symbol: String?
        var initial: String
        var alert: Bool
        var isStale: Bool
        /// The colour as drawn, resolved for the bar's appearance, so a
        /// changed accent colour counts.
        var rgba: [CGFloat]
        /// The pill's words: the chip in focus only.
        var words: [String]?
    }

    var faces: [Face]
    var focus: Int?
    var positions: [CGFloat]
    var pill: CGFloat
    var lead: CGFloat
    var markAlpha: CGFloat
    var lifts: [CGFloat]
    var growth: CGFloat
    var mark: String
    var badged: Bool
    var look: NSAppearance.Name?
    var height: CGFloat
    var scales: [CGFloat]

    init(
        chips: [ClusterChip], focus: Int?, color: (ClusterChip) -> NSColor, appearance: NSAppearance,
        positions: [CGFloat], pill: CGFloat, lead: CGFloat, markAlpha: CGFloat, lifts: [CGFloat],
        growth: CGFloat, mark: String, badged: Bool, height: CGFloat, scales: [CGFloat]
    ) {
        var faces: [Face] = []
        appearance.performAsCurrentDrawingAppearance {
            faces = chips.enumerated().map { index, chip in
                let resolved = color(chip).usingColorSpace(.sRGB)
                return Face(
                    symbol: chip.symbol, initial: chip.initial, alert: chip.alert, isStale: chip.isStale,
                    rgba: resolved.map { [$0.redComponent, $0.greenComponent, $0.blueComponent, $0.alphaComponent] } ?? [],
                    words: index == focus ? [chip.value, chip.name] : nil
                )
            }
        }
        self.faces = faces
        self.focus = focus
        self.positions = positions
        self.pill = pill
        self.lead = lead
        self.markAlpha = markAlpha
        self.lifts = lifts
        self.growth = growth
        self.mark = mark
        self.badged = badged
        self.look = MenuBarController.look(of: appearance)
        self.height = height
        self.scales = scales
    }
}

extension MenuBarController {
    /// The pixel densities of the attached displays, each menu bar drawing
    /// the item at its own.
    static func screenScales() -> [CGFloat] {
        let scales = Set(NSScreen.screens.map(\.backingScaleFactor)).sorted()
        return scales.isEmpty ? [2] : scales
    }

    /// `image` drawn once into bitmaps, one per display density. An image
    /// with a drawing handler runs it again each time it is drawn, and the
    /// menu bar draws a status item's image for every display it shows on;
    /// a bitmap is only copied.
    static func rasterized(_ image: NSImage, scales: [CGFloat]) -> NSImage {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return image }
        let result = NSImage(size: size)
        for scale in scales {
            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(ceil(size.width * scale)), pixelsHigh: Int(ceil(size.height * scale)),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0
            ) else { continue }
            // In points before the context is made, or it draws at 1×.
            rep.size = size
            guard let context = NSGraphicsContext(bitmapImageRep: rep) else { continue }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            image.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .copy, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
            result.addRepresentation(rep)
        }
        guard !result.representations.isEmpty else { return image }
        result.isTemplate = image.isTemplate
        return result
    }
}
