import AppKit
import MenubucketCore

/// Draws the folded cluster into the main status item: chips overlapping
/// left to right, each cut out of the one beneath by a clear ring, then the
/// BarShelf icon.
extension MenuBarController {
    /// Space the button keeps either side of the drawing.
    static let clusterItemInset: CGFloat = 3

    /// A chip's face, its coloured core and the ring between them.
    enum ChipMetrics {
        static let face: CGFloat = 20
        static let core: CGFloat = 15
        static let ringWidth: CGFloat = 1.5
        /// The clear ring that separates a chip from the one it covers.
        static let cutout: CGFloat = 2
        static let badge: CGFloat = 6
        static let glyphSize: CGFloat = 8.5
        /// The box a symbol is fitted into, inside the core.
        static let glyphBox: CGFloat = 9
        static let trackAlpha: CGFloat = 0.22
        static let staleAlpha: CGFloat = 0.45
        static let sheenAlpha: CGFloat = 0.3
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
        // Ring: the share, in the reading's colour, over a faint track.
        let ringDiameter = m.face - m.ringWidth
        let track = circle(ringDiameter)
        track.lineWidth = m.ringWidth
        NSColor.labelColor.withAlphaComponent(m.trackAlpha * alpha).setStroke()
        track.stroke()
        if let fraction = chip.fraction, fraction > 0 {
            let arc = NSBezierPath()
            // Flipped: -90° is the top; clockwise in screen terms.
            arc.appendArc(
                withCenter: center, radius: ringDiameter / 2,
                startAngle: -90, endAngle: -90 + 360 * CGFloat(fraction), clockwise: false
            )
            arc.lineWidth = m.ringWidth
            arc.lineCapStyle = .round
            let ink = chip.tint.map(nsColor(for:)) ?? .labelColor
            ink.withAlphaComponent(alpha).setStroke()
            arc.stroke()
        }

        // Core: the widget's colour, lit from above.
        let core = circle(m.core)
        color.withAlphaComponent(alpha).setFill()
        core.fill()
        NSGraphicsContext.saveGraphicsState()
        core.addClip()
        NSGradient(
            starting: NSColor.white.withAlphaComponent(m.sheenAlpha), ending: .clear
        )?.draw(in: core.bounds, angle: 90)
        NSGraphicsContext.restoreGraphicsState()

        drawGlyph(chip, at: center, alpha: alpha)

    }

    /// The red dot at a chip's top-trailing edge, cut out of what is under it.
    static func drawBadge(at center: NSPoint, context: NSGraphicsContext) {
        let m = ChipMetrics.self
        let badgeCenter = NSPoint(x: center.x + m.face / 2 - m.badge / 2, y: center.y - m.face / 2 + m.badge / 2)
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
