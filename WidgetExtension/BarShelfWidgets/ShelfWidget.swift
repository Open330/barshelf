import AppIntents
import MenubucketCore
import SwiftUI
import WidgetKit

struct ShelfEntry: TimelineEntry {
    let date: Date
    let widgetID: String?
    let snapshot: SharedShelf.Snapshot?
    /// Part keys the user picked, in their order; empty lets the widget pick.
    var partKeys: [String] = []
    var style: ShelfWidgetStyle = .automatic
}

struct ShelfProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> ShelfEntry {
        ShelfEntry(date: Date(), widgetID: "sample", snapshot: Self.sample)
    }

    func snapshot(for configuration: SelectShelfWidgetIntent, in context: Context) async -> ShelfEntry {
        if context.isPreview, configuration.widget == nil {
            // The gallery shows the user's own first widget when there is one.
            if let first = SharedContainer.index()?.entries.first, let snapshot = SharedContainer.snapshot(for: first.id) {
                return ShelfEntry(date: Date(), widgetID: first.id, snapshot: snapshot)
            }
            return ShelfEntry(date: Date(), widgetID: "sample", snapshot: Self.sample)
        }
        return entry(for: configuration, at: Date())
    }

    func timeline(for configuration: SelectShelfWidgetIntent, in context: Context) async -> Timeline<ShelfEntry> {
        let now = Date()
        var entries = [entry(for: configuration, at: now)]
        // A second entry at the moment the reading turns old, so the widget
        // says so without BarShelf spending a reload on it.
        if let staleAfter = entries[0].snapshot?.staleAfter, staleAfter > now {
            entries.append(entry(for: configuration, at: staleAfter))
        }
        // BarShelf asks for a reload when the data changes; the fallback
        // below only covers a BarShelf that is not running.
        return Timeline(entries: entries, policy: .after(now.addingTimeInterval(30 * 60)))
    }

    private func entry(for configuration: SelectShelfWidgetIntent, at date: Date) -> ShelfEntry {
        guard let id = configuration.widget?.id else {
            return ShelfEntry(date: date, widgetID: nil, snapshot: nil)
        }
        let keys = (configuration.parts ?? []).filter { $0.widgetID == id }.map(\.key)
        return ShelfEntry(
            date: date, widgetID: id, snapshot: SharedContainer.snapshot(for: id),
            partKeys: keys, style: configuration.style
        )
    }

    /// What the widget gallery shows when the user has no data yet.
    static let sample: SharedShelf.Snapshot = {
        func row(_ label: String, _ value: String, _ fraction: Double, _ tint: String) -> UINode {
            UINode(type: "vstack", children: [
                UINode(type: "hstack", children: [
                    UINode(type: "text", text: label),
                    UINode(type: "spacer"),
                    UINode(type: "text", text: value, foreground: tint),
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
    /// Where exported thumbnails are; the preview tool passes its own.
    var container: URL? = SharedContainer.url
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

    // MARK: - Layout

    private func content(_ snapshot: SharedShelf.Snapshot) -> some View {
        let accent = WidgetPalette.color(snapshot.accent) ?? .accentColor
        let plan = layout(for: snapshot)
        return VStack(alignment: .leading, spacing: 8) {
            header(snapshot, title: plan.heading, accent: accent)
            Group {
                switch plan.template {
                case .bigValue:
                    BigValueTemplate(summary: plan.headline ?? SharedShelf.Summary(title: snapshot.name), accent: accent, family: family)
                case .meters:
                    MetersTemplate(items: plan.items, accent: accent, family: family)
                case .list:
                    ListTemplate(items: plan.items, accent: accent, family: family)
                case .grid:
                    GridTemplate(items: plan.items, family: family)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipped()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private struct Plan {
        var template: SharedShelf.Template
        var items: [TemplateItem]
        /// The single item a big-value layout shows.
        var headline: SharedShelf.Summary?
        /// What the header names: the widget, or the one item shown.
        var heading: String?
    }

    /// Which items, in which layout. Picked items in the picked order;
    /// otherwise the widget's own items (sections that hold items are left
    /// out, so nothing shows twice). The small size shows one item large
    /// unless the items are a few readings that fit as rings.
    private func layout(for snapshot: SharedShelf.Snapshot) -> Plan {
        let picked = entry.partKeys.compactMap { key in snapshot.parts.first { $0.key == key } }
        let pool = picked.isEmpty ? snapshot.parts.filter { !$0.isGroup } : picked
        let all = pool.map { part in
            TemplateItem(
                id: part.key,
                summary: part.summary ?? SharedShelf.summarize(part.node, fallbackTitle: part.title),
                group: part.group,
                thumbnail: part.summary?.thumbnail.flatMap { name in
                    container.flatMap { SharedShelf.imagesDirectory(for: snapshot.widgetID, in: $0) }?
                        .appendingPathComponent(name)
                }
            )
        }

        var template = entry.style.template ?? SharedShelf.automaticTemplate(for: all.map(\.summary))
        if entry.style.template == nil, family == .systemSmall, template == .list {
            template = .bigValue
        }
        if template == .meters, entry.style.template == nil, family == .systemSmall, all.count > 3 {
            template = .bigValue
        }

        if template == .bigValue {
            if let first = all.first {
                return Plan(template: .bigValue, items: [], headline: first.summary, heading: first.summary.title)
            }
            var root = snapshot.summary ?? SharedShelf.Summary()
            if root.value == nil, let label = snapshot.statusLabel {
                root.value = label
                root.tone = root.tone ?? snapshot.statusTint
            }
            return Plan(template: .bigValue, items: [], headline: root, heading: root.title)
        }
        let count = WidgetMetrics.capacity(template, family)
        return Plan(template: template, items: Array(all.prefix(count)), headline: nil, heading: nil)
    }

    private func header(_ snapshot: SharedShelf.Snapshot, title: String?, accent: Color) -> some View {
        let stale = snapshot.staleAfter.map { entry.date >= $0 } ?? false
        return HStack(spacing: 5) {
            if let icon = snapshot.icon {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundStyle(accent)
                    .widgetAccentable()
            }
            // An item shown alone is named by itself ("chatgpt@codex"); the
            // widget's name is then the context.
            Text(title ?? snapshot.name)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if stale, let updated = snapshot.updatedAt {
                // Only an old reading says how old it is; the small size has
                // room for the clock alone beside the name.
                HStack(spacing: 3) {
                    Image(systemName: "clock.arrow.circlepath")
                    if family != .systemSmall {
                        Text(updated, style: .relative)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.orange)
                .lineLimit(1)
                .layoutPriority(-1)
            }
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
