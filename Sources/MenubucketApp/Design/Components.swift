import MenubucketCore
import SwiftUI

/// A symbol or image on an accent-tinted rounded square — the mark beside a
/// page title or the app name.
struct AccentTile<Content: View>: View {
    var size: CGFloat = 30
    @ViewBuilder var content: Content

    var body: some View {
        content
            .foregroundStyle(Color.accentColor)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .fill(Color.accentColor.opacity(Fill.Wash.soft))
            )
            .accessibilityHidden(true)
    }
}

/// A count with its label underneath, for at-a-glance totals.
struct StatBadge: View {
    enum Style { case compact, tile }

    let value: String
    let label: String
    var style: Style = .compact

    var body: some View {
        VStack(spacing: style == .tile ? Spacing.hair : 0) {
            Text(value)
                .font(style == .tile ? .title3 : .callout)
                .fontWeight(.semibold)
                .fontDesign(.rounded)
                .monospacedDigit()
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: style == .tile ? nil : 54, maxWidth: style == .tile ? .infinity : nil)
        .padding(.horizontal, style == .tile ? 0 : Spacing.xs)
        .frame(height: style == .tile ? 52 : 34)
        .cardSurface(radius: Radius.control)
        .accessibilityElement(children: .combine)
    }
}

/// A message with a severity and, when there is something to do about it,
/// the action that does it.
struct StatusBanner<Actions: View>: View {
    let tone: StatusTone
    let message: String
    var symbol: String?
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
            Image(systemName: symbol ?? tone.symbol)
                .foregroundStyle(tone.color)
                .accessibilityHidden(true)
            Text(message)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            actions
                .controlSize(.small)
        }
        .padding(Spacing.xs)
        .background(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .fill(tone.color.opacity(Fill.Wash.soft))
        )
        .accessibilityElement(children: .contain)
    }
}

extension StatusBanner where Actions == EmptyView {
    init(tone: StatusTone, message: String, symbol: String? = nil) {
        self.init(tone: tone, message: message, symbol: symbol) { EmptyView() }
    }
}

extension View {
    /// The fill and hairline every card-like object in the app's own chrome
    /// shares. `dimmed` is for something present but switched off.
    func cardSurface(radius: CGFloat = Radius.card, dimmed: Bool = false) -> some View {
        background(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(dimmed ? AnyShapeStyle(Fill.card) : AnyShapeStyle(Color(nsColor: .controlBackgroundColor)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Fill.hairline, lineWidth: 1)
        )
    }
}

/// Capsule chrome for floating controls: the hover toolbar on a card, the
/// toast. Glass, so it reads as floating over whatever is under it.
struct ControlCapsule: ViewModifier {
    func body(content: Content) -> some View {
        content.glassSurface(Capsule(), elevation: .control)
    }
}

/// Glass for something that floats over other content: a HUD, toast, or
/// panel. Not for the popup itself, whose `NSPopover` already draws the
/// system's material, and not for cards, which are solid.
///
/// macOS 26 and later get the system's own glass. Before that, a material
/// with a sheen along the top and a rim lit from above stands in. Reduce
/// Transparency gets an opaque surface; Increase Contrast a 1 pt border.
struct GlassSurface<S: InsettableShape>: ViewModifier {
    let shape: S
    var elevation: Elevation = .float
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(shape.fill(Color(nsColor: .windowBackgroundColor)).elevation(elevation))
                .overlay(shape.strokeBorder(Fill.hairline, lineWidth: contrast == .increased ? 1 : 0.5))
        } else if #available(macOS 26.0, *) {
            content
                .glassEffect(.regular, in: shape)
                .overlay {
                    if contrast == .increased {
                        shape.strokeBorder(Fill.hairline, lineWidth: 1).allowsHitTesting(false)
                    }
                }
        } else {
            content
                .background(
                    shape.fill(.regularMaterial)
                        .overlay(shape.fill(LinearGradient(
                            colors: [Fill.Glass.sheen, .clear],
                            startPoint: .top,
                            endPoint: UnitPoint(x: 0.5, y: Fill.Glass.sheenDepth)
                        )))
                        .elevation(elevation)
                )
                .overlay(rim.allowsHitTesting(false))
        }
    }

    @ViewBuilder private var rim: some View {
        if contrast == .increased {
            shape.strokeBorder(Fill.hairline, lineWidth: 1)
        } else {
            shape.strokeBorder(
                LinearGradient(
                    stops: [
                        .init(color: Fill.Glass.rimHigh, location: 0),
                        .init(color: Fill.Glass.rimLow, location: 0.3),
                        .init(color: Fill.Glass.rimLow, location: 0.8),
                        .init(color: Fill.Glass.rimHigh, location: 1),
                    ],
                    startPoint: .top, endPoint: .bottom
                ),
                lineWidth: 0.5
            )
        }
    }
}

extension View {
    func glassSurface<S: InsettableShape>(_ shape: S, elevation: Elevation = .float) -> some View {
        modifier(GlassSurface(shape: shape, elevation: elevation))
    }
}

