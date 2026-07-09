import MenubucketCore
import SwiftUI

// MARK: - Action environment

/// Per-widget action context injected into the rendered tree so buttons can
/// route their `NodeAction` back to the runtime.
struct ActionContext {
    var widgetID: String = ""
    var perform: (NodeAction) -> Void = { _ in }
}

private struct ActionContextKey: EnvironmentKey {
    static let defaultValue = ActionContext()
}

extension EnvironmentValues {
    var actionContext: ActionContext {
        get { self[ActionContextKey.self] }
        set { self[ActionContextKey.self] = newValue }
    }
}

// MARK: - Appearance environment (R12)

private struct WidgetAppearanceKey: EnvironmentKey {
    static let defaultValue = WidgetAppearance()
}

extension EnvironmentValues {
    /// Effective theming for the widget currently being rendered. The default
    /// is neutral (`WidgetAppearance()`), so an un-injected tree renders exactly
    /// as it did before theming existed. The popup injects
    /// `prefs.effectiveAppearance(for:)` here.
    var widgetAppearance: WidgetAppearance {
        get { self[WidgetAppearanceKey.self] }
        set { self[WidgetAppearanceKey.self] = newValue }
    }
}

extension WidgetAppearance {
    /// App-side mapping of the `accent` string to a SwiftUI color. Returns nil
    /// for an absent/unrecognized value so callers fall back to the system
    /// accent — which keeps neutral appearance pixel-identical to today.
    var accentColor: Color? {
        guard let accent = accent?.trimmingCharacters(in: .whitespaces),
              !accent.isEmpty else { return nil }
        if accent.hasPrefix("#") { return Color(hex: accent) }
        switch accent.lowercased() {
        case "default": return nil
        case "blue": return .blue
        case "purple": return .purple
        case "pink": return .pink
        case "red": return .red
        case "orange": return .orange
        case "yellow": return .yellow
        case "green": return .green
        case "gray", "grey": return .gray
        default: return nil
        }
    }
}

