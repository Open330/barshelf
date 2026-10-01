import AppKit
import MenubucketCore
import SwiftUI

// MARK: - Card

struct GalleryCard: View {
    let entry: RegistryWidgetEntry
    let isInstalled: Bool
    /// Registry advertises a newer version than the installed widget.json.
    let updateAvailable: Bool
    /// PATH status of `entry.requires`; `nil` while the probe is pending.
    let requirementStatus: RequirementChecker.Status?
    let install: () -> Void

    /// Card accent: the entry's registry `accent` (same vocabulary as widget
    /// `appearance.accent`), falling back to the system accent.
    private var accent: Color {
        WidgetAppearance(accent: entry.accent).accentColor ?? .accentColor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            screenshotPreview
            HStack(alignment: .top, spacing: 10) {
                iconTile
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                        .font(.headline)
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        if let kind = entry.kind {
                            badge(kind)
                        }
                        if let category = entry.category, !category.isEmpty {
                            Text(category)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        if let version = entry.version {
                            Text("v\(version)")
                                .font(.caption2)
                                .foregroundColor(Color.secondary.opacity(0.7))
                                .monospacedDigit()
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                installControl
            }
            if let description = entry.description {
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 4) {
                requiresBadge
                permissionChips
                Spacer(minLength: 0)
                if detailsURL != nil {
                    Button("Details") { openDetails() }
                        .buttonStyle(.link)
                        .font(.caption)
                        .help("Open the widget's Markdown introduction page")
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.08))
        )
    }

    /// App Store-style identity tile: filled accent square with a white glyph
    /// — the strongest per-card differentiator, so cards stop reading as
    /// walls of identical text.
    private var iconTile: some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [accent.opacity(0.95), accent.opacity(0.7)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: 40, height: 40)
            .overlay(
                Image(systemName: entry.icon ?? "app.dashed")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundColor(.white)
            )
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var installControl: some View {
        // Not installed and this BarShelf would refuse it: say so rather
        // than offer Install. (Installed, it just shows Installed — the
        // newer version is held back by `updateAvailable`.)
        if let needs = GalleryModel.needsNewerHost(entry), !isInstalled {
            Text(needs)
                .font(.caption)
                .foregroundColor(.secondary)
                .help("Update BarShelf to install this widget")
        } else if updateAvailable {
            Button("Update", action: install)
                .controlSize(.small)
                .help("A newer version is available in the registry")
        } else if isInstalled {
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Text("Installed")
                    .foregroundColor(.secondary)
            }
            .font(.caption)
            .contextMenu { Button("Reinstall", action: install) }
            .help("Installed — right-click to reinstall")
            .accessibilityLabel("\(entry.name) is installed")
        } else {
            Button("Install", action: install)
                .controlSize(.small)
        }
    }

    private func badge(_ kind: String) -> some View {
        Text(kind)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(badgeColor(kind).opacity(0.18))
            .foregroundColor(badgeColor(kind))
            .clipShape(Capsule())
    }

    private func badgeColor(_ kind: String) -> Color {
        switch kind {
        case "exec": return .blue
        case "script": return .purple
        case "workflow": return .orange
        default: return .gray
        }
    }

    /// External requirement badge (`requires` registry field): flags widgets
    /// that need a CLI or runtime installed first (e.g. "aas CLI", "Deno").
    ///
    /// Colour reflects the PATH probe (display-only — never blocks install):
    /// green check when the binary is present, orange "not installed" when it
    /// is missing, neutral while the probe is pending or indeterminate.
    @ViewBuilder
    private var requiresBadge: some View {
        if let requires = entry.requires,
           !requires.trimmingCharacters(in: .whitespaces).isEmpty {
            let style = requirementStyle
            Label(style.text(requires), systemImage: style.symbol)
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(style.color.opacity(0.15))
                .foregroundColor(style.color)
                .clipShape(Capsule())
                .padding(.top, 2)
                .help(style.help(requires))
                .accessibilityLabel(style.accessibilityLabel(requires))
        }
    }

    private struct RequirementStyle {
        let color: Color
        let symbol: String
        let text: (String) -> String
        let help: (String) -> String
        let accessibilityLabel: (String) -> String
    }

