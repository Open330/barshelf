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

@MainActor
final class GalleryModel: ObservableObject {
    @Published var searchText: String = ""
    @Published private(set) var entries: [RegistryWidgetEntry] = []
    @Published private(set) var installedIDs: Set<String> = []
    @Published private(set) var isLoading = false
    @Published private(set) var loadError: String?
    @Published private(set) var warnings: [String] = []
    @Published private(set) var sourceDescription: String?
    @Published private(set) var registryName: String?

    private let client: RegistryClient
    private var loadTask: Task<Void, Never>?
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
        guard !query.isEmpty else { return entries }
        return entries.filter { entry in
            if entry.name.lowercased().contains(query) { return true }
            if let tags = entry.tags,
               tags.contains(where: { $0.lowercased().contains(query) }) {
                return true
            }
            return false
        }
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
    /// installer's update detection).
    func refreshInstalledStates() {
        let widgetsDir = WidgetRuntime.applicationSupportDirectory
            .appendingPathComponent("widgets", isDirectory: true)
        let fm = FileManager.default
        var installed: Set<String> = []
        for entry in entries
        where fm.fileExists(atPath: widgetsDir.appendingPathComponent(entry.id).path) {
            installed.insert(entry.id)
        }
        installedIDs = installed
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
            Divider()
            content
        }
        .frame(minWidth: 420, minHeight: 320)
        .onReceive(installedPoll) { _ in
            model.refreshInstalledStates()
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
            TextField("Search by name or tag", text: $model.searchText)
                .textFieldStyle(.plain)
            if model.isLoading {
                ProgressView()
                    .controlSize(.small)
            }
            Button {
                model.refresh(force: true)
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh the registry (bypasses the 24h cache)")
            .disabled(model.isLoading)
        }
        .padding(10)
    }

    @ViewBuilder
    private var content: some View {
        if let error = model.loadError, model.filteredEntries.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "wifi.exclamationmark")
                    .font(.largeTitle)
                    .foregroundColor(.secondary)
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
        } else if model.filteredEntries.isEmpty && !model.isLoading {
            VStack(spacing: 6) {
                Image(systemName: "square.grid.2x2")
                    .font(.largeTitle)
                    .foregroundColor(.secondary)
                Text(model.searchText.isEmpty
                    ? "No widgets in the registry"
                    : "No widgets match \"\(model.searchText)\"")
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(model.filteredEntries, id: \.id) { entry in
                        GalleryCard(
                            entry: entry,
                            isInstalled: model.installedIDs.contains(entry.id),
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
    let install: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: entry.icon ?? "app.dashed")
                .font(.system(size: 22))
                .foregroundColor(.accentColor)
                .frame(width: 36, height: 36)
                .background(Color.accentColor.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(entry.name)
                        .font(.headline)
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
                        .fixedSize(horizontal: false, vertical: true)
                }
                requiresBadge
                permissionChips
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 4) {
                if isInstalled {
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
    @ViewBuilder
    private var requiresBadge: some View {
        if let requires = entry.requires,
           !requires.trimmingCharacters(in: .whitespaces).isEmpty {
            Label("Requires \(requires)", systemImage: "wrench.and.screwdriver")
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.orange.opacity(0.15))
                .foregroundColor(.orange)
                .clipShape(Capsule())
                .padding(.top, 2)
                .help("This widget needs \(requires) installed on your Mac")
        }
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
