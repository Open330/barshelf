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
                    .fill(Color.accentColor.opacity(0.12))
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
        VStack(spacing: style == .tile ? 2 : 0) {
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
                .fill(tone.color.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(tone.color.opacity(0.35), lineWidth: 1)
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
                .fill(dimmed ? Color.secondary.opacity(0.06) : Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .stroke(Color.primary.opacity(0.08))
        )
    }
}

/// Capsule chrome for floating controls: a solid, opaque surface with a
/// hairline border — no translucency.
struct ControlCapsule: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Capsule().fill(Color(nsColor: .windowBackgroundColor)))
            .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.25), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.10), radius: 2, y: 1)
    }
}

extension View {
    /// A form section's footer note, starting at the section's leading edge
    /// in every language. A grouped form otherwise lays a wrapped footer out
    /// against the trailing edge.
    func formFooter() -> some View {
        multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

