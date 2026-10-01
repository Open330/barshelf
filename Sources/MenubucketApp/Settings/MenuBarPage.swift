import MenubucketCore
import SwiftUI

/// Everything about the menu bar in one place (R13 §3.2): which widgets show
/// a value there, in what order, on the shared BarShelf item or their own,
/// and the style every item uses unless a widget sets its own. Per-widget
/// fine-tuning (label, icon, graph, alerts, click action) stays with the
/// widget's own settings, linked from each row.
struct MenuBarPage: View {
    @ObservedObject var appPrefs: AppPrefs
    @ObservedObject var runtime: WidgetRuntime

    var body: some View {
        SettingsPage {
            itemsSection
            styleSection
            overridesSection
        }
    }

    // MARK: - Items

    @ViewBuilder
    private var itemsSection: some View {
        let candidates = orderedCandidates
        Section {
            if candidates.isEmpty {
                Text("None of your widgets can show a value in the menu bar. Widgets like System, Battery, and Weather can.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(candidates) { widget in
                    MenuBarItemRow(runtime: runtime, widget: widget)
                }
            }
        } header: {
            Text("In the Menu Bar")
        } footer: {
            Text("Items that share the BarShelf icon appear next to it in this order. An item of its own can be moved by holding ⌘ and dragging it in the menu bar.")
        }
    }

    /// Shown items first, in the order they appear in the bar, then the rest
    /// by name.
    private var orderedCandidates: [LoadedWidget] {
        let order = runtime.menuBarStripOrder
        let shown = runtime.menuBarWidgetIDs
        return runtime.menuBarCandidates.sorted { a, b in
            let ai = order.firstIndex(of: a.id), bi = order.firstIndex(of: b.id)
            switch (shown.contains(a.id), shown.contains(b.id)) {
            case (true, false): return true
            case (false, true): return false
            default:
                if let ai, let bi { return ai < bi }
                return a.displayName.localizedStandardCompare(b.displayName) == .orderedAscending
            }
        }
    }

    // MARK: - Style

    @ViewBuilder
    private var styleSection: some View {
        let stored = appPrefs.preferences.menuBarPresentation
        let controls = MenuBarStyleControls(
            shown: MenuBarPolicy.resolvedPresentation(user: nil, global: stored, live: nil, manifest: nil),
            inherited: nil,
            usesOwnItem: nil,
            change: { edit in
                appPrefs.update { preferences in
                    var presentation = preferences.menuBarPresentation ?? MenuBarPresentation()
                    edit(&presentation)
                    preferences.menuBarPresentation = presentation
                }
            }
        )
        Section {
            styleRow("Width") { controls.width }
            styleRow("Text") { controls.text }
            styleRow("Color") { controls.color }
            styleRow("Presets") {
                HStack(spacing: Spacing.xs) {
                    ForEach(MenuBarPresentation.appWidePresets, id: \.name) { preset in
                        Button(preset.name) {
                            appPrefs.update { preferences in
                                preferences.menuBarPresentation = (preferences.menuBarPresentation
                                    ?? MenuBarPresentation()).applying(preset: preset.presentation)
                            }
                        }
                    }
                    if stored != nil {
                        Spacer()
                        Button("Restore Default Style") {
                            appPrefs.update { $0.menuBarPresentation = nil }
                        }
                    }
                }
            }
        } header: {
            Text("Style for All Items")
        } footer: {
            Text("Every item uses this style unless its own settings change it.")
        }
    }

    @ViewBuilder
    private var overridesSection: some View {
        let overriding = runtime.widgetsOverridingMenuBarStyle
        if !overriding.isEmpty {
            Section {
                LabeledContent {
                    Button("Use the Style for All") { runtime.clearItemMenuBarStyles() }
                } label: {
                    Text(overriding.map(\.displayName).joined(separator: ", "))
                    Text("These items set their own width, text, or color. Their labels, icons, and row order stay either way.")
                }
            } header: {
                Text("Items With Their Own Style")
            }
        }
    }

    // Stacked rather than LabeledContent: a grouped form pushes the control
    // to the trailing edge, which tears these wide controls apart.
    private func styleRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(title)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One widget that can show a value in the menu bar.
private struct MenuBarItemRow: View {
    @ObservedObject var runtime: WidgetRuntime
    let widget: LoadedWidget

    var body: some View {
        let isOn = runtime.menuBarWidgetIDs.contains(widget.id)
        let placement = runtime.prefs.menuBarPlacement(for: widget.manifest, widgetID: widget.id)
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Toggle(isOn: Binding(
                get: { isOn },
                set: { value in runtime.updateMenuBarPlacement(for: widget.id) { $0.enabled = value } }
            )) {
                Text(widget.displayName)
                if let reading = reading(isOn: isOn) {
                    Text(reading)
                }
            }

            if isOn {
                HStack(spacing: Spacing.xs) {
                    Picker("Placement", selection: Binding(
                        get: { placement.separate },
                        set: { value in runtime.updateMenuBarPlacement(for: widget.id) { $0.separate = value } }
                    )) {
                        Text("Next to the BarShelf icon").tag(false)
                        Text("Its own item").tag(true)
                    }
                    .labelsHidden()
                    .accessibilityLabel("Placement for \(widget.displayName)")
                    .fixedSize()

                    if !placement.separate {
                        Button {
                            runtime.moveInMenuBar(widget.id, by: -1)
                        } label: {
                            Image(systemName: "arrow.left")
                        }
                        .disabled(!runtime.canMoveInMenuBar(widget.id, by: -1))
                        .help("Move left")
                        .accessibilityLabel("Move \(widget.displayName) left")
                        Button {
                            runtime.moveInMenuBar(widget.id, by: 1)
                        } label: {
                            Image(systemName: "arrow.right")
                        }
                        .disabled(!runtime.canMoveInMenuBar(widget.id, by: 1))
                        .help("Move right")
                        .accessibilityLabel("Move \(widget.displayName) right")
                    }

                    Spacer()
                    Button("Customize…") {
                        HubWindowController.shared.showWidgetSettings(widgetID: widget.id)
                    }
                    .help("Label, icon, graph, alerts, and what a click does")
                }
                .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }

    /// What the item shows right now — or why a switched-on item shows
    /// nothing, which would otherwise look broken.
    private func reading(isOn: Bool) -> String? {
        guard isOn else { return nil }
        if runtime.dormantMenuBarWidgetIDs.contains(widget.id) {
            return "Hidden until its reading reaches the level you set"
        }
        return runtime.menuBar.entries.first { $0.widgetID == widget.id }?.label
    }
}
