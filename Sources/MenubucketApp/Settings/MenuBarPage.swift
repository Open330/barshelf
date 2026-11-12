import MenubucketCore
import SwiftUI

/// Everything about the menu bar in one place (R13 §3.2): which widgets show
/// a value there, in what order, on the shared BarShelf item or their own,
/// and the style every item uses unless a widget sets its own. Per-widget
/// fine-tuning (label, icon, graph, alerts, click action) stays with the
/// widget's own settings, linked from each row.
///
/// As a cluster every item is a chip: where an item goes and the text styles
/// do not apply, so they are not offered, and the page shows the chips as
/// the bar draws them.
struct MenuBarPage: View {
    @ObservedObject var appPrefs: AppPrefs
    @ObservedObject var runtime: WidgetRuntime
    /// Watched so the chip preview follows the readings.
    @ObservedObject private var store: MenuBarStatusStore

    init(appPrefs: AppPrefs, runtime: WidgetRuntime) {
        self.appPrefs = appPrefs
        self.runtime = runtime
        self.store = runtime.menuBar
    }

    private var isCluster: Bool { appPrefs.preferences.menuBarLayout == .cluster }

    var body: some View {
        SettingsPage(.menuBar, stats: stats) {
            MenuBarHiddenBanner { id in runtime.widgets.first { $0.id == id }?.displayName }
            layoutSection
            itemsSection
            if !isCluster {
                styleSection
                overridesSection
            }
        }
    }

    /// How many widgets are in the menu bar, how much room is left, and —
    /// when any — how many wait hidden for their alert level. The layout is
    /// the radio group just below, so it is not repeated here.
    private var stats: [SettingsStat] {
        let shown = store.entries.filter { !$0.isEmpty }.count
        let room = max(0, MenuBarPolicy.maxEntries - runtime.menuBarWidgetIDs.count)
        var stats = [
            SettingsStat(value: "\(shown)", label: String(localized: "In the menu bar")),
            SettingsStat(value: "\(room)", label: String(localized: "Room for more", comment: "Menu Bar summary: how many more widgets fit in the menu bar")),
        ]
        let dormant = runtime.dormantMenuBarWidgetIDs.count
        if dormant > 0 {
            stats.append(SettingsStat(value: "\(dormant)", label: String(localized: "Waiting for an alert", comment: "Menu Bar summary: items hidden until their reading reaches the level set")))
        }
        return stats
    }

    /// The chips the bar draws now.
    private var chips: [ClusterChip] {
        MenuBarClusterPolicy.chips(from: store.entries.filter { !$0.isEmpty }) {
            NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil
        }
    }

    // MARK: - Layout