    private var requirementStyle: RequirementStyle {
        switch requirementStatus {
        case .satisfied:
            return RequirementStyle(
                color: .green,
                symbol: "checkmark.seal",
                text: { "\($0) ready" },
                help: { "\($0) was found on your PATH" },
                accessibilityLabel: { "Requirement \($0) is installed" }
            )
        case .missing:
            return RequirementStyle(
                color: .orange,
                symbol: "exclamationmark.triangle",
                text: { "\($0) — not installed" },
                help: {
                    "This widget needs \($0) installed on your Mac. "
                        + "You can still install the widget now."
                },
                accessibilityLabel: { "Requirement \($0) is not installed" }
            )
        case .unknown, nil:
            return RequirementStyle(
                color: .orange,
                symbol: "wrench.and.screwdriver",
                text: { "Requires \($0)" },
                help: { "This widget needs \($0) installed on your Mac" },
                accessibilityLabel: { "Requires \($0)" }
            )
        }
    }

    /// Optional preview image (`screenshot` registry field). Renders a
    /// fixed-height thumbnail when the value forms a loadable `http(s)`/`file`
    /// URL; loading shows a placeholder and any failure degrades to nothing.
    @ViewBuilder
    private var screenshotPreview: some View {
        if let url = screenshotURL {
            AsyncImage(url: url) { phase in
                switch phase {
                case let .success(image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(maxWidth: .infinity)
                        .frame(height: 120)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .accessibilityLabel("\(entry.name) preview")
                case .empty:
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.secondary.opacity(0.08))
                        .frame(height: 120)
                        .overlay(ProgressView().controlSize(.small))
                        .accessibilityHidden(true)
                case .failure:
                    // Graceful absence — no broken-image chrome.
                    EmptyView()
                @unknown default:
                    EmptyView()
                }
            }
        }
    }

    /// Only `http(s)` and `file` schemes are honored; a bare relative path
    /// (which we cannot resolve without the registry base) yields `nil`.
    private var screenshotURL: URL? {
        guard let raw = entry.screenshot?
            .trimmingCharacters(in: .whitespaces), !raw.isEmpty,
            let url = URL(string: raw),
            let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https" || scheme == "file"
        else { return nil }
        return url
    }

    /// Registry `readme` accepts a rendered Markdown/documentation URL. Keep
    /// navigation user-initiated and outside the widget permission model.
    private var detailsURL: URL? {
        guard let raw = entry.readme?
            .trimmingCharacters(in: .whitespaces), !raw.isEmpty,
            let url = URL(string: raw),
            let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https" || scheme == "file"
        else { return nil }
        return url
    }

    private func openDetails() {
        guard let detailsURL else { return }
        NSWorkspace.shared.open(detailsURL)
    }

    /// Display-only permission chips ("신뢰 UX") — the enforcement gate stays
    /// the first-run approval card after install. Compact icon capsules; the
    /// specifics (which commands, which hosts) live in each chip's tooltip so
    /// the card stays scannable.
    @ViewBuilder
    private var permissionChips: some View {
        let chips = permissionChipLabels
        if !chips.isEmpty {
            HStack(spacing: 4) {
                ForEach(chips, id: \.self) { chip in
                    Image(systemName: chip.symbol)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.secondary.opacity(0.12))
                        .foregroundColor(.secondary)
                        .clipShape(Capsule())
                        .help(chip.help)
                        .accessibilityLabel(chip.help)
                }
            }
        }
    }

    private struct Chip: Hashable {
        let symbol: String
        let help: String
    }

    private var permissionChipLabels: [Chip] {
        guard let permissions = entry.permissions else { return [] }
        var chips: [Chip] = []
        let commands = permissions.exec ?? []
        if !commands.isEmpty {
            chips.append(Chip(
                symbol: "terminal",
                help: "Runs: \(commands.joined(separator: ", "))"
            ))
        }
        if permissions.keychain == true {
            chips.append(Chip(symbol: "key", help: "Reads a Keychain secret"))
        }
        if permissions.notifications == true {
            chips.append(Chip(symbol: "bell", help: "Posts notifications"))
        }
        let hosts = permissions.network ?? []
        if !hosts.isEmpty {
            chips.append(Chip(
                symbol: "network",
                help: "Network: \(hosts.joined(separator: ", "))"
            ))
        }
        let paths = permissions.readPaths ?? []
        if !paths.isEmpty {
            chips.append(Chip(
                symbol: "folder",
                help: "Reads files in: \(paths.joined(separator: ", "))"
            ))
        }
        let telemetry = permissions.system ?? []
        if !telemetry.isEmpty {
            chips.append(Chip(
                symbol: "gauge",
                help: "Reads system telemetry: \(telemetry.joined(separator: ", "))"
            ))
        }
        return chips
    }
}
