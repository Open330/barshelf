import AppKit
import MenubucketCore
import SwiftUI
import UniformTypeIdentifiers

/// One-time welcome card shown above the seeded starter widgets after the
/// first-run seeding pass. The close button records the dismissal in prefs,
/// so the card never returns.
struct WelcomeCardView: View {
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .foregroundColor(.accentColor)
                    .accessibilityHidden(true)
            Text("Welcome to BarShelf")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.secondary)
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
                Button("Open Widget Gallery") {
                    Task { @MainActor in
                        GalleryWindowController.shared.show()
                    }
                }
                .controlSize(.small)
                Button("Getting Started") {
                    NSWorkspace.shared.open(RootView.gettingStartedURL)
                }
                .controlSize(.small)
            }
            Text("Tip: the gear opens Settings. Swipe with two fingers or press ←/→ to switch pages.")
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
