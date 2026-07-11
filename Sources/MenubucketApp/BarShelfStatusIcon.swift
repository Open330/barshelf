import AppKit

/// Single-color Bar + Spark brand mark for the macOS status bar.
enum BarShelfStatusIcon {
    static let logoSymbol = "barshelf.logo"
    private static let canvasSize = NSSize(width: 24, height: 18)

    /// The bar + spark mark is drawn well inside the canvas, so at native size it
    /// reads lighter than the SF Symbols beside it in the menu bar. Enlarge the
    /// mark about its optical center to close that gap without changing the
    /// image's point size (which would risk the status bar down-scaling it).
    private static let contentZoom: CGFloat = 1.2
    private static let inkCenter = NSPoint(x: 12.0, y: 9.325)

    static func image(for symbol: String, fallback: String) -> NSImage {
        let trimmed = symbol.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == logoSymbol {
            return logoImage()
        }
        if let sf = NSImage(systemSymbolName: trimmed, accessibilityDescription: "BarShelf") {
            sf.isTemplate = true
            return sf
        }
        if let sf = NSImage(systemSymbolName: fallback, accessibilityDescription: "BarShelf") {
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
