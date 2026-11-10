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

// MARK: - View

/// Find, inspect, install, update, and remove widgets from the registry.
/// The grid and a widget's detail page share this view; the detail page
/// replaces the grid until Back (or Esc).
struct GalleryView: View {
    @ObservedObject var model: GalleryModel
    /// Bumped by ⌘F to put the cursor in the search field.
    @State private var searchFocusRequest = 0
    /// The app's runtime, used to remove widgets. Without one, Remove reports
    /// that it cannot.
    var runtime: WidgetRuntime?

    var body: some View {
        Group {
            if let entry = model.detailEntry {
                GalleryDetailView(entry: entry, model: model)
            } else {
                browser
            }
        }
        .frame(minWidth: 420, minHeight: 320)
        .background(WindowVisibilityReader { model.setWindowVisible($0) })
        .onAppear {
            if let runtime { model.runtime = runtime }
        }
        .onDisappear {
            model.onWindowHidden()
        }
        .onChange(of: model.kindFilter) {
            // A category may not exist for the new type; drop a stale
            // selection so results don't silently empty out.
            if let selected = model.selectedCategory,
               !model.availableCategories.contains(selected) {
                model.selectedCategory = nil
            }
        }
    }

    private var browser: some View {
        VStack(spacing: 0) {
            toolbar
            filters
            Divider()
            content
        }
    }

    // MARK: Toolbar and filters

    private var toolbar: some View {
        HStack(spacing: Spacing.xs) {
            SearchField(
                text: $model.searchText,
                placeholder: String(localized: "Search widgets"),
                focusRequest: searchFocusRequest,
                onCancel: { model.searchText = "" }
            )
            .frame(minWidth: 160, idealWidth: 260, maxWidth: 300)
            .frame(height: 22)
            .accessibilityLabel("Search widgets by name, description, or tag")
            .hoverHint("Search", key: "⌘F")
            // ⌘F puts the cursor in the field, as it does in the popup.
            .background {
                Button("Search") { searchFocusRequest += 1 }
                    .keyboardShortcut("f", modifiers: .command)
                    .hidden()
                    .accessibilityHidden(true)
            }
            Spacer(minLength: Spacing.xs)
            Button {
                WidgetInstaller.shared.promptForURL()
            } label: {
                Label("Install Widget from URL…", systemImage: "link")
            }
            .buttonStyle(.glass(.secondary))
            .controlSize(.small)
            .help("Install a widget from a GitHub repository or a .zip/.mbw link")
            Button {
                HubWindowController.shared.show(tab: .create)
            } label: {
                Label("Create Widget…", systemImage: "wand.and.stars")
            }
            .buttonStyle(.glass(.secondary))
            .controlSize(.small)
            .help("Build your own widget")
            refreshButton
        }
        .padding(.horizontal, Spacing.m)
        .padding(.top, Spacing.s)
        .padding(.bottom, Spacing.xs)
    }