/// BarShelf's buttons: capsules that lighten under the pointer and give a
/// little when pressed. `.small` control size makes them 24 pt tall.
///
///     Button { allow() } label: { ShortcutLabel("Allow", key: "↵") }
///         .buttonStyle(.glass(.primary))
///         .keyboardShortcut(.defaultAction)
struct GlassButtonStyle: ButtonStyle {
    enum Role {
        /// The one main action: filled.
        case primary
        /// Another action: a quiet fill.
        case secondary
        /// Cancel, dismiss, a link-like action: text until hovered.
        case plain
        /// An action that adds or starts something, in the accent colour.
        case accent
        /// Delete, remove: red text.
        case destructive
    }

    var role: Role = .secondary

    func makeBody(configuration: Configuration) -> some View {
        GlassButton(configuration: configuration, role: role)
    }
}

extension ButtonStyle where Self == GlassButtonStyle {
    static func glass(_ role: GlassButtonStyle.Role = .secondary) -> GlassButtonStyle {
        GlassButtonStyle(role: role)
    }
}

private struct GlassButton: View {
    let configuration: ButtonStyle.Configuration
    let role: GlassButtonStyle.Role
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var small: Bool { controlSize == .small || controlSize == .mini }

    var body: some View {
        configuration.label
            .font(small ? .callout.weight(.medium) : .body.weight(.medium))
            .lineLimit(1)
            .foregroundStyle(foreground)
            .padding(.horizontal, small ? ControlMetrics.smallInset : ControlMetrics.inset)
            .frame(height: small ? ControlMetrics.smallHeight : ControlMetrics.height)
            .background(background)
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed && !reduceMotion ? Motion.pressScale : 1)
            .opacity(isEnabled ? 1 : Fill.disabled)
            .animation(Motion.respecting(reduceMotion, Motion.press), value: configuration.isPressed)
            .animation(Motion.respecting(reduceMotion, Motion.quick), value: hovering)
            .onHover { hovering = $0 && isEnabled }
    }

    private var foreground: AnyShapeStyle {
        switch role {
        case .primary: return AnyShapeStyle(Fill.primaryButtonInk)
        case .accent: return AnyShapeStyle(Color.white)
        case .secondary: return AnyShapeStyle(.primary)
        case .plain: return hovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)
        case .destructive: return AnyShapeStyle(Color.red)
        }
    }

    @ViewBuilder private var background: some View {
        switch role {
        case .primary, .accent:
            Capsule()
                .fill(role == .primary ? Fill.primaryButton : Color.accentColor)
                .overlay(Capsule().fill(LinearGradient(
                    colors: [.white.opacity(Fill.Tile.rim), .clear],
                    startPoint: .top, endPoint: .center
                )))
                .brightness(hovering ? Fill.hoverBrightness : 0)
                .elevation(.control)
        case .secondary:
            Capsule().fill(hovering || configuration.isPressed ? Fill.pressed : Fill.hover)
        case .plain, .destructive:
            Capsule().fill(hovering || configuration.isPressed ? Fill.hover : .clear)
        }
    }
}

/// A key as the keyboard shows it: ⌘F, ↵, esc.
struct KeyCap: View {
    let key: String

    init(_ key: String) { self.key = key }

    var body: some View {
        Text(key)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, Spacing.xxs)
            .frame(minWidth: ControlMetrics.keyCap, minHeight: ControlMetrics.keyCap)
            .background(RoundedRectangle(cornerRadius: Radius.key, style: .continuous).fill(Fill.hover))
            .accessibilityHidden(true)
    }
}

/// A button title with the key that triggers it, for a filled button.
struct ShortcutLabel: View {
    let title: LocalizedStringKey
    let key: String

    init(_ title: LocalizedStringKey, key: String) {
        self.title = title
        self.key = key
    }

    var body: some View {
        HStack(spacing: Spacing.stack) {
            Text(title)
            Text(key)
                .opacity(Fill.keyCapInButton)
                .accessibilityHidden(true)
        }
    }
}

/// A card's hero reading: big rounded digits with a small raised unit —
/// 80 %, 14 °, 1:42.
struct MetricText: View {
    let value: String
    var unit: String?
    var size: Typography.MetricSize = .regular

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.hair / 2) {
            Text(value)
                .font(Typography.metric(size))
                .tracking(Typography.metricTracking(size))
            if let unit {
                Text(unit)
                    .font(Typography.metricUnit(size))
                    .foregroundStyle(.secondary)
                    .padding(.top, size.unitRaise)
            }
        }
        .lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(unit.map { value + $0 } ?? value)
    }
}

extension View {
    /// A form section's footer note, starting at the section's leading edge
    /// in every language. A grouped form otherwise lays a wrapped footer out
    /// against the trailing edge.
    func formFooter() -> some View {
        font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}


/// A one-line status word on a soft wash of its colour: "Cached", "Active",
/// "Update". Never wraps — it shrinks before it splits.
struct Pill: View {
    let text: String
    var symbol: String?
    var color: Color = .secondary
    /// A status dot in front of the word, for live states: "Live", "Failed".
    var dot = false

