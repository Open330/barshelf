import AppKit
import MenubucketCore
import SwiftUI
import UniformTypeIdentifiers

/// One-time welcome card shown above the seeded starter widgets after the
/// first-run seeding pass. The close button records the dismissal in prefs,
/// so the card never returns.
struct WelcomeCardView: View {
    let addWidget: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                Text("Welcome to BarShelf")
                    .font(.callout)
                    .fontWeight(.semibold)
                Spacer()
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Dismiss")
                .accessibilityLabel("Dismiss welcome card")
            }
            Text("We installed a couple of starter widgets so this popup isn't empty. Browse the gallery for more — like usage meters and OTP codes — or remove the starters anytime.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Add Widget…", action: addWidget)
                    .controlSize(.small)
                Button("Getting Started") {
                    NSWorkspace.shared.open(RootView.gettingStartedURL)
                }
                .controlSize(.small)
            }
            Text("Tip: ⋯ has everything else — editing the shelf, settings, updates. Swipe with two fingers or press ←/→ to switch pages.")
                .font(.caption2)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.07))
    }
}
