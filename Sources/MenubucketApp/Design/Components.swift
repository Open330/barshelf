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

/// Capsule chrome for floating controls: a solid, opaque surface with a
/// hairline border — no translucency.
struct ControlCapsule: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Capsule().fill(Color(nsColor: .windowBackgroundColor)))
            .overlay(Capsule().strokeBorder(Fill.hairline, lineWidth: 0.5))
            .shadow(color: .black.opacity(Fill.Wash.soft), radius: Spacing.hair, y: 1)
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

    var body: some View {
        HStack(spacing: Spacing.hair) {
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