    var body: some View {
        HStack(spacing: dot ? Spacing.xxs : Spacing.hair) {
            if dot {
                Circle()
                    .frame(width: Spacing.stack, height: Spacing.stack)
                    .accessibilityHidden(true)
            }
            if let symbol {
                Image(systemName: symbol)
                    .accessibilityHidden(true)
            }
            Text(text)
        }
        .font(.caption2.weight(.medium))
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, Spacing.stack)
        .padding(.vertical, Spacing.hair)
        .foregroundStyle(color)
        .background(Capsule().fill(color.opacity(Fill.Wash.medium)))
    }
}

/// Nothing here yet: one symbol, one sentence, and the way to fill it.
struct EmptyStateView<Action: View>: View {
    let symbol: String
    let title: String
    var message: String?
    @ViewBuilder var action: Action

    var body: some View {
        VStack(spacing: Spacing.stack) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text(title)
                .font(.callout.weight(.semibold))
                .multilineTextAlignment(.center)
            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            action
                .controlSize(.small)
                .padding(.top, Spacing.xxs)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.s)
        .accessibilityElement(children: .contain)
    }
}

extension EmptyStateView where Action == EmptyView {
    init(symbol: String, title: String, message: String? = nil) {
        self.init(symbol: symbol, title: title, message: message) { EmptyView() }
    }
}

/// A widget's mark wherever the app lists it — Shelf board, inspector,
/// Menu Bar and Privacy settings — the same tile its popup card carries.
struct WidgetMark: View {
    let widget: LoadedWidget
    @ObservedObject var runtime: WidgetRuntime
    var size: CGFloat = 20

    var body: some View {
        CardIconTile(
            symbol: widget.manifest.icon ?? "square.dashed",
            color: runtime.prefs.effectiveAppearance(for: widget.manifest, widgetID: widget.id).accentColor ?? .accentColor,
            size: size
        )
    }
}

/// A toolbar symbol: bare at rest, on a soft disc under the pointer, giving a
/// little when pressed.
struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        IconButton(configuration: configuration)
    }
}

extension ButtonStyle where Self == IconButtonStyle {
    static var icon: IconButtonStyle { IconButtonStyle() }
}

private struct IconButton: View {
    let configuration: ButtonStyle.Configuration
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        configuration.label
            .font(.body.weight(.medium))
            .foregroundStyle(hovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .frame(width: ControlMetrics.height, height: ControlMetrics.height)
            .background(Circle().fill(
                configuration.isPressed ? Fill.pressed : hovering ? Fill.hover : .clear
            ))
            .contentShape(Circle())
            .scaleEffect(configuration.isPressed && !reduceMotion ? Motion.pressScale : 1)
            .opacity(isEnabled ? 1 : Fill.disabled)
            .animation(Motion.respecting(reduceMotion, Motion.press), value: configuration.isPressed)
            .animation(Motion.respecting(reduceMotion, Motion.quick), value: hovering)
            .onHover { hovering = $0 && isEnabled }
    }
}

/// A small glass label naming a control and its key, shown after the
/// pointer rests on the control for a moment: "Refresh All ⌘R".
///
/// Drawn inside the window rather than as a system tooltip, so it shows the
/// key the way the rest of the app does. `alignment` keeps a control at the
/// window's edge from pushing its hint off the side.
struct HoverHint: ViewModifier {
    let title: LocalizedStringKey
    var key: String?
    var alignment: HorizontalAlignment = .center
    @State private var shown = false
    @State private var pending: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                pending?.cancel()
                if inside {
                    pending = Task { @MainActor in
                        try? await Task.sleep(for: Self.delay)
                        guard !Task.isCancelled else { return }
                        shown = true
                    }
                } else {
                    shown = false
                }
            }
            .overlay(alignment: Alignment(horizontal: alignment, vertical: .bottom)) {
                if shown {
                    label
                        .alignmentGuide(.bottom) { $0[.top] - Spacing.xxs }
                        .transition(.opacity.combined(with: .offset(y: -Spacing.xxs)))
                        .allowsHitTesting(false)
                }
            }
            .animation(Motion.respecting(reduceMotion, Motion.quick), value: shown)
            .onDisappear { pending?.cancel() }
    }

    private var label: some View {
        HStack(spacing: Spacing.stack) {
            Text(title)
            if let key { KeyCap(key) }
        }
        .font(.caption.weight(.medium))
        .padding(.leading, Spacing.xs)
        .padding(.trailing, key == nil ? Spacing.xs : Spacing.xxs)
        .frame(height: ControlMetrics.smallHeight)
        .fixedSize()
        .glassSurface(Capsule())
        .accessibilityHidden(true)
    }

    static let delay: Duration = .milliseconds(450)
}

extension View {
    /// See `HoverHint`. The control keeps its own accessibility label; the
    /// hint is for the pointer only.
    func hoverHint(
        _ title: LocalizedStringKey, key: String? = nil, alignment: HorizontalAlignment = .center
    ) -> some View {
        modifier(HoverHint(title: title, key: key, alignment: alignment))
    }
}
