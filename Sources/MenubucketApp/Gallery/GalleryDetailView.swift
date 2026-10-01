import AppKit
import MenubucketCore
import SwiftUI

/// A widget's page inside the gallery: what it is, what it may do, what it
/// needs, and the action that fits its state — Install, Update, or Open,
/// plus Remove… once installed. Back (or Esc) returns to the grid.
struct GalleryDetailView: View {
    let entry: RegistryWidgetEntry
    @ObservedObject var model: GalleryModel
    /// False lays the page out flat, for `ImageRenderer` (screenshots).
    var scrolls = true

    @State private var requirementStatus: [GalleryRequirement: RequirementChecker.Status] = [:]
    @State private var confirmingRemove = false

    private var isInstalled: Bool { model.installedIDs.contains(entry.id) }
    private var updateAvailable: Bool { model.updateAvailable(for: entry) }
    private var requirements: [GalleryRequirement] {
        GalleryRequirementText.requirements(from: entry.requires)
    }

    var body: some View {
        VStack(spacing: 0) {
            backBar
            Divider()
            scrollContainer {
                VStack(alignment: .leading, spacing: Spacing.l) {
                    header
                    if let error = model.removeError {
                        StatusBanner(tone: .critical, message: error)
                    }
                    if let url = GalleryLinks.screenshotURL(entry) {
                        GalleryScreenshot(url: url, name: entry.name, height: 240)
                    }
                    if let description = entry.description, !description.isEmpty {
                        Text(description)
                            .font(.body)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    permissionsSection
                    if !requirements.isEmpty {
                        requirementsSection
                    }
                    informationSection
                }
                .padding(Spacing.l)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task(id: entry.id) {
            requirementStatus = await model.requirementStatuses(for: requirements)
        }
        .onExitCommand { model.closeDetail() }
        .confirmationDialog(
            "Remove “\(entry.name)”?",
            isPresented: $confirmingRemove
        ) {
            Button("Remove", role: .destructive) { model.remove(entry) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes the widget and its settings from this Mac. You can install it again from the Gallery.")
        }
    }

    @ViewBuilder
    private func scrollContainer<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        if scrolls {
            ScrollView { content() }
        } else {
            content()
        }
    }

    // MARK: Header

    private var backBar: some View {
        HStack {
            Button {
                model.closeDetail()
            } label: {
                Label("Gallery", systemImage: "chevron.left")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.cancelAction)
            .help("Back to all widgets (Esc)")
            .accessibilityLabel("Back to Gallery")
            Spacer()
        }
        .padding(.horizontal, Spacing.m)
        .padding(.vertical, Spacing.xs)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: Spacing.m) {
            GalleryIconTile(entry: entry, size: 64)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(entry.name)
                    .font(.title2.weight(.semibold))
                    .textSelection(.enabled)
                    .accessibilityAddTraits(.isHeader)
                HStack(spacing: Spacing.xs) {
                    if let kind = entry.kind {
                        GalleryTypeBadge(kind: kind)
                            .accessibilityLabel("Type: \(WidgetTypeName.name(kind))")
                    }
                    if let version = entry.version {
                        Text("Version \(version)")
                            .monospacedDigit()
                    }
                    if let author = entry.author, !author.isEmpty {
                        Text("by \(author)")
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                statusLabel
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            actions
        }
    }

    private var statusLabel: some View {
        let text = GalleryCard.status(
            entry: entry, isInstalled: isInstalled, updateAvailable: updateAvailable
        )
        let symbol = updateAvailable
            ? "arrow.down.circle.fill"
            : (isInstalled ? "checkmark.circle.fill" : "circle.dashed")
        let tone: Color = updateAvailable
            ? StatusTone.info.color
            : (isInstalled ? StatusTone.success.color : .secondary)
        return Label(text, systemImage: symbol)
            .font(.caption)
            .foregroundStyle(tone)
            .padding(.top, 2)
    }

    @ViewBuilder
    private var actions: some View {
        VStack(alignment: .trailing, spacing: Spacing.xs) {
            if let needs = GalleryModel.needsNewerHost(entry), !isInstalled {
                Text(needs)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if updateAvailable {
                Button("Update") { model.install(entry) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .help("Install the newer version from the registry")
                    .accessibilityLabel("Update \(entry.name)")
            } else if isInstalled {
                Button("Open") {
                    HubWindowController.shared.showWidgetSettings(widgetID: entry.id)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .help("Show this widget’s settings")
                .accessibilityLabel("Open \(entry.name) settings")
            } else {
                Button("Install") { model.install(entry) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityLabel("Install \(entry.name)")
            }
            if isInstalled {
                Button("Remove…", role: .destructive) { confirmingRemove = true }
                    .help("Delete this widget from your Mac")
                    .accessibilityLabel("Remove \(entry.name)")
            }
        }
        .controlSize(.large)
    }

    // MARK: Sections

    private func section<Content: View>(
        _ title: LocalizedStringKey, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: Spacing.s) {
                content()
            }
            .padding(Spacing.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface()
        }
    }

    private var permissionsSection: some View {
        let lines = GalleryPermissionText.lines(for: entry.permissions)
        return section("What It Can Do") {
            if lines.isEmpty {
                row(symbol: "checkmark.shield", tint: StatusTone.success.color) {
                    Text("Needs no special permissions.")
                }
            } else {
                ForEach(lines, id: \.self) { line in
                    row(symbol: line.symbol, tint: .accentColor) {
                        Text(line.sentence)
                    }
                }
                Text("BarShelf asks you to allow these the first time the widget runs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var requirementsSection: some View {
        section("What It Needs") {
            ForEach(requirements, id: \.self) { requirement in
                requirementRow(requirement)
            }
        }
    }

    private func requirementRow(_ requirement: GalleryRequirement) -> some View {
        let status = requirementStatus[requirement]
        let tone: StatusTone? = switch status {
        case .satisfied: .success
        case .missing: .warning
        default: nil
        }
        return VStack(alignment: .leading, spacing: Spacing.xxs) {
            row(
                symbol: tone?.symbol ?? "wrench.and.screwdriver",
                tint: tone?.color ?? .secondary
            ) {
                switch status {
                case .satisfied: Text("\(requirement.name) — installed")
                case .missing: Text("\(requirement.name) — not installed")
                case .unknown: Text(requirement.name)
                case nil: Text("\(requirement.name) — checking…")
                }
            }
            if status == .missing {
                installHint(for: requirement)
                    .padding(.leading, 28)
            }
        }
    }

    @ViewBuilder
    private func installHint(for requirement: GalleryRequirement) -> some View {
        if let command = requirement.installCommand {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text("Install it with Homebrew in Terminal:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: Spacing.xs) {
                    Text(command)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .padding(.horizontal, Spacing.xs)
                        .padding(.vertical, Spacing.xxs)
                        .background(
                            Color.secondary.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                        )
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                    }
                    .controlSize(.small)
                    .accessibilityLabel("Copy install command")
                }
            }
        } else if let homepage = GalleryLinks.homepageURL(entry) {
            HStack(spacing: Spacing.xxs) {
                Text("Install \(requirement.name) first —")
                Link("see how on its project page", destination: homepage)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
            Text("Install \(requirement.name) on this Mac first. The widget can still be installed now.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var informationSection: some View {
        section("Information") {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Spacing.m, verticalSpacing: Spacing.xs) {
                if let kind = entry.kind {
                    infoRow("Type", WidgetTypeName.name(kind))
                }
                if let version = entry.version {
                    infoRow("Version", version)
                }
                if let installed = model.installedVersions[entry.id], isInstalled {
                    infoRow("Installed", installed)
                }
                if let category = entry.category, !category.isEmpty {
                    infoRow("Category", category)
                }
                if let tags = entry.tags, !tags.isEmpty {
                    infoRow("Tags", tags.joined(separator: ", "))
                }
                if let author = entry.author, !author.isEmpty {
                    infoRow("Author", author)
                }
                infoRow("Identifier", entry.id)
            }
            let links = linkItems
            if !links.isEmpty {
                HStack(spacing: Spacing.m) {
                    ForEach(links, id: \.url) { link in
                        Link(destination: link.url) {
                            Label(link.title, systemImage: link.symbol)
                        }
                        .help(link.url.absoluteString)
                    }
                }
                .font(.callout)
            }
        }
    }

    private func infoRow(_ label: LocalizedStringKey, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(value)
                .textSelection(.enabled)
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }

    private struct LinkItem {
        let title: LocalizedStringKey
        let symbol: String
        let url: URL
    }

    private var linkItems: [LinkItem] {
        var items: [LinkItem] = []
        if let url = GalleryLinks.readmeURL(entry) {
            items.append(LinkItem(title: "Details", symbol: "doc.text", url: url))
        }
        if let url = GalleryLinks.homepageURL(entry) {
            items.append(LinkItem(title: "Project Page", symbol: "safari", url: url))
        }
        if let url = GalleryLinks.sourceURL(entry),
           !items.contains(where: { $0.url == url }) {
            items.append(LinkItem(title: "Source", symbol: "chevron.left.forwardslash.chevron.right", url: url))
        }
        return items
    }

    private func row<Content: View>(
        symbol: String, tint: Color, @ViewBuilder text: () -> Content
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .frame(width: 20)
                .accessibilityHidden(true)
            text()
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}
