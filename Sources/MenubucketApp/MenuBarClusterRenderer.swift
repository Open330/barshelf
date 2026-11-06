import AppKit
import MenubucketCore

/// Draws the folded cluster into the main status item: chips overlapping
/// left to right, each cut out of the one beneath by a clear ring, then the
/// BarShelf icon.
extension MenuBarController {
    /// Space the button keeps either side of the drawing.
    static let clusterItemInset: CGFloat = 3

    /// A chip: a solid disc in the widget's colour. Folded, that is all it
    /// is (plus an alert dot); the share ring appears only in the fanned-out
    /// strip, a thin arc held off the disc by a gap, so the menu bar never
    /// shows a pile of concentric outlines.
    enum ChipMetrics {
        /// The disc.
        static let face: CGFloat = 18
        static let core: CGFloat = face
        /// The share arc in the strip, and the gap between it and the disc.
        static let ringWidth: CGFloat = 1.5
        static let ringGap: CGFloat = 1.5
        /// The clear ring that separates a chip from the one it covers.
        static let cutout: CGFloat = 1.5
        static let badge: CGFloat = 6
        static let glyphSize: CGFloat = 8.5
        /// The box a symbol is fitted into, inside the disc.
        static let glyphBox: CGFloat = 9.5
        /// The arc's track, barely there.
        static let trackAlpha: CGFloat = 0.12
        static let staleAlpha: CGFloat = 0.45
        /// How much lighter the disc's top is than its colour.
        static let sheenAlpha: CGFloat = 0.22
        /// The disc's fine inner edge, which keeps a dark colour from
        /// melting into a dark menu bar.
        static let rimAlpha: CGFloat = 0.18
        static let rimWidth: CGFloat = 0.5
    }

    static func clusterImage(
        _ chips: [ClusterChip],
        mark: NSImage,
        badged: Bool,
        color: @escaping (String) -> NSColor,
        appearance: NSAppearance,
        height: CGFloat
    ) -> NSImage {
        let geometry = ClusterGeometry(count: chips.count)
        let size = NSSize(width: ceil(geometry.itemWidth), height: height)
        let image = NSImage(size: size, flipped: true) { _ in
            appearance.performAsCurrentDrawingAppearance {
                guard let context = NSGraphicsContext.current else { return }
                // Chips are drawn on a layer of their own so a cutout clears
                // only the chips beneath, not the bar.
                context.cgContext.beginTransparencyLayer(auxiliaryInfo: nil)
                for (index, chip) in chips.enumerated() {
                    let center = NSPoint(
                        x: geometry.collapsedX(index) + ClusterGeometry.slot / 2,
                        y: height / 2
                    )
                    drawChip(chip, at: center, color: color(chip.widgetID), context: context)
                }
                // Alert dots last: the next chip would cover a dot drawn
                // with its own chip.
                for (index, chip) in chips.enumerated() where chip.alert {
                    let center = NSPoint(
                        x: geometry.collapsedX(index) + ClusterGeometry.slot / 2,
                        y: height / 2
                    )
                    drawBadge(at: center, context: context)
                }
                context.cgContext.endTransparencyLayer()
                let markRect = NSRect(
                    x: geometry.collapsedMarkX, y: (height - mark.size.height) / 2,
                    width: ClusterGeometry.markWidth, height: mark.size.height
                )
                drawTemplate(badged ? BarShelfStatusIcon.badgedImage(mark) : mark, in: markRect)
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    /// A template image in the bar's text colour.
    private static func drawTemplate(_ template: NSImage, in rect: NSRect) {
        let fitted = NSRect(
            x: rect.midX - template.size.width / 2, y: rect.minY,
            width: template.size.width, height: template.size.height
        )
        let tinted = NSImage(size: template.size, flipped: false) { bounds in
            template.draw(in: bounds)
            NSColor.labelColor.set()
            bounds.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(in: fitted)
    }

    static func drawChip(_ chip: ClusterChip, at center: NSPoint, color: NSColor, context: NSGraphicsContext) {
        let m = ChipMetrics.self
        func circle(_ diameter: CGFloat, at point: NSPoint = center) -> NSBezierPath {
            NSBezierPath(ovalIn: NSRect(
                x: point.x - diameter / 2, y: point.y - diameter / 2, width: diameter, height: diameter
            ))
        }
        // Clear what the previous chip drew under this one, plus a gap.
        context.compositingOperation = .clear
        circle(m.face + m.cutout * 2).fill()
        context.compositingOperation = .sourceOver

        let alpha = chip.isStale ? m.staleAlpha : 1
        // The disc: the widget's colour, a little lighter at the top.
        let disc = circle(m.face)
        let base = color.withAlphaComponent(alpha)
        let lit = (color.blended(withFraction: m.sheenAlpha, of: .white) ?? color).withAlphaComponent(alpha)
        NSGraphicsContext.saveGraphicsState()
        disc.addClip()
        NSGradient(starting: lit, ending: base)?.draw(
            from: NSPoint(x: center.x, y: center.y - m.face / 2),
            to: NSPoint(x: center.x, y: center.y + m.face / 2),
            options: [.drawsBeforeStartingLocation, .drawsAfterEndingLocation]
        )
        NSGraphicsContext.restoreGraphicsState()
        let rim = circle(m.face - m.rimWidth)
        rim.lineWidth = m.rimWidth
        NSColor.white.withAlphaComponent(m.rimAlpha * alpha).setStroke()
        rim.stroke()

        drawGlyph(chip, at: center, alpha: alpha)

    }

    /// The red dot at a chip's top-trailing edge, cut out of what is under it.
    static func drawBadge(at center: NSPoint, context: NSGraphicsContext) {
        let m = ChipMetrics.self
        let badgeCenter = NSPoint(x: center.x + m.face / 2 - m.badge / 3, y: center.y - m.face / 2 + m.badge / 3)
        func circle(_ diameter: CGFloat) -> NSBezierPath {
            NSBezierPath(ovalIn: NSRect(
                x: badgeCenter.x - diameter / 2, y: badgeCenter.y - diameter / 2, width: diameter, height: diameter
            ))
        }
        context.compositingOperation = .clear
        circle(m.badge + m.cutout * 2).fill()
        context.compositingOperation = .sourceOver
        NSColor.systemRed.setFill()
        circle(m.badge).fill()
    }

    private static func drawGlyph(_ chip: ClusterChip, at center: NSPoint, alpha: CGFloat) {
        let ink = NSColor.white.withAlphaComponent(alpha)
        if let name = chip.symbol,
           let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: ChipMetrics.glyphSize, weight: .bold)) {
            let tinted = NSImage(size: symbol.size, flipped: false) { bounds in
                symbol.draw(in: bounds)
                ink.set()
                bounds.fill(using: .sourceAtop)
                return true
            }
            // Wide symbols (a battery) are fitted into the core's box.
            let box = ChipMetrics.glyphBox
            let scale = min(box / symbol.size.width, box / symbol.size.height, 1)
            let size = NSSize(width: symbol.size.width * scale, height: symbol.size.height * scale)
            tinted.draw(in: NSRect(
                x: center.x - size.width / 2, y: center.y - size.height / 2,
                width: size.width, height: size.height
            ))
            return
        }
        let font = NSFont.systemFont(ofSize: ChipMetrics.glyphSize, weight: .heavy)
        let rounded = font.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: ChipMetrics.glyphSize) } ?? font
        let text = NSAttributedString(string: chip.initial, attributes: [.font: rounded, .foregroundColor: ink])
        let size = text.size()
        text.draw(at: NSPoint(x: center.x - size.width / 2, y: center.y - size.height / 2))
    }
}
