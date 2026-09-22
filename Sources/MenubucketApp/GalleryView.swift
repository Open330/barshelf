import AppKit
import MenubucketCore
import SwiftUI

// MARK: - Window shim (the gallery now lives in the hub's Gallery section)

/// Back-compat shim: `GalleryView` is embedded in the hub, so opening the
/// gallery just routes to the hub's Gallery section. Keeps the historical
/// `show()` signature so RootView and the status item menu need no edits.
@MainActor
final class GalleryWindowController {
    static let shared = GalleryWindowController()

    func show() {
        HubWindowController.shared.show(tab: .gallery)
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
    /// A short, user-facing explanation for a fallback or partial registry.
    /// Detailed source errors stay in diagnostics rather than appearing in the
    /// gallery as noisy transport or parser text.
    @Published private(set) var registryNotice: String?

    private let client: RegistryClient
    private let widgetsDirectory: URL
    private let requirementChecker: RequirementChecker
    private var loadTask: Task<Void, Never>?
    private var requirementTask: Task<Void, Never>?
    private var installedStateTask: Task<Void, Never>?
    private var installedWatcher: DirectoryWatcher?
    private var installedWatcherMode: InstalledWatcherMode?
    private var loadGeneration = 0
    private var installedStateGeneration = 0
    private var requirementGeneration = 0
    private var isGalleryVisible = false
    private var hasLoadedOnce = false

    init(
        client: RegistryClient = GalleryModel.makeDefaultClient(),
        widgetsDirectory: URL? = nil,
        requirementChecker: RequirementChecker = .shared
    ) {
        self.client = client
        self.requirementChecker = requirementChecker
        self.widgetsDirectory = widgetsDirectory
            ?? WidgetRuntime.applicationSupportDirectory
                .appendingPathComponent("widgets", isDirectory: true)
    }

    /// Default client: env override → project remote URL → bundled fallback.
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

    var filtersAreActive: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || kindFilter != .all || selectedCategory != nil
    }

    func clearFilters() {
        searchText = ""
        kindFilter = .all
        selectedCategory = nil
    }

