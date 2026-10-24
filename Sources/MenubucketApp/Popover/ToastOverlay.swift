import SwiftUI

/// The transient confirmation capsule (`ToastCenter`), drawn by every popup
/// surface — the shelf and a single card — so a copy says "Copied" wherever
/// it happened.
struct ToastOverlay: View {
    @ObservedObject private var toast = ToastCenter.shared
    /// Distance from the bottom edge; the shelf lifts it above its footer.
    var bottomInset: CGFloat = Spacing.s
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .bottom) {
            if let message = toast.message {
                Text(message)
                    .font(.caption)
                    .fontWeight(.medium)
                    .padding(.horizontal, Spacing.s)
                    .padding(.vertical, Spacing.xs)
                    .modifier(ControlCapsule())
                    .padding(.bottom, bottomInset)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)))
                    // `ToastCenter.show` already announced it; a live-region
                    // trait here would have VoiceOver read it a second time.
                    .accessibilityLabel(message)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .allowsHitTesting(false)
        .animation(.easeInOut(duration: 0.2), value: toast.message)
    }
}