    private var layoutSection: some View {
        Section {
            Picker(selection: Binding(
                get: { appPrefs.preferences.menuBarLayout },
                set: { value in appPrefs.update { $0.menuBarLayout = value } }
            )) {
                Text("Text and Items").tag(MenuBarLayout.items)
                Text("Cluster").tag(MenuBarLayout.cluster)
            } label: {
                Text("Show widgets as")
                Text(isCluster
                    ? "One small chip per widget beside the BarShelf icon. Point at a chip to see its reading, click it to open its card, then press ← → for the others."
                    : "Readings as text beside the BarShelf icon, or as items of their own.")
            }
            // What the menu bar does, like the Dock's mode: a radio group
            // (`Components.swift`, choices).
            .pickerStyle(.radioGroup)
            .accessibilityLabel("Show widgets as")
            // Both layouts show what the bar draws now, so switching between
            // them shows the difference rather than describing it.
            LabeledContent("Preview") {
                if isCluster {
                    if chips.isEmpty {
                        Text("Nothing in the menu bar yet").foregroundStyle(.secondary)
                    } else {
                        ClusterSettingsPreview(
                            chips: chips,
                            color: { runtime.chipColor(for: $0.widgetID) ?? .controlAccentColor },
                            markSymbol: appPrefs.preferences.menuBarSymbol
                        )
                    }
                } else {
                    MenuBarItemsPreview(
                        entries: store.entries.filter { !$0.isEmpty },
                        markSymbol: appPrefs.preferences.menuBarSymbol
                    )
                }
            }
            if isCluster {
                Toggle(isOn: Binding(
                    get: { appPrefs.preferences.menuBarPulse },
                    set: { value in appPrefs.update { $0.menuBarPulse = value } }
                )) {
                    Text("Wave when a widget changes")
                    Text("The chips come forward one by one when a reading turns to a warning, switches on or off, or changes its icon. At most once every three minutes; never for a number that just ticks.")
                }
            }
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
                    MenuBarItemRow(runtime: runtime, widget: widget, isCluster: isCluster)
                }
            }
            addWidgetRow
        } header: {
            Text("In the Menu Bar")
                .settingsSectionTitle()
        } footer: {
            Text(isCluster
                ? "Chips appear left to right in this order. At most \(MenuBarPolicy.maxEntries) widgets are shown; colours come from each widget's accent."
                : "Items that share the BarShelf icon appear next to it in this order. An item of its own can be moved by holding ⌘ and dragging it in the menu bar.")
                .formFooter()
        }
    }

    /// Widgets whose author did not offer a menu bar reading can still show
    /// their icon and status there; the list above only carries the ones that
    /// did, so the rest are added from here rather than only from each
    /// widget's own settings.
    @ViewBuilder
    private var addWidgetRow: some View {
        let others = runtime.menuBarAddableWidgets
        let full = runtime.menuBarWidgetIDs.count >= MenuBarPolicy.maxEntries
        LabeledContent {
            Menu("Add Widget") {
                ForEach(others) { widget in
                    Button(widget.displayName) {
                        runtime.updateMenuBarPlacement(for: widget.id) { $0.enabled = true }
                    }
                }
            }
            .fixedSize()
            .disabled(others.isEmpty || full)
        } label: {
            Text("Another widget")
            Text(full
                ? "The menu bar is full. Turn an item off to make room."
                : others.isEmpty
                    ? "Every widget on your shelf is listed above."
                    : "Widgets that publish no reading show their icon, and their status once they have one.")
        }
    }

    /// Shown items first, in the order they appear in the bar, then the rest
    /// by name.
    private var orderedCandidates: [LoadedWidget] {
        let order = runtime.menuBarMoveOrder
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
                        Button(MenuBarPresetName.title(preset.name)) {
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
                .settingsSectionTitle()
        } footer: {
            Text("Every item uses this style unless its own settings change it.")
                .formFooter()
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
                    .settingsSectionTitle()
            }
        }
    }

    // Stacked rather than LabeledContent: a grouped form pushes the control
    // to the trailing edge, which tears these wide controls apart.
    private func styleRow<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(title)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A style preset's name as the app shows it. The core keeps the English
/// name as the preset's identity.
enum MenuBarPresetName {
    static func title(_ name: String) -> String {
        switch name {
        case "Compact": return String(localized: "Compact", comment: "Menu bar style preset")
        case "Steady": return String(localized: "Steady", comment: "Menu bar style preset: values keep a fixed width")
        case "Bold": return String(localized: "Bold", comment: "Menu bar style preset")
        case "Minimal": return String(localized: "Minimal", comment: "Menu bar style preset")
        case "Graph": return String(localized: "Graph", comment: "Menu bar style preset")
        default: return name
        }
    }
}

/// One widget that can show a value in the menu bar.
private struct MenuBarItemRow: View {
    @ObservedObject var runtime: WidgetRuntime
    /// Watched so the reading beside the switch follows the menu bar.
    @ObservedObject var store: MenuBarStatusStore
    let widget: LoadedWidget
    /// Every item is a chip: no placement to choose, and every chip moves.
    let isCluster: Bool

    init(runtime: WidgetRuntime, widget: LoadedWidget, isCluster: Bool) {
        self.runtime = runtime
        self.store = runtime.menuBar
        self.widget = widget
        self.isCluster = isCluster
    }

