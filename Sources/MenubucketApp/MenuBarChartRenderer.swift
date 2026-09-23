import AppKit
import MenubucketCore

extension MenuBarController {
    /// Space between a chart and whatever it sits in front of.
    static let chartGap: CGFloat = 3
    /// Line and bar charts: wide enough to read a trend, narrow enough to sit
    /// beside a reading without doubling the item.
    static let chartTrendWidth: CGFloat = 24

    static func chartSize(_ chart: MenuBarChart, height: CGFloat) -> NSSize {
        let side = max(min(height - 6, 14), 6)
        switch chart {
        case .none: return .zero
        case .gauge: return NSSize(width: side, height: side)
        case .line, .bars: return NSSize(width: chartTrendWidth, height: side)
        }
    }

    /// The entry's chart, or nil when it has none or nothing to draw yet.
    ///
    /// `template` has to match the image it is composed with: a template is
    /// drawn in black and tinted by the menu bar, a coloured image draws its
    /// own colours — a black chart inside a coloured image would vanish on a
    /// dark menu bar.
    static func chartImage(for entry: MenuBarEntry, template: Bool, height: CGFloat) -> NSImage? {
        let chart = entry.presentation.effectiveChart
        guard chart != .none, let latest = entry.history.last else { return nil }
        let size = chartSize(chart, height: height)
        let values = entry.history
        // A percentage is drawn against 0–100. Anything else: a gauge fills
        // against the danger threshold when there is one — against its own
        // peak it would read full at every new high — and a trend against its
        // recent peak, so a quiet disk still shows its shape.
        let peak = max(values.max() ?? 0, .leastNonzeroMagnitude)
        let danger = entry.presentation.dangerAt.flatMap { $0 > 0 ? $0 : nil }
        let top = entry.chartScale ?? (chart == .gauge ? danger ?? peak : peak)
        let bottom = entry.chartScale == nil ? min(values.min() ?? 0, 0) : 0
        let span = max(top - bottom, .leastNonzeroMagnitude)
        func fraction(_ value: Double) -> CGFloat {
            CGFloat(min(max((value - bottom) / span, 0), 1))
        }
        let dim: CGFloat = entry.isStale ? staleOpacity : 1
        let base = entry.tint.map(nsColor(for:)) ?? (template ? NSColor.black : .labelColor)
        let ink = base.withAlphaComponent(dim)
        let faint = base.withAlphaComponent(0.25 * dim)

        let image = NSImage(size: size, flipped: false) { rect in
            switch chart {
            case .none:
                break
            case .line:
                let line: CGFloat = 1.25
                // Inset by half the stroke, so the newest point — the one that
                // matters — is not clipped against the text beside it.
                let right = rect.maxX - line / 2
                let step = (rect.width - line) / CGFloat(MenuBarPolicy.chartHistoryLimit - 1)
                // Newest at the right edge, so the line grows in from the left
                // as history fills.
                let startX = right - step * CGFloat(values.count - 1)
                faint.set()
                NSBezierPath.fill(NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: 0.75))
                let path = NSBezierPath()
                path.lineWidth = line
                path.lineJoinStyle = .round
                path.lineCapStyle = .round
                for (index, value) in values.enumerated() {
                    let point = NSPoint(
                        x: startX + step * CGFloat(index),
                        y: rect.minY + line / 2 + fraction(value) * (rect.height - line)
                    )
                    index == 0 ? path.move(to: point) : path.line(to: point)
                }
                ink.set()
                if values.count == 1 {
                    NSBezierPath(ovalIn: NSRect(x: right - 1, y: path.currentPoint.y - 1, width: 2, height: 2)).fill()
                } else {
                    path.stroke()
                }
            case .bars:
                let bar: CGFloat = 2
                let gap: CGFloat = 1
                let count = Int((rect.width + gap) / (bar + gap))
                let shown = values.suffix(count)
                var x = rect.maxX - bar
                for value in shown.reversed() {
                    let height = max(fraction(value) * rect.height, 1)
                    ink.set()
                    NSBezierPath.fill(NSRect(x: x, y: rect.minY, width: bar, height: height))
                    x -= bar + gap
                }
                faint.set()
                NSBezierPath.fill(NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: 0.75))
            case .gauge:
                let line: CGFloat = 2
                let ring = rect.insetBy(dx: line / 2, dy: line / 2)
                let center = NSPoint(x: ring.midX, y: ring.midY)
                let radius = ring.width / 2
                let track = NSBezierPath(ovalIn: ring)
                track.lineWidth = line
                faint.set()
                track.stroke()
                let share = fraction(latest)
                guard share > 0 else { break }
                // Clockwise from twelve o'clock, the way a gauge reads.
                let arc = NSBezierPath()
                arc.appendArc(withCenter: center, radius: radius, startAngle: 90,
                              endAngle: 90 - 360 * share, clockwise: true)
                arc.lineWidth = line
                arc.lineCapStyle = .round
                ink.set()
                arc.stroke()
            }
            return true
        }
        image.isTemplate = template
        return image
    }

    /// A stacked or metrics item's whole image: its rows, and its chart in
    /// front of them. `minimumWidth` is the whole item's, chart included, so
    /// a kept width floor does not grow by the chart on every redraw.
    static func drawnImage(
        _ entry: MenuBarEntry, symbol: NSImage?, glyph: String?,
        height: CGFloat = NSStatusBar.system.thickness, minimumWidth: CGFloat = 0
    ) -> NSImage {
        let chrome = entry.presentation.effectiveChart == .none || entry.history.isEmpty ? 0
            : stackedHorizontalPadding + chartSize(entry.presentation.effectiveChart, height: height).width + chartGap
        let rows = entry.style == .metrics
            ? metricsImage(entry, symbol: symbol, glyph: glyph, height: height,
                           minimumWidth: max(minimumWidth - chrome, 0))
            : stackedImage(entry, symbol: symbol, glyph: glyph, height: height,
                           minimumWidth: max(minimumWidth - chrome, 0))
        let chart = chartImage(for: entry, template: entry.tint == nil && rows.isTemplate, height: height)
        return composing(chart: chart, before: rows, height: height) ?? rows
    }

    /// An inline item's leading image: its chart, then its icon.
    static func leadingImage(_ entry: MenuBarEntry, symbol: NSImage?, height: CGFloat) -> NSImage? {
        let chart = chartImage(for: entry, template: entry.tint == nil && (symbol?.isTemplate ?? true), height: height)
        return composing(chart: chart, before: symbol, height: height)
    }

    /// `chart` in front of `image`, vertically centred, as one image. nil
    /// chart returns `image` untouched.
    static func composing(chart: NSImage?, before image: NSImage?, height: CGFloat) -> NSImage? {
        guard let chart else { return image }
        let lead = stackedHorizontalPadding
        let gap = image == nil ? 0 : chartGap
        let width = lead + chart.size.width + gap + (image?.size.width ?? lead)
        let composed = NSImage(size: NSSize(width: ceil(width), height: height), flipped: false) { _ in
            chart.draw(in: NSRect(x: lead, y: ((height - chart.size.height) / 2).rounded(),
                                  width: chart.size.width, height: chart.size.height))
            if let image {
                image.draw(in: NSRect(x: lead + chart.size.width + gap,
                                      y: ((height - image.size.height) / 2).rounded(),
                                      width: image.size.width, height: image.size.height))
            }
            return true
        }
        composed.isTemplate = chart.isTemplate && (image?.isTemplate ?? true)
        return composed
    }
}
