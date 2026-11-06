import SwiftUI

/// The popup's search field at rest: a capsule that names what it finds and
/// the key that opens it. Clicking it (or ⌘F) opens `SearchOverlay`, where
/// the real field takes the typing.
struct SearchCapsule: View {
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.stack) {
                Image(systemName: "magnifyingglass")
                    .font(.callout.weight(.medium))
                    .accessibilityHidden(true)
                Text("Search widgets")
                    .font(.callout)
                Spacer(minLength: 0)
                KeyCap("⌘F")
            }
            .foregroundStyle(.secondary)
            .padding(.leading, Spacing.s - Spacing.hair)
            .padding(.trailing, Spacing.stack)
            .frame(height: ControlMetrics.height)
            .background(Capsule().fill(hovering ? Fill.pressed : Fill.hover))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.respecting(reduceMotion, Motion.quick), value: hovering)
        .accessibilityLabel("Search")
        .accessibilityHint("Searches widget names and what they show")
    }
}
