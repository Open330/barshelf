import AppKit
import MenubucketCore
import SwiftUI

/// Widget management section of the hub (moved here from the R11 Settings
/// "Widgets" tab and upgraded): a `List` grouped by bucket with `.onMove`
/// drag-reorder inside each bucket, an enable toggle, bucket menu, per-widget
/// settings sheet, reveal, and remove. Disabled widgets are shown too (they
/// never appear in `runtime.pages`).
struct HubWidgetsView: View {
    @ObservedObject var runtime: WidgetRuntime

    @State private var settingsSheetWidget: LoadedWidget?
    @State private var removalTarget: LoadedWidget?
    @State private var newBucketTarget: LoadedWidget?
    @State private var newBucketName = ""
    @State private var widgetActionError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Installed Widgets")
                    .font(.headline)
                Spacer()
                Text("\(runtime.widgets.count) total")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 8)

            if runtime.widgets.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "square.grid.2x2")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                        .accessibilityHidden(true)
                    Text("No widgets installed yet.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(buckets, id: \.self) { bucket in
                        Section {
                            ForEach(widgets(inBucket: bucket)) { widget in
                                widgetRow(widget)
                                    .padding(.vertical, 3)
                            }
                            .onMove { source, destination in
                                move(bucket: bucket, from: source, to: destination)
                            }
                        } header: {
                            Text(bucket)
                        }
                    }
                }
            }
        }
        .sheet(item: $settingsSheetWidget) { widget in
            WidgetSettingsView(widget: widget, runtime: runtime)
        }
        .alert(
            "Remove Widget?",
            isPresented: Binding(
                get: { removalTarget != nil },
                set: { if !$0 { removalTarget = nil } }
            ),
            presenting: removalTarget
        ) { widget in
            Button("Remove", role: .destructive) { performRemoval(widget) }
            Button("Cancel", role: .cancel) { removalTarget = nil }
        } message: { widget in
            Text("This permanently deletes \"\(widget.manifest.name)\" and all of its data. This cannot be undone.")
        }
        .alert(
            "New Bucket",
            isPresented: Binding(
                get: { newBucketTarget != nil },
                set: { if !$0 { newBucketTarget = nil } }
            ),
            presenting: newBucketTarget
        ) { widget in
            TextField("Bucket name", text: $newBucketName)
            Button("Move") {
                let name = newBucketName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty { runtime.moveWidget(id: widget.id, toGroup: name) }
                newBucketName = ""
                newBucketTarget = nil
            }
            Button("Cancel", role: .cancel) {
                newBucketName = ""
                newBucketTarget = nil
            }
        } message: { _ in
            Text("Move this widget to a new bucket.")
        }
        .alert(
            "Could Not Remove Widget",
            isPresented: Binding(
                get: { widgetActionError != nil },
                set: { if !$0 { widgetActionError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { widgetActionError = nil }
        } message: {
            Text(widgetActionError ?? "")
        }
    }

    @ViewBuilder
    private func widgetRow(_ widget: LoadedWidget) -> some View {
        let disabled = runtime.prefs.isDisabled(widget.id)
        let group = runtime.effectiveGroup(for: widget.id)
        HStack(spacing: 10) {
            Image(systemName: widget.manifest.icon ?? "square.grid.2x2")
                .frame(width: 20)
                .foregroundColor(disabled ? .secondary : .primary)

            VStack(alignment: .leading, spacing: 2) {
                Text(widget.manifest.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(disabled ? .secondary : .primary)
                Text(widget.id)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .frame(minWidth: 130, alignment: .leading)

            Spacer(minLength: 8)

            Toggle("", isOn: Binding(
                get: { !runtime.prefs.isDisabled(widget.id) },
                set: { runtime.setWidgetDisabled(widget.id, !$0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .help(disabled ? "Enable widget" : "Disable widget")
            .accessibilityLabel("\(disabled ? "Enable" : "Disable") \(widget.manifest.name)")

            Menu {
                ForEach(bucketOptions(current: group), id: \.self) { option in
                    Button {
                        runtime.moveWidget(id: widget.id, toGroup: option)
                    } label: {
                        if option == group {
                            Label(option, systemImage: "checkmark")
                        } else {
                            Text(option)
                        }
                    }
                }
                Divider()
                Button("New Bucket…") {
                    newBucketName = ""
                    newBucketTarget = widget
                }
            } label: {
                Text(group)
                    .lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 110)
            .help("Move to bucket")
            .accessibilityLabel("Bucket for \(widget.manifest.name)")

            Button {
                settingsSheetWidget = widget
            } label: {
                Image(systemName: "gearshape")
            }
            .help("Settings…")
            .accessibilityLabel("Settings for \(widget.manifest.name)")

            Button {
                revealInFinder(widget)
            } label: {
                Image(systemName: "folder")
            }
            .help("Reveal in Finder")
            .accessibilityLabel("Reveal \(widget.manifest.name) in Finder")

            Button(role: .destructive) {
                removalTarget = widget
            } label: {
                Image(systemName: "trash")
            }
            .help("Remove…")
            .accessibilityLabel("Remove \(widget.manifest.name)")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
    }

    // MARK: - Ordering

    /// All widgets sorted by effective bucket, then override order, then name —
    /// includes disabled widgets (which never appear in `runtime.pages`).
    private var widgetRows: [LoadedWidget] {
        runtime.widgets.sorted { lhs, rhs in
            let lg = runtime.effectiveGroup(for: lhs.id)
            let rg = runtime.effectiveGroup(for: rhs.id)
            if lg != rg {
                return lg.localizedCaseInsensitiveCompare(rg) == .orderedAscending
            }
            let lo = orderValue(lhs)
            let ro = orderValue(rhs)
            if lo != ro { return lo < ro }
            return lhs.manifest.name.localizedCaseInsensitiveCompare(rhs.manifest.name)
                == .orderedAscending
        }
    }

    /// Bucket section headers in the same order as `widgetRows`.
    private var buckets: [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for widget in widgetRows {
            let group = runtime.effectiveGroup(for: widget.id)
            if seen.insert(group).inserted { ordered.append(group) }
        }
        return ordered
    }

    private func widgets(inBucket bucket: String) -> [LoadedWidget] {
        widgetRows.filter { runtime.effectiveGroup(for: $0.id) == bucket }
    }

    private func orderValue(_ widget: LoadedWidget) -> Double {
        runtime.prefs.override(for: widget.id)?.order ?? Double(widget.order)
    }

    private func bucketOptions(current: String) -> [String] {
        var options = Set(runtime.allGroups)
        options.insert(current)
        return options.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Drag-reorder within one bucket: rewrites that bucket's order overrides
    /// as a dense 0..<n sequence so the arrangement persists (group override is
    /// preserved). Fires `objectWillChange` so the list and popup pages update.
    private func move(bucket: String, from source: IndexSet, to destination: Int) {
        var items = widgets(inBucket: bucket)
        items.move(fromOffsets: source, toOffset: destination)
        for (position, widget) in items.enumerated() {
            runtime.prefs.setOverride(
                group: runtime.prefs.override(for: widget.id)?.group,
                order: Double(position),
                for: widget.id
            )
        }
        runtime.objectWillChange.send()
    }

    private func revealInFinder(_ widget: LoadedWidget) {
        guard let url = runtime.widgetDirectory(for: widget.id) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func performRemoval(_ widget: LoadedWidget) {
        removalTarget = nil
        do {
            try runtime.removeWidget(id: widget.id)
        } catch {
            widgetActionError = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }
}