    private var refreshButton: some View {
        Button {
            model.refresh(force: true)
        } label: {
            if model.isLoading {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "arrow.clockwise")
            }
        }
        .buttonStyle(.icon)
        .keyboardShortcut("r", modifiers: .command)
        .disabled(model.isLoading)
        .hoverHint(model.isLoading ? "Loading the widget list…" : "Refresh", key: model.isLoading ? nil : "⌘R", alignment: .trailing)
        .accessibilityLabel(model.isLoading ? "Loading widget list" : "Refresh widget list")
    }

    /// Categories lead, as chips: what a widget is for is the first thing a
    /// person browses by. How it is built (Command, Workflow, Script) is for
    /// authors, so it sits behind a small menu at the end.
    private var filters: some View {
        HStack(spacing: Spacing.xs) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.xxs) {
                    categoryChip(nil, label: String(localized: "All", comment: "Gallery filter: every widget type"))
                    ForEach(model.availableCategories, id: \.self) { category in
                        categoryChip(category, label: GalleryEntryText.categoryLabel(category))
                    }
                }
                .padding(.vertical, Spacing.hair)
            }
            Picker(selection: $model.kindFilter) {
                ForEach(GalleryKindFilter.allCases) { kind in
                    Text(kind.label).tag(kind)
                }
            } label: {
                Label("Type", systemImage: "line.3.horizontal.decrease")
            }
            .pickerStyle(.menu)
            .fixedSize()
            .help("Command widgets run a command; Workflows are built from steps; Scripts run JavaScript")
            resultCount
        }
        .controlSize(.small)
        .padding(.horizontal, Spacing.m)
        .padding(.bottom, Spacing.s)
    }

    private func categoryChip(_ category: String?, label: String) -> some View {
        let selected = model.selectedCategory == category
        return Button {
            model.selectedCategory = category
        } label: {
            Text(label)
                .font(.callout.weight(selected ? .semibold : .regular))
                .padding(.horizontal, Spacing.s)
                .padding(.vertical, Spacing.xxs)
                .foregroundStyle(selected ? Color.white : Color.primary)
                .background(
                    Capsule().fill(selected ? Color.accentColor : Fill.pressed)
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private var resultCount: some View {
        let shown = model.filteredEntries.count
        let total = model.entries.count
        if total > 0 {
            Group {
                if model.filtersAreActive {
                    Text("\(shown) of \(total) widgets")
                } else {
                    Text("^[\(total) widget](inflect: true)")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
    }

    // MARK: Content states

    @ViewBuilder
    private var content: some View {
        if let error = model.loadError, model.entries.isEmpty {
            EmptyStateView(
                symbol: "wifi.exclamationmark",
                title: String(localized: "Couldn’t load the widget list"),
                message: String(localized: "Check your internet connection, then try again."),
                size: .page
            ) {
                StatusBanner(tone: .critical, message: error)
                    .frame(maxWidth: 420)
                retryButton
                    .buttonStyle(.glass(.primary))
            }
        } else if model.entries.isEmpty && (model.isLoading || !model.hasLoaded) {
            EmptyStateView(symbol: nil, title: String(localized: "Loading widgets…"), size: .page) {
                ProgressView()
                    .controlSize(.small)
            }
        } else if model.entries.isEmpty {
            EmptyStateView(
                symbol: "square.grid.2x2",
                title: String(localized: "No widgets yet"),
                message: String(localized: "The widget list is empty. Check again later, or make your own."),
                size: .page
            ) {
                HStack(spacing: Spacing.xs) {
                    retryButton
                        .buttonStyle(.glass(.secondary))
                    Button("Create Widget…") { HubWindowController.shared.show(tab: .create) }
                        .buttonStyle(.glass(.secondary))
                }
            }
        } else if model.filteredEntries.isEmpty {
            noResults
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Spacing.l) {
                    notices
                    if !model.filtersAreActive, !model.packs.isEmpty {
                        packsSection
                    }
                    ForEach(model.sections) { section in
                        sectionView(section)
                    }
                    footer
                }
                .padding(Spacing.m)
            }
        }
    }

    private var noResults: some View {
        let query = model.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return EmptyStateView(
            symbol: "magnifyingglass",
            title: query.isEmpty
                ? String(localized: "No widgets match these filters")
                : String(localized: "No widgets match “\(query)”"),
            message: model.pickerFiltersAreActive
                ? String(localized: "Try a different search, or show every type and category.")
                : String(localized: "Try a different word, or search by what the widget shows."),
            size: .page
        ) {
            HStack(spacing: Spacing.xs) {
                if !query.isEmpty {
                    Button("Clear Search") { model.searchText = "" }
                }
                if model.pickerFiltersAreActive {
                    Button("Show All Widgets") { model.clearFilters() }
                }
            }
            .buttonStyle(.glass(.secondary))
        }
    }

    @ViewBuilder
    private var notices: some View {
        if let notice = model.registryNotice {
            StatusBanner(tone: .warning, message: notice, symbol: "icloud.slash") { retryButton.buttonStyle(.glass(.secondary)) }
        }
        if model.loadError != nil {
            StatusBanner(
                tone: .warning,
                message: String(localized: "Couldn’t refresh the widget list. Showing the widgets already loaded."),
                symbol: "wifi.exclamationmark"
            ) { retryButton.buttonStyle(.glass(.secondary)) }
        }
    }

    private var retryButton: some View {
        Button("Retry") { model.refresh(force: true) }
            .disabled(model.isLoading)
    }

    /// Packs: curated sets installed together, above the shelves.
    private var packsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("Packs")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text("Sets of widgets that work well together. Installing grants no permissions; a widget that needs one asks on its card.")
                .font(.caption)
                .foregroundStyle(.secondary)
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 290), spacing: Spacing.s, alignment: .top)],
                alignment: .leading,
                spacing: Spacing.s
            ) {
                ForEach(model.packs) { pack in
                    let members = model.entries(in: pack)
                    GalleryPackCard(
                        pack: pack,
                        members: members,
                        missing: model.installable(in: pack).count,
                        installedCount: members.filter { model.installedIDs.contains($0.id) }.count,
                        install: { model.installPack(pack) }
                    )
                }
            }
            .padding(.top, Spacing.xxs)
        }
    }

    /// One shelf: title + count, a one-line subtitle, and an adaptive grid of
    /// cards (two columns at hub width, one when narrow).
    private func sectionView(_ section: GalleryModel.GallerySection) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                Text(section.title)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Text("\(section.entries.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .accessibilityLabel(Text("^[\(section.entries.count) widget](inflect: true)"))
            }
            Text(section.subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 290), spacing: Spacing.s, alignment: .top)],
                alignment: .leading,
                spacing: Spacing.s
            ) {
                ForEach(section.entries, id: \.id) { entry in
                    GalleryCard(
                        entry: entry,
                        isInstalled: model.installedIDs.contains(entry.id),
                        updateAvailable: model.updateAvailable(for: entry),
                        requirementStatus: model.requirementStatus[entry.id],
                        install: { model.install(entry) },
                        openDetails: { model.showDetail(entry) }
                    )
                }
            }
            .padding(.top, Spacing.xxs)
        }
    }

    @ViewBuilder
    private var footer: some View {
        if let source = model.sourceDescription {
            Text("Source: \(source)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, Spacing.xxs)
        }
    }
}

/// A pack in the gallery: what it is, what it adds, and one button for
/// whatever is not installed yet.
struct GalleryPackCard: View {
    let pack: RegistryPack
    let members: [RegistryWidgetEntry]
    /// How many members this BarShelf can still add.
    let missing: Int
    let installedCount: Int
    let install: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.xs) {
                Image(systemName: pack.icon ?? "square.stack.3d.up")
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                Text(pack.name).font(.headline)
                Spacer(minLength: Spacing.xs)
                if missing == 0 && installedCount == members.count {
                    Label("Installed", systemImage: StatusTone.success.symbol)
                        .font(.callout)
                        .foregroundStyle(StatusTone.success.color)
                } else if missing == 0 {
                    Text("Needs a newer BarShelf")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Button(installedCount == 0
                           ? String(localized: "Install \(missing)", comment: "Pack button: install every widget in the pack")
                           : String(localized: "Install the other \(missing)", comment: "Pack button: install the pack's widgets not installed yet"),
                           action: install)
                        .buttonStyle(.glass(.primary))
                        .controlSize(.small)
                }
            }
            if let description = pack.description, !description.isEmpty {
                Text(description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(members.map(\.name).joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Spacing.s)
        .cardSurface()
        .accessibilityElement(children: .contain)
    }
}
