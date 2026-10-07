import MenubucketCore
import SwiftUI

/// A widget at icon height, for the Classic dock: its name, its main value,
/// and up to two bars, the way the desktop widgets boil a view down (R14-B
/// `SharedShelf.summarize`). The full card lives in the Shelf style and the
/// popup; squeezing it to icon height would only crop it.
struct DockWidgetGlance: View {
    let widget: LoadedWidget
    let height: CGFloat
    @ObservedObject private var model: WidgetCardModel

    init(widget: LoadedWidget, runtime: WidgetRuntime, height: CGFloat) {
        self.widget = widget
        self.height = height
        _model = ObservedObject(wrappedValue: runtime.cardModel(for: widget.id))
    }

    /// How wide a glance is for the widget's chosen size, in icon heights.
    static func widthFactor(size: String) -> CGFloat {
        switch size {
        case "XS", "S": return 2.2
        case "L": return 3.6
        default: return 2.8
        }
    }

    private var summary: SharedShelf.Summary? {
        model.snapshot.viewTree.map { SharedShelf.summarize($0, fallbackTitle: widget.displayName) }
    }

    var body: some View {
        let summary = self.summary
        let metrics = Array((summary?.metrics ?? []).prefix(2))
        VStack(alignment: .leading, spacing: height * 0.06) {
            HStack(spacing: 4) {
                if let symbol = summary?.symbol {
                    Image(systemName: symbol).imageScale(.small)
                }
                // The widget's own name: a summary's first text can be a
                // reading (System's load average came out as its "title").
                Text(widget.displayName)
                    .lineLimit(1)
            }
            .font(.system(size: max(8, height * 0.2), weight: .medium))
            .foregroundStyle(.secondary)

            if model.snapshot.error != nil {
                Label("Error", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: max(9, height * 0.26), weight: .semibold))
                    .foregroundStyle(.orange)
            } else if !metrics.isEmpty {
                ForEach(Array(metrics.enumerated()), id: \.offset) { _, metric in
                    meter(metric)
                }
            } else {
                Text(summary?.value ?? "—")
                    .font(.system(size: max(10, height * 0.36), weight: .semibold, design: .rounded))
                    .foregroundStyle(nodeColor(summary?.tone) ?? .primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
        }
        .padding(.horizontal, height * 0.16)
        .frame(height: height, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func meter(_ metric: SharedShelf.Metric) -> some View {
        let barHeight = max(3, height * 0.08)
        return HStack(spacing: 4) {
            if let label = metric.label {
                Text(label)
                    .font(.system(size: max(8, height * 0.18)))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.12))
                    Capsule()
                        .fill(nodeColor(metric.tone) ?? .accentColor)
                        .frame(width: proxy.size.width * CGFloat(min(max(metric.fraction ?? 0, 0), 1)))
                }
            }
            .frame(height: barHeight)
            if let value = metric.value {
                Text(value)
                    .font(.system(size: max(8, height * 0.2), weight: .semibold).monospacedDigit())
                    .lineLimit(1)
                    .fixedSize()
            }
        }
    }
}
