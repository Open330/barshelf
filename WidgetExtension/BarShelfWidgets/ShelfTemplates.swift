import AppKit
import MenubucketCore
import SwiftUI
import WidgetKit

// The desktop widget's layouts (R14-B). Each draws item summaries — title,
// value, fraction, tone, detail — the way macOS's own widgets do: one focus,
// three levels of type at most, no cards inside the widget, and every state
// told by shape and text as well as colour, so the dimmed desktop rendering
// still reads.

/// An item as a template receives it.
struct TemplateItem: Identifiable {
    let id: String
    let summary: SharedShelf.Summary
    /// The section it came from ("Codex"), for headings in the large size.
    let group: String?
    /// Its exported thumbnail, already resolved to a file.
    let thumbnail: URL?
}

enum WidgetMetrics {
    /// How many items each layout shows at each size.
    static func capacity(_ template: SharedShelf.Template, _ family: WidgetFamily) -> Int {
        switch (template, family) {
        case (.bigValue, _): return 1
        case (.grid, .systemSmall): return 4
        case (.grid, .systemMedium): return 4
        case (.grid, .systemExtraLarge): return 12
        case (_, .systemExtraLarge): return 14
        case (.grid, _): return 12
        case (.meters, .systemSmall): return 3
        case (_, .systemSmall): return 3
        case (.meters, .systemMedium): return 3
        case (_, .systemMedium): return 4
        default: return 7
        }
    }
}

extension WidgetFamily {
    /// Large and extra large: room for headings and a line of detail.
    var isRoomy: Bool { self == .systemLarge || self == .systemExtraLarge }
    /// Extra large lays rows out in two columns.
    var columnCount: Int { self == .systemExtraLarge ? 2 : 1 }
}

// MARK: - Big value

struct BigValueTemplate: View {
    let summary: SharedShelf.Summary
    let accent: Color
    let family: WidgetFamily

