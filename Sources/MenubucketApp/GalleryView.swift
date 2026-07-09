import AppKit
import MenubucketCore
import SwiftUI

// MARK: - Window (independent NSWindow — the popup is too small for a gallery)

/// Owns the standalone "Widget Gallery" window. Opened from the status item
/// context menu; a plain resizable window (not a popover) so the card list
/// and search field get real estate.
@MainActor
final class GalleryWindowController {
    static let shared = GalleryWindowController()

    private var window: NSWindow?
    private let model = GalleryModel()

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        if let window {
            window.makeKeyAndOrderFront(nil)
            model.onWindowShown()
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Widget Gallery"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 420, height: 320)
        window.contentView = NSHostingView(rootView: GalleryView(model: model))
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        model.onWindowShown()
    }
}

// MARK: - Model

/// Top-level kind segments for the gallery filter row. `all` disables the
/// kind predicate; the rest match `RegistryWidgetEntry.kind` exactly.
enum GalleryKindFilter: String, CaseIterable, Identifiable {
    case all, exec, workflow, script

    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: return "All"
        case .exec: return "exec"
        case .workflow: return "workflow"
        case .script: return "script"
        }
    }
}

@MainActor
final class GalleryModel: ObservableObject {
    @Published var searchText: String = ""
    /// Kind segment + optional category chip. Both narrow `filteredEntries`.
    @Published var kindFilter: GalleryKindFilter = .all
    @Published var selectedCategory: String?
    @Published private(set) var entries: [RegistryWidgetEntry] = []
    @Published private(set) var installedIDs: Set<String> = []
    /// Installed widget's `widget.json` version, keyed by entry id — the input
    /// to update detection. Absent means "not installed" or "version unknown".
    @Published private(set) var installedVersions: [String: String] = [:]
    /// Requirement (`requires`) PATH status keyed by entry id. Computed off the
    /// main thread; `.unknown` until the first probe resolves.
    @Published private(set) var requirementStatus: [String: RequirementChecker.Status] = [:]
    @Published private(set) var isLoading = false
    @Published private(set) var loadError: String?
    @Published private(set) var warnings: [String] = []
    @Published private(set) var sourceDescription: String?
    @Published private(set) var registryName: String?

    private let client: RegistryClient
    private var loadTask: Task<Void, Never>?
    private var requirementTask: Task<Void, Never>?
    private var hasLoadedOnce = false

    init(client: RegistryClient = GalleryModel.makeDefaultClient()) {
        self.client = client
    }

    /// Default client: env var → remote placeholder URL → bundled fallback.
    /// Fallback candidates cover the packaged app (Resources/registry/) and
    /// running from a source checkout (repo-root registry/).
    nonisolated static func makeDefaultClient() -> RegistryClient {
        var fallbacks: [URL] = []
        if let resources = Bundle.main.resourceURL {
            fallbacks.append(
                resources.appendingPathComponent("registry/index.json")
            )
            fallbacks.append(resources.appendingPathComponent("index.json"))
        }
        // Development: <repo>/Sources/MenubucketApp/GalleryView.swift → <repo>/registry/index.json
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // MenubucketApp
            .deletingLastPathComponent()  // Sources
            .deletingLastPathComponent()  // repo root
        fallbacks.append(
            repoRoot.appendingPathComponent("registry/index.json")
        )
        return RegistryClient(
            configuration: RegistryClient.Configuration(bundledFallbacks: fallbacks)
        )
    }

