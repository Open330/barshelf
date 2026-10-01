import AppKit
import MenubucketCore
import SwiftUI

// MARK: - Model

/// Top-level kind segments for the gallery filter row. `all` disables the
/// kind predicate; the rest match `RegistryWidgetEntry.kind` exactly.
enum GalleryKindFilter: String, CaseIterable, Identifiable {
    case all, exec, workflow, script

    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: return "All"
        case .exec: return WidgetTypeName.name("exec")
        case .workflow: return WidgetTypeName.name("workflow")
        case .script: return WidgetTypeName.name("script")
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
        // An update this BarShelf would refuse is not one to offer.
        guard Self.needsNewerHost(entry) == nil else { return false }
        return SemanticVersionOrder.isNewer(
            entry.version, than: installedVersions[entry.id]
        )
    }

    /// Why this BarShelf cannot install `entry`, or nil.
    static func needsNewerHost(_ entry: RegistryWidgetEntry) -> String? {
        guard let required = entry.minHostVersion, let host = WidgetRuntime.hostVersion,
              SemanticVersionOrder.isNewer(required, than: host)
        else { return nil }
        return "Needs BarShelf \(required) or later"
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