    var body: some View {
        let (number, unit) = splitValue(summary.value)
        let tone = WidgetPalette.color(summary.tone, accent: accent) ?? .primary
        VStack(alignment: .leading, spacing: 4) {
            if let number {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(number)
                        .font(.system(size: family == .systemSmall ? 40 : 48, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(tone == .secondary ? .primary : tone)
                        .lineLimit(1)
                        .minimumScaleFactor(0.4)
                        .widgetAccentable()
                    if let unit {
                        Text(unit)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            if let detail = summary.detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(family == .systemSmall ? 2 : 3)
            }
            Spacer(minLength: 0)
            if let fraction = summary.fraction {
                MeterBar(fraction: fraction, tone: tone)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// "97% left" → ("97%", "left"); "18%" → ("18%", nil); "Discharging" → whole.
func splitValue(_ value: String?) -> (String?, String?) {
    guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return (nil, nil) }
    let parts = value.split(separator: " ", maxSplits: 1).map(String.init)
    if parts.count == 2, parts[0].contains(where: \.isNumber), parts[0].count <= 8 {
        return (parts[0], parts[1])
    }
    return (value, nil)
}

// MARK: - Meters

struct MetersTemplate: View {
    let items: [TemplateItem]
    let accent: Color
    let family: WidgetFamily

    var body: some View {
        if family == .systemSmall, items.allSatisfy({ $0.summary.fraction != nil }) {
            rings
        } else {
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 18, alignment: .top), count: family.columnCount),
                alignment: .leading, spacing: family.isRoomy ? 10 : 7
            ) {
                ForEach(items) { item in row(item.summary) }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var rings: some View {
        HStack(alignment: .top, spacing: 6) {
            ForEach(items) { item in
                let tone = WidgetPalette.color(item.summary.tone, accent: accent) ?? accent
                VStack(spacing: 4) {
                    ZStack {
                        Circle().stroke(Color.primary.opacity(0.12), lineWidth: 4)
                        Circle()
                            .trim(from: 0, to: item.summary.fraction ?? 0)
                            .stroke(tone, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .widgetAccentable()
                        Text(shortNumber(item.summary.value))
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .minimumScaleFactor(0.6)
                    }
                    .frame(width: 38, height: 38)
                    Text(item.summary.title ?? "")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxHeight: .infinity, alignment: .center)
    }

    private func row(_ summary: SharedShelf.Summary) -> some View {
        let tone = WidgetPalette.color(summary.tone, accent: accent)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(summary.title ?? "")
                    .font(.caption)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(summary.value ?? "")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(tone == .secondary ? .primary : (tone ?? .primary))
                    .lineLimit(1)
            }
            if let fraction = summary.fraction {
                MeterBar(fraction: fraction, tone: tone ?? accent)
            }
        }
    }
}

/// "97% left" → "97%"; "6%" → "6%"; "—" stays.
func shortNumber(_ value: String?) -> String {
    splitValue(value).0 ?? "—"
}

// MARK: - List

struct ListTemplate: View {
    let items: [TemplateItem]
    let accent: Color
    let family: WidgetFamily

    var body: some View {
        // Extra large: the same list in two columns, split in the middle.
        let half = (items.count + 1) / 2
        let columns = family.columnCount == 2 && items.count > 4
            ? [Array(items.prefix(half)), Array(items.dropFirst(half))]
            : [items]
        HStack(alignment: .top, spacing: 18) {
            ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                VStack(alignment: .leading, spacing: family.isRoomy ? 8 : 6) {
                    ForEach(Array(column.enumerated()), id: \.element.id) { index, item in
                        if family.isRoomy, let group = item.group, index == 0 || column[index - 1].group != group {
                            Text(group)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.top, index == 0 ? 0 : 2)
                        }
                        row(item.summary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func row(_ summary: SharedShelf.Summary) -> some View {
        let tone = WidgetPalette.color(summary.tone, accent: accent)
        let trailing = summary.value.map(shortNumber) ?? summary.status
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 7) {
                leading(summary)
                Text(summary.title ?? "")
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                if let trailing {
                    Text(trailing)
                        .font(.caption.weight(summary.value != nil ? .semibold : .regular))
                        .monospacedDigit()
                        .foregroundStyle(summary.value != nil ? (tone == .secondary ? .primary : (tone ?? .primary)) : .secondary)
                        .lineLimit(1)
                }
            }
            if let fraction = summary.fraction {
                MeterBar(fraction: fraction, tone: tone ?? accent, height: 3)
                    .padding(.leading, 21)
            }
            if family.isRoomy, let line = summary.detail ?? summary.subtitle {
                Text(line)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.leading, 21)
            }
        }
    }

    /// A status dot, a symbol, or the title's initial — never an empty shape.
    @ViewBuilder
    private func leading(_ summary: SharedShelf.Summary) -> some View {
        if let dot = summary.dotTone {
            Circle()
                .fill(WidgetPalette.color(dot, accent: accent) ?? .secondary)
                .frame(width: 7, height: 7)
                .frame(width: 14)
                .widgetAccentable()
        } else if let symbol = summary.symbol {
            Image(systemName: symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 14)
        } else {
            // An initial on the item's colour: red when it is in trouble,
            // otherwise the widget's accent.
            Text(String((summary.title ?? "•").prefix(1)).uppercased())
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 14, height: 14)
                .background(Circle().fill(["danger", "red"].contains(summary.tone) ? Color.red : accent))
                .widgetAccentable()
        }
    }
}

// MARK: - Grid

struct GridTemplate: View {
    let items: [TemplateItem]
    let family: WidgetFamily

    var body: some View {
        let columns = family == .systemSmall ? 2 : family == .systemExtraLarge ? 6 : 4
        let spacing: CGFloat = family == .systemSmall ? 5 : 8
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: spacing, alignment: .top), count: columns),
            alignment: .leading, spacing: spacing
        ) {
            ForEach(items) { item in
                VStack(spacing: 3) {
                    // A square cell the picture fills and is cut to.
                    Color.clear
                        .aspectRatio(1, contentMode: .fit)
                        .overlay { thumbnail(item) }
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    if family != .systemSmall {
                        Text(shortFileName(item.summary.title ?? ""))
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .truncationMode(.middle)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func thumbnail(_ item: TemplateItem) -> some View {
        if let url = item.thumbnail, let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.08))
                Image(systemName: "doc")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// "Screenshot 2026-10-03 200519.png" → "Screenshot 20:05"; other names
/// lose only their extension, which the thumbnail already shows.
func shortFileName(_ name: String) -> String {
    let stem = (name as NSString).deletingPathExtension
    let pattern = #"^(.*?)[ _-]*\d{4}-\d{2}-\d{2}(?: at)?[ _-]*(\d{1,2})[.:]?(\d{2})(?:[.:]?\d{2})?(?: ?[AP]M)?(?: \(\d+\))?$"#
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: stem, range: NSRange(stem.startIndex..., in: stem)),
          let prefix = Range(match.range(at: 1), in: stem),
          let hour = Range(match.range(at: 2), in: stem),
          let minute = Range(match.range(at: 3), in: stem)
    else { return stem }
    let lead = stem[prefix].trimmingCharacters(in: .whitespaces)
    return (lead.isEmpty ? "" : lead + " ") + "\(stem[hour]):\(stem[minute])"
}

// MARK: - Pieces

/// The thin capsule meter every template uses.
struct MeterBar: View {
    let fraction: Double
    let tone: Color
    var height: CGFloat = 5

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule()
                    .fill(tone)
                    .frame(width: max(height, proxy.size.width * min(max(fraction, 0), 1)))
                    .widgetAccentable()
            }
        }
        .frame(height: height)
    }
}
