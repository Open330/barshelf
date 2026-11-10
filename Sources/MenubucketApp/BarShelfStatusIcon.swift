import AppKit

/// Single-color Bar + Spark brand mark for the macOS status bar.
enum BarShelfStatusIcon {
    static let logoSymbol = "barshelf.logo"
    static let accessibilityName = "BarShelf"
    private static let canvasSize = NSSize(width: 24, height: 18)

    /// The bar + spark mark is drawn well inside the canvas, so at native size it
    /// reads lighter than the SF Symbols beside it in the menu bar. Enlarge the
    /// mark about its optical center to close that gap without changing the
    /// image's point size (which would risk the status bar down-scaling it).
    private static let contentZoom: CGFloat = 1.2
    private static let inkCenter = NSPoint(x: 12.0, y: 9.325)

    /// Applies the selected mark and its stable accessible name to the status
    /// control. The button label is authoritative because the custom-drawn
    /// logo has no intrinsic accessibility description.
    ///
    /// `badged` adds the attention dot: something in BarShelf (a widget
    /// awaiting approval or failing) wants the user. The spoken name says so
    /// too, so the dot is not the only signal.
    static func configure(
        _ button: NSStatusBarButton,
        symbol: String,
        fallback: String,
        badged: Bool = false
    ) {
        let base = image(for: symbol, fallback: fallback)
        button.image = badged ? badgedImage(base) : base
        button.imagePosition = .imageOnly
        button.setAccessibilityLabel(accessibilityLabel(badged: badged))
    }

    static func accessibilityLabel(badged: Bool) -> String {
        badged
            ? String(localized: "BarShelf, needs attention")
            : accessibilityName
    }

    /// `base` with a red dot at its top-trailing corner, cut out of the mark
    /// by a clear ring so it reads at menu bar size.
    ///
    /// The dot used to be part of a template image, so the menu bar painted
    /// it the same black or white as the mark and it read as a nick in the
    /// logo, not an alert. A template image cannot hold a colour, so this one
    /// is not a template: its drawing handler runs at draw time, in the menu
    /// bar's appearance, and tints the mark with `labelColor` itself — the
    /// same tint the cluster gives the mark — then adds the red dot, the
    /// colour cluster chips already use for their alert dot.
    static func badgedImage(_ base: NSImage) -> NSImage {
        let image = NSImage(size: base.size, flipped: false) { rect in
            let dot = badgeRect(in: rect)
            let mark = NSImage(size: rect.size, flipped: false) { bounds in
                base.draw(in: bounds)
                NSColor.labelColor.set()
                bounds.fill(using: .sourceAtop)
                NSGraphicsContext.current?.compositingOperation = .clear
                NSBezierPath(ovalIn: dot.insetBy(dx: -badgeRing, dy: -badgeRing)).fill()
                return true
            }
            mark.draw(in: rect)
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: dot).fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    /// The clear ring between the dot and the mark.
    static let badgeRing: CGFloat = 1.5

    /// Where the dot sits in an image of `rect`: a circle at the
    /// top-trailing corner, big enough to read as a dot, not a speck.
    static func badgeRect(in rect: NSRect) -> NSRect {
        let diameter = max(6, (min(rect.width, rect.height) * 0.4).rounded())
        return NSRect(x: rect.maxX - diameter, y: rect.maxY - diameter, width: diameter, height: diameter)
    }

    static func image(for symbol: String, fallback: String) -> NSImage {
        let trimmed = symbol.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == logoSymbol {
            return logoImage()
        }
        if let sf = NSImage(
            systemSymbolName: trimmed,
            accessibilityDescription: accessibilityName
        ) {
            sf.isTemplate = true
            return sf
        }
        if let sf = NSImage(
            systemSymbolName: fallback,
            accessibilityDescription: accessibilityName
        ) {
            sf.isTemplate = true
            return sf
        }
        return logoImage()
    }

    static func logoImage(size: NSSize = NSSize(width: 24, height: 18)) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()

        NSGraphicsContext.current?.shouldAntialias = true

        // Keep every call site on the same proportions, including Hub previews.
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.scaleX(
            by: size.width / canvasSize.width,
            yBy: size.height / canvasSize.height
        )
        transform.concat()

        // Grow the mark in place (about its optical center) so it fills more of
        // the canvas — larger presence in the bar, same image bounds.
        let zoom = NSAffineTransform()
        zoom.translateX(by: inkCenter.x, yBy: inkCenter.y)
        zoom.scale(by: contentZoom)
        zoom.translateX(by: -inkCenter.x, yBy: -inkCenter.y)
        zoom.concat()

        NSColor.black.setStroke()
        NSColor.black.setFill()
        sparkle(center: NSPoint(x: 12.0, y: 11.4), radius: 4.25).fill()
        barPath().fill()

        NSGraphicsContext.restoreGraphicsState()

        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    private static func barPath() -> NSBezierPath {
        NSBezierPath(
            roundedRect: NSRect(x: 5.1, y: 3.0, width: 13.8, height: 2.35),
            xRadius: 1.18,
            yRadius: 1.18
        )
    }

    private static func sparkle(center: NSPoint, radius: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: center.x, y: center.y + radius))
        path.curve(
            to: NSPoint(x: center.x + radius, y: center.y),
            controlPoint1: NSPoint(x: center.x + radius * 0.22, y: center.y + radius * 0.42),
            controlPoint2: NSPoint(x: center.x + radius * 0.42, y: center.y + radius * 0.22)
        )
        path.curve(
            to: NSPoint(x: center.x, y: center.y - radius),
            controlPoint1: NSPoint(x: center.x + radius * 0.42, y: center.y - radius * 0.22),
            controlPoint2: NSPoint(x: center.x + radius * 0.22, y: center.y - radius * 0.42)
        )
        path.curve(
            to: NSPoint(x: center.x - radius, y: center.y),
            controlPoint1: NSPoint(x: center.x - radius * 0.22, y: center.y - radius * 0.42),
            controlPoint2: NSPoint(x: center.x - radius * 0.42, y: center.y - radius * 0.22)
        )
        path.curve(
            to: NSPoint(x: center.x, y: center.y + radius),
            controlPoint1: NSPoint(x: center.x - radius * 0.42, y: center.y + radius * 0.22),
            controlPoint2: NSPoint(x: center.x - radius * 0.22, y: center.y + radius * 0.42)
        )
        path.close()
        return path
    }
}
