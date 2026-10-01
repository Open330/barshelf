import AppKit
import MenubucketCore
import SwiftUI

// MARK: - Card

/// One registry widget in the grid. Clicking (or Return on a focused card)
/// opens its detail page; the quick Install/Update button installs in place.
struct GalleryCard: View {
    let entry: RegistryWidgetEntry
    let isInstalled: Bool
    /// Registry advertises a newer version than the installed widget.json.
    let updateAvailable: Bool
    /// PATH status of `entry.requires`; `nil` while the probe is pending.
    let requirementStatus: RequirementChecker.Status?
    let install: () -> Void
    /// Opens the detail page. Nil renders a static card (screenshots).
    var openDetails: (() -> Void)?

    @FocusState private var isFocused: Bool
    @State private var isHovered = false

    private var accent: Color {
        GalleryIconTile.accent(for: entry)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            screenshotPreview
            HStack(alignment: .top, spacing: Spacing.s) {
                GalleryIconTile(entry: entry, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                        .font(.headline)
                        .lineLimit(1)
                    HStack(spacing: Spacing.xxs) {
                        if let kind = entry.kind {
                            GalleryTypeBadge(kind: kind)
                        }
                        if let category = entry.category, !category.isEmpty {
                            Text(category)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        if let version = entry.version {
                            Text("v\(version)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
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
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: Spacing.xxs) {
                requiresBadge
                permissionIcons
                Spacer(minLength: 0)
            }
        }
        .padding(Spacing.s)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .cardSurface()
        .overlay(focusRing)
        .contentShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .modifier(OpensDetail(
            open: openDetails, isFocused: $isFocused, isHovered: $isHovered
        ))
        // VoiceOver reads the card as one element: name, type, status, and
        // what it needs; the default action opens details, Install is a
        // named action.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityName)
        .accessibilityValue(statusText)
        .accessibilityHint(openDetails == nil ? "" : "Opens the widget’s details")
        .accessibilityAddTraits(openDetails == nil ? [] : .isButton)
        .accessibilityAction { openDetails?() }
        .accessibilityActions {
            if let title = quickActionTitle {
                Button(title, action: install)
            }
        }
    }

    @ViewBuilder
    private var focusRing: some View {
        if isFocused {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: 2)
        } else if isHovered {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.18), lineWidth: 1)
        }
    }

    private var accessibilityName: String {
        var parts = [entry.name]
        if let kind = entry.kind { parts.append(String(localized: "\(WidgetTypeName.name(kind)) widget", comment: "Accessibility: widget type, e.g. Command widget")) }
        if let description = entry.description { parts.append(description) }
        if let requires = entry.requires, !requires.isEmpty {
            parts.append(requirementStyle.accessibilityLabel(requires))
        }
        return parts.joined(separator: ", ")
    }

    private var statusText: String {
        GalleryCard.status(
            entry: entry, isInstalled: isInstalled, updateAvailable: updateAvailable
        )
    }

    /// Install state in words, shared with the detail page.
    static func status(
        entry: RegistryWidgetEntry, isInstalled: Bool, updateAvailable: Bool
    ) -> String {
        if updateAvailable { return String(localized: "Installed, update available") }
        if isInstalled { return String(localized: "Installed") }
        if let needs = GalleryModel.needsNewerHost(entry) { return needs }
        return String(localized: "Not installed")
    }

    private var quickActionTitle: String? {
        if updateAvailable { return String(localized: "Update", comment: "Button: install a newer version of a widget") }
        if isInstalled || GalleryModel.needsNewerHost(entry) != nil { return nil }
        return String(localized: "Install")
    }

    @ViewBuilder
    private var installControl: some View {
        // Not installed and this BarShelf would refuse it: say so rather
        // than offer Install. (Installed, it just shows Installed — the
        // newer version is held back by `updateAvailable`.)
        if let needs = GalleryModel.needsNewerHost(entry), !isInstalled {
            Text(needs)
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("Update BarShelf to install this widget")
        } else if updateAvailable {
            Button("Update", action: install)
                .controlSize(.small)
                .help("A newer version is available in the registry")
                .accessibilityLabel("Update \(entry.name)")
        } else if isInstalled {
            Label("Installed", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
                .symbolRenderingMode(.multicolor)
                .contextMenu { Button("Reinstall", action: install) }
                .help("Installed — right-click to reinstall")
        } else {
            Button("Install", action: install)
                .controlSize(.small)
                .accessibilityLabel("Install \(entry.name)")
        }
    }

    /// External requirement badge (`requires` registry field): flags widgets
    /// that need a CLI or runtime installed first (e.g. "Deno").
    ///
    /// Colour reflects the PATH probe (display-only — never blocks install),
    /// and the symbol and text carry the same verdict.
    @ViewBuilder
    private var requiresBadge: some View {
        if let requires = entry.requires,
           !requires.trimmingCharacters(in: .whitespaces).isEmpty {
            let style = requirementStyle
            Label(style.text(requires), systemImage: style.symbol)
                .font(.caption2.weight(.medium))
                .padding(.horizontal, Spacing.xs)
                .padding(.vertical, 2)
                .background(style.color.opacity(0.15), in: Capsule())
                .foregroundStyle(style.color)
                .help(style.help(requires))
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
                color: StatusTone.success.color,
                symbol: "checkmark.seal",
                text: { String(localized: "\($0) ready", comment: "A required tool, e.g. Deno ready") },
                help: { String(localized: "\($0) was found on your Mac") },
                accessibilityLabel: { String(localized: "needs \($0), which is installed") }
            )
        case .missing:
            return RequirementStyle(
                color: StatusTone.warning.color,
                symbol: "exclamationmark.triangle",
                text: { String(localized: "\($0) — not installed") },
                help: {
                    String(localized: "This widget needs \($0) installed on your Mac. You can still install the widget now.")
                },
                accessibilityLabel: { String(localized: "needs \($0), which is not installed") }
            )
        case .unknown, nil:
            return RequirementStyle(
                color: .secondary,
                symbol: "wrench.and.screwdriver",
                text: { String(localized: "Requires \($0)") },
                help: { String(localized: "This widget needs \($0) installed on your Mac") },
                accessibilityLabel: { String(localized: "needs \($0)") }
            )
        }
    }

    /// Optional preview image (`screenshot` registry field), loaded through
    /// `GalleryScreenshot`; any failure degrades to nothing.
    @ViewBuilder
    private var screenshotPreview: some View {
        if let url = GalleryLinks.screenshotURL(entry) {
            GalleryScreenshot(url: url, name: entry.name, height: 120)
        }
    }

    /// Compact permission icons; the detail page spells each one out.
    @ViewBuilder
    private var permissionIcons: some View {
        let lines = GalleryPermissionText.lines(for: entry.permissions)
        if !lines.isEmpty {
            HStack(spacing: Spacing.xxs) {
                ForEach(lines, id: \.self) { line in
                    Image(systemName: line.symbol)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                        .foregroundStyle(.secondary)
                        .help(line.short)
                }
            }
        }
    }
}

/// Click, hover, and keyboard focus for a card that opens a detail page.
private struct OpensDetail: ViewModifier {
    let open: (() -> Void)?
    var isFocused: FocusState<Bool>.Binding
    @Binding var isHovered: Bool

