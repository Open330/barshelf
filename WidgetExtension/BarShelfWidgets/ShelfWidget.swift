import AppIntents
import MenubucketCore
import SwiftUI
import WidgetKit

struct ShelfEntry: TimelineEntry {
    let date: Date
    let widgetID: String?
    let snapshot: SharedShelf.Snapshot?
    /// Part keys the user picked, in their order; empty for the summary.
    var partKeys: [String] = []
}

struct ShelfProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> ShelfEntry {
        ShelfEntry(date: Date(), widgetID: "sample", snapshot: Self.sample)
    }

    func snapshot(for configuration: SelectShelfWidgetIntent, in context: Context) async -> ShelfEntry {
        if context.isPreview, configuration.widget == nil {
            return ShelfEntry(date: Date(), widgetID: "sample", snapshot: Self.sample)
        }
        return entry(for: configuration)
    }

    func timeline(for configuration: SelectShelfWidgetIntent, in context: Context) async -> Timeline<ShelfEntry> {
        // BarShelf asks for a reload when the data changes; the fallback
        // below only covers a BarShelf that is not running.
        Timeline(entries: [entry(for: configuration)], policy: .after(Date().addingTimeInterval(30 * 60)))
    }

    private func entry(for configuration: SelectShelfWidgetIntent) -> ShelfEntry {
        guard let id = configuration.widget?.id else {
            return ShelfEntry(date: Date(), widgetID: nil, snapshot: nil)
        }
        let keys = (configuration.parts ?? []).filter { $0.widgetID == id }.map(\.key)
        return ShelfEntry(date: Date(), widgetID: id, snapshot: SharedContainer.snapshot(for: id), partKeys: keys)
    }

    /// What the widget gallery shows before anything is chosen.
    static let sample: SharedShelf.Snapshot = {
        func row(_ label: String, _ value: String, _ fraction: Double, _ tint: String) -> UINode {
            UINode(type: "vstack", children: [
                UINode(type: "hstack", children: [
                    UINode(type: "text", text: label, role: "caption"),
                    UINode(type: "spacer"),
                    UINode(type: "text", text: value, role: "caption", foreground: tint),
                ]),
                UINode(type: "progress", tint: tint, value: fraction),
            ], spacing: 4)
        }
        return SharedShelf.Snapshot(
            widgetID: "sample",
            name: String(localized: "System"),
            icon: "cpu.fill",
            accent: "purple",
            viewTree: UINode(type: "vstack", children: [
                row("CPU", "23%", 0.23, "good"),
                row("Memory", "68%", 0.68, "warning"),
                row("Disk", "31%", 0.31, "good"),
            ]),
            updatedAt: Date(),
            statusLabel: "23%",
            statusTint: "good"
        )
    }()
}