    var filteredEntries: [RegistryWidgetEntry] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        return entries.filter { entry in
            matchesKind(entry) && matchesCategory(entry) && matchesQuery(entry, query)
        }
    }

    private func matchesKind(_ entry: RegistryWidgetEntry) -> Bool {
        guard kindFilter != .all else { return true }
        return entry.kind == kindFilter.rawValue
    }

    private func matchesCategory(_ entry: RegistryWidgetEntry) -> Bool {
        guard let category = selectedCategory else { return true }
        return categories(of: entry).contains(category)
    }

    private func matchesQuery(_ entry: RegistryWidgetEntry, _ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        if entry.name.lowercased().contains(query) { return true }
        if let tags = entry.tags,
           tags.contains(where: { $0.lowercased().contains(query) }) {
            return true
        }
        return false
    }

    /// Category chip labels for an entry: its curated `category` plus its tags.
    /// Chips filter on this same set so either source matches a selection.
    private func categories(of entry: RegistryWidgetEntry) -> [String] {
        var values: [String] = []
        if let category = entry.category?.trimmingCharacters(in: .whitespaces),
           !category.isEmpty {
            values.append(category)
        }
        values.append(contentsOf: entry.tags ?? [])
        return values
    }

    /// Distinct category chips across the (kind-filtered) registry, sorted so
    /// the chip row is stable. Empty when no entry carries a category or tag.
    var availableCategories: [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for entry in entries where matchesKind(entry) {
            for value in categories(of: entry) where !value.isEmpty {
                let key = value.lowercased()
                if seen.insert(key).inserted { ordered.append(value) }
            }
        }
        return ordered.sorted { $0.lowercased() < $1.lowercased() }
    }

    /// True when the registry advertises a strictly newer version than the
    /// installed `widget.json` — drives the card's primary "Update" button.
    func updateAvailable(for entry: RegistryWidgetEntry) -> Bool {
        guard installedIDs.contains(entry.id) else { return false }
        return SemanticVersionOrder.isNewer(
            entry.version, than: installedVersions[entry.id]
        )
    }

    func onWindowShown() {
        refreshInstalledStates()
        if !hasLoadedOnce {
            refresh(force: false)
        }
    }

    func refresh(force: Bool) {
        loadTask?.cancel()
        isLoading = true
        loadError = nil
        loadTask = Task { [client] in
            do {
                let result = try await client.load(forceRefresh: force)
                guard !Task.isCancelled else { return }
                self.entries = result.index.widgets
                self.warnings = result.warnings
                self.sourceDescription = result.source.displayName
                self.registryName = result.index.name
                self.hasLoadedOnce = true
                self.recomputeRequirements()
                for warning in result.warnings {
                    FileHandle.standardError.write(
                        Data("registry warning: \(warning)\n".utf8)
                    )
                }
            } catch {
                guard !Task.isCancelled else { return }
                self.loadError = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
            self.isLoading = false
            self.refreshInstalledStates()
        }
    }

    /// Kicks off the existing GUI install flow (per-widget confirmation
    /// dialog with the permission summary, then the completion alert).
    func install(_ entry: RegistryWidgetEntry) {
        WidgetInstaller.shared.install(registryEntry: entry) { [weak self] in
            self?.refreshInstalledStates()
        }
    }

    /// Installed = the widget's install directory exists (same rule as the
    /// installer's update detection). Also reads each installed widget's
    /// `widget.json` version so the card can flip to "Update" when the registry
    /// advertises a newer release. Both are cheap directory/file reads.
    func refreshInstalledStates() {
        let widgetsDir = WidgetRuntime.applicationSupportDirectory
            .appendingPathComponent("widgets", isDirectory: true)
        let fm = FileManager.default
        var installed: Set<String> = []
        var versions: [String: String] = [:]
        for entry in entries {
            let dir = widgetsDir.appendingPathComponent(entry.id)
            guard fm.fileExists(atPath: dir.path) else { continue }
            installed.insert(entry.id)
            if let version = Self.installedVersion(inWidgetDirectory: dir) {
                versions[entry.id] = version
            }
        }
        installedIDs = installed
        installedVersions = versions
    }

    /// Reads the top-level `version` string from an installed widget's
    /// `widget.json` (the `Manifest` decoder deliberately ignores this field).
    private nonisolated static func installedVersion(
        inWidgetDirectory directory: URL
    ) -> String? {
        let manifestURL = directory.appendingPathComponent("widget.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let probe = try? JSONDecoder().decode(VersionProbe.self, from: data)
        else { return nil }
        return probe.version
    }

    private struct VersionProbe: Decodable {
        let version: String?
    }

    /// Resolves `requires` PATH status for every entry off the main thread
    /// (RequirementChecker caches, so this is a one-time cost per binary), then
    /// publishes the map back on the main actor.
    func recomputeRequirements() {
        requirementTask?.cancel()
        let pending: [(id: String, requires: String)] = entries.compactMap { entry in
            guard let requires = entry.requires?
                .trimmingCharacters(in: .whitespaces), !requires.isEmpty
            else { return nil }
            return (entry.id, requires)
        }
        guard !pending.isEmpty else {
            requirementStatus = [:]
            return
        }
        requirementTask = Task.detached(priority: .utility) {
            var resolved: [String: RequirementChecker.Status] = [:]
            for item in pending {
                if Task.isCancelled { return }
                resolved[item.id] = RequirementChecker.shared
                    .status(forRequires: item.requires)
            }
            let result = resolved
            await MainActor.run { [weak self] in
                guard let self, !Task.isCancelled else { return }
                self.requirementStatus = result
            }
        }
    }
}

// MARK: - View

struct GalleryView: View {
    @ObservedObject var model: GalleryModel

    /// Cheap periodic re-check so cards flip to "Installed" after the
    /// installer dialogs finish (the flow runs outside this view).
    private let installedPoll = Timer.publish(
        every: 2, on: .main, in: .common
    ).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            header
            filters
            Divider()
            content
        }
        .frame(minWidth: 420, minHeight: 320)
        .onReceive(installedPoll) { _ in
            model.refreshInstalledStates()
        }
        .onChange(of: model.kindFilter) { _ in
            // A category chip may no longer exist for the new kind segment;
            // drop a stale selection so results don't silently empty out.
            if let selected = model.selectedCategory,
               !model.availableCategories.contains(selected) {
                model.selectedCategory = nil
            }
        }
    }

    /// Kind segments + tag/category chips. Both narrow the list; the chip row
    /// hides itself when the registry carries no categories or tags.
    @ViewBuilder
    private var filters: some View {
        let categories = model.availableCategories
        VStack(spacing: 8) {
            Picker("Filter by kind", selection: $model.kindFilter) {
                ForEach(GalleryKindFilter.allCases) { kind in
                    Text(kind.label).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Filter widgets by kind")

            if !categories.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        categoryChip(title: "All", isSelected: model.selectedCategory == nil) {
                            model.selectedCategory = nil
                        }
                        ForEach(categories, id: \.self) { category in
                            categoryChip(
                                title: category,
                                isSelected: model.selectedCategory == category
                            ) {
                                model.selectedCategory =
                                    (model.selectedCategory == category) ? nil : category
                            }
                        }
                    }
                    .padding(.horizontal, 1)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    private func categoryChip(
        title: String, isSelected: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill(
                        isSelected
                            ? Color.accentColor.opacity(0.2)
                            : Color.secondary.opacity(0.12)
                    )
                )
                .foregroundColor(isSelected ? .accentColor : .primary)
                .overlay(
                    Capsule().stroke(
                        isSelected ? Color.accentColor.opacity(0.5) : .clear
                    )
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Category \(title)")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
                .accessibilityHidden(true)
            TextField("Search by name or tag", text: $model.searchText)
                .textFieldStyle(.plain)
                .accessibilityLabel("Search widgets by name or tag")
            if model.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Loading registry")
            }
            Button {
                model.refresh(force: true)
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh the registry (bypasses the 24h cache)")
            .accessibilityLabel("Refresh registry")
            .disabled(model.isLoading)
        }
        .padding(10)
    }

    /// Distinguishes "the registry is empty" from "your filters excluded
    /// everything" so an active kind/category/search filter is discoverable.
    private var emptyStateMessage: String {
        let filtersActive = !model.searchText.isEmpty
            || model.kindFilter != .all
            || model.selectedCategory != nil
        if filtersActive {
            if !model.searchText.isEmpty {
                return "No widgets match \"\(model.searchText)\""
            }
            return "No widgets match the selected filters"
        }
        return "No widgets in the registry"
    }

    @ViewBuilder
    private var content: some View {
        if let error = model.loadError, model.filteredEntries.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "wifi.exclamationmark")
                    .font(.largeTitle)
                    .foregroundColor(.secondary)
                    .accessibilityHidden(true)
                Text("Could not load the widget registry")
                    .font(.headline)
                Text(error)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                Button("Try Again") { model.refresh(force: true) }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.filteredEntries.isEmpty && model.isLoading {
            VStack(spacing: 10) {
                ProgressView()
                Text("Loading widgets…")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.filteredEntries.isEmpty && !model.isLoading {
            VStack(spacing: 6) {
                Image(systemName: "square.grid.2x2")
                    .font(.largeTitle)
                    .foregroundColor(.secondary)
                    .accessibilityHidden(true)
                Text(emptyStateMessage)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(model.filteredEntries, id: \.id) { entry in
                        GalleryCard(
                            entry: entry,
                            isInstalled: model.installedIDs.contains(entry.id),
                            updateAvailable: model.updateAvailable(for: entry),
                            requirementStatus: model.requirementStatus[entry.id],
                            install: { model.install(entry) }
                        )
                    }
                    footer
                }
                .padding(12)
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        if let source = model.sourceDescription {
            Text("Source: \(source)")
                .font(.caption2)
                .foregroundColor(Color.secondary.opacity(0.7))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
        }
    }
}

// MARK: - Card

private struct GalleryCard: View {
    let entry: RegistryWidgetEntry
    let isInstalled: Bool
    /// Registry advertises a newer version than the installed widget.json.
    let updateAvailable: Bool
    /// PATH status of `entry.requires`; `nil` while the probe is pending.
    let requirementStatus: RequirementChecker.Status?
    let install: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            screenshotPreview
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: entry.icon ?? "app.dashed")
                    .font(.system(size: 22))
                    .foregroundColor(.accentColor)
                    .frame(width: 36, height: 36)
                    .background(Color.accentColor.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(entry.name)
                            .font(.headline)
                            .lineLimit(1)
                        if let kind = entry.kind {
                            badge(kind)
                        }
                        if let version = entry.version {
                            Text("v\(version)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    if let description = entry.description {
                        Text(description)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .lineLimit(4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    requiresBadge
                    permissionChips
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .trailing, spacing: 4) {
                    if updateAvailable {
                        Label("Update available", systemImage: "arrow.up.circle.fill")
                            .font(.caption)
                            .foregroundColor(.accentColor)
                        Button("Update", action: install)
                            .keyboardShortcut(.defaultAction)
                            .controlSize(.small)
                            .help("A newer version is available in the registry")
                    } else if isInstalled {
                        Label("Installed", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundColor(.green)
                        Button("Reinstall", action: install)
                            .controlSize(.small)
                    } else {
                        Button("Install", action: install)
                            .keyboardShortcut(.defaultAction)
                            .controlSize(.small)
                    }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.08))
        )
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

    /// Display-only permission chips ("신뢰 UX") — the enforcement gate stays
    /// the first-run approval card after install.
    @ViewBuilder
    private var permissionChips: some View {
        let chips = permissionChipLabels
        if !chips.isEmpty {
            HStack(spacing: 4) {
                ForEach(chips, id: \.self) { chip in
                    Label(chip.text, systemImage: chip.symbol)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.12))
                        .foregroundColor(.secondary)
                        .clipShape(Capsule())
                }
            }
            .padding(.top, 2)
        }
    }

    private struct Chip: Hashable {
        let text: String
        let symbol: String
    }

    private var permissionChipLabels: [Chip] {
        guard let permissions = entry.permissions else { return [] }
        var chips: [Chip] = []
        for command in permissions.exec ?? [] {
            chips.append(Chip(text: "exec: \(command)", symbol: "terminal"))
        }
        if permissions.keychain == true {
            chips.append(Chip(text: "Keychain", symbol: "key"))
        }
        if permissions.notifications == true {
            chips.append(Chip(text: "Notifications", symbol: "bell"))
        }
        return chips
    }
}