    func body(content: Content) -> some View {
        if let open {
            content
                .onTapGesture(perform: open)
                .onHover { isHovered = $0 }
                .focusable(interactions: .activate)
                .focused(isFocused)
                .focusEffectDisabled()
                .onKeyPress(.return) { open(); return .handled }
                .onKeyPress(.space) { open(); return .handled }
        } else {
            content
        }
    }
}

// MARK: - Shared pieces (card + detail page)

/// App Store-style identity tile: the entry's accent with a white glyph.
struct GalleryIconTile: View {
    let entry: RegistryWidgetEntry
    var size: CGFloat = 40

    /// The entry's registry `accent` (same vocabulary as widget
    /// `appearance.accent`), falling back to the system accent.
    static func accent(for entry: RegistryWidgetEntry) -> Color {
        WidgetAppearance(accent: entry.accent).accentColor ?? .accentColor
    }

    var body: some View {
        let accent = Self.accent(for: entry)
        RoundedRectangle(cornerRadius: size > 48 ? Radius.surface : Radius.card, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [accent.opacity(0.95), accent.opacity(0.7)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: entry.icon ?? "app.dashed")
                    .font(size > 48 ? .largeTitle : .title3)
                    .foregroundStyle(.white)
            )
            .accessibilityHidden(true)
    }
}

/// Command / Workflow / Script, as a tinted capsule with its name.
struct GalleryTypeBadge: View {
    let kind: String

    var body: some View {
        Text(WidgetTypeName.name(kind))
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    private var color: Color {
        switch kind {
        case "exec": return .blue
        case "script": return .purple
        case "workflow": return .orange
        default: return .gray
        }
    }
}

/// A registry screenshot; a placeholder while loading, nothing on failure.
struct GalleryScreenshot: View {
    let url: URL
    let name: String
    let height: CGFloat

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case let .success(image):
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity)
                    .frame(height: height)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                    .accessibilityLabel("Preview of \(name)")
            case .empty:
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .fill(Color.secondary.opacity(0.08))
                    .frame(height: height)
                    .overlay(ProgressView().controlSize(.small))
                    .accessibilityHidden(true)
            default:
                // Graceful absence — no broken-image chrome.
                EmptyView()
            }
        }
    }
}

/// Registry URLs the gallery will open or load. Only `http(s)` and `file`
/// schemes; a bare relative path (unresolvable without the registry base)
/// yields nil.
enum GalleryLinks {
    static func screenshotURL(_ entry: RegistryWidgetEntry) -> URL? {
        url(entry.screenshot)
    }

    static func readmeURL(_ entry: RegistryWidgetEntry) -> URL? {
        url(entry.readme)
    }

    static func homepageURL(_ entry: RegistryWidgetEntry) -> URL? {
        url(entry.homepage)
    }

    /// Where the widget is downloaded from, when that is a web page.
    static func sourceURL(_ entry: RegistryWidgetEntry) -> URL? {
        guard entry.install.bundled == nil else { return nil }
        guard let url = url(entry.install.url), url.scheme?.lowercased() != "file" else {
            return nil
        }
        return url
    }

    private static func url(_ raw: String?) -> URL? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty,
              let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" || scheme == "file"
        else { return nil }
        return url
    }
}
