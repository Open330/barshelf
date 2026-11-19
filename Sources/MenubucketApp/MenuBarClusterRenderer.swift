import AppKit
import MenubucketCore

/// Draws the folded cluster into the main status item: the chips left to
/// right, a hair apart or overlapping (each cut out of the one beneath by a
/// clear ring), then the BarShelf icon. How a chip looks is a
/// `ChipAppearance`, called `look` here (`appearance` is the bar's light or
/// dark).
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
        /// How large a symbol is drawn, measured on the drawing itself and
        /// not on its font size: its longer side is at most `glyphSize`,
        /// and all of it lies within a circle `glyphCircle` across at the
        /// disc's centre, so a square symbol (a chip) and a long one (a
        /// battery) carry the same weight and none crowds the rim.
        /// A symbol's image is mostly margin, and uneven margin: asked for
        /// at "8.5 pt" and centred as an image, a symbol was about 8.6 pt
        /// of drawing in an 18 pt disc, up to half a point off centre.
        /// These are the Medium size; `ChipAppearance.glyphSide` has the
        /// others.
        static let glyphSize: CGFloat = 13
        static let glyphCircle: CGFloat = glyphSize + glyphFit
        static let glyphSmall: CGFloat = 11
        static let glyphLarge: CGFloat = 14.5
        /// The circle is this much wider than the longer side, and never
        /// wider than `glyphCircleMax`, which leaves a point to the rim.
        static let glyphFit: CGFloat = 2.5
        static let glyphCircleMax: CGFloat = 16
        /// The initial drawn when a chip has no symbol.
        static let initialSize: CGFloat = 12
        static let initialSmall: CGFloat = 11
        static let initialLarge: CGFloat = 13
        /// A glyph may sit this far from its drawing's bounding-box middle,
        /// towards where its weight is (`GlyphCache`).
        static let opticalLimit: CGFloat = 1
        /// Stacked, the glyph of a covered chip keeps this much clear of
        /// the edges of the part in view.
        static let coverMargin: CGFloat = 1.5
        /// How quickly a chip the update wave lifts over its neighbour
        /// takes the neighbour's place on top: the glyphs glide between
        /// "covered" and "whole" over a quarter of the lift, not in a jump.
        static let coverBlend: CGFloat = 4
        /// The arc's track, barely there.
        static let trackAlpha: CGFloat = 0.12
        static let staleAlpha = CGFloat(Fill.staleOpacity)
        /// How much lighter the disc's top is than its colour. Slight: a
        /// strong sheen made the discs look like candy beside the bar's
        /// flat items.
        static let sheenAlpha: CGFloat = 0.10
        /// The Soft style: a wash of the face colour, a rim of it, and the
        /// glyph in its hue (`ChipColor.ink`).
        static let softFill: CGFloat = 0.24
        static let softRim: CGFloat = 0.45
        /// The Mono style: the bar's text colour, faint for the disc.
        static let monoFill: CGFloat = 0.12
        static let monoRim: CGFloat = 0.18
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
    /// family. The first keeps the colour as chosen. Each is then brought to
    /// the tone's lightness and strength (`ChipColor`), so the row is a
    /// palette.
    static func clusterColors(
        _ chips: [ClusterChip], look: ChipAppearance = ChipAppearance(), base: (String) -> NSColor
    ) -> [String: NSColor] {
        let bases = chips.map { base($0.widgetID).usingColorSpace(.sRGB) ?? base($0.widgetID) }
        let keys = bases.map { color -> String in
            guard let rgb = color.usingColorSpace(.sRGB) else { return color.description }
            return [rgb.redComponent, rgb.greenComponent, rgb.blueComponent]
                .map { String(Int(($0 * 100).rounded())) }.joined(separator: ",")
        }
        let steps = MenuBarClusterPolicy.toneSteps(keys: keys)
        var colors: [String: NSColor] = [:]
        for (index, chip) in chips.enumerated() {
            let step = steps[index]
            let turned = toned(bases[index], step: step)
            // A colour whose hue could not turn (orange, grey) was told
            // apart by brightness, which the tone levels: it goes deeper
            // instead.
            let deeper = step > 0 && ChipColor.sharesHue(turned, bases[index]) ? step : 0
            colors[chip.id] = ChipColor.face(turned, tone: look.tone, deeper: deeper)
        }
        return colors
    }

    /// The colour a disc is filled with, from the colour its widget chose:
    /// the same hue at the tone's lightness and strength.
    static func chipFace(_ color: NSColor, tone: ChipAppearance.Tone = ChipAppearance().tone) -> NSColor {
        ChipColor.face(color, tone: tone)
    }

    /// Whether the bar the chips are drawn on is dark.
    nonisolated static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    /// What a chip is painted with, for its style.
    struct ChipPaint {
        /// The disc or pill: lighter at the top when the style has a sheen.
        var top: NSColor
        var fill: NSColor
        var rim: NSColor
        /// The glyph's colour; nil is white, the colour glyphs are cached in.
        var ink: NSColor?
        var text: NSColor
    }

    /// `color` is the chip's face colour; `alpha` fades a stale chip, and
    /// `glow` is how far up the update wave the chip is. Call inside the
    /// drawing appearance: Mono takes the bar's text colour.
    static func chipPaint(
        _ color: NSColor, look: ChipAppearance, dark: Bool, alpha: CGFloat = 1, glow: CGFloat = 0
    ) -> ChipPaint {
        let m = ChipMetrics.self
        switch look.style {
        case .solid:
            // A chip at the top of the update wave is a little brighter.
            let color = glow > 0 ? (color.blended(withFraction: m.glowAlpha * glow, of: .white) ?? color) : color
            let lit = color.blended(withFraction: m.sheenAlpha, of: .white) ?? color
            return ChipPaint(
                top: lit.withAlphaComponent(alpha), fill: color.withAlphaComponent(alpha),
                rim: NSColor.white.withAlphaComponent(m.rimAlpha * alpha),
                ink: nil, text: NSColor.white.withAlphaComponent(alpha)
            )
        case .soft:
            // No white to blend into a wash: the wave makes it denser.
            let fill = color.withAlphaComponent((m.softFill + m.glowAlpha * glow) * alpha)
            let ink = ChipColor.ink(face: color, tone: look.tone, dark: dark)
            return ChipPaint(
                top: fill, fill: fill, rim: color.withAlphaComponent(m.softRim * alpha),
                ink: ink, text: ink.withAlphaComponent(alpha)
            )
        case .mono:
            let label = NSColor.labelColor
            let fill = label.withAlphaComponent((m.monoFill + m.glowAlpha * glow) * alpha)
            return ChipPaint(
                top: fill, fill: fill, rim: label.withAlphaComponent(m.monoRim * alpha),
                ink: label, text: label.withAlphaComponent(alpha)
            )
        }
    }

    /// Fills `shape` with the paint, then strokes `rim` (already inset).
    private static func paint(_ shape: NSBezierPath, rim: NSBezierPath, in rect: NSRect, with paint: ChipPaint) {
        if paint.top == paint.fill {
            paint.fill.setFill()
            shape.fill()
        } else {
            NSGraphicsContext.saveGraphicsState()
            shape.addClip()
            NSGradient(starting: paint.top, ending: paint.fill)?.draw(
                from: NSPoint(x: rect.midX, y: rect.minY), to: NSPoint(x: rect.midX, y: rect.maxY),
                options: [.drawsBeforeStartingLocation, .drawsAfterEndingLocation]
            )
            NSGraphicsContext.restoreGraphicsState()
        }
        rim.lineWidth = ChipMetrics.rimWidth
        paint.rim.setStroke()
        rim.stroke()
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
        // A step's turn is no good if keeping the white glyph readable
        // would darken it into mud (orange to yellow ends up olive), or if
        // it turns red, which in the menu bar reads as an alert and
        // swallows the red alert dot. No mirror retry: the mirror is the
        // next step's turn, and two chips would share a colour.
        let ceiling = luminance(rgb) + toneLuminanceSlack
        var turned = hue + turn * toneHueStep / 360
        turned -= floor(turned)
        if !(isRed(turned) && !isRed(hue)) {
            let plain = NSColor(hue: turned, saturation: saturation, brightness: brightness, alpha: alpha)
            let light = luminance(plain)
            let darkening = light > ceiling ? pow(ceiling / light, 1 / 2.2) : 1
            if darkening >= toneMinimumDarkening {
                return NSColor(hue: turned, saturation: saturation, brightness: brightness * darkening, alpha: alpha)
            }
        }
        // The turn is refused (orange): the same hue, darker for each step.
        let darker = brightness - toneFallbackStep * CGFloat(step)
        return NSColor(hue: hue, saturation: saturation, brightness: max(darker, 0.2), alpha: alpha)
    }

    /// The share of its brightness a turned tone may lose to the
    /// luminance ceiling before it counts as muddy.
    static let toneMinimumDarkening: CGFloat = 0.85
    /// Brightness per step when no hue turn works.
    static let toneFallbackStep: CGFloat = 0.18

    /// Hues that read as red: the alert colour.
    static func isRed(_ hue: CGFloat) -> Bool {
        let degrees = hue * 360
        return degrees >= 345 || degrees < 20
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
        look: ChipAppearance = ChipAppearance(),
        appearance: NSAppearance,
        height: CGFloat
    ) -> NSImage {
        let geometry = ClusterGeometry(count: chips.count, spacing: look.spacing)
        let dark = isDark(appearance)
        // A glyph moved aside (below) still starts on a pixel of the
        // coarsest display.
        let pixel = 1 / max((GlyphCache.shared.scalesForTesting ?? screenScales()).min() ?? 1, 1)
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
                let m = ChipMetrics.self
                let pillSpan = pill ?? CGFloat(ClusterGeometry.disc)
                // A lone chip keeps the BarShelf icon beside it, so there
                // is no room for a pill: it grows as a disc, and its
                // reading is in the peek.
                let focusedIsPill = focused.map { pillSpan > m.face * m.focusScale && geometry.hidesMark(focus: $0) } ?? false
                func lift(_ index: Int) -> CGFloat { lifts[cluster: index] ?? 0 }
                func scale(_ index: Int) -> CGFloat { index == focused ? m.focusScale : 1 + growth * lift(index) }
                func pillLeft(_ index: Int) -> CGFloat {
                    (positions?[cluster: index] ?? CGFloat(geometry.collapsedX(index))) + CGFloat(ClusterGeometry.slotInset)
                }
                // The drawn shape's edges: a disc, or the focused pill.
                func leading(_ index: Int) -> CGFloat {
                    index == focused && focusedIsPill ? pillLeft(index) : center(index).x - m.face * scale(index) / 2
                }
                func trailing(_ index: Int) -> CGFloat {
                    index == focused && focusedIsPill
                        ? pillLeft(index) + max(pillSpan, m.face * m.focusScale)
                        : center(index).x + m.face * scale(index) / 2
                }
                // How far `over` is on top of its neighbour `under`, 0...1.
                // At rest the earlier chip is on top; the focused chip is on
                // top of both neighbours, and so is a chip the wave lifts
                // higher than them (`coverBlend`).
                func cover(_ over: Int, _ under: Int) -> CGFloat {
                    if under == focused { return 0 }
                    if over == focused { return 1 }
                    let ahead = min(max((lift(over) - lift(under)) * m.coverBlend, -1), 1)
                    return over < under ? 1 + min(ahead, 0) : max(ahead, 0)
                }
                // Where a chip's glyph goes: the middle of the part of the
                // chip in view, smaller if that part is narrower than the
                // glyph. Stacked, a glyph in the middle of its disc was cut
                // in half by the chip over it. Taken from where the chips
                // are drawn now, so it glides as they fold and fan.
                func glyphPlace(_ index: Int) -> GlyphPlace {
                    let middle = center(index).x, size = scale(index)
                    var low = middle - m.face * size / 2, high = middle + m.face * size / 2
                    if index > 0 {
                        low += cover(index - 1, index) * max(0, trailing(index - 1) + m.cutout - low)
                    }
                    if index < chips.count - 1 {
                        high -= cover(index + 1, index) * max(0, high - (leading(index + 1) - m.cutout))
                    }
                    let free = max(high - low, 0)
                    guard free < m.face * size - 0.01 else { return GlyphPlace(x: middle, factor: 1) }
                    let x = ((low + high) / 2 / pixel).rounded() * pixel
                    return GlyphPlace(x: x, factor: min(1, max(0, free - m.coverMargin) / (look.glyphCircle * size)))
                }
                // Folded, each chip lies over the one to its right, as a
                // stack of avatars does, so a chip's top-trailing corner —
                // where its alert dot goes — is over the chip beneath and in
                // view, and plainly its own. Drawn right to left. A chip the
                // update wave lifts comes to the front: the highest last.
                let order = chips.indices.filter { $0 != focused }
                    .sorted { (lifts[cluster: $0] ?? 0, -$0) < (lifts[cluster: $1] ?? 0, -$1) }
                for index in order {
                    drawChip(
                        chips[index], at: center(index), color: color(chips[index]), context: context,
                        scale: scale(index), glow: lift(index), look: look, dark: dark, glyph: glyphPlace(index)
                    )
                    // With its chip, so a chip drawn later covers it as it
                    // covers the chip, and it grows with the chip.
                    if chips[index].alert {
                        drawBadge(at: center(index), context: context, scale: scale(index))
                    }
                }
                // The focused chip last, so it sits on top of both neighbours.
                if let focused {
                    let chip = chips[focused]
                    let width = pillSpan
                    if focusedIsPill {
                        let left = pillLeft(focused)
                        drawPill(
                            chip, left: left, width: width, midY: height / 2, color: color(chip), context: context,
                            look: look, dark: dark
                        )
                        if chip.alert {
                            // At the pill's trailing end, where a disc's dot sits.
                            let face = ChipMetrics.face * ChipMetrics.focusScale
                            drawBadge(
                                at: NSPoint(x: left + width - face / 2, y: height / 2),
                                context: context, scale: ChipMetrics.focusScale
                            )
                        }
                    } else {
                        drawChip(
                            chip, at: center(focused), color: color(chip),
                            context: context, scale: ChipMetrics.focusScale, look: look, dark: dark
                        )
                        if chip.alert {
                            drawBadge(at: center(focused), context: context, scale: ChipMetrics.focusScale)
                        }
                    }
                }
                context.cgContext.endTransparencyLayer()
                let markRect = NSRect(
                    x: geometry.collapsedMarkX, y: (height - mark.size.height) / 2,
                    width: ClusterGeometry.markWidth, height: mark.size.height
                )
                // Hidden while a chip is in focus: its room is the chips'.
                if markAlpha > 0 {
                    if badged {
                        // Already tinted, with its red dot: drawn as is.
                        let badgedMark = BarShelfStatusIcon.badgedImage(mark)
                        let fitted = NSRect(
                            x: markRect.midX - badgedMark.size.width / 2, y: markRect.minY,
                            width: badgedMark.size.width, height: badgedMark.size.height
                        )
                        badgedMark.draw(in: fitted, from: .zero, operation: .sourceOver, fraction: markAlpha, respectFlipped: true, hints: nil)
                    } else {
                        drawTemplate(mark, in: markRect, alpha: markAlpha)
                    }
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

    /// Where a chip's glyph is drawn when not at its disc's centre at full
    /// size: `x` is its middle, `factor` how much smaller it is.
    struct GlyphPlace: Equatable {
        var x: CGFloat
        var factor: CGFloat
    }

    static func drawChip(
        _ chip: ClusterChip, at center: NSPoint, color: NSColor, context: NSGraphicsContext,
        scale: CGFloat = 1, glow: CGFloat = 0, look: ChipAppearance = ChipAppearance(), dark: Bool = true,
        glyph place: GlyphPlace? = nil
    ) {
        let m = ChipMetrics.self
        let face = m.face * scale
        func circle(_ diameter: CGFloat, at point: NSPoint = center) -> NSBezierPath {
            NSBezierPath(ovalIn: NSRect(
                x: point.x - diameter / 2, y: point.y - diameter / 2, width: diameter, height: diameter
            ))
        }
        // Clear what the previous chip drew under this one, plus a gap.
        // Apart, nothing is under it at rest; a chip that grows (focus,
        // the wave) still keeps its gap this way.
        context.compositingOperation = .clear
        circle(face + m.cutout * 2).fill()
        context.compositingOperation = .sourceOver

        let alpha = chip.isStale ? m.staleAlpha : 1
        let paint = chipPaint(color, look: look, dark: dark, alpha: alpha, glow: glow)
        // The disc: the widget's colour, a little lighter at the top (Solid).
        let disc = circle(face)
        Self.paint(disc, rim: circle(face - m.rimWidth), in: disc.bounds, with: paint)

        let size = scale * (place?.factor ?? 1)
        guard size > 0 else { return }
        drawGlyph(
            chip, at: NSPoint(x: place?.x ?? center.x, y: center.y), alpha: alpha, scale: size,
            look: look, ink: paint, context: context
        )
    }

    /// The focused chip grown into a pill: its disc's colour, the glyph at
    /// the start, then its value. Cut out of the chips beneath, like a
    /// disc.
    static func drawPill(
        _ chip: ClusterChip, left: CGFloat, width: CGFloat, midY: CGFloat, color: NSColor, context: NSGraphicsContext,
        look: ChipAppearance = ChipAppearance(), dark: Bool = true
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
        let paint = chipPaint(color, look: look, dark: dark, alpha: alpha)
        Self.paint(shape, rim: capsule(rect.insetBy(dx: m.rimWidth / 2, dy: m.rimWidth / 2)), in: rect, with: paint)
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        // The value, else the name when it fits whole; else the glyph alone
        // in the middle of the pill.
        let label = chip.value.isEmpty ? chip.name : chip.value
        let fits = !chip.value.isEmpty
            || pillWidth(text: chip.name) <= rect.width + 0.5
        drawGlyph(
            chip, at: NSPoint(x: fits ? rect.minX + height / 2 : rect.midX, y: midY), alpha: alpha,
            look: look, ink: paint, context: context
        )
        if fits, !label.isEmpty {
            let text = NSAttributedString(string: label, attributes: [
                .font: pillFont(), .foregroundColor: paint.text,
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
    }

    /// The red dot at the top-trailing edge of a chip drawn at `scale`, cut
    /// out of what is under it. The dot keeps its size; only its place
    /// follows the chip.
    static func drawBadge(at center: NSPoint, context: NSGraphicsContext, scale: CGFloat = 1) {
        let m = ChipMetrics.self
        let face = m.face * scale
        let badgeCenter = NSPoint(x: center.x + face / 2 - m.badge / 3, y: center.y - face / 2 + m.badge / 3)
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

    private static func drawGlyph(
        _ chip: ClusterChip, at center: NSPoint, alpha: CGFloat, scale: CGFloat = 1,
        look: ChipAppearance, ink paint: ChipPaint, context: NSGraphicsContext
    ) {
        if let name = chip.symbol, let glyph = GlyphCache.shared.glyph(name, look: look, scale: scale) {
            // The image's middle is the point of the drawing that belongs
            // at the disc's centre.
            let size = glyph.size
            let rect = NSRect(
                x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height
            )
            guard let ink = paint.ink else {
                // The cluster is drawn in a flipped image; without
                // `respectFlipped` a symbol comes out upside down (a down
                // arrow pointing up, a cup spilling).
                glyph.draw(in: rect, from: .zero, operation: .sourceOver, fraction: alpha, respectFlipped: true, hints: nil)
                return
            }
            // The cached glyph is white: drawn on a layer of its own and
            // filled through, it is a mask for the colour. No symbol is
            // drawn again, only a bitmap a few points across.
            let layer = context.cgContext
            layer.saveGState()
            layer.clip(to: rect)
            layer.setAlpha(alpha)
            layer.beginTransparencyLayer(auxiliaryInfo: nil)
            glyph.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            ink.setFill()
            rect.fill(using: .sourceAtop)
            layer.endTransparencyLayer()
            layer.restoreGState()
            return
        }
        let pointSize = look.initialPointSize * scale
        let font = NSFont.systemFont(ofSize: pointSize, weight: .heavy)
        let rounded = font.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: pointSize) } ?? font
        let text = NSAttributedString(string: chip.initial, attributes: [.font: rounded, .foregroundColor: paint.text])
        let size = text.size()
        text.draw(at: NSPoint(x: center.x - size.width / 2, y: center.y - size.height / 2))
    }
}

extension ChipAppearance {
    /// The longer side of a glyph's drawing, in points.
    var glyphSide: CGFloat {
        switch glyphSize {
        case .small: return MenuBarController.ChipMetrics.glyphSmall
        case .medium: return MenuBarController.ChipMetrics.glyphSize
        case .large: return MenuBarController.ChipMetrics.glyphLarge
        }
    }

    /// The circle at the disc's centre the whole drawing lies within.
    var glyphCircle: CGFloat {
        min(glyphSide + MenuBarController.ChipMetrics.glyphFit, MenuBarController.ChipMetrics.glyphCircleMax)
    }

    /// The initial drawn when a chip has no symbol.
    var initialPointSize: CGFloat {
        switch glyphSize {
        case .small: return MenuBarController.ChipMetrics.initialSmall
        case .medium: return MenuBarController.ChipMetrics.initialSize
        case .large: return MenuBarController.ChipMetrics.initialLarge
        }
    }
}

private extension Array {
    subscript(cluster index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

/// White chip glyphs, drawn once per glyph and size.
///
/// A chip's glyph was a fresh SF Symbol, tinted, on every frame: two thirds
/// of drawing the cluster, which the update wave and the hover glide do
/// sixty times a second. The glyph is drawn white at full strength; a stale
/// chip's fade and a style's colour are applied when it is drawn. Sizes are
/// rounded to a quarter point, so the wave's growing chips reuse a few
/// dozen images.
///
/// A glyph is the drawing with its image's margins cut away, scaled to a
/// size measured on the drawing (`ChipAppearance.glyphSide`). The image's
/// middle is the point that belongs at a disc's centre, so whoever draws it
/// centres the drawing by centring the image. That point is halfway from
/// the middle of the drawing's bounding box to its centre of mass: a
/// lopsided drawing (a thermometer, all bulb at the bottom) centred by its
/// box alone looks pushed towards its heavy end.
///
/// An SF Symbol and a glyph of the Simple set (`ChipGlyph`) are measured
/// and drawn the same way.
final class GlyphCache: @unchecked Sendable {
    static let shared = GlyphCache()
    /// Off draws every glyph afresh, as before (tests compare the two).
    var isEnabled = true
    /// The display densities glyphs are cached for, in place of the
    /// attached displays': a test's result must not depend on the screen
    /// of the Mac it runs on.
    var scalesForTesting: [CGFloat]?
    static let limit = 96

    private let lock = NSLock()
    private var images: [Key: NSImage] = [:]
    /// Where each drawing sits in its image, by source.
    private var inks: [String: Ink] = [:]
    /// The Simple set's images, read once; nil for one that would not load.
    private var simple: [ChipGlyph: NSImage?] = [:]

    private struct Key: Hashable {
        /// The drawing: a Simple glyph or an SF Symbol.
        let source: String
        let set: ChipAppearance.GlyphSet
        /// Sets the circle the drawing must fit.
        let size: ChipAppearance.GlyphSize
        let quarterPoints: Int
        let scales: [CGFloat]
    }

    struct Ink: Equatable {
        /// The drawing's bounding box, as fractions of its image (origin
        /// bottom-left).
        var frame: CGRect
        /// The drawing's size in points when its image is `inkPointSize`.
        var size: CGSize
        /// The drawing's centre of mass, as fractions of its image.
        var mass: CGPoint
    }

    /// What is drawn for a name: the image at the measuring size.
    struct Source {
        var key: String
        var image: NSImage
        var isSimple: Bool
    }

    /// Main actor: the key includes the attached displays' densities.
    /// `scale` is the chip's (a chip in focus or in the wave is larger, a
    /// covered one's glyph smaller).
    @MainActor
    func glyph(_ name: String, look: ChipAppearance = ChipAppearance(), scale: CGFloat = 1) -> NSImage? {
        guard let source = source(name, set: look.glyphSet) else { return nil }
        let fit = look.glyphCircle / look.glyphSide
        guard isEnabled else { return draw(source, side: look.glyphSide * scale, circle: look.glyphCircle * scale) }
        let quarterPoints = Int((look.glyphSide * scale * 4).rounded())
        let side = CGFloat(quarterPoints) / 4
        let scales = scalesForTesting ?? MenuBarController.screenScales()
        let key = Key(
            source: source.key, set: look.glyphSet, size: look.glyphSize, quarterPoints: quarterPoints, scales: scales
        )
        lock.lock()
        if let image = images[key] {
            lock.unlock()
            return image
        }
        lock.unlock()
        guard let drawn = draw(source, side: side, circle: side * fit) else { return nil }
        let image = MenuBarController.rasterized(drawn, scales: scales)
        lock.lock()
        if images.count >= Self.limit { images.removeAll(keepingCapacity: true) }
        images[key] = image
        lock.unlock()
        return image
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return images.count
    }

    /// The drawing, white, in an image just large enough for it: its longer
    /// side `side` at most, all of it within a circle `circle` across
    /// around the image's middle.
    private func draw(_ source: Source, side: CGFloat, circle: CGFloat) -> NSImage? {
        guard side > 0, let ink = ink(of: source) else { return nil }
        // The measured image itself, drawn smaller: a symbol asked for at
        // a small size comes in an image rounded to whole points, and the
        // drawing would no longer be where it was measured.
        let image = source.image
        let full = image.size
        // At the measuring size, origin bottom-left.
        let box = CGRect(
            x: ink.frame.minX * full.width, y: ink.frame.minY * full.height,
            width: ink.frame.width * full.width, height: ink.frame.height * full.height
        )
        // Halfway from the box's middle to the centre of mass.
        let shift = CGVector(
            dx: (ink.mass.x * full.width - box.midX) / 2, dy: (ink.mass.y * full.height - box.midY) / 2
        )
        let reach = hypot(box.width / 2 + abs(shift.dx), box.height / 2 + abs(shift.dy))
        let factor = min(side / max(box.width, box.height), circle / 2 / reach)
        var nudge = CGVector(dx: shift.dx * factor, dy: shift.dy * factor)
        let length = hypot(nudge.dx, nudge.dy)
        let limit = MenuBarController.ChipMetrics.opticalLimit
        if length > limit {
            nudge.dx *= limit / length
            nudge.dy *= limit / length
        }
        let scaled = NSSize(width: full.width * factor, height: full.height * factor)
        let frame = CGRect(
            x: box.minX * factor, y: box.minY * factor, width: box.width * factor, height: box.height * factor
        )
        let anchor = CGPoint(x: frame.midX + nudge.dx, y: frame.midY + nudge.dy)
        // An even number of points, the anchor in the middle: centred on
        // a chip (whose middle is on a whole point) the image then starts
        // on a whole point, which is a pixel on any display. An odd size
        // starts half a point in, and on a 1x display a cached bitmap was
        // resampled half a pixel aside and blurred.
        let size = NSSize(
            width: 2 * ceil(max(anchor.x - frame.minX, frame.maxX - anchor.x) - Self.hair),
            height: 2 * ceil(max(anchor.y - frame.minY, frame.maxY - anchor.y) - Self.hair)
        )
        let origin = NSPoint(x: size.width / 2 - anchor.x, y: size.height / 2 - anchor.y)
        return NSImage(size: size, flipped: false) { bounds in
            image.draw(in: NSRect(origin: origin, size: scaled))
            NSColor.white.set()
            bounds.fill(using: .sourceAtop)
            return true
        }
    }

    /// Less than any pixel: keeps arithmetic dust from adding two points.
    private static let hair: CGFloat = 0.001

    /// The size drawings are measured at: large, so the measure is fine.
    static let inkPointSize: CGFloat = 48

    private static func symbol(_ name: String, pointSize: CGFloat) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: .bold))
    }

    /// What `name` draws in `set`: the Simple glyph that stands for it, if
    /// there is one and it loads; else the SF Symbol.
    func source(_ name: String, set: ChipAppearance.GlyphSet) -> Source? {
        if set == .simple, let glyph = ChipGlyph.replacing(name), let image = simpleImage(glyph) {
            return Source(key: "simple/\(glyph.rawValue)", image: image, isSimple: true)
        }
        guard let symbol = Self.symbol(name, pointSize: Self.inkPointSize) else { return nil }
        return Source(key: "symbol/\(name)", image: symbol, isSimple: false)
    }

    private func simpleImage(_ glyph: ChipGlyph) -> NSImage? {
        lock.lock()
        if let known = simple[glyph] {
            lock.unlock()
            return known
        }
        lock.unlock()
        let image = glyph.image()
        if let image {
            let longer = max(image.size.width, image.size.height)
            image.size = NSSize(
                width: image.size.width * Self.inkPointSize / longer, height: image.size.height * Self.inkPointSize / longer
            )
        }
        lock.lock()
        simple[glyph] = .some(image)
        lock.unlock()
        return image
    }

    /// Where `name`'s drawing is inside its image, found by drawing it once.
    func ink(of name: String, set: ChipAppearance.GlyphSet = .symbols) -> Ink? {
        source(name, set: set).flatMap(ink(of:))
    }

    private func ink(of source: Source) -> Ink? {
        lock.lock()
        if let known = inks[source.key] {
            lock.unlock()
            return known
        }
        lock.unlock()
        guard let measured = Self.measure(source.image) else { return nil }
        lock.lock()
        inks[source.key] = measured
        lock.unlock()
        return measured
    }

    private static func measure(_ image: NSImage) -> Ink? {
        let size = image.size
        let scale: CGFloat = 2
        let wide = Int(ceil(size.width * scale)), high = Int(ceil(size.height * scale))
        guard wide > 0, high > 0, let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: wide, pixelsHigh: high,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: wide * 4, bitsPerPixel: 32
        ) else { return nil }
        rep.size = NSSize(width: CGFloat(wide) / scale, height: CGFloat(high) / scale)
        guard let context = NSGraphicsContext(bitmapImageRep: rep), let data = rep.bitmapData else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        // Rows run top to bottom in the bitmap. A pixel counts once it is
        // more than faintly covered, so a hairline of antialiasing does
        // not move the middle. The centre of mass counts every pixel by
        // how much of it is covered.
        var minX = wide, maxX = -1, minRow = high, maxRow = -1
        var sumX = 0.0, sumRow = 0.0, total = 0.0
        for row in 0..<high {
            for column in 0..<wide {
                let alpha = data[(row * wide + column) * 4 + 3]
                guard alpha > 0 else { continue }
                let weight = Double(alpha)
                sumX += weight * (Double(column) + 0.5)
                sumRow += weight * (Double(row) + 0.5)
                total += weight
                guard alpha > 40 else { continue }
                minX = min(minX, column); maxX = max(maxX, column)
                minRow = min(minRow, row); maxRow = max(maxRow, row)
            }
        }
        guard maxX >= minX, maxRow >= minRow, total > 0 else { return nil }
        let w = CGFloat(wide), h = CGFloat(high)
        let frame = CGRect(
            x: CGFloat(minX) / w, y: CGFloat(high - 1 - maxRow) / h,
            width: CGFloat(maxX - minX + 1) / w, height: CGFloat(maxRow - minRow + 1) / h
        )
        return Ink(
            frame: frame,
            size: CGSize(width: frame.width * rep.size.width, height: frame.height * rep.size.height),
            mass: CGPoint(x: CGFloat(sumX / total) / w, y: 1 - CGFloat(sumRow / total) / h)
        )
    }
}
