import SwiftUI

/// The transient confirmation capsule (`ToastCenter`), mounted once by every
/// surface — the shelf popup, a menu bar card, the Dock and the BarShelf
/// window — each showing only the toasts raised on it, so a copy says
/// "Copied" wherever it happened.
struct ToastOverlay: View {
    @ObservedObject private var toasts = ToastCenter.shared
    /// The surface this overlay draws for.
    let surface: ToastSurface
    /// Distance from the bottom edge; the shelf lifts it above its footer.
    var bottomInset: CGFloat = Spacing.s
    var alignment: Alignment = .bottom
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(surface: ToastSurface, bottomInset: CGFloat = Spacing.s, alignment: Alignment = .bottom) {
        self.surface = surface
        self.bottomInset = bottomInset
        self.alignment = alignment
    }

    var body: some View {
        let toast = toasts.current.flatMap { $0.surface == surface ? $0 : nil }
        ZStack(alignment: alignment) {
            if let toast {
                ToastCapsule(toast: toast) { toasts.performAction(of: toast.id) }
                    .padding(.bottom, alignment == .bottom ? bottomInset : 0)
                    .padding(.horizontal, Spacing.s)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: Motion.pressScale)).combined(with: .move(edge: .bottom)))
                    .id(toast.id)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
        // Only a toast with a button takes clicks; the rest float over
        // whatever is under them without getting in the way.
        .allowsHitTesting(toast?.action != nil)
        .animation(Motion.respecting(reduceMotion, Motion.press), value: toast?.id)
    }
}

/// The toast itself: a glass capsule with one line, a quieter second line
/// when there is a reason to give, and an optional button.
struct ToastCapsule: View {
    let toast: Toast
    let onAction: () -> Void

    var body: some View {
        // Side by side when there is room; the button under the words in a
        // narrow place (a dock on the side of the screen).
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Spacing.xs) { message; button }
            VStack(alignment: .leading, spacing: Spacing.xxs) { message; button }
        }
        .padding(.horizontal, Spacing.m)
        .padding(.vertical, toast.detail == nil ? 0 : Spacing.xs)
        .frame(minHeight: ControlMetrics.height + Spacing.xs)
        .frame(maxWidth: 360)
        .glassSurface(RoundedRectangle(
            cornerRadius: toast.detail == nil ? (ControlMetrics.height + Spacing.xs) / 2 : Radius.card,
            style: .continuous
        ))
        // `ToastCenter.show` already announced it; a live-region trait here
        // would have VoiceOver read it a second time.
        .accessibilityElement(children: .combine)
    }

    private var message: some View {
        HStack(spacing: Spacing.xs) {
            if toast.tone == .failure {
                Image(systemName: StatusTone.warning.symbol)
                    .foregroundStyle(StatusTone.warning.color)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: Spacing.hair) {
                Text(toast.message)
                    .font(.callout.weight(.medium))
                if let detail = toast.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private var button: some View {
        if let action = toast.action {
            Button(action.title, action: onAction)
                .buttonStyle(.glass(.secondary))
                .controlSize(.small)
        }
    }
}
