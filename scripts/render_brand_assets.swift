import AppKit
import Foundation

private enum Brand {
    static let canvas: CGFloat = 1024

    static let ink = NSColor(
        calibratedRed: 0.035, green: 0.075, blue: 0.080, alpha: 1
    )
    static let inkStroke = NSColor(
        calibratedWhite: 1, alpha: 0.07
    )
    static let ivory = NSColor(
        calibratedRed: 0.950, green: 0.920, blue: 0.855, alpha: 1
    )
    static let warmWhite = NSColor(
        calibratedRed: 0.985, green: 0.965, blue: 0.920, alpha: 1
    )
    static let shadow = NSColor(
        calibratedWhite: 0, alpha: 0.30
    )

    static func appIconTile(size: Int) throws -> NSBitmapImageRep {
        try render(size: size) {
            drawBackground()
            drawTileMark()
        }
    }

    static func portableLogo(size: Int) throws -> NSBitmapImageRep {
        try render(size: size) {
            ink.setFill()
            sparkle(center: NSPoint(x: 512, y: 604), radius: 196).fill()
            barPath().fill()
        }
    }

    private static func render(size: Int, draw: () -> Void) throws -> NSBitmapImageRep {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: size,
            pixelsHigh: size,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw NSError(
                domain: "BarShelfBrandRenderer",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Unable to create bitmap \(size)x\(size)"]
            )
        }
        rep.size = NSSize(width: size, height: size)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        NSGraphicsContext.current?.shouldAntialias = true
        let canvasRect = NSRect(x: 0, y: 0, width: size, height: size)
        NSColor.clear.setFill()
        canvasRect.fill()

        NSGraphicsContext.saveGraphicsState()
        let scale = CGFloat(size) / canvas
        let transform = NSAffineTransform()
        transform.scaleX(by: scale, yBy: scale)
        transform.concat()

        draw()

        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    private static func drawBackground() {
        let rect = NSRect(x: 72, y: 72, width: 880, height: 880)
        let background = NSBezierPath(roundedRect: rect, xRadius: 222, yRadius: 222)

        withShadow(offset: NSSize(width: 0, height: -22), blur: 34, color: shadow) {
            ink.setFill()
            background.fill()
        }

        inkStroke.setStroke()
        background.lineWidth = 3
        background.stroke()
    }

    private static func drawTileMark() {
        withShadow(offset: NSSize(width: 0, height: -18), blur: 24, color: shadow) {
            warmWhite.setFill()
            sparkle(center: NSPoint(x: 512, y: 600), radius: 184).fill()
        }

        withShadow(offset: NSSize(width: 0, height: -18), blur: 20, color: shadow) {
            ivory.setFill()
            barPath().fill()
        }

        NSColor(calibratedWhite: 1, alpha: 0.10).setFill()
        NSBezierPath(
            roundedRect: NSRect(x: 306, y: 315, width: 412, height: 10),
            xRadius: 5,
            yRadius: 5
        ).fill()
    }

    private static func barPath() -> NSBezierPath {
        NSBezierPath(
            roundedRect: NSRect(x: 292, y: 288, width: 440, height: 76),
            xRadius: 38,
            yRadius: 38
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

    private static func withShadow(
        offset: NSSize,
        blur: CGFloat,
        color: NSColor,
        draw: () -> Void
    ) {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowOffset = offset
        shadow.shadowBlurRadius = blur
        shadow.shadowColor = color
        shadow.set()
        draw()
        NSGraphicsContext.restoreGraphicsState()
    }
}

private func writePNG(_ rep: NSBitmapImageRep, to url: URL) throws {
    guard let png = rep.representation(using: .png, properties: [:]) else {
        throw NSError(
            domain: "BarShelfBrandRenderer",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Unable to encode PNG at \(url.path)"]
        )
    }
    try png.write(to: url)
}

private let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
private let iconset = root.appendingPathComponent("assets/AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

try writePNG(try Brand.portableLogo(size: 1024), to: root.appendingPathComponent("assets/AppIcon-1024.png"))

let tileOutputs: [(String, Int)] = [
    ("assets/media/icon-512.png", 512),
    ("site/icon-512.png", 512),
    ("assets/AppIcon.iconset/icon_16x16.png", 16),
    ("assets/AppIcon.iconset/icon_16x16@2x.png", 32),
    ("assets/AppIcon.iconset/icon_32x32.png", 32),
    ("assets/AppIcon.iconset/icon_32x32@2x.png", 64),
    ("assets/AppIcon.iconset/icon_128x128.png", 128),
    ("assets/AppIcon.iconset/icon_128x128@2x.png", 256),
    ("assets/AppIcon.iconset/icon_256x256.png", 256),
    ("assets/AppIcon.iconset/icon_256x256@2x.png", 512),
    ("assets/AppIcon.iconset/icon_512x512.png", 512),
    ("assets/AppIcon.iconset/icon_512x512@2x.png", 1024),
]

for (path, size) in tileOutputs {
    try writePNG(try Brand.appIconTile(size: size), to: root.appendingPathComponent(path))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = [
    "-c", "icns",
    iconset.path,
    "-o", root.appendingPathComponent("assets/AppIcon.icns").path,
]
try iconutil.run()
iconutil.waitUntilExit()
if iconutil.terminationStatus != 0 {
    throw NSError(
        domain: "BarShelfBrandRenderer",
        code: Int(iconutil.terminationStatus),
        userInfo: [NSLocalizedDescriptionKey: "iconutil failed"]
    )
}
