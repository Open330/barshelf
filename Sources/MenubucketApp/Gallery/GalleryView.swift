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
        .onChange(of: model.kindFilter) {
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
        StatusBanner(tone: .warning, message: text) { retryButton }
            .accessibilityLabel("Registry status: \(text)")
    }

    private func refreshFailureNotice() -> some View {
        StatusBanner(
            tone: .warning,
            message: "Couldn’t refresh the registry. Showing the widgets already loaded.",
            symbol: "wifi.exclamationmark"
        ) { retryButton }
    }

    private var retryButton: some View {
        Button("Retry") { model.refresh(force: true) }
            .disabled(model.isLoading)
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