extension Color {
    /// Parses `"#RRGGBB"` (case-insensitive, `#` optional). Nil on malformed input.
    init?(hex: String) {
        var string = hex
        if string.hasPrefix("#") { string.removeFirst() }
        guard string.count == 6, let value = UInt32(string, radix: 16) else { return nil }
        self.init(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

// MARK: - Renderer

/// Recursive UINode → SwiftUI renderer (v0).
struct ViewTreeRenderer: View {
    let node: UINode

    var body: some View {
        NodeView(node: node)
    }
}

private struct IdentifiedNode: Identifiable {
    let id: String
    let node: UINode
}

/// Stable identity: prefer explicit node `id`, fall back to positional index.
private func identified(_ nodes: [UINode]) -> [IdentifiedNode] {
    nodes.enumerated().map { index, node in
        IdentifiedNode(id: node.id ?? "#\(index)", node: node)
    }
}

struct NodeChildrenView: View {
    let nodes: [UINode]

    var body: some View {
        ForEach(identified(nodes)) { item in
            NodeView(node: item.node)
        }
    }
}

struct NodeView: View {
    let node: UINode
    @Environment(\.actionContext) private var actionContext
    @Environment(\.widgetAppearance) private var appearance

    /// Custom accent color, or nil when the widget uses the system accent.
    private var accentOverride: Color? { appearance.accentColor }
    /// The accent to draw with: custom when set, else the system accent (so a
    /// neutral appearance is unchanged).
    private var effectiveAccent: Color { appearance.accentColor ?? .accentColor }
    /// Compact density shrinks paddings, spacing and text ≈15%. Regular = 1.0
    /// so a neutral appearance renders identically.
    private var scale: Double { (appearance.density ?? .regular) == .compact ? 0.85 : 1 }

    var body: some View {
        // Explicit widget-author label (VoiceOver). When absent, keep the
        // default behavior of each leaf (decorative symbols, file-name
        // thumbnails, etc.).
        if let label = node.accessibilityLabel {
            decorated.accessibilityLabel(label)
        } else {
            decorated
        }
    }

    @ViewBuilder
    private var decorated: some View {
        if let drag = node.drag {
            // Drag-out surface: hand a file URL to Finder / other apps.
            content
                .modifier(NodeLayoutModifier(node: node))
                .onDrag { NSItemProvider(object: URL(fileURLWithPath: drag.filePath) as NSURL) }
        } else {
            content
                .modifier(NodeLayoutModifier(node: node))
        }
    }

    @ViewBuilder
    private var content: some View {
        switch UINode.KnownType(rawValue: node.type) {
        case .vstack:
            VStack(alignment: .leading, spacing: (node.spacing ?? 6) * scale) {
                NodeChildrenView(nodes: node.children ?? [])
            }
        case .hstack:
            HStack(alignment: .center, spacing: (node.spacing ?? 6) * scale) {
                NodeChildrenView(nodes: node.children ?? [])
            }
        case .list:
            VStack(alignment: .leading, spacing: (node.spacing ?? 4) * scale) {
                NodeChildrenView(nodes: node.items ?? node.children ?? [])
            }
        case .section:
            sectionView
        case .card:
            cardView
        case .text:
            textView
        case .image:
            imageView
        case .progress:
            progressView
        case .button:
            buttonView
        case .badge:
            badgeView
        case .banner:
            bannerView
        case .empty:
            emptyView
        case .divider:
            Divider()
        case .spacer:
            Spacer(minLength: 0)
        case nil:
            unsupportedView
        }
    }

    // MARK: - Leaf views

    private var sectionView: some View {
        VStack(alignment: .leading, spacing: (node.spacing ?? 4) * scale) {
            if let title = node.title {
                Text(title)
                    .font(.system(size: 11 * scale, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            NodeChildrenView(nodes: node.children ?? [])
        }
    }

    private var cardView: some View {
        let color = nodeColor(node.tone ?? node.tint, accent: accentOverride) ?? effectiveAccent
        return VStack(alignment: .leading, spacing: (node.spacing ?? 6) * scale) {
            NodeChildrenView(nodes: node.children ?? [])
        }
        .padding(node.padding ?? 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(color.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(color.opacity(0.18), lineWidth: 1)
        )
    }

    private var textView: some View {
        var text = Text(node.text ?? "")
        var font: Font
        var defaultColor: Color? = nil
        switch node.role {
        case "title":
            font = .system(size: 13 * scale, weight: .semibold)
        case "caption":
            font = .caption
            defaultColor = .secondary
        case "code":
            font = .system(size: 11 * scale, design: .monospaced)
        default: // "body"
            font = .system(size: 12 * scale)
        }
        if node.monospacedDigit == true {
            font = font.monospacedDigit()
        }
        text = text.font(font)
        if let color = nodeColor(node.foreground, accent: accentOverride) ?? defaultColor {
            text = text.foregroundColor(color)
        }
        return text
            .lineLimit(node.lineLimit)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var imageView: some View {
        if let source = node.source, source.kind == "sfSymbol", let name = source.name {
            Image(systemName: name)
                .font(.system(size: node.size ?? 13))
                .foregroundColor(nodeColor(node.tint ?? node.foreground, accent: accentOverride) ?? .primary)
        } else if let source = node.source,
                  source.kind == "fileIcon" || source.kind == "fileThumbnail",
                  let path = source.path {
            FileImageView(source: source, path: path, pointSize: CGFloat(node.size ?? 28))
        } else {
            Image(systemName: "questionmark.square.dashed")
                .foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    private var progressView: some View {
        if node.countdown != nil {
            // Countdown nodes tick 1 Hz on the host side (TimelineView); the
            // timeline pauses automatically while the popup is not visible.
            CountdownProgressView(node: node)
        } else if node.style == "ring" {
            RingProgressView(
                fraction: min(max(node.value ?? 0, 0), 1),
                tint: nodeColor(node.tint, accent: accentOverride) ?? effectiveAccent,
                centerText: nil,
                diameter: CGFloat(node.size ?? 26)
            )
        } else {
            HStack(spacing: 6) {
                if let label = node.label {
                    Text(label)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                LinearMeter(
                    fraction: min(max(node.value ?? 0, 0), 1),
                    tint: nodeColor(node.tint, accent: accentOverride) ?? effectiveAccent
                )
            }
        }
    }

    private var buttonView: some View {
        Button {
            if let action = node.action {
                actionContext.perform(action)
            }
        } label: {
            HStack(spacing: 4) {
                if let icon = node.icon {
                    Image(systemName: icon)
                }
                if let title = node.title ?? node.text {
                    Text(title)
                }
            }
            .font(.system(size: 12))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .modifier(AccentTint(color: accentOverride))
    }

    private var badgeView: some View {
        let color = nodeColor(node.tint ?? node.tone, accent: accentOverride) ?? .secondary
        return Text(node.text ?? node.title ?? "")
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundColor(color)
            .background(Capsule().fill(color.opacity(0.15)))
    }

    private var bannerView: some View {
        let color = nodeColor(node.tone ?? node.tint, accent: accentOverride) ?? .orange
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: node.icon ?? "exclamationmark.triangle.fill")
                .foregroundColor(color)
            Text(node.text ?? node.title ?? "")
                .font(.caption)
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(color.opacity(0.12)))
    }

    private var emptyView: some View {
        VStack(spacing: 6) {
            if let icon = node.icon {
                Image(systemName: icon)
                    .font(.system(size: 24))
                    .foregroundColor(.secondary)
            }
            if let title = node.title {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
            }
            if let subtitle = node.subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    private var unsupportedView: some View {
        Text("⚠︎ unsupported: \(node.type)")
            .font(.caption)
            .foregroundColor(.secondary)
            .padding(4)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.1)))
    }
}

// MARK: - Countdown progress (host-driven 1 Hz tick)

/// Renders a `progress` node with a `countdown` window. The host re-evaluates
/// remaining time every second via `TimelineView` — no script re-run needed.
/// Ticks stop when the view leaves the window (popup closed).
private struct CountdownProgressView: View {
    let node: UINode
    @Environment(\.widgetAppearance) private var appearance

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let nowMs = timeline.date.timeIntervalSince1970 * 1000
            let fraction = node.countdownFraction(nowMs: nowMs) ?? 0
            let remaining = node.countdownRemainingSeconds(nowMs: nowMs) ?? 0
            let tint = nodeColor(node.countdownTint(nowMs: nowMs), accent: appearance.accentColor)
                ?? (appearance.accentColor ?? .accentColor)
            let remainingText = node.labelFrom == "remainingSeconds"
                ? String(Int(remaining.rounded(.down)))
                : nil

            if node.style == "ring" {
                RingProgressView(
                    fraction: fraction,
                    tint: tint,
                    centerText: remainingText,
                    diameter: CGFloat(node.size ?? 26)
                )
            } else {
                HStack(spacing: 6) {
                    if let label = node.label {
                        Text(label)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    LinearMeter(fraction: fraction, tint: tint)
                    if let remainingText {
                        Text(remainingText + "s")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
    }
}

/// Linear meter as a custom capsule (track + fill) rather than `ProgressView`.
/// A capsule renders correctly offscreen (ImageRenderer) and honors the exact
/// tint, where the AppKit-backed `.linear` ProgressView does neither.
private struct LinearMeter: View {
    let fraction: Double
    let tint: Color
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule().fill(tint)
                    .frame(width: max(height, geo.size.width * CGFloat(min(max(fraction, 0), 1))))
            }
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
    }
}

/// Circular progress: background track + trimmed arc, optional center label.
private struct RingProgressView: View {
    let fraction: Double
    let tint: Color
    let centerText: String?
    let diameter: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.25), lineWidth: 3)
            Circle()
                .trim(from: 0, to: CGFloat(min(max(fraction, 0), 1)))
                .stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if let centerText {
                Text(centerText)
                    .font(.system(size: max(diameter * 0.36, 8), weight: .medium))
                    .monospacedDigit()
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
        }
        .frame(width: diameter, height: diameter)
        .padding(2)
    }
}

// MARK: - Common layout modifiers

private struct NodeLayoutModifier: ViewModifier {
    let node: UINode
    @Environment(\.widgetAppearance) private var appearance

    private var scale: Double { (appearance.density ?? .regular) == .compact ? 0.85 : 1 }

    func body(content: Content) -> some View {
        content
            .padding(.all, node.padding.map { $0 * scale } ?? 0)
            .frame(
                maxWidth: node.widthFill == true ? .infinity : nil,
                alignment: .leading
            )
    }
}

// MARK: - Color mapping

/// Maps semantic color names from the view-tree contract to SwiftUI colors.
/// When `accent` is supplied, the semantic `"accent"` name resolves to it (the
/// widget's custom accent); otherwise it falls back to the system accent, so an
/// un-themed call is unchanged.
func nodeColor(_ name: String?, accent: Color? = nil) -> Color? {
    switch name {
    case "primary": return .primary
    case "secondary": return .secondary
    case "tertiary": return Color(nsColor: .tertiaryLabelColor)
    case "accent": return accent ?? .accentColor
    case "good": return .green
    case "warning": return .orange
    case "danger": return .red
    case "neutral": return .gray
    default: return nil
    }
}

/// Applies a custom accent tint only when one is set. A nil color leaves the
/// view untouched so neutral appearance keeps the system accent unchanged.
private struct AccentTint: ViewModifier {
    let color: Color?

    func body(content: Content) -> some View {
        if let color {
            content.tint(color)
        } else {
            content
        }
    }
}

// MARK: - File images (fileIcon / fileThumbnail)

/// Renders instantly with the file's icon, then swaps in the QuickLook
/// thumbnail when the service delivers it. Loads happen only while the view
/// is on screen, so a closed popup never prefetches.
private struct FileImageView: View {
    let source: ImageSource
    let path: String
    let pointSize: CGFloat

    @State private var thumbnail: NSImage?

    var body: some View {
        Image(nsImage: thumbnail ?? ThumbnailService.shared.icon(forPath: path))
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: pointSize, height: pointSize)
            .cornerRadius(3)
            .accessibilityLabel((path as NSString).lastPathComponent)
            .onAppear(perform: load)
            .onChange(of: cacheIdentity) { _ in
                thumbnail = nil
                load()
            }
    }

    /// Path + mtime — a re-render after a file change reloads the thumbnail.
    private var cacheIdentity: String {
        "\(path)-\(Int(source.modifiedAt ?? 0))"
    }

    private func load() {
        guard source.kind == "fileThumbnail" else { return }
        let expected = cacheIdentity
        let cached = ThumbnailService.shared.thumbnail(
            path: path,
            modifiedAt: source.modifiedAt,
            pointSize: pointSize
        ) { image in
            guard cacheIdentity == expected, let image else { return }
            thumbnail = image
        }
        if let cached { thumbnail = cached }
    }
}
