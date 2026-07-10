import AppKit
import MenubucketCore
import SwiftUI
import UniformTypeIdentifiers

/// Widget management section of the hub (moved here from the R11 Settings
/// "Widgets" tab and upgraded): a `List` grouped by panel with `.onMove`
/// drag-reorder inside each panel, an enable toggle, panel menu, per-widget
/// settings sheet, reveal, and remove. Disabled widgets are shown too (they
/// never appear in `runtime.pages`).
struct HubWidgetsView: View {
    @ObservedObject var runtime: WidgetRuntime

    private let layoutSizes = ["XS", "S", "M", "L"]

    @State private var settingsSheetWidget: LoadedWidget?
    @State private var removalTarget: LoadedWidget?
    @State private var duplicateTarget: LoadedWidget?
    @State private var duplicateName = ""
    @State private var newBucketTarget: LoadedWidget?
    @State private var newBucketName = ""
    @State private var widgetActionError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            managementHeader

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
                                    .padding(.vertical, 5)
                            }
                            .onMove { source, destination in
                                move(bucket: bucket, from: source, to: destination)
                            }
                        } header: {
                            HStack(spacing: 4) {
                                Image(systemName: "line.3.horizontal")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                                    .accessibilityHidden(true)
                                Text(bucket)
                                Spacer()
                                Button { moveBucket(bucket, by: -1) } label: {
                                    Image(systemName: "chevron.up")
                                }
                                .buttonStyle(.borderless)
                                .disabled(buckets.first == bucket)
                                .help("Move panel up")
                                .accessibilityLabel("Move panel \(bucket) up")
                                Button { moveBucket(bucket, by: 1) } label: {
                                    Image(systemName: "chevron.down")
                                }
                                .buttonStyle(.borderless)
                                .disabled(buckets.last == bucket)
                                .help("Move panel down")
                                .accessibilityLabel("Move panel \(bucket) down")
                            }
                            .contentShape(Rectangle())
                            .onDrag { NSItemProvider(object: bucket as NSString) }
                            .onDrop(of: [UTType.plainText], isTargeted: nil) { providers in
                                dropPanel(providers, before: bucket)
                            }
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
            Text("This permanently deletes \"\(widget.displayName)\" and all of its data. This cannot be undone.")
        }
        .alert(
            "Add Widget Instance",
            isPresented: Binding(
                get: { duplicateTarget != nil },
                set: { if !$0 { duplicateTarget = nil } }
            ),
            presenting: duplicateTarget
        ) { widget in
            TextField("Instance name (for example jiun-mbp)", text: $duplicateName)
            Button("Add") { performDuplicate(widget) }
            Button("Cancel", role: .cancel) {
                duplicateName = ""
                duplicateTarget = nil
            }
        } message: { widget in
            Text("Add an independently configurable instance of \"\(widget.displayName)\".")
        }
        .alert(
            "New Panel",
            isPresented: Binding(
                get: { newBucketTarget != nil },
                set: { if !$0 { newBucketTarget = nil } }
            ),
            presenting: newBucketTarget
        ) { widget in
            TextField("Panel name", text: $newBucketName)
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
            Text("Move this widget to a new panel.")
        }
        .alert(
            "Widget Action Failed",
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

    private var managementHeader: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Installed Widgets")
                    .font(.system(size: 15, weight: .semibold))
                Text("Drag the handle on each row to arrange popup pages. Panels become pages.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            Spacer()
            statPill("\(runtime.widgets.count)", "total")
            statPill("\(runtime.pages.count)", "pages")
            statPill("\(runtime.prefs.disabled.count)", "disabled")
            Button {
                resetLayoutOverrides()
            } label: {
                Label("Reset Layout", systemImage: "arrow.counterclockwise")
            }
            .controlSize(.small)
            .disabled(runtime.prefs.bucketOverrides.isEmpty)
            .help("Clear custom panel, order, and size overrides")
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 10)
    }

    private func statPill(_ value: String, _ label: String) -> some View {
        VStack(spacing: 0) {
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(width: 54, height: 34)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(Color.primary.opacity(0.08))
        )
    }

    @ViewBuilder
    private func widgetRow(_ widget: LoadedWidget) -> some View {
        let disabled = runtime.prefs.isDisabled(widget.id)
        let group = runtime.effectiveGroup(for: widget.id)
        let size = runtime.effectiveSize(for: widget.id)
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary.opacity(0.75))
                .frame(width: 14)
                .help("Drag to reorder")
                .accessibilityLabel("Drag to reorder \(widget.displayName)")

            Image(systemName: widget.manifest.icon ?? "square.grid.2x2")
                .frame(width: 20)
                .foregroundColor(disabled ? .secondary : .primary)

            VStack(alignment: .leading, spacing: 2) {
                Text(widget.displayName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(disabled ? .secondary : .primary)
                Text(widget.id)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .frame(minWidth: 170, alignment: .leading)

            Spacer(minLength: 8)

            Text("#\(displayPosition(widget))")
                .font(.caption2.monospacedDigit())
                .foregroundColor(.secondary)
                .frame(width: 28, alignment: .trailing)

            Toggle("", isOn: Binding(
                get: { !runtime.prefs.isDisabled(widget.id) },
                set: { runtime.setWidgetDisabled(widget.id, !$0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .help(disabled ? "Enable widget" : "Disable widget")
            .accessibilityLabel("\(disabled ? "Enable" : "Disable") \(widget.displayName)")

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
                Button("New Panel…") {
                    newBucketName = ""
                    newBucketTarget = widget
                }
            } label: {
                Text(group)
                    .lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 110)
            .help("Move to panel")
            .accessibilityLabel("Panel for \(widget.displayName)")

            Menu {
                Button {
                    runtime.resizeWidget(id: widget.id, toSize: nil)
                } label: {
                    if runtime.prefs.override(for: widget.id)?.size == nil {
                        Label("Widget Default (\(widget.size))", systemImage: "checkmark")
                    } else {
                        Text("Widget Default (\(widget.size))")
                    }
                }
                Divider()
                ForEach(layoutSizes, id: \.self) { option in
                    Button {
                        runtime.resizeWidget(id: widget.id, toSize: option)
                    } label: {
                        if runtime.prefs.override(for: widget.id)?.size != nil,
                           option == size {
                            Label(option, systemImage: "checkmark")
                        } else {
                            Text(option)
                        }
                    }
                }
            } label: {
                Text(size)
                    .monospacedDigit()
            }
            .menuStyle(.borderlessButton)
            .frame(width: 46)
            .help("Change card size")
            .accessibilityLabel("Size for \(widget.displayName)")

            Button {
                settingsSheetWidget = widget
            } label: {
                Image(systemName: "gearshape")
            }
            .help("Settings…")
            .accessibilityLabel("Settings for \(widget.displayName)")

            Button {
                duplicateName = ""
                duplicateTarget = widget
            } label: {
                Image(systemName: "plus.square.on.square")
            }
            .help("Add another instance…")
            .accessibilityLabel("Add another instance of \(widget.displayName)")

            Button {
                revealInFinder(widget)
            } label: {
                Image(systemName: "folder")
            }
            .help("Reveal in Finder")
            .accessibilityLabel("Reveal \(widget.displayName) in Finder")

            Button(role: .destructive) {
                removalTarget = widget
            } label: {
                Image(systemName: "trash")
            }
            .help("Remove…")
            .accessibilityLabel("Remove \(widget.displayName)")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(disabled
                    ? Color.secondary.opacity(0.06)
                    : Color(nsColor: .controlBackgroundColor))
        )
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
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
                == .orderedAscending
        }
    }

    /// Bucket section headers, ordered by the user's explicit panel order (when
    /// set) then name — matching how the popup pages are ordered.
    private var buckets: [String] {
        var seen = Set<String>()
        var distinct: [String] = []
        for widget in widgetRows {
            let group = runtime.effectiveGroup(for: widget.id)
            if seen.insert(group).inserted { distinct.append(group) }
        }
        return distinct.sorted { lhs, rhs in
            let lk = runtime.prefs.groupSortKey(lhs) ?? .greatestFiniteMagnitude
            let rk = runtime.prefs.groupSortKey(rhs) ?? .greatestFiniteMagnitude
            if lk != rk { return lk < rk }
            return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }
    }

    /// Drop handler: reorders the dragged panel to sit before `target`.
    private func dropPanel(_ providers: [NSItemProvider], before target: String) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let dragged = object as? String, dragged != target else { return }
            DispatchQueue.main.async {
                var order = buckets
                guard let from = order.firstIndex(of: dragged) else { return }
                order.remove(at: from)
                let to = order.firstIndex(of: target) ?? order.count
                order.insert(dragged, at: to)
                runtime.prefs.setGroupsOrder(order)
                runtime.objectWillChange.send()
            }
        }
        return true
    }

    /// Moves a panel up (delta -1) or down (delta +1) and persists the order.
    private func moveBucket(_ bucket: String, by delta: Int) {
        var order = buckets
        guard let index = order.firstIndex(of: bucket) else { return }
        let target = index + delta
        guard target >= 0, target < order.count else { return }
        order.swapAt(index, target)
        runtime.prefs.setGroupsOrder(order)
        runtime.objectWillChange.send()
    }

    private func widgets(inBucket bucket: String) -> [LoadedWidget] {
        widgetRows.filter { runtime.effectiveGroup(for: $0.id) == bucket }
    }

    private func orderValue(_ widget: LoadedWidget) -> Double {
        runtime.prefs.override(for: widget.id)?.order ?? Double(widget.order)
    }

    private func displayPosition(_ widget: LoadedWidget) -> Int {
        let bucket = runtime.effectiveGroup(for: widget.id)
        let index = widgets(inBucket: bucket).firstIndex { $0.id == widget.id } ?? 0
        return index + 1
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
        persistOrder(items)
    }

    private func persistOrder(_ items: [LoadedWidget]) {
        for (position, widget) in items.enumerated() {
            runtime.prefs.setOverride(
                group: runtime.prefs.override(for: widget.id)?.group,
                order: Double(position),
                size: runtime.prefs.override(for: widget.id)?.size,
                for: widget.id
            )
        }
        runtime.objectWillChange.send()
    }

    private func resetLayoutOverrides() {
        for widget in runtime.widgets {
            runtime.prefs.setOverride(group: nil, order: nil, size: nil, for: widget.id)
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

    private func performDuplicate(_ widget: LoadedWidget) {
        let name = duplicateName
        duplicateName = ""
        duplicateTarget = nil
        do {
            let newID = try runtime.duplicateWidget(id: widget.id, label: name)
            if let duplicate = runtime.widgets.first(where: { $0.id == newID }) {
                settingsSheetWidget = duplicate
            }
        } catch {
            widgetActionError = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }
}
