import MenubucketCore
import SwiftUI
import WidgetKit

/// Draws a BarShelf view tree inside a macOS widget.
///
/// A smaller sibling of the app's `ViewTreeRenderer`: widgets cannot scroll,
/// take clicks on parts of themselves, load images from the network, or run
/// a 1 Hz timer, so (R14 §2):
/// - `scroll` shows its content clipped, `list` its first rows, `grid` a
///   fixed grid;
/// - countdowns use the system timer views, which tick without reloads;
/// - images other than SF Symbols and monograms fall back to a monogram;
/// - buttons become plain labels — the whole widget opens BarShelf.
struct WidgetNodeView: View {
    let node: UINode
    let accent: Color
    /// Rows a `list` or `grid` shows before it is cut.
    var rowLimit: Int = 8

    var body: some View {
        if node.hidden == true {
            EmptyView()
        } else {
            content
                .padding(.all, node.padding ?? 0)
                .frame(maxWidth: node.widthFill == true ? .infinity : nil, alignment: .leading)
        }
    }

    private func child(_ node: UINode) -> WidgetNodeView {
        WidgetNodeView(node: node, accent: accent, rowLimit: rowLimit)
    }

    private func children(_ nodes: [UINode]) -> some View {
        ForEach(Array(nodes.enumerated()), id: \.offset) { _, node in child(node) }
    }