    struct GallerySection: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let entries: [RegistryWidgetEntry]
    }

    /// Two shelves: built-ins first, then the custom-tool integrations
    /// (`collection == "custom"` — muxa, aas, otpeek, stashbar). Sections
    /// respect the active filters and drop out when they empty.
    var sections: [GallerySection] {
        let filtered = filteredEntries
        let custom = filtered.filter { $0.collection?.lowercased() == "custom" }
        let builtin = filtered.filter { $0.collection?.lowercased() != "custom" }
        var result: [GallerySection] = []
        if !builtin.isEmpty {
            result.append(GallerySection(
                id: "builtin",
                title: "Built-in Widgets",
                subtitle: "Native widgets that work out of the box.",
                entries: builtin
            ))
        }
        if !custom.isEmpty {
            result.append(GallerySection(
                id: "custom",
                title: "Custom Widgets",
                subtitle: "Companions for your own tools — muxa, aas, otpeek, Stashbar.",
                entries: custom
            ))
        }
        return result
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
        isGalleryVisible = true
        startWatchingInstalledWidgets()
        refreshInstalledStates()
        // A CLI may have been installed while BarShelf was running. Recheck
        // only when the gallery becomes visible (and on manual refresh), not
        // continuously while cards render.
        requirementChecker.invalidateCache()
        recomputeRequirements()
        if !hasLoadedOnce {
            refresh(force: false)
        }
    }

    /// Called when the Gallery section leaves the view hierarchy, including
    /// when its containing hub window closes. Keeping an FSEvents stream alive
    /// while the gallery is hidden would otherwise wake the app for unrelated
    /// filesystem activity.
    func onWindowHidden() {
        isGalleryVisible = false
        loadTask?.cancel()
        loadTask = nil
        // A cancelled load returns before its normal cleanup. Clearing this
        // here keeps a later appearance from inheriting a stuck spinner and a
        // disabled refresh button.
        loadGeneration += 1
        isLoading = false
        requirementTask?.cancel()
        requirementTask = nil
        // A requirement probe is deliberately detached from the main actor.
        // Invalidate its result as well as cancelling it, because a blocking
        // PATH probe can complete after cancellation.
        requirementGeneration += 1
        installedStateTask?.cancel()
        installedStateTask = nil
        installedStateGeneration += 1
        installedWatcher?.cancel()
        installedWatcher = nil
        installedWatcherMode = nil
    }

    /// Screenshot/preview support: inject entries directly (no registry
    /// fetch, no requirement probes) so offscreen renders are deterministic.
    func setEntries(forPreview entries: [RegistryWidgetEntry]) {
        self.entries = entries
        self.hasLoadedOnce = true
    }

    func refresh(force: Bool) {
        loadTask?.cancel()
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        loadError = nil
        if force {
            requirementChecker.invalidateCache()
            // Do not make CLI availability wait on the registry request. A
            // forced refresh may fail or fall back to stale data, while the
            // already visible cards can still reflect a newly installed tool.
            recomputeRequirements()
        }
        loadTask = Task { [weak self, client] in
            do {
                let result = try await client.load(forceRefresh: force)
                guard !Task.isCancelled, let self,
                      self.loadGeneration == generation
                else { return }
                self.entries = result.index.widgets
                self.warnings = result.warnings
                self.sourceDescription = result.source.displayName
                self.registryName = result.index.name
                self.registryNotice = Self.notice(for: result)
                self.hasLoadedOnce = true
                self.recomputeRequirements()
            } catch {
                guard !Task.isCancelled, let self,
                      self.loadGeneration == generation
                else { return }
                self.loadError = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
            guard !Task.isCancelled, let self,
                  self.loadGeneration == generation
            else { return }
            self.isLoading = false
            self.loadTask = nil
            self.refreshInstalledStates()
        }
    }

    private nonisolated static func notice(
        for result: RegistryClient.LoadResult
    ) -> String? {
        let warningText = result.warnings.joined(separator: " ").lowercased()
        if warningText.contains("refresh failed"), case .cache = result.source {
            return "Couldn’t refresh the registry. Showing cached widgets."
        }
        if case .bundled = result.source,
           warningText.contains("unavailable") || warningText.contains("failed") {
            return "Using the bundled widget registry while the online registry is unavailable."
        }
        if !result.warnings.isEmpty {
            return "Some registry details could not be loaded."
        }
        return nil
    }

    /// Kicks off the existing GUI install flow (per-widget confirmation
    /// dialog with the permission summary, then the completion alert).
    func install(_ entry: RegistryWidgetEntry) {
        WidgetInstaller.shared.install(registryEntry: entry) { [weak self] in
            self?.refreshInstalledStates()
        }
    }

    /// Installed = the widget's install directory exists (same rule as the
    /// installer's update detection). File access runs at utility priority, so
    /// a registry with many entries never blocks the gallery's main actor.
    /// A generation check drops late results when another filesystem event or
    /// registry refresh supersedes the scan.
    func refreshInstalledStates() {
        guard isGalleryVisible else { return }
        installedStateTask?.cancel()
        installedStateGeneration += 1
        let generation = installedStateGeneration
        let entries = entries
        let widgetsDirectory = widgetsDirectory
        installedStateTask = Task { @MainActor [weak self] in
            let scanTask = Task.detached(priority: .utility) {
                Self.readInstalledState(
                    for: entries, widgetsDirectory: widgetsDirectory
                )
            }
            let state = await withTaskCancellationHandler(operation: {
                await scanTask.value
            }, onCancel: {
                scanTask.cancel()
            })
            guard !Task.isCancelled,
                  let self,
                  self.installedStateGeneration == generation
            else { return }
            if self.installedIDs != state.ids {
                self.installedIDs = state.ids
            }
            if self.installedVersions != state.versions {
                self.installedVersions = state.versions
            }
        }
    }

    /// Keeps cards in sync with installs performed by another process while
    /// the gallery is visible. Watching both the directory and its parent also
    /// covers the first CLI install, which creates `widgets/` itself.
    private func startWatchingInstalledWidgets() {
        guard installedWatcher == nil else { return }
        installWatcher(mode: desiredInstalledWatcherMode)
    }

    private enum InstalledWatcherMode: Equatable {
        case widgetsDirectory
        case parentDirectory
    }

    private var desiredInstalledWatcherMode: InstalledWatcherMode {
        FileManager.default.fileExists(atPath: widgetsDirectory.path)
            ? .widgetsDirectory
            : .parentDirectory
    }

    private func installWatcher(mode: InstalledWatcherMode) {
        do {
            let paths: [String]
            switch mode {
            case .widgetsDirectory:
                paths = [widgetsDirectory.path]
            case .parentDirectory:
                paths = [widgetsDirectory.deletingLastPathComponent().path]
            }
            installedWatcher = try DirectoryWatcher(
                paths: paths,
                debounce: 0.25
            ) { [weak self] in
                self?.handleInstalledWidgetDirectoryChange()
            }
            installedWatcherMode = mode
        } catch {
            // A failed watcher must not break the gallery. The installer
            // completion callback still refreshes its own cards.
            installedWatcher = nil
            installedWatcherMode = nil
        }
    }

    private func handleInstalledWidgetDirectoryChange() {
        guard isGalleryVisible else { return }
        let desiredMode = desiredInstalledWatcherMode
        if installedWatcherMode != desiredMode {
            installedWatcher?.cancel()
            installedWatcher = nil
            installedWatcherMode = nil
            installWatcher(mode: desiredMode)
        }
        refreshInstalledStates()
    }

    private struct InstalledState: Sendable {
        let ids: Set<String>
        let versions: [String: String]
    }

    private nonisolated static func readInstalledState(
        for entries: [RegistryWidgetEntry], widgetsDirectory: URL
    ) -> InstalledState {
        let fm = FileManager.default
        var installed: Set<String> = []
        var versions: [String: String] = [:]
        for entry in entries {
            guard !Task.isCancelled else {
                return InstalledState(ids: installed, versions: versions)
            }
            let directory = widgetsDirectory.appendingPathComponent(entry.id)
            guard fm.fileExists(atPath: directory.path) else { continue }
            installed.insert(entry.id)
            if let version = installedVersion(inWidgetDirectory: directory) {
                versions[entry.id] = version
            }
        }
        return InstalledState(ids: installed, versions: versions)
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

    deinit {
        loadTask?.cancel()
        requirementTask?.cancel()
        installedStateTask?.cancel()
        installedWatcher?.cancel()
    }

    /// Resolves `requires` PATH status for every entry off the main thread
    /// (RequirementChecker caches, so this is a one-time cost per binary), then
    /// publishes the map back on the main actor.
    func recomputeRequirements() {
        guard isGalleryVisible else { return }
        requirementTask?.cancel()
        requirementGeneration += 1
        let generation = requirementGeneration
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
        let checker = requirementChecker
        requirementTask = Task.detached(priority: .utility) {
            var resolved: [String: RequirementChecker.Status] = [:]
            for item in pending {
                if Task.isCancelled { return }
                resolved[item.id] = checker.status(forRequires: item.requires)
            }
            let result = resolved
            await MainActor.run { [weak self] in
                guard let self, !Task.isCancelled,
                      self.requirementGeneration == generation
                else { return }
                self.requirementStatus = result
            }
        }
    }
}

// MARK: - View

struct GalleryView: View {
    @ObservedObject var model: GalleryModel

    var body: some View {
        VStack(spacing: 0) {
            header
            filters
            Divider()
            content
        }
        .frame(minWidth: 420, minHeight: 320)
        .onDisappear {
            model.onWindowHidden()
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
            if model.filtersAreActive {
                Button("Clear Filters") {
                    model.clearFilters()
                }
                .controlSize(.small)
                .help("Show all widgets")
                .accessibilityLabel("Clear all gallery filters")
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
        if model.filtersAreActive {
            if !model.searchText.isEmpty {
                return "No widgets match \"\(model.searchText)\""
            }
            return "No widgets match the selected filters"
        }
        return "No widgets in the registry"
    }

    @ViewBuilder
    private var content: some View {
        if let error = model.loadError, model.entries.isEmpty {
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
                if model.filtersAreActive {
                    Button("Clear Filters") { model.clearFilters() }
                        .accessibilityLabel("Clear all gallery filters")
                }
                if let notice = model.registryNotice {
                    registryNotice(notice)
                        .padding(.top, 8)
                }
                if model.loadError != nil {
                    refreshFailureNotice()
                        .padding(.top, 8)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if let notice = model.registryNotice {
                        registryNotice(notice)
                    }
                    if model.loadError != nil {
                        refreshFailureNotice()
                    }
                    ForEach(model.sections) { section in
                        sectionView(section)
                    }
                    footer
                }
                .padding(12)
            }
        }
    }

    private func registryNotice(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button("Retry") { model.refresh(force: true) }
                .controlSize(.small)
                .disabled(model.isLoading)
        }
        .padding(10)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Registry status: \(text)")
    }

    private func refreshFailureNotice() -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "wifi.exclamationmark")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Couldn’t refresh the registry. Showing the widgets already loaded.")
                    .font(.caption)
            }
            Spacer(minLength: 0)
            Button("Retry") { model.refresh(force: true) }
                .controlSize(.small)
                .disabled(model.isLoading)
        }
        .padding(10)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Registry refresh failed. Showing widgets already loaded.")
    }

    /// One shelf: title + count, a one-line subtitle, and an adaptive grid of
    /// compact cards (two columns at hub width, one when narrow).
    private func sectionView(_ section: GalleryModel.GallerySection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(section.title)
                    .font(.system(size: 13, weight: .semibold))
                Text("\(section.entries.count)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
                Spacer()
            }
            Text(section.subtitle)
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.top, -4)
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 290), spacing: 10, alignment: .top)],
                alignment: .leading,
                spacing: 10
            ) {
                ForEach(section.entries, id: \.id) { entry in
                    GalleryCard(
                        entry: entry,
                        isInstalled: model.installedIDs.contains(entry.id),
                        updateAvailable: model.updateAvailable(for: entry),
                        requirementStatus: model.requirementStatus[entry.id],
                        install: { model.install(entry) }
                    )
                }
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
        if updateAvailable {
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
