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
    /// Where a refresh asked for from this widget stands.
    var refresh: SharedShelf.RefreshRequestState = .none
    /// False once BarShelf no longer offers the chosen widget.
    var offered = true

    /// Asked for and not answered yet.
    var refreshing: Bool {
        if case .pending = refresh { return true }
        return false
    }

    /// Asked for, and BarShelf never sent anything back.
    var unanswered: Bool {
        if case .unanswered = refresh { return true }
        return false
    }
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
        // When a pending refresh lapses, the widget says BarShelf did not
        // answer (it is not running, or gave up) instead of going quiet. An
        // answer reloads the timeline first, so this entry is never shown then.
        if case let .pending(since) = entries[0].refresh {
            entries.append(entry(for: configuration, at: since.addingTimeInterval(SharedShelf.refreshRequestLifetime)))
        }
        // A second entry at the moment the reading turns old, so the widget
        // says so without BarShelf spending a reload on it.
        if let staleAfter = entries[0].snapshot?.staleAfter, staleAfter > now {
            entries.append(entry(for: configuration, at: staleAfter))
        }
        entries.sort { $0.date < $1.date }
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
            partKeys: keys, style: configuration.style,
            refresh: SharedContainer.refreshState(for: id, at: date),
            offered: SharedContainer.isOffered(id)
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
        .description("Shows BarShelf’s latest result. Desktop placement does not keep the source running. Open its shelf page or use Refresh to update; show the source in the menu bar or Dock for updates while the shelf is closed.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge])
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
            if entry.widgetID == nil {
                placeholder(
                    symbol: "square.grid.2x2",
                    title: String(localized: "Choose a widget"),
                    text: String(localized: "Right-click here and choose Edit Widget.")
                )
            } else if !entry.offered {
                placeholder(
                    symbol: "square.dashed",
                    title: String(localized: "Not available"),
                    text: String(localized: "BarShelf no longer offers this widget. Right-click here and choose Edit Widget.")
                )
            } else if let snapshot = entry.snapshot, snapshot.viewTree != nil || !snapshot.parts.isEmpty {
                content(snapshot)
            } else if let error = entry.snapshot?.error, !entry.unanswered {
                // Failed before it ever had a reading: the reason, and a retry.
                placeholder(
                    symbol: "exclamationmark.triangle",
                    title: String(localized: "Couldn’t refresh"),
                    text: error,
                    retry: !entry.refreshing
                )
            } else if entry.unanswered {
                placeholder(
                    symbol: Self.noAnswerSymbol,
                    title: String(localized: "BarShelf didn’t respond"),
                    text: String(localized: "Click to open BarShelf, then refresh again."),
                    retry: true
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
            if !plan.missingKeys.isEmpty {
                missingSelection(plan.missingKeys)
            } else {
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
            // The small size has the header icon alone; larger ones say why.
            if family != .systemSmall, let notice = notice(snapshot) {
                Label {
                    Text(notice).lineLimit(2)
                } icon: {
                    Image(systemName: entry.unanswered ? Self.noAnswerSymbol : "exclamationmark.triangle.fill")
                }
                .font(.caption2)
                .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    static let noAnswerSymbol = "exclamationmark.arrow.triangle.2.circlepath"

    /// Why what is shown may not be current: BarShelf never answered the
    /// refresh asked for here, or its last refresh failed (the last good
    /// reading stays). Nil while a refresh is still pending.
    private func notice(_ snapshot: SharedShelf.Snapshot) -> String? {
        if entry.refreshing { return nil }
        if entry.unanswered {
            return String(localized: "BarShelf didn’t respond. Click to open it, then refresh.")
        }
        if let error = snapshot.error, !error.isEmpty {
            return String(localized: "Couldn’t refresh. Showing the last reading: \(error)")
        }
        return nil
    }

    /// The picked items are all gone (renamed, removed, or the widget shows
    /// different ones now). Says which, and how to pick again.
    private func missingSelection(_ keys: [String]) -> some View {
        let text = keys.count == 1
            ? String(localized: "“\(SharedShelf.title(ofMissingPartKey: keys[0]))” isn’t in this widget right now. Right-click here and choose Edit Widget to pick again.")
            : String(localized: "The \(keys.count) items you picked aren’t in this widget right now. Right-click here and choose Edit Widget to pick again.")
        return placeholder(symbol: "questionmark.square.dashed", title: String(localized: "Picked item not available"), text: text)
    }

    private struct Plan {
        var template: SharedShelf.Template
        var items: [TemplateItem]
        /// The single item a big-value layout shows.
        var headline: SharedShelf.Summary?
        /// What the header names: the widget, or the one item shown.
        var heading: String?
        /// Items were picked and none of them is in the widget any more.
        var missingKeys: [String] = []
    }

    /// Which items, in which layout. Picked items in the picked order;
    /// otherwise the widget's own items (sections that hold items are left
    /// out, so nothing shows twice). The small size shows one item large
    /// unless the items are a few readings that fit as rings.
    private func layout(for snapshot: SharedShelf.Snapshot) -> Plan {
        let pool: [SharedShelf.Part]
        switch SharedShelf.selection(keys: entry.partKeys, from: snapshot.parts) {
        case let .automatic(parts), let .picked(parts):
            pool = parts
        case let .missing(keys):
            // Never someone else's items in place of the ones picked.
            return Plan(template: .list, items: [], headline: nil, heading: nil, missingKeys: keys)
        }
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

        // The user's Style, else the widget author's, else BarShelf's guess
        // — which the small size narrows to what fits.
        let authored = snapshot.preferredStyle.flatMap(SharedShelf.Template.init(rawValue:))
        var template = entry.style.template ?? authored ?? SharedShelf.automaticTemplate(for: all.map(\.summary))
        if entry.style.template == nil, authored == nil, family == .systemSmall, template == .list {
            template = .bigValue
        }
        if template == .meters, entry.style.template == nil, authored == nil, family == .systemSmall, all.count > 3 {
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
            if entry.refreshing {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(Text("Refreshing"))
            } else if let notice = notice(snapshot) {
                let symbol = entry.unanswered ? Self.noAnswerSymbol : "exclamationmark.triangle.fill"
                if family == .systemSmall, let id = entry.widgetID {
                    // The only control the small size has room for: a retry.
                    Button(intent: RefreshShelfWidgetIntent(widgetID: id)) {
                        Image(systemName: symbol)
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(notice))
                    .accessibilityHint(Text("Refresh"))
                } else {
                    Image(systemName: symbol)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .accessibilityLabel(Text(notice))
                }
            } else if stale, family == .systemSmall, let id = entry.widgetID {
                // The small size has room for the clock alone, which is also
                // its refresh button.
                Button(intent: RefreshShelfWidgetIntent(widgetID: id)) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Refresh"))
            } else if stale, let updated = snapshot.updatedAt {
                // Only an old reading says how old it is.
                HStack(spacing: 3) {
                    Image(systemName: "clock.arrow.circlepath")
                    Text(updated, style: .relative)
                }
                .font(.caption2)
                .foregroundStyle(.orange)
                .lineLimit(1)
                .layoutPriority(-1)
            }
            if !entry.refreshing, family != .systemSmall, let id = entry.widgetID {
                Button(intent: RefreshShelfWidgetIntent(widgetID: id)) {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Refresh"))
            }
        }
    }

    private func placeholder(symbol: String, title: String?, text: String, retry: Bool = false) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(spacing: 6) {
                if let title {
                    Text(title).font(.callout.weight(.semibold))
                }
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(family == .systemSmall ? 3 : 5)
            }
            .accessibilityElement(children: .combine)
            if retry, let id = entry.widgetID {
                Button(intent: RefreshShelfWidgetIntent(widgetID: id)) {
                    Label("Try Again", systemImage: "arrow.clockwise")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
