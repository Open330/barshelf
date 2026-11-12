import MenubucketCore
import SwiftUI

// Settings pages share one frame: the page's own header (the sidebar tile,
// its name and what it is for), an optional row of big summary figures, and
// then the grouped form, held to a readable width. The window toolbar keeps
// only the page name.

enum SettingsMetrics {
    /// The form's readable width; wider windows centre it.
    static let contentWidth: CGFloat = 660
    /// The tile beside a page's name.
    static let headerTile: CGFloat = 44
    /// The tile in a one-line page header (the Shelf, the Gallery, Create).
    static let compactHeaderTile: CGFloat = 32
}

/// A figure under a settings page's header: 13 Allowed, 2 Waiting.
struct SettingsStat: Identifiable {
    let value: String
    let label: String
    /// Colours the figure when it needs attention; nil keeps it plain.
    var tone: StatusTone?

    var id: String { label }
}

/// One settings page: the page header, then a single grouped form, the way
/// System Settings lays out a pane. No page nests another picker inside it
/// (R13 §4.1).
struct SettingsPage<Content: View>: View {
    var tab: HubTab?
    var stats: [SettingsStat]
    @ViewBuilder var content: Content

    init(_ tab: HubTab? = nil, stats: [SettingsStat] = [], @ViewBuilder content: () -> Content) {
        self.tab = tab
        self.stats = stats
        self.content = content()
    }

    var body: some View {
        GeometryReader { proxy in
            Form {
                if let tab {
                    // A section header, not a row: a grouped form boxes every
                    // row, and the page's header should sit on the window.
                    Section {
                        EmptyView()
                    } header: {
                        SettingsHeader(tab: tab, stats: stats)
                            .textCase(nil)
                            .foregroundStyle(.primary)
                    }
                }
                content
            }
            .formStyle(.grouped)
            // Centre a readable column but keep the scroll view (and its
            // scroller) the full width of the window.
            .contentMargins(.horizontal, Self.margin(for: proxy.size.width), for: .scrollContent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    static func margin(for width: CGFloat) -> CGFloat {
        max(0, (width - SettingsMetrics.contentWidth) / 2)
    }
}

/// The page's tile, name and purpose, and its summary figures.
struct SettingsHeader: View {
    let tab: HubTab
    var stats: [SettingsStat] = []

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            HStack(spacing: Spacing.s) {
                CardIconTile(symbol: tab.symbol, color: tab.tint, size: SettingsMetrics.headerTile)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Spacing.hair) {
                    Text(tab.title)
                        .font(.title2.weight(.bold))
                        .accessibilityAddTraits(.isHeader)
                    Text(tab.subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !stats.isEmpty {
                HStack(spacing: Spacing.xs) {
                    ForEach(stats) { SettingsStatTile(stat: $0) }
                }
            }
        }
        .padding(.top, Spacing.xs)
        .padding(.bottom, Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A page's header in one compact line, for the pages that are not a
/// settings form (the Shelf, Create): the same tile, name and purpose as a
/// settings page has, and a short summary on the trailing side, so the
/// page's own content starts high in the window.
struct CompactPageHeader: View {
    let tab: HubTab
    var summary: String?

    var body: some View {
        HStack(alignment: .center, spacing: Spacing.s) {
            CardIconTile(symbol: tab.symbol, color: tab.tint, size: SettingsMetrics.compactHeaderTile)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(tab.title)
                    .font(.title3.weight(.bold))
                    .accessibilityAddTraits(.isHeader)
                Text(tab.subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Spacing.s)
            if let summary {
                Text(summary)
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A summary figure on its own tile: big rounded digits, a caption below.
struct SettingsStatTile: View {
    let stat: SettingsStat

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.hair) {
            Text(stat.value)
                .font(Typography.metric(.compact))
                .tracking(Typography.metricTracking(.compact))
                .foregroundStyle(stat.tone?.color ?? .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(stat.label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Spacing.s)
        .padding(.vertical, Spacing.xs + Spacing.hair)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(radius: Radius.control)
        .accessibilityElement(children: .combine)
    }
}

/// What a widget may do, as a compact chip: its symbol and a short phrase.
/// Sensitive access (secrets, the vault, environment variables, quitting
/// apps) takes the Privacy page's colour: notable, not an error. Access the
/// widget uses without declaring it is a warning, since it will be blocked.
struct PermissionChip: View {
    let line: WidgetPermissionSummary.Line

    var body: some View {
        Label {
            Text(line.text)
                .lineLimit(1)
                .truncationMode(.middle)
        } icon: {
            Image(systemName: line.symbol)
                .imageScale(.small)
        }
        .labelStyle(ChipLabelStyle())
        .font(.caption)
        .foregroundStyle(tint ?? .secondary)
        .padding(.horizontal, Spacing.xs)
        .padding(.vertical, Spacing.hair)
        .background(Capsule().fill(tint.map { $0.opacity(Fill.Wash.soft) } ?? Fill.hover))
        .help(line.help.map { "\(line.text)\n\($0)" } ?? line.text)
    }

    private var tint: Color? {
        switch line.tone {
        case .normal: return nil
        case .sensitive: return HubTab.privacy.tint
        case .blocked: return StatusTone.warning.color
        }
    }

    private struct ChipLabelStyle: LabelStyle {
        func makeBody(configuration: Configuration) -> some View {
            HStack(spacing: Spacing.xxs) {
                configuration.icon
                configuration.title
            }
        }
    }
}

/// Lays children out left to right, wrapping to a new line when a row is
/// full. For chips, whose count and widths vary.
struct FlowLayout: Layout {
    var spacing: CGFloat = Spacing.xxs

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil))
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

extension View {
    /// A settings section's title. Set explicitly: a grouped form draws the
    /// first title after the page header small and grey, the rest bold.
    func settingsSectionTitle() -> some View {
        font(.headline)
            .foregroundStyle(.primary)
            .textCase(nil)
    }
}
