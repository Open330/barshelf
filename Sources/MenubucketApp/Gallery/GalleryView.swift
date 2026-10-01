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
                onCancel: { model.searchText = "" }
            )
            .frame(minWidth: 160, idealWidth: 260, maxWidth: 300)
            .frame(height: 22)
            .accessibilityLabel("Search widgets by name, description, or tag")
            Spacer(minLength: Spacing.xs)
            Button {
                WidgetInstaller.shared.promptForURL()
            } label: {
                Label("Install from URL…", systemImage: "link")
            }
            .help("Install a widget from a GitHub repository or a .zip/.mbw link")
            Button {
                HubWindowController.shared.show(tab: .create)
            } label: {
                Label("Create Widget", systemImage: "wand.and.stars")
            }
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
                    .frame(width: 16, height: 16)
            } else {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 16, height: 16)
            }
        }
        .disabled(model.isLoading)
        .help(model.isLoading ? "Loading the widget list…" : "Check for new and updated widgets")
        .accessibilityLabel(model.isLoading ? "Loading widget list" : "Refresh widget list")
    }

    private var filters: some View {
        HStack(spacing: Spacing.m) {
            Picker("Type", selection: $model.kindFilter) {
                ForEach(GalleryKindFilter.allCases) { kind in
                    Text(kind.label).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .help("Command widgets run a command; Workflows are built from steps; Scripts run JavaScript")

            let categories = model.availableCategories
            if !categories.isEmpty {
                Picker("Category", selection: $model.selectedCategory) {
                    Text("All Categories").tag(String?.none)
                    Divider()
                    ForEach(categories, id: \.self) { category in
                        Text(category).tag(String?.some(category))
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
            }

            if model.pickerFiltersAreActive {
                Button("Clear Filters") { model.clearPickerFilters() }
                    .help("Show every type and category")
            }

            Spacer(minLength: 0)
            resultCount
        }
        .controlSize(.small)
        .padding(.horizontal, Spacing.m)
        .padding(.bottom, Spacing.s)
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
                    Text("\(total) widgets")
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
            placeholder(symbol: "wifi.exclamationmark", title: Text("Couldn’t load the widget list")) {
                StatusBanner(tone: .critical, message: error) { retryButton }
                    .frame(maxWidth: 420)
                Text("Check your internet connection, then try again.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } else if model.entries.isEmpty && (model.isLoading || !model.hasLoaded) {
            placeholder(symbol: nil, title: Text("Loading widgets…")) {
                ProgressView()
                    .controlSize(.small)
            }
        } else if model.entries.isEmpty {
            placeholder(symbol: "square.grid.2x2", title: Text("No widgets yet")) {
                Text("The widget list is empty. Check again later, or make your own.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack {
                    retryButton
                    Button("Create Widget") { HubWindowController.shared.show(tab: .create) }
                }
            }
        } else if model.filteredEntries.isEmpty {
            noResults
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Spacing.l) {
                    notices
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
        return placeholder(
            symbol: "magnifyingglass",
            title: query.isEmpty
                ? Text("No widgets match these filters")
                : Text("No widgets match “\(query)”")
        ) {
            Text(model.pickerFiltersAreActive
                ? "Try a different search, or show every type and category."
                : "Try a different word, or search by what the widget shows.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                if !query.isEmpty {
                    Button("Clear Search") { model.searchText = "" }
                }
                if model.pickerFiltersAreActive {
                    Button("Show All Widgets") { model.clearFilters() }
                }
            }
        }
    }

    private func placeholder<Content: View>(
        symbol: String?, title: Text, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: Spacing.s) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            title
                .font(.headline)
                .multilineTextAlignment(.center)
            content()
        }
        .multilineTextAlignment(.center)
        .padding(Spacing.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var notices: some View {
        if let notice = model.registryNotice {
            StatusBanner(tone: .warning, message: notice, symbol: "icloud.slash") { retryButton }
        }
        if model.loadError != nil {
            StatusBanner(
                tone: .warning,
                message: String(localized: "Couldn’t refresh the widget list. Showing the widgets already loaded."),
                symbol: "wifi.exclamationmark"
            ) { retryButton }
        }
    }

    private var retryButton: some View {
        Button("Retry") { model.refresh(force: true) }
            .disabled(model.isLoading)
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
                    .accessibilityLabel("\(section.entries.count) widgets")
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