    var body: some View {
        let placement = runtime.prefs.menuBarPlacement(for: widget.manifest, widgetID: widget.id)
        let isShown = runtime.menuBarWidgetIDs.contains(widget.id)
        // Switched on but past the limit is still on: the switch says what
        // the user chose, the line under it why nothing appears.
        let isOn = isShown || placement.enabled
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Toggle(isOn: Binding(
                get: { isOn },
                set: { value in runtime.updateMenuBarPlacement(for: widget.id) { $0.enabled = value } }
            )) {
                HStack(spacing: Spacing.xs) {
                    WidgetMark(widget: widget, runtime: runtime)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(widget.displayName)
                        if let reading = reading(isOn: isOn, isShown: isShown) {
                            Text(reading)
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if isShown {
                HStack(spacing: Spacing.xs) {
                    if !isCluster {
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
                    }

                    if isCluster || !placement.separate {
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

                    if isCluster {
                        ClusterChipControls(runtime: runtime, widget: widget, placement: placement)
                    }

                    Spacer()
                    Button("Customize…") {
                        HubWindowController.shared.showWidgetSettings(widgetID: widget.id, page: .menuBar)
                    }
                    .help(isCluster
                        ? "Icon, alerts, and what a click does"
                        : "Label, icon, graph, alerts, and what a click does")
                }
                .controlSize(.small)
            }
        }
        .padding(.vertical, Spacing.hair)
    }

    /// What the item shows right now — or why a switched-on item shows
    /// nothing, which would otherwise look broken.
    private func reading(isOn: Bool, isShown: Bool) -> String? {
        guard isOn else { return nil }
        guard isShown else {
            // Not for an item waiting on something else (its permissions).
            guard runtime.menuBarWidgetIDs.count >= MenuBarPolicy.maxEntries else { return nil }
            return String(localized: "Not shown: at most \(MenuBarPolicy.maxEntries) widgets fit. Turn another off to make room.")
        }
        if runtime.dormantMenuBarWidgetIDs.contains(widget.id) {
            return String(localized: "Hidden until its reading reaches the level you set")
        }
        return store.entries.first { $0.widgetID == widget.id }?.label
    }
}

/// What a chip can change without leaving the page: the icon on its face and
/// the colour it is drawn in (the widget's accent, shared with its card).
private struct ClusterChipControls: View {
    @ObservedObject var runtime: WidgetRuntime
    let widget: LoadedWidget
    let placement: MenuBarPlacement

    var body: some View {
        TextField(
            "",
            text: Binding(
                get: { placement.icon ?? "" },
                set: { value in
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    runtime.updateMenuBarPlacement(for: widget.id) { $0.icon = trimmed.isEmpty ? nil : trimmed }
                }
            ),
            prompt: Text("Icon", comment: "Placeholder: a chip's icon (SF Symbol or emoji)")
        )
        .labelsHidden()
        .textFieldStyle(.roundedBorder)
        .frame(width: 90)
        .help("An emoji, or a symbol name from SF Symbols, such as star.fill. Leave it empty for the widget’s icon.")
        .accessibilityLabel("Chip icon for \(widget.displayName)")

        let current = runtime.prefs.effectiveAppearance(for: widget.manifest, widgetID: widget.id).accent
        Menu {
            ForEach(AccentPalette.swatches) { swatch in
                Toggle(swatch.name, isOn: Binding(
                    get: { AccentPalette.matches(swatch.value, current) },
                    set: { _ in runtime.setAccent(swatch.value, for: widget.id) }
                ))
            }
        } label: {
            // A menu button draws its label through AppKit, which drops a
            // SwiftUI shape: a drawn, non-template image keeps its colour.
            Image(nsImage: ColorSwatchImage.make(NSColor(WidgetAppearance(accent: current).accentColor ?? .accentColor)))
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Chip colour")
        .accessibilityLabel("Chip colour for \(widget.displayName)")
    }
}

/// A filled circle in one colour with a hairline rim, as an image a menu
/// button or menu item shows in colour.
enum ColorSwatchImage {
    static func make(_ color: NSColor, diameter: CGFloat = 12) -> NSImage {
        let image = NSImage(size: NSSize(width: diameter, height: diameter), flipped: false) { rect in
            let path = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
            color.setFill()
            path.fill()
            NSColor.separatorColor.setStroke()
            path.lineWidth = 1
            path.stroke()
            return true
        }
        image.isTemplate = false
        return image
    }
}
