import AppIntents
import MenubucketCore
import SwiftUI
import WidgetKit

struct ShelfEntry: TimelineEntry {
    let date: Date
    let widgetID: String?
    let snapshot: SharedShelf.Snapshot?
}

struct ShelfProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> ShelfEntry {
        ShelfEntry(date: Date(), widgetID: nil, snapshot: Self.sample)
    }

    func snapshot(for configuration: SelectShelfWidgetIntent, in context: Context) async -> ShelfEntry {
        if context.isPreview, configuration.widget == nil {
            return ShelfEntry(date: Date(), widgetID: nil, snapshot: Self.sample)
        }
        return entry(for: configuration)
    }

    func timeline(for configuration: SelectShelfWidgetIntent, in context: Context) async -> Timeline<ShelfEntry> {
        // BarShelf asks for a reload when the data changes; the fallback
        // below only covers a BarShelf that is not running.
        Timeline(entries: [entry(for: configuration)], policy: .after(Date().addingTimeInterval(30 * 60)))
    }

    private func entry(for configuration: SelectShelfWidgetIntent) -> ShelfEntry {
        let id = configuration.widget?.id ?? SharedContainer.index()?.entries.first?.id
        return ShelfEntry(date: Date(), widgetID: id, snapshot: id.flatMap(SharedContainer.snapshot(for:)))
    }

    /// What the widget gallery shows before anything is chosen.
    static let sample = SharedShelf.Snapshot(
        widgetID: "sample",
        name: String(localized: "Battery"),
        icon: "battery.75percent",
        accent: "green",
        viewTree: UINode(type: "vstack", children: [
            UINode(type: "text", text: "80%", role: "title", size: 34),
            UINode(type: "progress", tint: "good", value: 0.8),
        ]),
        updatedAt: Date()
    )
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
        .description("Shows one of your BarShelf widgets as it last looked.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct ShelfWidgetView: View {
    let entry: ShelfEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            if let snapshot = entry.snapshot {
                content(snapshot)
            } else if entry.widgetID == nil {
                placeholder(
                    symbol: "square.grid.2x2",
                    text: String(localized: "Open BarShelf once, then choose a widget to show here.")
                )
            } else {
                placeholder(
                    symbol: "clock",
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

    private func content(_ snapshot: SharedShelf.Snapshot) -> some View {
        let accent = WidgetPalette.color(snapshot.accent) ?? .accentColor
        return VStack(alignment: .leading, spacing: 6) {
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
                Spacer(minLength: 0)
                if let updated = snapshot.updatedAt {
                    // Ticks without spending reloads.
                    Text(updated, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .multilineTextAlignment(.trailing)
                }
            }
            if let tree = snapshot.viewTree {
                WidgetNodeView(node: tree, accent: accent, rowLimit: rowLimit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .clipped()
            } else if let error = snapshot.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// How many list rows fit; the rest is cut rather than scrolled.
    private var rowLimit: Int {
        switch family {
        case .systemSmall: return 3
        case .systemMedium: return 3
        default: return 8
        }
    }

    private func placeholder(symbol: String, text: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
