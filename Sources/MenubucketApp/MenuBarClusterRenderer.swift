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
        /// The chip under the pointer: a little larger, and on top of both
        /// neighbours. No ring: the peek below the bar carries the reading.
        static let focusScale: CGFloat = 1.1
        /// How much whiter a chip is at the top of the update wave.
        static let glowAlpha: CGFloat = 0.18
        /// The focused chip's pill: its reading after the glyph.
        static let pillFontSize: CGFloat = 11
        static let pillTextGap: CGFloat = 3
        static let pillTrailing: CGFloat = 8
        /// Longer readings are cut short, so one pill never takes the bar.
        static let pillTextMax: CGFloat = 76
    }

    /// Each chip's face colour, by chip id: its widget's colour, turned a
    /// step around the colour wheel for every chip before it that has the
    /// same colour. Two chips of one widget (CPU and RAM), or two widgets
    /// that chose the same colour, then tell apart and still read as one
    /// family. The first keeps the colour as chosen.
    static func clusterColors(_ chips: [ClusterChip], base: (String) -> NSColor) -> [String: NSColor] {
        let bases = chips.map { base($0.widgetID).usingColorSpace(.sRGB) ?? base($0.widgetID) }
        let keys = bases.map { color -> String in
            guard let rgb = color.usingColorSpace(.sRGB) else { return color.description }
            return [rgb.redComponent, rgb.greenComponent, rgb.blueComponent]
                .map { String(Int(($0 * 100).rounded())) }.joined(separator: ",")
        }
        let steps = MenuBarClusterPolicy.toneSteps(keys: keys)
        var colors: [String: NSColor] = [:]
        for (index, chip) in chips.enumerated() {
            colors[chip.id] = toned(bases[index], step: steps[index])
        }
        return colors
    }

    /// Hue degrees per tone step, and the order steps alternate in: the
    /// second chip of a colour turns one way, the third the other.
    static let toneHueStep: CGFloat = 30
    static let toneOrder: [CGFloat] = [0, 1, -1, 2, -2, 3, -3, 4]
    /// For a colour with too little hue to turn (grey), brightness steps.
    static let toneBrightnessStep: CGFloat = 0.12

    static func toned(_ color: NSColor, step: Int) -> NSColor {
        guard step > 0, let rgb = color.usingColorSpace(.sRGB) else { return color }
        let turn = toneOrder[step % toneOrder.count]
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        rgb.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        if saturation < 0.15 {
            let shifted = brightness - turn * toneBrightnessStep
            return NSColor(hue: hue, saturation: saturation, brightness: min(max(shifted, 0.2), 0.95), alpha: alpha)
        }
        var turned = hue + turn * toneHueStep / 360
        turned -= floor(turned)
        // Turning orange towards yellow makes it much lighter, and the
        // white glyph fades into it: keep the new tone no lighter than the
        // colour it came from.
        let ceiling = luminance(rgb) + toneLuminanceSlack
        var result = NSColor(hue: turned, saturation: saturation, brightness: brightness, alpha: alpha)
        let light = luminance(result)
        if light > ceiling {
            result = NSColor(hue: turned, saturation: saturation, brightness: brightness * pow(ceiling / light, 1 / 2.2), alpha: alpha)
        }
        return result
    }

    static let toneLuminanceSlack: CGFloat = 0.04

    /// Relative luminance, near enough to compare two tones.
    static func luminance(_ color: NSColor) -> CGFloat {
        guard let rgb = color.usingColorSpace(.sRGB) else { return 0 }
        func linear(_ c: CGFloat) -> CGFloat { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent) + 0.0722 * linear(rgb.blueComponent)
    }

    static func pillFont() -> NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: ChipMetrics.pillFontSize, weight: .semibold)
    }

    /// Every pill in a cluster is as wide as the widest, so the layout has
    /// one shape whichever chip is under the pointer, and the place that
    /// selects each chip does not move as the pointer goes along.
    /// Chips with no value take the others' width; if none has one, the
    /// names set it, so an all-icon cluster still grows pills.
    static func pillWidth(_ chips: [ClusterChip]) -> CGFloat {
        let valued = chips.filter { !$0.value.isEmpty }
        if let widest = valued.map(pillWidth).max() { return widest }
        return chips.map { pillWidth(text: $0.name) }.max() ?? CGFloat(ClusterGeometry.disc)
    }

    /// The width of a chip's pill: its disc, then its value. A chip
    /// without one stays a disc.
    static func pillWidth(_ chip: ClusterChip) -> CGFloat {
        pillWidth(text: chip.value)
    }

    static func pillWidth(text: String) -> CGFloat {
        guard !text.isEmpty else { return CGFloat(ClusterGeometry.disc) }
        let width = NSAttributedString(string: text, attributes: [.font: pillFont()]).size().width
        let height = ChipMetrics.face * ChipMetrics.focusScale
        return ceil(height + ChipMetrics.pillTextGap + min(width, ChipMetrics.pillTextMax) + ChipMetrics.pillTrailing)
    }

    static func clusterImage(
        _ chips: [ClusterChip],
        positions: [CGFloat]? = nil,
        focus: Int? = nil,
        pill: CGFloat? = nil,
        lead: CGFloat = 0,
        markAlpha: CGFloat = 1,
        lifts: [CGFloat] = [],
        growth: CGFloat = CGFloat(ClusterPulse.growth),
        mark: NSImage,
        badged: Bool,
        color: @escaping (ClusterChip) -> NSColor,
        appearance: NSAppearance,
        height: CGFloat
    ) -> NSImage {
        let geometry = ClusterGeometry(count: chips.count)
        let size = NSSize(width: ceil(lead + geometry.itemWidth), height: height)
        let image = NSImage(size: size, flipped: true) { _ in
            appearance.performAsCurrentDrawingAppearance {
                guard let context = NSGraphicsContext.current else { return }
                // Stack coordinates: the folded stack starts past the room
                // the item takes on its left while a chip is in focus.
                context.cgContext.translateBy(x: lead, y: 0)
                // Chips are drawn on a layer of their own so a cutout clears
                // only the chips beneath, not the bar.
                context.cgContext.beginTransparencyLayer(auxiliaryInfo: nil)
                func center(_ index: Int) -> NSPoint {
                    NSPoint(
                        x: (positions?[cluster: index] ?? CGFloat(geometry.collapsedX(index))) + ClusterGeometry.slot / 2,
                        y: height / 2
                    )
                }
                let focused = focus.flatMap { chips.indices.contains($0) ? $0 : nil }
                // A chip the update wave lifts comes to the front: drawn
                // after the resting ones, the highest last.
                let order = chips.indices.filter { $0 != focused }
                    .sorted { (lifts[cluster: $0] ?? 0, $0) < (lifts[cluster: $1] ?? 0, $1) }
                for index in order {
                    let lift = lifts[cluster: index] ?? 0
                    drawChip(
                        chips[index], at: center(index), color: color(chips[index]), context: context,
                        scale: 1 + growth * lift, glow: lift
                    )
                }
                // The focused chip last, so it sits on top of both neighbours.
                if let focused {
                    let chip = chips[focused]
                    let width = pill ?? CGFloat(ClusterGeometry.disc)
                    if width > ChipMetrics.face * ChipMetrics.focusScale {
                        let left = (positions?[cluster: focused] ?? CGFloat(geometry.collapsedX(focused)))
                            + CGFloat(ClusterGeometry.slotInset)
                        drawPill(chip, left: left, width: width, midY: height / 2, color: color(chip), context: context)
                    } else {
                        drawChip(
                            chip, at: center(focused), color: color(chip),
                            context: context, scale: ChipMetrics.focusScale
                        )
                    }
                }
                // Alert dots last: the next chip would cover a dot drawn
                // with its own chip.
                for (index, chip) in chips.enumerated() where chip.alert {
                    drawBadge(at: center(index), context: context)
                }
                context.cgContext.endTransparencyLayer()
                let markRect = NSRect(
                    x: geometry.collapsedMarkX, y: (height - mark.size.height) / 2,
                    width: ClusterGeometry.markWidth, height: mark.size.height
                )
                // Hidden while a chip is in focus: its room is the chips'.
                if markAlpha > 0 {
                    drawTemplate(badged ? BarShelfStatusIcon.badgedImage(mark) : mark, in: markRect, alpha: markAlpha)
                }
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    /// A template image in the bar's text colour.
    private static func drawTemplate(_ template: NSImage, in rect: NSRect, alpha: CGFloat = 1) {
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
        tinted.draw(in: fitted, from: .zero, operation: .sourceOver, fraction: alpha, respectFlipped: true, hints: nil)
    }

    static func drawChip(
        _ chip: ClusterChip, at center: NSPoint, color: NSColor, context: NSGraphicsContext,
        scale: CGFloat = 1, glow: CGFloat = 0
    ) {
        // A chip at the top of the update wave is a little brighter.
        let color = glow > 0 ? (color.blended(withFraction: ChipMetrics.glowAlpha * glow, of: .white) ?? color) : color
        let m = ChipMetrics.self
        let face = m.face * scale
        func circle(_ diameter: CGFloat, at point: NSPoint = center) -> NSBezierPath {
            NSBezierPath(ovalIn: NSRect(
                x: point.x - diameter / 2, y: point.y - diameter / 2, width: diameter, height: diameter
            ))
        }
        // Clear what the previous chip drew under this one, plus a gap.
        context.compositingOperation = .clear
        circle(face + m.cutout * 2).fill()
        context.compositingOperation = .sourceOver

        let alpha = chip.isStale ? m.staleAlpha : 1
        // The disc: the widget's colour, a little lighter at the top.
        let disc = circle(face)
        let base = color.withAlphaComponent(alpha)
        let lit = (color.blended(withFraction: m.sheenAlpha, of: .white) ?? color).withAlphaComponent(alpha)
        NSGraphicsContext.saveGraphicsState()
        disc.addClip()
        NSGradient(starting: lit, ending: base)?.draw(
            from: NSPoint(x: center.x, y: center.y - face / 2),
            to: NSPoint(x: center.x, y: center.y + face / 2),
            options: [.drawsBeforeStartingLocation, .drawsAfterEndingLocation]
        )
        NSGraphicsContext.restoreGraphicsState()
        let rim = circle(face - m.rimWidth)
        rim.lineWidth = m.rimWidth
        NSColor.white.withAlphaComponent(m.rimAlpha * alpha).setStroke()
        rim.stroke()

        drawGlyph(chip, at: center, alpha: alpha, scale: scale)
    }

    /// The focused chip grown into a pill: its disc's colour, the glyph at
    /// the start, then its value. Cut out of the chips beneath, like a
    /// disc.
    static func drawPill(
        _ chip: ClusterChip, left: CGFloat, width: CGFloat, midY: CGFloat, color: NSColor, context: NSGraphicsContext
    ) {
        let m = ChipMetrics.self
        let height = m.face * m.focusScale
        let rect = NSRect(x: left, y: midY - height / 2, width: max(width, height), height: height)
        func capsule(_ r: NSRect) -> NSBezierPath {
            NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
        }
        context.compositingOperation = .clear
        capsule(rect.insetBy(dx: -m.cutout, dy: -m.cutout)).fill()
        context.compositingOperation = .sourceOver

        let alpha = chip.isStale ? m.staleAlpha : 1
        let shape = capsule(rect)
        let base = color.withAlphaComponent(alpha)
        let lit = (color.blended(withFraction: m.sheenAlpha, of: .white) ?? color).withAlphaComponent(alpha)
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        NSGradient(starting: lit, ending: base)?.draw(
            from: NSPoint(x: rect.midX, y: rect.minY), to: NSPoint(x: rect.midX, y: rect.maxY),
            options: [.drawsBeforeStartingLocation, .drawsAfterEndingLocation]
        )
        // The value, else the name when it fits whole; else the glyph alone
        // in the middle of the pill.
        let label = chip.value.isEmpty ? chip.name : chip.value
        let fits = !chip.value.isEmpty
            || pillWidth(text: chip.name) <= rect.width + 0.5
        drawGlyph(chip, at: NSPoint(x: fits ? rect.minX + height / 2 : rect.midX, y: midY), alpha: alpha)
        if fits, !label.isEmpty {
            let text = NSAttributedString(string: label, attributes: [
                .font: pillFont(), .foregroundColor: NSColor.white.withAlphaComponent(alpha),
            ])
            let size = text.size()
            let x = rect.minX + height + m.pillTextGap
            let room = rect.maxX - m.pillTrailing - x
            if room > 0 {
                // Cut short with a fade-free clip; the reading is whole once
                // the pill has grown.
                NSGraphicsContext.saveGraphicsState()
                NSRect(x: x, y: rect.minY, width: room, height: rect.height).clip()
                text.draw(at: NSPoint(x: x, y: midY - size.height / 2))
                NSGraphicsContext.restoreGraphicsState()
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        let rim = capsule(rect.insetBy(dx: m.rimWidth / 2, dy: m.rimWidth / 2))
        rim.lineWidth = m.rimWidth
        NSColor.white.withAlphaComponent(m.rimAlpha * alpha).setStroke()
        rim.stroke()
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

    private static func drawGlyph(_ chip: ClusterChip, at center: NSPoint, alpha: CGFloat, scale: CGFloat = 1) {
        let ink = NSColor.white.withAlphaComponent(alpha)
        if let name = chip.symbol,
           let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: ChipMetrics.glyphSize * scale, weight: .bold)) {
            let tinted = NSImage(size: symbol.size, flipped: false) { bounds in
                symbol.draw(in: bounds)
                ink.set()
                bounds.fill(using: .sourceAtop)
                return true
            }
            // Wide symbols (a battery) are fitted into the core's box.
            let box = ChipMetrics.glyphBox * scale
            let fit = min(box / symbol.size.width, box / symbol.size.height, 1)
            let size = NSSize(width: symbol.size.width * fit, height: symbol.size.height * fit)
            tinted.draw(in: NSRect(
                x: center.x - size.width / 2, y: center.y - size.height / 2,
                width: size.width, height: size.height
            ))
            return
        }
        let pointSize = ChipMetrics.glyphSize * scale
        let font = NSFont.systemFont(ofSize: pointSize, weight: .heavy)
        let rounded = font.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: pointSize) } ?? font
        let text = NSAttributedString(string: chip.initial, attributes: [.font: rounded, .foregroundColor: ink])
        let size = text.size()
        text.draw(at: NSPoint(x: center.x - size.width / 2, y: center.y - size.height / 2))
    }
}

private extension Array {
    subscript(cluster index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
