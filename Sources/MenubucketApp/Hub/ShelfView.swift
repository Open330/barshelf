import AppKit
import MenubucketCore
import SwiftUI

/// The Shelf (R13 §4.1–4.2): the popup's pages laid out side by side, each a
/// column of its widgets in popup order. Drag a widget within a column to
/// reorder it or onto another column to move it there; select one to edit it
/// in the inspector. Includes switched-off widgets, which the popup hides.
struct ShelfView: View {
    @ObservedObject var runtime: WidgetRuntime
    @ObservedObject var model: HubModel

    @State private var selection: String?
    @State private var inspectorShown = false
    @State private var removalTarget: LoadedWidget?
    @State private var duplicateTarget: LoadedWidget?
    @State private var duplicateName = ""
    @State private var actionError: String?
    @State private var dropHighlight: String?
    /// The inspector part a request ("Customize…") asked for, for that widget
    /// only; any other selection opens on General.
    @State private var requestedPage: (widgetID: String, page: WidgetSettingsView.InspectorTab)?
    @Environment(\.undoManager) private var undoManager

    private let columnWidth: CGFloat = 230

    var body: some View {
        Group {
            if runtime.widgets.isEmpty {
                emptyState
            } else {
                board
            }
        }
        .inspector(isPresented: $inspectorShown) {
            inspector
                .inspectorColumnWidth(min: 320, ideal: 360, max: 480)
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    model.tab = .gallery
                } label: {
                    Label("Add Widget", systemImage: "plus")
                }
                .help("Find a widget in the Gallery")
                Button {
                    inspectorShown.toggle()
                } label: {
                    Label("Inspector", systemImage: "sidebar.trailing")
                }
                .help(inspectorShown ? "Hide Inspector" : "Show Inspector")
                .disabled(selectedWidget == nil)
            }
        }
        .onAppear(perform: openRequestedSettings)
        .onChange(of: model.settingsWidgetID) { openRequestedSettings() }
        .onChange(of: selection) { _, id in
            if id != nil { inspectorShown = true }
            if id != requestedPage?.widgetID { requestedPage = nil }
        }
        .alert(
            "Remove \(removalTarget?.displayName ?? String(localized: "Widget"))?",
            isPresented: Binding(
                get: { removalTarget != nil },
                set: { if !$0 { removalTarget = nil } }
            ),
            presenting: removalTarget
        ) { widget in
            Button("Remove", role: .destructive) { remove(widget) }
            Button("Cancel", role: .cancel) { removalTarget = nil }
        } message: { widget in
            Text("This deletes \"\(widget.displayName)\" and its data. It can be installed again from the Gallery.")
        }
        .alert(
            "Duplicate \(duplicateTarget?.displayName ?? String(localized: "Widget"))",
            isPresented: Binding(
                get: { duplicateTarget != nil },
                set: { if !$0 { duplicateTarget = nil } }
            ),
            presenting: duplicateTarget
        ) { widget in
            TextField("Name for the copy", text: $duplicateName)
            Button("Duplicate") { duplicate(widget) }
            Button("Cancel", role: .cancel) {
                duplicateName = ""
                duplicateTarget = nil
            }
        } message: { _ in
            Text("The copy has its own settings — for example one per server or account.")
        }
        .alert(
            "Couldn't Do That",
            isPresented: Binding(
                get: { actionError != nil },
                set: { if !$0 { actionError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { actionError = nil }
        } message: {
            Text(actionError ?? "")
        }
    }

    // MARK: - Board

    private var board: some View {
        ScrollView([.horizontal, .vertical]) {
            HStack(alignment: .top, spacing: Spacing.m) {
                let pages = shelfPages
                ForEach(Array(pages.enumerated()), id: \.element.name) { index, page in
                    column(page, index: index, count: pages.count)
                }
            }
            .padding(Spacing.m)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        // Clicking empty space clears the selection, as in Finder.
        .background(Color.clear.contentShape(Rectangle()).onTapGesture { selection = nil })
    }

    private func column(_ page: ShelfPage, index: Int, count: Int) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.xxs) {
                Text(page.name)
                    .font(.headline)
                    .lineLimit(1)
                Text("\(page.widgets.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer(minLength: 0)
                Menu {
                    Button("Move Page Left") { movePage(page.name, by: -1) }
                        .disabled(index == 0)
                    Button("Move Page Right") { movePage(page.name, by: 1) }
                        .disabled(index == count - 1)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Page \(page.name) options")
            }
            .padding(.horizontal, Spacing.xxs)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Page \(page.name), \(page.widgets.count) widgets")

            ForEach(page.widgets) { widget in
                chip(widget, in: page)
            }

            // The end of the column, so a widget can be dropped last.
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .foregroundStyle(dropHighlight == page.name ? Color.accentColor : Color.secondary.opacity(0.35))
                .frame(height: 30)
                .overlay(Text("Drop here").font(.caption).foregroundStyle(.secondary))
                .dropDestination(for: String.self) { ids, _ in
                    guard let id = ids.first else { return false }
                    move(id, toPage: page.name, before: nil)
                    return true
                } isTargeted: { targeted in
                    dropHighlight = targeted ? page.name : (dropHighlight == page.name ? nil : dropHighlight)
                }
                .accessibilityHidden(true)
        }
        .padding(Spacing.xs)
        .frame(width: columnWidth, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
    }

    private func chip(_ widget: LoadedWidget, in page: ShelfPage) -> some View {
        let isSelected = selection == widget.id
        let disabled = runtime.prefs.isDisabled(widget.id)
        let status = chipStatus(widget, disabled: disabled)
        return HStack(spacing: Spacing.xs) {
            Image(systemName: widget.manifest.icon ?? "square.dashed")
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(widget.displayName)
                    .lineLimit(1)
                Text(LayoutSizeName.name(runtime.effectiveSize(for: widget.id)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if let status {
                Image(systemName: status.tone.symbol)
                    .foregroundStyle(status.tone.color)
                    .help(status.text)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, Spacing.xs)
        .padding(.vertical, 6)
        .opacity(disabled ? 0.55 : 1)
        .background(
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.16) : Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.08))
        )
        .contentShape(Rectangle())
        .onTapGesture { selection = widget.id }
        .draggable(widget.id) {
            Label(widget.displayName, systemImage: widget.manifest.icon ?? "square.dashed")
                .padding(Spacing.xs)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.control))
        }
        .dropDestination(for: String.self) { ids, _ in
            guard let id = ids.first, id != widget.id else { return false }
            move(id, toPage: page.name, before: widget.id)
            return true
        }
        .contextMenu { chipMenu(widget, disabled: disabled) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(widget.displayName)
        .accessibilityValue(
            [LayoutSizeName.name(runtime.effectiveSize(for: widget.id)), status?.text]
                .compactMap { $0 }.joined(separator: ", ")
        )
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        .accessibilityAction { selection = widget.id }
        .accessibilityAction(named: "Move up") { step(widget, in: page, by: -1) }
        .accessibilityAction(named: "Move down") { step(widget, in: page, by: 1) }
    }

    @ViewBuilder
    private func chipMenu(_ widget: LoadedWidget, disabled: Bool) -> some View {
        Button("Settings") { selection = widget.id; inspectorShown = true }
        Button(disabled ? "Show on the Shelf" : "Turn Off") {
            runtime.changeLayout((disabled ? String(localized: "Show Widget") : String(localized: "Turn Off Widget")), undoManager: undoManager) {
                runtime.setWidgetDisabled(widget.id, !disabled)
            }
        }
        Menu("Move to Page") {
            ForEach(shelfPages.map(\.name), id: \.self) { name in
                Button(name) { move(widget.id, toPage: name, before: nil) }
                    .disabled(name == runtime.effectiveGroup(for: widget.id))
            }
        }
        Divider()
        Button("Duplicate…") { duplicateTarget = widget }
        Button("Show in Finder") {
            if let url = runtime.widgetDirectory(for: widget.id) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
        Divider()
        Button("Remove…", role: .destructive) { removalTarget = widget }
    }

    private func chipStatus(_ widget: LoadedWidget, disabled: Bool) -> (text: String, tone: StatusTone)? {
        if disabled { return (String(localized: "Turned off"), .info) }
        switch runtime.permissionState(for: widget) {
        case .notAsked: return (String(localized: "Waiting for your permission"), .warning)
        case .denied: return (String(localized: "Permission denied"), .critical)
        default: break
        }
        if runtime.snapshots[widget.id]?.error != nil { return (String(localized: "Last refresh failed"), .critical) }
        return nil
    }

    // MARK: - Inspector

    @ViewBuilder
    private var inspector: some View {
        if let widget = selectedWidget {
            WidgetSettingsView(
                widget: widget,
                runtime: runtime,
                page: requestedPage?.widgetID == widget.id ? requestedPage!.page : .general,
                onDuplicate: { duplicateTarget = widget },
                onRemove: { removalTarget = widget }
            )
            // A new widget gets fresh drafts rather than the last one's.
            .id(widget.id)
        } else {
            VStack(spacing: Spacing.xs) {
                Image(systemName: "cursorarrow.click.2")
                    .font(.largeTitle)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                Text("Select a widget to change its settings.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var selectedWidget: LoadedWidget? {
        selection.flatMap { id in runtime.widgets.first { $0.id == id } }
    }

    private var emptyState: some View {
        VStack(spacing: Spacing.s) {
            Image(systemName: "square.grid.2x2")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Your shelf is empty")
                .font(.title3.weight(.semibold))
            Text("Add a widget from the Gallery, or build your own.")
                .foregroundStyle(.secondary)
            HStack {
                Button("Open Gallery") { model.tab = .gallery }
                    .buttonStyle(.borderedProminent)
                Button("Create Widget") { model.tab = .create }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Layout

    struct ShelfPage {
        let name: String
        let widgets: [LoadedWidget]
    }

    /// The popup's pages in the popup's order, switched-off widgets included
    /// where they would sit.
    private var shelfPages: [ShelfPage] {
        runtime.shelfPages.map { ShelfPage(name: $0.group, widgets: $0.widgets) }
    }

    /// Puts `id` on `page` just before `target` (or last), and rewrites that
    /// page's order as a dense sequence so the popup shows the same thing.
    private func move(_ id: String, toPage page: String, before target: String?) {
        guard runtime.widgets.contains(where: { $0.id == id }) else { return }
        runtime.changeLayout(String(localized: "Move Widget"), undoManager: undoManager) {
            place(id, onPage: page, before: target)
        }
    }

    private func place(_ id: String, onPage page: String, before target: String?) {
        // Pin the page order first: renumbering a page's widgets must not
        // move the page itself when no order has been saved yet.
        if runtime.prefs.groupOrder.isEmpty {
            runtime.prefs.setGroupsOrder(shelfPages.map(\.name))
        }
        if runtime.effectiveGroup(for: id) != page {
            runtime.moveWidget(id: id, toGroup: page)
        }
        var ids = (shelfPages.first { $0.name == page }?.widgets.map(\.id) ?? []).filter { $0 != id }
        let index = target.flatMap { ids.firstIndex(of: $0) } ?? ids.count
        ids.insert(id, at: index)
        for (position, wid) in ids.enumerated() {
            let existing = runtime.prefs.override(for: wid)
            runtime.prefs.setOverride(
                group: existing?.group, order: Double(position), size: existing?.size, for: wid
            )
        }
        runtime.objectWillChange.send()
    }

    private func step(_ widget: LoadedWidget, in page: ShelfPage, by offset: Int) {
        guard let index = page.widgets.firstIndex(where: { $0.id == widget.id }) else { return }
        let target = index + offset
        guard page.widgets.indices.contains(target) else { return }
        let before = offset < 0 ? page.widgets[target].id
            : (page.widgets.indices.contains(target + 1) ? page.widgets[target + 1].id : nil)
        move(widget.id, toPage: page.name, before: before)
    }

    private func movePage(_ name: String, by offset: Int) {
        var order = shelfPages.map(\.name)
        guard let index = order.firstIndex(of: name) else { return }
        let target = index + offset
        guard order.indices.contains(target) else { return }
        order.swapAt(index, target)
        runtime.changeLayout(String(localized: "Move Page"), undoManager: undoManager) {
            runtime.prefs.setGroupsOrder(order)
        }
        runtime.objectWillChange.send()
    }

    // MARK: - Actions

    private func openRequestedSettings() {
        guard let id = model.settingsWidgetID else { return }
        model.settingsWidgetID = nil
        requestedPage = (id, model.settingsPage)
        model.settingsPage = .general
        selection = id
        inspectorShown = true
    }

    private func remove(_ widget: LoadedWidget) {
        removalTarget = nil
        if selection == widget.id { selection = nil }
        do {
            try runtime.removeWidget(id: widget.id)
        } catch {
            actionError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func duplicate(_ widget: LoadedWidget) {
        let name = duplicateName
        duplicateName = ""
        duplicateTarget = nil
        do {
            selection = try runtime.duplicateWidget(id: widget.id, label: name)
        } catch {
            actionError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
