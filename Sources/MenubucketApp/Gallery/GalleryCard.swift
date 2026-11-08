import AppKit
import MenubucketCore
import SwiftUI

// MARK: - Card

/// One registry widget in the grid. Clicking (or Return on a focused card)
/// opens its detail page; the quick Install/Update button installs in place.
struct GalleryCard: View {
    let entry: RegistryWidgetEntry
    /// The entry's name as the shelf shows it (`GalleryEntryText.title`).
    private var displayName: String { GalleryEntryText.title(for: entry) }
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
                VStack(alignment: .leading, spacing: Spacing.hair) {
                    Text(displayName)
                        .font(.headline)
                        .lineLimit(1)
                    HStack(spacing: Spacing.xxs) {
                        // Most widgets are workflows; naming that on every card is
                        // noise. A command or script runs something, which is
                        // worth a quiet word.
                        if let kind = entry.kind, kind != "workflow" {
                            GalleryTypeBadge(kind: kind)
                        }
                        if let category = entry.category, !category.isEmpty {
                            Text(GalleryEntryText.categoryLabel(category))
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
            if let description = GalleryEntryText.description(for: entry) {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    // Two lines held even for a one-line summary, so cards
                    // in a row end at the same height.
                    .lineLimit(2, reservesSpace: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        }
    }

    private var accessibilityName: String {
        var parts = [displayName]
        if let kind = entry.kind { parts.append(String(localized: "\(WidgetTypeName.name(kind)) widget", comment: "Accessibility: widget type, e.g. Command widget")) }
        if let description = GalleryEntryText.description(for: entry) { parts.append(description) }
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
            // Quiet in the grid, where every card has one; the detail
            // page, with a single action, fills it with the accent.
            Button("Update", action: install)
                .buttonStyle(.glass(.secondary))
                .controlSize(.small)
                .help("A newer version is available in the registry")
                .accessibilityLabel("Update \(displayName)")
        } else if isInstalled {
            // The same green as the detail page's status.
            Label("Installed", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(StatusTone.success.color)
                .contextMenu { Button("Reinstall", action: install) }
                .help("Installed — right-click to reinstall")
        } else {
            Button("Install", action: install)
                .buttonStyle(.glass(.secondary))
                .controlSize(.small)
                .accessibilityLabel("Install \(displayName)")
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
                .padding(.vertical, Spacing.hair)
                .background(style.color.opacity(Fill.Wash.medium), in: Capsule())
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
    /// Every card gets the same preview band, so the grid lines up: the
    /// screenshot when there is one, the widget's icon large when not.
    private var screenshotPreview: some View {
        GalleryScreenshot(
            url: GalleryLinks.screenshotURL(entry), name: displayName, height: 120,
            placeholder: {
                GalleryPreviewStandIn(symbol: entry.icon ?? "app.dashed", color: accent, name: displayName)
            }
        )
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
                        .padding(.horizontal, Spacing.stack)
                        .padding(.vertical, Spacing.hair + 1)
                        .background(Fill.pressed, in: Capsule())
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
        // The same tile a widget's card and Shelf chip carry once installed.
        CardIconTile(symbol: entry.icon ?? "app.dashed", color: Self.accent(for: entry), size: size)
    }
}

/// Command / Workflow / Script, as a tinted capsule with its name.
struct GalleryTypeBadge: View {
    let kind: String

    var body: some View {
        Pill(text: WidgetTypeName.name(kind))
    }
}

/// A registry screenshot, whole, in a soft band of fixed height. While it
/// loads the band waits; without one (or on failure) it shows `placeholder`.
/// Screenshots are pictures of a widget card, so cropping one to fill the
/// band cut its edges into stray vertical lines.
struct GalleryScreenshot<Placeholder: View>: View {
    let url: URL?
    let name: String
    let height: CGFloat
    @ViewBuilder var placeholder: () -> Placeholder

    var body: some View {
        RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
            .fill(Fill.card)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .overlay {
                if let url {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case let .success(image):
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .padding(Spacing.xs)
                                .accessibilityLabel("Preview of \(name)")
                        case .empty:
                            // The shape of a card, not a spinner: the band
                            // keeps its look while the picture arrives.
                            GalleryPreviewSkeleton()
                        default:
                            placeholder()
                        }
                    }
                } else {
                    placeholder()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }
}

/// A widget without a screenshot, drawn as the card it will be: its tile and
/// name over a few placeholder rows, on its colour's faint wash. Reads as a
/// widget, where a big symbol on a pastel field read as missing artwork.
struct GalleryPreviewStandIn: View {
    let symbol: String
    let color: Color
    let name: String

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [color.opacity(Fill.Wash.soft), .clear],
                startPoint: .top, endPoint: .bottom
            )
            VStack(alignment: .leading, spacing: Spacing.xs) {
                HStack(spacing: Spacing.stack) {
                    CardIconTile(symbol: symbol, color: color)
                    Text(name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                }
                GalleryPreviewSkeleton(tint: color)
            }
            .padding(Spacing.cardInset)
            .frame(width: Self.cardWidth, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Radius.nested(in: Radius.card, inset: Spacing.xs), style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .elevation(.control)
            )
        }
        .accessibilityHidden(true)
    }

    static let cardWidth: CGFloat = 200
}

/// Placeholder rows: a wide headline bar in the widget's colour, then two
/// quiet lines.
struct GalleryPreviewSkeleton: View {
    var tint: Color?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.stack) {
            bar(width: 0.45, height: Spacing.s, fill: tint.map { AnyShapeStyle($0.opacity(Fill.Wash.strong)) })
            bar(width: 0.9, height: Spacing.stack, fill: nil)
            bar(width: 0.65, height: Spacing.stack, fill: nil)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(tint == nil ? Spacing.m : 0)
        .accessibilityHidden(true)
    }

    private func bar(width: CGFloat, height: CGFloat, fill: AnyShapeStyle?) -> some View {
        GeometryReader { proxy in
            Capsule()
                .fill(fill ?? AnyShapeStyle(Fill.pressed))
                .frame(width: proxy.size.width * width)
        }
        .frame(height: height)
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