struct ShelfWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: SharedShelf.widgetKind,
            intent: SelectShelfWidgetIntent.self,
            provider: ShelfProvider()
        ) { entry in
            ShelfWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("BarShelf Widget")
        .description("Shows one of your BarShelf widgets, or just the items you pick from it.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct ShelfWidgetView: View {
    let entry: ShelfEntry
    /// Set by the preview tool, which has no real widget family.
    var familyOverride: WidgetFamily?
    @Environment(\.widgetFamily) private var environmentFamily

    private var family: WidgetFamily { familyOverride ?? environmentFamily }

    var body: some View {
        Group {
            if let snapshot = entry.snapshot {
                content(snapshot)
            } else if entry.widgetID == nil {
                placeholder(
                    symbol: "square.grid.2x2",
                    title: String(localized: "Choose a widget"),
                    text: String(localized: "Right-click here and choose Edit Widget.")
                )
            } else {
                placeholder(
                    symbol: "clock",
                    title: nil,
                    text: String(localized: "Waiting for BarShelf to refresh this widget.")
                )
            }
        }
        .widgetURL(deepLink)
    }

    private var deepLink: URL? {
        var components = URLComponents()
        components.scheme = "barshelf"
        components.host = "show"
        if let id = entry.widgetID {
            components.queryItems = [URLQueryItem(name: "widget", value: id)]
        }
        return components.url
    }

    // MARK: - Content

    private func content(_ snapshot: SharedShelf.Snapshot) -> some View {
        let accent = WidgetPalette.color(snapshot.accent) ?? .accentColor
        return VStack(alignment: .leading, spacing: 8) {
            header(snapshot, accent: accent)
            body(for: snapshot, accent: accent)
                .modifier(TopAlignedClip())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func header(_ snapshot: SharedShelf.Snapshot, accent: Color) -> some View {
        HStack(spacing: 5) {
            if let icon = snapshot.icon {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundStyle(accent)
                    .widgetAccentable()
            }
            Text(snapshot.name)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            if let updated = snapshot.updatedAt {
                // "6 min, 4 sec" ticks without spending reloads, but crowds
                // out the name in the small size; there the time will do.
                Group {
                    if family == .systemSmall {
                        Text(updated, style: .time)
                    } else {
                        Text(updated, style: .relative)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .multilineTextAlignment(.trailing)
                .layoutPriority(-1)
            }
        }
    }

    @ViewBuilder
    private func body(for snapshot: SharedShelf.Snapshot, accent: Color) -> some View {
        let chosen = entry.partKeys.compactMap { key in snapshot.parts.first { $0.key == key } }
        if !chosen.isEmpty {
            parts(chosen, accent: accent)
        } else if family == .systemSmall, let headline = snapshot.statusLabel, !headline.isEmpty {
            headlineView(headline, tint: WidgetPalette.color(snapshot.statusTint, accent: accent) ?? .primary,
                         detail: automaticParts(snapshot).prefix(1).map { $0 }, accent: accent)
        } else if !automaticParts(snapshot).isEmpty {
            parts(automaticParts(snapshot), accent: accent)
        } else if let tree = snapshot.viewTree {
            WidgetNodeView(node: tree, accent: accent, rowLimit: rowLimit)
        } else if let error = snapshot.error {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Items to show when none were picked: the leaves, not the sections
    /// holding them, so nothing appears twice.
    private func automaticParts(_ snapshot: SharedShelf.Snapshot) -> [SharedShelf.Part] {
        snapshot.parts.filter { !$0.isGroup }
    }

    /// The small widget's summary: the reading the widget puts in the menu
    /// bar, large, over its first item.
    private func headlineView(_ text: String, tint: Color, detail: [SharedShelf.Part], accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text)
                .font(.system(size: 34, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .widgetAccentable()
            ForEach(detail) { part in
                WidgetNodeView(node: part.node, accent: accent, rowLimit: 2)
            }
        }
    }

    /// Chosen or leading items. Cards and sections sit two to a row when
    /// there is room; label-and-value rows stack.
    @ViewBuilder
    private func parts(_ parts: [SharedShelf.Part], accent: Color) -> some View {
        let blocky = parts.contains { ["card", "section"].contains($0.node.type) }
        if blocky && family != .systemSmall && parts.count > 1 {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8, alignment: .top), GridItem(.flexible(), spacing: 8, alignment: .top)],
                      alignment: .leading, spacing: 8) {
                ForEach(parts) { part in
                    WidgetNodeView(node: part.node, accent: accent, rowLimit: 3)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: blocky ? 8 : 6) {
                ForEach(parts) { part in
                    WidgetNodeView(node: part.node, accent: accent, rowLimit: rowLimit)
                }
            }
        }
    }

    /// How many list rows fit; the rest is cut rather than scrolled.
    private var rowLimit: Int {
        switch family {
        case .systemSmall, .systemMedium: return 3
        default: return 8
        }
    }

    private func placeholder(symbol: String, title: String?, text: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.secondary)
            if let title {
                Text(title).font(.callout.weight(.semibold))
            }
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Lays content out from the top at its natural height and cuts whatever
/// does not fit at the bottom, with a short fade — never centering an
/// oversized view so that its top (and the header above it) is lost.
private struct TopAlignedClip: ViewModifier {
    func body(content: Content) -> some View {
        GeometryReader { proxy in
            content
                .frame(width: proxy.size.width, alignment: .topLeading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                .clipped()
                .mask(
                    VStack(spacing: 0) {
                        Rectangle()
                        LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                            .frame(height: min(14, proxy.size.height / 4))
                    }
                )
        }
    }
}
