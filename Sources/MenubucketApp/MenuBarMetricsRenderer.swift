import AppKit
import MenubucketCore

extension MenuBarController {
    /// Two independent readings, with optional activity indicators. The same
    /// renderer serves transfer rates, read/write counts, queues, or sensors.
    /// No sampling or animation timer belongs to this presentation layer.
    static func metricsImage(
        _ entry: MenuBarEntry,
        symbol: NSImage? = nil,
        glyph: String? = nil,
        height: CGFloat = NSStatusBar.system.thickness,
        minimumWidth: CGFloat = 0
    ) -> NSImage {
        let metrics = MenuBarPolicy.normalizedMetrics(entry.metrics)
        guard !metrics.isEmpty else {
            return stackedImage(
                entry, symbol: symbol, glyph: glyph, height: height, minimumWidth: minimumWidth
            )
        }
        let presentation = entry.presentation
        let height = max(height.isFinite ? height : 22, 12)
        let rowHeight = (height - 3) / CGFloat(metrics.count)
        // Two rows leave no height to trade, so size is a small nudge that
        // still stays inside the row.
        let sizeFactor: CGFloat = presentation.size == .small ? 0.9 : presentation.size == .large ? 1.08 : 1
        let font = NSFont.monospacedDigitSystemFont(
            ofSize: min(10 * sizeFactor, rowHeight * 0.9),
            weight: nsWeight(presentation.weight, default: .medium)
        )
        let dotSize: CGFloat = min(6, rowHeight - 2)
        let hasDots = metrics.contains { $0.active != nil }
        let hasValues = metrics.contains { !$0.value.isEmpty }
        let labelWidth = metrics.map { ($0.label as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        // The value column. Rates change units as well as digits ("999 KB/s"
        // → "1.2 MB/s"), which digit padding alone cannot hold still, so auto
        // keeps a floor wide enough for an ordinary rate. Fixed is the user's
        // own column; fit is the measured text. Wider content always fits.
        let measuredValues = metrics.map {
            ($0.value as NSString).size(withAttributes: [.font: font]).width
        }.max() ?? 0
        let columnFloor: CGFloat
        switch presentation.effectiveWidth {
        case .auto: columnFloor = 56
        case .fixed: columnFloor = CGFloat(presentation.effectiveFixedWidth)
        case .fit: columnFloor = 0
        }
        let valueWidth = hasValues ? max(columnFloor, measuredValues) : 0
        let side = symbol == nil ? 0 : min(16, height - 4)
        let glyphWidth = ((glyph ?? "") as NSString).size(withAttributes: [.font: font]).width
        let leadingWidth = side > 0 ? side + 3 : (glyphWidth > 0 ? glyphWidth + 3 : 0)
        let dotColumn = hasDots ? dotSize + (labelWidth + valueWidth > 0 ? 3 : 0) : 0
        let columnGap: CGFloat = labelWidth > 0 && hasValues ? 4 : 0
        let contentWidth = dotColumn + labelWidth + columnGap + valueWidth
        let width = max(18, ceil(6 + leadingWidth + contentWidth), ceil(minimumWidth))
        let template = entry.tint == nil && metrics.allSatisfy { MenuBarTint.named($0.tint) == nil }
        let image = NSImage(size: NSSize(width: width, height: height), flipped: true) { _ in
            let dim: CGFloat = entry.isStale ? staleOpacity : 1
            let defaultInk = entry.tint.map(nsColor(for:)) ?? (template ? NSColor.black : .labelColor)
            // The block sits by the item's alignment when the item is wider
            // than it (a kept floor) — the same default the settings show.
            let block = leadingWidth + contentWidth
            let startX = 3 + alignedOffset(block, in: width - 6, presentation.effectiveAlignment)
            if let symbol {
                symbol.draw(in: NSRect(x: startX, y: (height - side) / 2, width: side, height: side),
                            from: .zero, operation: .sourceOver, fraction: dim)
            } else if let glyph, !glyph.isEmpty {
                (glyph as NSString).draw(at: NSPoint(x: startX, y: (height - font.ascender + font.descender) / 2),
                                        withAttributes: [.font: font, .foregroundColor: defaultInk.withAlphaComponent(dim)])
            }
            for (index, metric) in metrics.enumerated() {
                let centerY = 1.5 + rowHeight * (CGFloat(index) + 0.5)
                let rowInk = metric.tint == "monochrome"
                    ? (template ? NSColor.black : .labelColor)
                    : MenuBarTint.named(metric.tint).map(nsColor(for:)) ?? defaultInk
                var x = startX + leadingWidth
                if let active = metric.active {
                    let rect = NSRect(x: x + 0.5, y: centerY - dotSize / 2 + 0.5,
                                      width: dotSize - 1, height: dotSize - 1)
                    let dot = NSBezierPath(ovalIn: rect)
                    rowInk.withAlphaComponent(dim * (active ? 1 : 0.45)).set()
                    if active { dot.fill() } else { dot.lineWidth = 1; dot.stroke() }
                }
                x += dotColumn
                // Align cap heights instead of overflowing the menu bar with
                // AppKit's extra line-box leading.
                let y = centerY - inkHeight(of: font) / 2 - (font.ascender - font.capHeight)
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: font, .foregroundColor: rowInk.withAlphaComponent(dim),
                ]
                (metric.label as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: attributes)
                let value = metric.value as NSString
                let measured = value.size(withAttributes: attributes).width
                value.draw(at: NSPoint(x: x + labelWidth + columnGap + valueWidth - measured, y: y),
                           withAttributes: attributes)
            }
            return true
        }
        image.isTemplate = template
        return image
    }
}