    @ViewBuilder
    private var content: some View {
        switch UINode.KnownType(rawValue: node.type) {
        case .vstack:
            VStack(alignment: .leading, spacing: node.spacing ?? 6) { children(node.children ?? []) }
        case .hstack:
            HStack(alignment: hstackAlignment, spacing: node.spacing ?? 6) { children(node.children ?? []) }
        case .zstack:
            ZStack { children(node.children ?? []) }
        case .scroll:
            if let inner = node.child?.node { child(inner) }
        case .list:
            VStack(alignment: .leading, spacing: node.spacing ?? 4) {
                children(Array((node.items ?? node.children ?? []).prefix(rowLimit)))
            }
        case .grid:
            grid
        case .section:
            VStack(alignment: .leading, spacing: node.spacing ?? 4) {
                if let title = node.title {
                    Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                children(node.children ?? [])
            }
        case .card:
            let color = WidgetPalette.color(node.tone ?? node.tint, accent: accent) ?? accent
            VStack(alignment: .leading, spacing: node.spacing ?? 6) { children(node.children ?? []) }
                .padding(node.padding ?? 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(color.opacity(0.10)))
        case .text:
            text
        case .image:
            image
        case .progress:
            progress
        case .button:
            // The widget as a whole opens BarShelf; a button is just its label.
            Label(node.title ?? node.text ?? "", systemImage: node.icon ?? "arrow.up.forward.app")
                .font(.caption)
                .foregroundStyle(accent)
        case .badge:
            let color = WidgetPalette.color(node.tint ?? node.tone, accent: accent) ?? .secondary
            Text(node.text ?? node.title ?? "")
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .foregroundStyle(color)
                .background(Capsule().fill(color.opacity(0.15)))
        case .banner:
            let color = WidgetPalette.color(node.tone ?? node.tint, accent: accent) ?? .orange
            Label(node.text ?? node.title ?? "", systemImage: node.icon ?? "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(color)
        case .empty:
            VStack(spacing: 4) {
                if let icon = node.icon { Image(systemName: icon).foregroundStyle(.secondary) }
                if let title = node.title { Text(title).font(.caption.weight(.semibold)) }
                if let subtitle = node.subtitle {
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
        case .divider:
            Divider()
        case .spacer:
            Spacer(minLength: node.minLength ?? 0)
        case .some(.none), nil:
            EmptyView()
        }
    }

    private var hstackAlignment: VerticalAlignment {
        switch node.alignment {
        case "top": return .top
        case "bottom": return .bottom
        case "baseline": return .firstTextBaseline
        default: return .center
        }
    }

    // MARK: - Leaves

    private var text: some View {
        var font: Font
        var color: Color? = WidgetPalette.color(node.foreground, accent: accent)
        switch node.role {
        case "title": font = .system(size: 13, weight: .semibold)
        case "caption": font = .caption; color = color ?? .secondary
        case "code": font = .system(size: 11, design: .monospaced)
        default: font = .system(size: 12)
        }
        if let size = node.size {
            font = .system(
                size: CGFloat(size),
                weight: node.role == "title" ? .bold : .regular,
                design: node.role == "code" ? .monospaced : .default
            )
        }
        if node.monospacedDigit == true { font = font.monospacedDigit() }
        return Text(node.text ?? "")
            .font(font)
            .foregroundStyle(color ?? .primary)
            .lineLimit(node.lineLimit ?? 2)
            .minimumScaleFactor(0.7)
    }

    @ViewBuilder
    private var image: some View {
        let size = CGFloat(node.size ?? 14)
        if let source = node.source, source.kind == "sfSymbol", let name = source.name {
            Image(systemName: name)
                .font(.system(size: size))
                .foregroundStyle(WidgetPalette.color(node.tint ?? node.foreground, accent: accent) ?? .primary)
        } else {
            // Files, thumbnails, remote images, and brand marks need the app;
            // a monogram keeps the row's shape.
            let letter = node.source?.monogram ?? node.source?.name ?? node.accessibilityLabel ?? "•"
            Text(String(letter.prefix(1)).uppercased())
                .font(.system(size: size * 0.55, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(Circle().fill(WidgetPalette.color(node.tint, accent: accent) ?? accent))
        }
    }

    @ViewBuilder
    private var progress: some View {
        let tint = WidgetPalette.color(node.tint, accent: accent) ?? accent
        if let countdown = node.countdown {
            // The system timer views tick on their own, with no reloads.
            let interval = Date(timeIntervalSince1970: countdown.from / 1000)...Date(timeIntervalSince1970: max(countdown.from, countdown.until) / 1000)
            if node.style == "ring" {
                ProgressView(timerInterval: interval, countsDown: true) { EmptyView() } currentValueLabel: { EmptyView() }
                    .progressViewStyle(.circular)
                    .tint(tint)
                    .frame(width: CGFloat(node.size ?? 26))
            } else {
                HStack(spacing: 6) {
                    if let label = node.label {
                        Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    ProgressView(timerInterval: interval, countsDown: true) { EmptyView() } currentValueLabel: { EmptyView() }
                        .tint(tint)
                }
            }
        } else if node.style == "ring" {
            let diameter = CGFloat(node.size ?? 26)
            ZStack {
                Circle().stroke(Color.primary.opacity(0.12), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: min(max(node.value ?? 0, 0), 1))
                    .stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .widgetAccentable()
            }
            .frame(width: diameter, height: diameter)
        } else {
            HStack(spacing: 6) {
                if let label = node.label {
                    Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                // The app's meter: a capsule track and fill, tinted the same.
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.10))
                        Capsule()
                            .fill(tint)
                            .frame(width: max(4, proxy.size.width * min(max(node.value ?? 0, 0), 1)))
                            .widgetAccentable()
                    }
                }
                .frame(height: 6)
            }
        }
    }

    private var grid: some View {
        let items = Array((node.items ?? node.children ?? []).prefix(rowLimit * max(node.columns ?? 3, 1)))
        let columns = Array(
            repeating: GridItem(.flexible(), spacing: node.spacing ?? 8),
            count: max(node.columns ?? 3, 1)
        )
        return LazyVGrid(columns: columns, alignment: .center, spacing: node.spacing ?? 8) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                child(item).frame(maxWidth: .infinity)
            }
        }
    }
}

/// BarShelf's color names, as widgets draw them. Mirrors `nodeColor` and
/// `WidgetAppearance.accentColor` in the app.
enum WidgetPalette {
    static func color(_ name: String?, accent: Color = .accentColor) -> Color? {
        guard let raw = name?.trimmingCharacters(in: .whitespaces).lowercased(), !raw.isEmpty else { return nil }
        switch raw {
        case "primary": return .primary
        case "secondary": return .secondary
        case "tertiary": return .secondary.opacity(0.6)
        case "accent": return accent
        case "good", "green": return .green
        case "warning", "orange": return .orange
        case "danger", "red": return .red
        case "neutral", "gray", "grey": return .gray
        case "blue": return .blue
        case "purple": return .purple
        case "pink": return .pink
        case "yellow": return .yellow
        case "default": return nil
        default:
            return hex(raw)
        }
    }

    private static func hex(_ value: String) -> Color? {
        let digits = value.hasPrefix("#") ? String(value.dropFirst()) : value
        guard digits.count == 6, let number = UInt32(digits, radix: 16) else { return nil }
        return Color(
            red: Double((number >> 16) & 0xFF) / 255,
            green: Double((number >> 8) & 0xFF) / 255,
            blue: Double(number & 0xFF) / 255
        )
    }
}
