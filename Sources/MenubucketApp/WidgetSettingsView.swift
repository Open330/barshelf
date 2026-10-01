import AppKit
import MenubucketCore
import SwiftUI
import UniformTypeIdentifiers

/// One widget's settings, shown in the Shelf's inspector (R13 §4.2): the
/// manifest's own `settings[]` (string / integer / boolean / enum /
/// directory), its look, its menu bar item, and what it is.
///
/// Changes apply as they are made — there is no Save. Each change is one
/// step on the window's undo stack, so ⌘Z takes it back.
struct WidgetSettingsView: View {
    let widget: LoadedWidget
    @ObservedObject var runtime: WidgetRuntime
    /// Shelf actions that need a confirmation the Shelf owns.
    var onDuplicate: (() -> Void)?
    var onRemove: (() -> Void)?
    /// Observed so an open pane follows a change to the app-wide menu bar
    /// style: its preview and the values its setters compare against both
    /// include it.
    @ObservedObject private var appPrefs: AppPrefs
    @Environment(\.dismiss) private var dismiss

    init(
        widget: LoadedWidget,
        runtime: WidgetRuntime,
        initialTab: MenuBarSettingsTab = .look,
        page: InspectorTab = .general,
        onDuplicate: (() -> Void)? = nil,
        onRemove: (() -> Void)? = nil
    ) {
        self.widget = widget
        self.runtime = runtime
        self.onDuplicate = onDuplicate
        self.onRemove = onRemove
        _menuBarTab = State(initialValue: initialTab)
        _page = State(initialValue: page)
        _appPrefs = ObservedObject(wrappedValue: runtime.appPrefs)
    }

    /// The inspector's four pages.
    enum InspectorTab: String, CaseIterable, Identifiable {
        case general, look, menuBar, about
        var id: String { rawValue }
        var title: String {
            switch self {
            case .general: return "General"
            case .look: return "Look"
            case .menuBar: return "Menu Bar"
            case .about: return "About"
            }
        }
    }

    @State private var page: InspectorTab
    @Environment(\.undoManager) private var undoManager
    /// What is saved, so a change can be told apart from a reload and undone.
    @State private var committed: Snapshot?
    @State private var pendingCommit: Task<Void, Never>?
    @State private var newPageName = ""
    @State private var askingForNewPage = false

    /// Everything the settings pane edits through its drafts.
    private struct Snapshot: Equatable {
        var values: [String: JSONValue]
        var appearance: WidgetAppearance
        var menuBar: MenuBarPlacement
    }

    @State private var values: [String: JSONValue] = [:]
    /// The theming override being edited (R12). Loaded from the effective
    /// appearance so the controls reflect the widget's current look.
    @State private var appearanceDraft = WidgetAppearance()
    /// Menu-bar promotion being edited.
    @State private var menuBarDraft = MenuBarPlacement(enabled: false)
    /// The placement as the pane opened, so Save leaves alone a placement
    /// that was changed elsewhere (App Settings' "Use These for All") while
    /// this pane never touched it.
    @State private var menuBarLoaded = MenuBarPlacement(enabled: false)
    @State private var menuBarTab: MenuBarSettingsTab
    /// This Mac's sensors, for a setting with `optionsSource: system.sensors`.
    @State private var sensorOptions: [SensorReading] = []
    /// Whether the click target resolves; nil with no target.
    @State private var clickTargetResolves: Bool?
    @State private var warningText = ""
    @State private var dangerText = ""
    @State private var showWhenText = ""
    /// Height of the scrolling settings area. A variable only so the
    /// screenshot test can render the whole pane rather than its first screen.
    static var scrollMaxHeight: CGFloat = 420

    private var entries: [Manifest.Setting] {
        (widget.manifest.settings ?? []).filter { $0.key != nil }
    }

    /// The widget's author default (manifest appearance over neutral). Editing
    /// the controls back to this is treated as "no override".
    private var authorBase: WidgetAppearance {
        let neutral = WidgetAppearance()
        return (widget.manifest.appearance ?? neutral).merged(over: neutral)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Picker("Section", selection: $page) {
                ForEach(InspectorTab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Widget settings section")
            .padding(.horizontal, Spacing.m)
            .padding(.bottom, Spacing.s)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.s) {
                    switch page {
                    case .general: generalPage
                    case .look: appearanceSection
                    case .menuBar: menuBarSection
                    case .about: aboutPage
                    }
                }
                .padding(Spacing.m)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: Self.scrollMaxHeight)
        }
        .frame(minWidth: 320, maxWidth: .infinity, alignment: .topLeading)
        .onAppear(perform: load)
        .onDisappear(perform: flush)
        .onChange(of: snapshot) { scheduleCommit() }
        .alert("New Page", isPresented: $askingForNewPage) {
            TextField("Page name", text: $newPageName)
            Button("Move") {
                let name = newPageName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty { runtime.moveWidget(id: widget.id, toGroup: name) }
                newPageName = ""
            }
            Button("Cancel", role: .cancel) { newPageName = "" }
        } message: {
            Text("Move \(widget.displayName) to a new page.")
        }
    }

    private var header: some View {
        HStack(spacing: Spacing.xs) {
            AccentTile(size: 28) {
                Image(systemName: widget.manifest.icon ?? "square.dashed")
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(widget.displayName).font(.headline)
                Text("\(WidgetTypeName.name(widget.manifest.entry.kind)) · version \(widget.packageInfo.version ?? "–")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(Spacing.m)
        .accessibilityElement(children: .combine)
    }

    // MARK: - General

    @ViewBuilder
    private var generalPage: some View {
        let isEnabled = !runtime.prefs.isDisabled(widget.id)
        Toggle(isOn: Binding(
            get: { isEnabled },
            set: { runtime.setWidgetDisabled(widget.id, !$0) }
        )) {
            Text("Show on the shelf")
        }
        .toggleStyle(.switch)
        if !isEnabled {
            settingsHint("Turned off: it doesn't refresh and isn't in the popup.")
        }

        LabeledContent("Page") {
            Picker("Page", selection: Binding(
                get: { runtime.effectiveGroup(for: widget.id) },
                set: { value in
                    if value == Self.newPageTag { askingForNewPage = true } else {
                        runtime.moveWidget(id: widget.id, toGroup: value)
                    }
                }
            )) {
                ForEach(pageOptions, id: \.self) { Text($0).tag($0) }
                Divider()
                Text("New Page…").tag(Self.newPageTag)
            }
            .labelsHidden()
            .fixedSize()
        }

        LabeledContent("Size") {
            Picker("Size", selection: Binding(
                get: { runtime.effectiveSize(for: widget.id).uppercased() },
                set: { runtime.resizeWidget(id: widget.id, toSize: $0 == widget.size.uppercased() ? nil : $0) }
            )) {
                ForEach(["XS", "S", "M", "L"], id: \.self) { code in
                    Text(LayoutSizeName.name(code)).tag(code)
                }
            }
            .labelsHidden()
            .fixedSize()
        }
        settingsHint(LayoutSizeName.description(runtime.effectiveSize(for: widget.id)))

        Divider()

        if entries.isEmpty {
            Text("This widget has no options of its own.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            ForEach(entries, id: \.key) { entry in
                row(for: entry, key: entry.key ?? "")
            }
        }
    }

    private static let newPageTag = "\u{0}new-page"

    private var pageOptions: [String] {
        var options = Set(runtime.allGroups)
        options.insert(runtime.effectiveGroup(for: widget.id))
        return options.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    // MARK: - About

    @ViewBuilder
    private var aboutPage: some View {
        LabeledContent("Type", value: WidgetTypeName.name(widget.manifest.entry.kind))
        let info = widget.packageInfo
        LabeledContent("Version", value: info.version ?? "–")
        LabeledContent("Identifier") {
            Text(widget.id).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
        }
        if let description = info.description, !description.isEmpty {
            Text(description)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        Divider()

        let lines = WidgetPermissionSummary.lines(for: widget.manifest)
        if lines.isEmpty {
            Label("Needs no permissions", systemImage: "checkmark.shield")
                .foregroundStyle(.secondary)
        } else {
            Text("Permissions").font(.headline)
            ForEach(lines, id: \.self) { line in
                Label(line.text, systemImage: line.symbol).font(.callout)
            }
            HStack {
                switch runtime.permissionState(for: widget) {
                case .allowed:
                    Text("Allowed").foregroundStyle(StatusTone.success.color)
                    Spacer()
                    Button("Revoke") { runtime.revokePermissions(widgetID: widget.id) }
                case .denied:
                    Text("Denied").foregroundStyle(StatusTone.critical.color)
                    Spacer()
                    Button("Allow") { runtime.approvePermissions(widgetID: widget.id) }
                case .notAsked:
                    Text("Waiting for you").foregroundStyle(StatusTone.warning.color)
                    Spacer()
                    Button("Deny") { runtime.denyPermissions(widgetID: widget.id) }
                    Button("Allow") { runtime.approvePermissions(widgetID: widget.id) }
                case .notNeeded:
                    EmptyView()
                }
            }
        }

        Divider()

        HStack {
            Button("Show in Finder") {
                if let url = runtime.widgetDirectory(for: widget.id) {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
            if let onDuplicate {
                Button("Duplicate…", action: onDuplicate)
                    .help("Add a second copy with its own settings")
            }
            Spacer()
            if let onRemove {
                Button("Remove…", role: .destructive, action: onRemove)
            }
        }
    }

    // MARK: - Applying changes

    private var snapshot: Snapshot {
        Snapshot(values: values, appearance: appearanceDraft, menuBar: menuBarDraft)
    }

    private func load() {
        values = runtime.prefs.effectiveSettings(
            for: widget.manifest, widgetID: widget.id
        ).objectValue ?? [:]
        appearanceDraft = runtime.prefs.effectiveAppearance(
            for: widget.manifest, widgetID: widget.id
        )
        menuBarDraft = runtime.prefs.menuBarPlacement(
            for: widget.manifest, widgetID: widget.id
        )
        menuBarLoaded = menuBarDraft
        committed = snapshot
        loadDynamicOptions()
        syncAlertTexts()
        clickTargetResolves = menuBarDraft.clickTarget.map { StatusItemController.clickTargetURL($0) != nil }
    }

    /// Typing in a field should not run the widget once per keystroke; the
    /// change lands a moment after the last one.
    private func scheduleCommit() {
        pendingCommit?.cancel()
        pendingCommit = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            commit()
        }
    }

    private func flush() {
        pendingCommit?.cancel()
        commit()
    }

    private func commit() {
        guard let previous = committed, previous != snapshot else { return }
        let current = snapshot
        persist(current, over: previous)
        committed = current
        undoManager?.registerUndo(withTarget: UndoAnchor.shared) { _ in
            restore(previous)
        }
        undoManager?.setActionName("Change \(widget.displayName)")
    }

    /// Puts the drafts back to `snapshot`; the change handler then saves it,
    /// which registers the redo.
    private func restore(_ snapshot: Snapshot) {
        values = snapshot.values
        appearanceDraft = snapshot.appearance
        menuBarDraft = snapshot.menuBar
        syncAlertTexts()
    }

    /// The label a picker shows for a stored option value.
    ///
    /// Falls back to the value itself, including when `optionTitles` is the
    /// wrong length — a manifest that miscounts should look unpolished, not
    /// put the wrong name on the wrong choice.
    static func optionTitle(_ option: String, in entry: Manifest.Setting) -> String {
        guard let options = entry.options,
              let titles = entry.optionTitles,
              titles.count == options.count,
              let index = options.firstIndex(of: option)
        else { return option }
        let title = titles[index].trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? option : title
    }

    private func persist(_ current: Snapshot, over previous: Snapshot) {
        if current.values != previous.values {
            for entry in entries {
                guard let key = entry.key else { continue }
                // Integer min/max are enforced on what is stored, not on the
                // field, so typing "1" on the way to "15" is not rewritten.
                var value = current.values[key]
                if entry.type == "integer", let number = value?.numberValue {
                    value = .number(clampedInteger(number, entry: entry))
                }
                runtime.prefs.setSetting(widgetID: widget.id, key: key, value: value)
            }
        }
        if current.appearance != previous.appearance {
            // Editing everything back to the author default clears the override.
            runtime.prefs.setAppearanceOverride(
                current.appearance == authorBase ? nil : current.appearance, for: widget.id
            )
        }
        // Same rule: storing a placement that matches the default would pin
        // the widget away from it forever. And a placement this pane never
        // touched is left alone, so a change made elsewhere survives.
        if current.menuBar != previous.menuBar {
            let menuBarBase = MenuBarPolicy.resolvedPlacement(
                stored: nil, statusItem: widget.manifest.statusItem
            )
            runtime.setMenuBarPlacement(
                current.menuBar == menuBarBase ? nil : current.menuBar, for: widget.id
            )
            menuBarLoaded = current.menuBar
        }
        runtime.refresh(widgetID: widget.id)
    }

    // MARK: - Menu bar section

    /// True when the widget can contribute text to the shared strip. An
    /// icon-only widget always needs its own status item.
    ///
    /// Resolved through the same rule the renderer uses, so this pane cannot
    /// promise a layout the menu bar will not produce.
    private var canShareStrip: Bool {
        MenuBarPolicy.effectiveStatusItem(widget.manifest.statusItem).showsLabel
    }

    /// The widget last rendered without any status text, so promoting it would
    /// show nothing (or the icon alone) — worth saying before the user does it.
    private var publishesNoStatusText: Bool {
        let snapshot = runtime.snapshots[widget.id]
        // A metrics-only widget (Network) publishes no label but still draws.
        return snapshot?.updatedAt != nil && snapshot?.statusLabel == nil
            && (snapshot?.statusMetrics ?? []).isEmpty
    }

    /// What the menu bar will draw for the settings as they stand.
    ///
    /// Built from the draft rather than from what is currently on the bar, so
    /// the preview moves as the controls do — including before Save.
    private var previewEntry: MenuBarEntry {
        let statusItem = MenuBarPolicy.effectiveStatusItem(widget.manifest.statusItem)
        let snapshot = runtime.snapshots[widget.id]
        let entry = MenuBarEntry(
            widgetID: widget.id,
            name: widget.displayName,
            symbol: statusItem.showsIcon
                ? MenuBarPolicy.resolvedIcon(
                    user: nil, live: snapshot?.statusIcon,
                    statusItem: statusItem.icon, manifest: widget.manifest.icon
                )
                : nil,
            iconOverride: MenuBarPolicy.normalizedIcon(menuBarDraft.icon),
            prefix: MenuBarPolicy.resolvedPrefix(
                user: menuBarDraft.label,
                live: snapshot?.statusPrefix,
                manifest: statusItem.label
            ),
            style: effectiveStyle,
            tint: MenuBarTint.named(snapshot?.statusTint),
            // A widget that has never run has nothing to show, so the preview
            // stands in rather than rendering an empty box.
            label: statusItem.showsLabel
                ? (MenuBarPolicy.normalizedLabel(snapshot?.statusLabel) ?? "42%") : nil,
            // Same gate the runtime applies: an icon-only widget's readings
            // never reach the bar, so the preview must not show them either.
            metrics: statusItem.showsLabel ? (snapshot?.statusMetrics ?? []) : []
        )
        // The preview intentionally goes through the production resolver. A
        // draft is still only local state, but it must answer the same
        // presentation questions as the status item will after Save.
        let presentation = MenuBarPolicy.resolvedPresentation(
            user: menuBarDraft.presentation,
            global: globalPresentation,
            live: snapshot?.statusPresentation,
            manifest: statusItem.presentation
        )
        var applied = MenuBarPolicy.applyingPresentation(presentation, to: entry)
        // Only what the bar will draw: an item of its own with a numeric
        // reading. Its own history when it has some; otherwise an example
        // shape, so choosing a chart shows what it looks like at once.
        if presentation.effectiveChart != .none, usesOwnItem, let sample = MenuBarPolicy.chartSample(applied) {
            let own = runtime.menuBarHistory[widget.id]
            let history = own.map { $0.values.count >= 2 && $0.series == sample.key ? $0 : nil } ?? nil
            let scale = sample.scale ?? max(sample.value * 1.5, 1)
            applied = MenuBarPolicy.applyingChart(applied, history: history ?? MenuBarChartHistory(
                series: sample.key, scale: sample.scale,
                values: Self.exampleChart.map { $0 * scale } + [sample.value]
            ))
        }
        return applied
    }

    private var effectiveStyle: MenuBarStyle {
        MenuBarPolicy.resolvedStyle(
            user: menuBarDraft.style, manifest: widget.manifest.statusItem?.style
        )
    }

    /// Two rows cannot be drawn into the shared strip, so choosing the stacked
    /// layout takes the widget's own item whether or not the user picked that.
    private var stackedForcesOwnItem: Bool {
        (effectiveStyle == .stacked || effectiveStyle == .metrics) && canShareStrip
    }

    private var usesOwnItem: Bool {
        !canShareStrip || stackedForcesOwnItem || menuBarDraft.separate
    }

    private var menuBarSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Menu Bar")
                .font(.system(size: 12, weight: .semibold))

            Toggle("Show in the menu bar", isOn: Binding(
                get: { menuBarDraft.enabled },
                set: { menuBarDraft.enabled = $0 }
            ))
            .toggleStyle(.checkbox)

            if menuBarDraft.enabled {
                menuBarPreview
                menuBarControls
                // The one thing worth saying at the bottom rather than beside
                // a control, because it is about the widget, not a setting.
                if publishesNoStatusText {
                    settingsHint(
                        "This widget publishes no value, so only its icon can"
                            + " appear. Give its workflow a `status.label` (or a"
                            + " script `host.render` status) to show one."
                    )
                } else {
                    settingsHint(
                        "It keeps refreshing while the popup is closed."
                            + " At most \(MenuBarPolicy.maxEntries) widgets are shown."
                    )
                }
            }
        }
    }

    /// The item as it will appear, drawn by the menu bar's own renderer.
    private var menuBarPreview: some View {
        HStack(spacing: 8) {
            Text("Preview").font(.caption).foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
            let image = MenuBarController.previewImage(for: previewEntry)
            Image(nsImage: image)
                .renderingMode(image.isTemplate ? .template : .original)
                .padding(.horizontal, 6)
                .frame(height: 24)
                .background(
                    RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                        .fill(Color.primary.opacity(0.07))
                )
            Spacer(minLength: 0)
        }
    }

    /// One row per question, each with its own heading — the controls used to
    /// be two unlabelled radio groups in a row, which gave four buttons and no
    /// way to tell which question either pair answered.
    private var menuBarControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Fourteen rows in one column had become a wall; three questions —
            // how it looks, what it reads, what it does — each get a tab.
            Picker("", selection: $menuBarTab) {
                ForEach(MenuBarSettingsTab.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Menu bar settings")
            .frame(width: 260)

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 10) {
                switch menuBarTab {
                case .look:
                    GridRow {
                        settingsRowLabel("Item")
                        VStack(alignment: .leading, spacing: 4) {
                            Picker("", selection: Binding(
                                get: { usesOwnItem },
                                set: { menuBarDraft.separate = $0 }
                            )) {
                                Text("Share the BarShelf icon").tag(false)
                                Text("Its own menu bar item").tag(true)
                            }
                            .pickerStyle(.radioGroup)
                            .labelsHidden()
                            .disabled(!canShareStrip || stackedForcesOwnItem)

                            if !canShareStrip {
                                settingsHint("This widget shows no text, and an icon cannot join the shared strip.")
                            } else if stackedForcesOwnItem {
                                settingsHint("Two rows need their own item.")
                            } else if !menuBarDraft.separate {
                                HStack(spacing: 6) {
                                    Button("Move Left") { runtime.moveInMenuBar(widget.id, by: -1) }
                                        .disabled(!runtime.canMoveInMenuBar(widget.id, by: -1))
                                    Button("Move Right") { runtime.moveInMenuBar(widget.id, by: 1) }
                                        .disabled(!runtime.canMoveInMenuBar(widget.id, by: 1))
                                }
                                .controlSize(.small)
                            } else {
                                settingsHint("Drag it in the menu bar with ⌘ to reorder.")
                            }
                        }
                    }

                    GridRow {
                        settingsRowLabel("Layout")
                        Picker("", selection: Binding(
                            get: { effectiveStyle },
                            set: { menuBarDraft.style = $0 }
                        )) {
                            ForEach(MenuBarStyle.allCases, id: \.self) { style in
                                Text(style.title).tag(style)
                            }
                        }
                        .pickerStyle(.radioGroup)
                        .labelsHidden()
                    }

                    if effectiveStyle != .metrics {
                        GridRow {
                            settingsRowLabel("Label")
                            VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                // Same three-state problem the icon has: "" is no
                                // label, nil is the widget's own, and a text field
                                // cannot say which an empty box means.
                                Toggle("", isOn: Binding(
                                    get: { menuBarDraft.label != "" },
                                    set: { menuBarDraft.label = $0 ? nil : "" }
                                ))
                                .toggleStyle(.checkbox)
                                .labelsHidden()
                                TextField("the widget's own", text: Binding(
                                    get: { menuBarDraft.label == "" ? "" : (menuBarDraft.label ?? "") },
                                    set: { menuBarDraft.label = $0.isEmpty ? nil : $0 }
                                ))
                                .frame(width: 150)
                                .disabled(menuBarDraft.label == "")
                            }
                                settingsHint(
                                    effectiveStyle == .stacked
                                    ? "Drawn above the value. Uncheck for the value alone."
                                    : "Drawn before the value. Uncheck for the value alone."
                                )
                            }
                        }
                    }

                    GridRow {
                        settingsRowLabel("Icon")
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                // "" means no icon, nil means the widget's own. A text
                                // field cannot say the difference, so the checkbox does
                                // — and it sits beside the field it governs.
                                Toggle("", isOn: Binding(
                                    get: { menuBarDraft.icon != "" },
                                    set: { menuBarDraft.icon = $0 ? nil : "" }
                                ))
                                .toggleStyle(.checkbox)
                                .labelsHidden()
                                TextField(
                                    widget.manifest.statusItem?.icon ?? "the widget's own",
                                    text: Binding(
                                        get: { menuBarDraft.icon == "" ? "" : (menuBarDraft.icon ?? "") },
                                        set: { menuBarDraft.icon = $0.isEmpty ? nil : $0 }
                                    )
                                )
                                .frame(width: 150)
                                .disabled(menuBarDraft.icon == "")
                            }
                            settingsHint("An SF Symbol name or an emoji. Uncheck for no icon.")
                        }
                    }

                    GridRow {
                        settingsRowLabel("Width")
                        styleControls.width
                    }

                    GridRow {
                        settingsRowLabel("Text")
                        styleControls.text
                    }

                    GridRow {
                        settingsRowLabel("Graph")
                        VStack(alignment: .leading, spacing: 4) {
                            Picker("", selection: Binding(
                                get: { shownPresentation.effectiveChart },
                                set: { value in
                                    let inherited = inheritedPresentation.effectiveChart
                                    setPresentation { $0.chart = value == inherited ? nil : value }
                                }
                            )) {
                                Text("None").tag(MenuBarChart.none)
                                Text("Line").tag(MenuBarChart.line)
                                Text("Bars").tag(MenuBarChart.bars)
                                Text("Gauge").tag(MenuBarChart.gauge)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .frame(width: 240)
                            settingsHint(usesOwnItem
                                ? "Drawn from the item's first reading as it refreshes. Percentages use 0–100; anything else scales to its recent peak."
                                : "A graph needs the item's own place in the menu bar; sharing the BarShelf icon, it shows text only.")
                        }
                    }

                    GridRow {
                        settingsRowLabel("Color")
                        styleControls.color
                    }

                    GridRow {
                        settingsRowLabel("Style")
                        styleShortcuts
                    }

                case .readings:
                    // Computed once per render; each resolves the whole
                    // presentation.
                    let judged = thresholdMetrics
                    let rows = editableMetricRows
                    if !judged.isEmpty || menuBarDraft.presentation?.hasThresholds == true
                        || menuBarDraft.presentation?.showWhen != nil {
                        GridRow {
                            settingsRowLabel("Alerts")
                            thresholdControls
                        }
                    }

                    if !rows.isEmpty {
                        GridRow {
                            settingsRowLabel("Metrics")
                            metricPresentationControls
                        }
                    }

                    if judged.isEmpty, rows.isEmpty,
                       menuBarDraft.presentation?.hasThresholds != true,
                       menuBarDraft.presentation?.showWhen == nil {
                        GridRow {
                            settingsRowLabel("")
                            // No snapshot is "not yet", not "never".
                            settingsHint(runtime.snapshots[widget.id]?.statusMetrics == nil
                                ? "No reading yet. Once the widget refreshes, its alerts and rows can be set here."
                                : "This widget has no numeric readings to set alerts or row options for.")
                        }
                    }
                    if !rows.isEmpty, effectiveStyle != .metrics {
                        GridRow {
                            settingsRowLabel("")
                            settingsHint("Per-row labels, colours and order appear with the Two metric rows layout, on the Look tab.")
                        }
                    }
                case .behavior:
                    GridRow {
                        settingsRowLabel("Click")
                        clickControls
                    }

                    GridRow {
                        settingsRowLabel("Update")
                        VStack(alignment: .leading, spacing: 4) {
                            Picker("", selection: intervalBinding) {
                                Text(widgetIntervalTitle).tag(0.0)
                                Divider()
                                ForEach(MenuBarPlacement.intervalChoices, id: \.self) { seconds in
                                    Text(Self.intervalTitle(seconds)).tag(seconds)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 180)
                            settingsHint("How often this item refreshes while it is in the menu bar. Slower is lighter on battery.")
                        }
                    }

                }
                // Resets only what this tab shows: a button on Behavior must
                // not quietly wipe the graph and alerts set on the others.
                if tabHasChoices(menuBarTab) {
                    GridRow {
                        settingsRowLabel("")
                        Button("Reset \(menuBarTab.title)") { resetTab(menuBarTab) }
                            .controlSize(.small)
                    }
                }
            }
        }
    }

    /// All layouts can render structured readings. Row-specific controls only
    /// affect the dedicated metric-row layout.
    @ViewBuilder
    private var metricPresentationControls: some View {
        let rows = editableMetricRows
        if rows.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                settingsHint("This widget has no metric rows to customize yet.")
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                metricFormatControls(rows.map(\.metric))
                if effectiveStyle == .metrics {
                    Divider()
                    ForEach(Array(rows.enumerated()), id: \.element.key) { offset, row in
                        metricRow(row.metric, key: row.key, at: offset, rows: rows)
                    }
                }
            }
        }
    }

    /// Keep fallback `row:n` keys attached to the original payload position.
    /// The visible editor then follows a stored order without changing what a
    /// later refresh means by an id-less row.
    private var editableMetricRows: [(key: String, metric: StatusMetric)] {
        let snapshot = runtime.snapshots[widget.id]
        let source = MenuBarPolicy.normalizedMetrics(snapshot?.statusMetrics ?? [])
        let rows = zip(MenuBarPolicy.metricKeys(source), source).enumerated().map { index, pair in
            (key: pair.0, metric: pair.1, sourceIndex: index)
        }
        // The order the bar will actually use — the user's, else the render's,
        // else the manifest's — so the editor and its arrows match the bar.
        let resolved = MenuBarPolicy.resolvedPresentation(
            user: menuBarDraft.presentation,
            global: globalPresentation,
            live: snapshot?.statusPresentation,
            manifest: MenuBarPolicy.effectiveStatusItem(widget.manifest.statusItem).presentation
        )
        let ranks = MenuBarPolicy.orderRanks(resolved.metricOrder ?? [])
        return rows.sorted { lhs, rhs in
            let leftRank = ranks[lhs.key] ?? Int.max
            let rightRank = ranks[rhs.key] ?? Int.max
            return leftRank == rightRank ? lhs.sourceIndex < rhs.sourceIndex : leftRank < rightRank
        }.map { (key: $0.key, metric: $0.metric) }
    }

    private func metricFormatControls(_ metrics: [StatusMetric]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Show values", isOn: presentationBoolBinding(\.showValues))
            Toggle("Show units", isOn: presentationBoolBinding(\.showUnits))

            if metrics.contains(where: { $0.number != nil || $0.format != nil }) {
                HStack(spacing: 8) {
                    Text("Decimals").font(.caption).foregroundStyle(.secondary)
                    Picker("", selection: precisionBinding) {
                        Text("Auto").tag(-1)
                        Text("0").tag(0)
                        Text("1").tag(1)
                        Text("2").tag(2)
                        Text("3").tag(3)
                    }
                    .labelsHidden()
                    .frame(width: 105)
                }
            } else {
                settingsHint("This widget supplies text readings, so decimal controls do not apply.")
            }

        }
    }

    private func metricRow(
        _ metric: StatusMetric, key: String, at offset: Int,
        rows: [(key: String, metric: StatusMetric)]
    ) -> some View {
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Toggle("", isOn: metricHiddenBinding(key))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .accessibilityLabel("Show \(metricRowTitle(metric, offset: offset))")
                TextField(metricRowTitle(metric, offset: offset), text: metricLabelBinding(key))
                    .frame(width: 108)
                Picker("", selection: metricTintBinding(key)) {
                    Text("Auto").tag("automatic")
                    Text("Monochrome").tag("monochrome")
                    Text("Accent").tag("accent")
                    Text("Good").tag("good")
                    Text("Warning").tag("warning")
                    Text("Danger").tag("danger")
                    Text("Secondary").tag("secondary")
                }
                .labelsHidden()
                .frame(width: 104)
                Button("↑") { moveMetric(key, by: -1, rows: rows) }
                    .disabled(offset == 0)
                Button("↓") { moveMetric(key, by: 1, rows: rows) }
                    .disabled(offset == rows.count - 1)
            }
        }
    }

    private func metricRowTitle(_ metric: StatusMetric, offset: Int) -> String {
        metric.label.isEmpty ? "Metric \(offset + 1)" : metric.label
    }

    private var inheritedPresentation: MenuBarPresentation {
        let statusItem = MenuBarPolicy.effectiveStatusItem(widget.manifest.statusItem)
        return MenuBarPolicy.resolvedPresentation(
            user: nil,
            global: globalPresentation,
            live: runtime.snapshots[widget.id]?.statusPresentation,
            manifest: statusItem.presentation
        )
    }

    private func presentationBoolBinding(_ keyPath: WritableKeyPath<MenuBarPresentation, Bool?>) -> Binding<Bool> {
        Binding(
            get: { menuBarDraft.presentation?[keyPath: keyPath] ?? inheritedPresentation[keyPath: keyPath] ?? true },
            set: { newValue in
                setPresentation { presentation in
                    let inherited = inheritedPresentation[keyPath: keyPath] ?? true
                    presentation[keyPath: keyPath] = newValue == inherited ? nil : newValue
                }
            }
        )
    }

    private var precisionBinding: Binding<Int> {
        Binding(
            get: { menuBarDraft.presentation?.precision ?? -1 },
            set: { newValue in setPresentation { $0.precision = newValue < 0 ? nil : newValue } }
        )
    }

    // MARK: Width, text and cadence

    /// What the item will actually use — the draft over the render's and the
    /// manifest's defaults. Controls show this, not the draft alone: a widget
    /// that asks for left-aligned numbers must not show the toggle as on.
    /// Setters compare against `inheritedPresentation` and store nil only for
    /// a choice equal to it; otherwise picking "right" over a widget's "left"
    /// would write nil and fall straight back to "left".
    private var shownPresentation: MenuBarPresentation {
        MenuBarPolicy.resolvedPresentation(
            user: menuBarDraft.presentation, global: globalPresentation,
            live: livePresentation, manifest: manifestPresentation
        )
    }

    /// The app-wide menu bar style, which ranks between this item's choices
    /// and the widget's.
    private var globalPresentation: MenuBarPresentation? {
        appPrefs.preferences.menuBarPresentation
    }

    private var styleControls: MenuBarStyleControls {
        MenuBarStyleControls(
            shown: shownPresentation,
            inherited: inheritedPresentation,
            usesOwnItem: usesOwnItem,
            change: { setPresentation($0) }
        )
    }

    /// Readings a threshold can be judged against.
    private var thresholdMetrics: [StatusMetric] {
        let metrics = runtime.snapshots[widget.id]?.statusMetrics ?? []
        return MenuBarPolicy.judgedMetrics(metrics).map { metrics[$0] }
    }

    @ViewBuilder
    private var thresholdControls: some View {
        let presentation = shownPresentation
        let unit = MenuBarPolicy.thresholdUnit(thresholdMetrics)
        let below = presentation.thresholdDirection == .below
        VStack(alignment: .leading, spacing: 6) {
            Picker("", selection: Binding(
                get: { presentation.thresholdDirection ?? .above },
                set: { value in setPresentation { $0.thresholdDirection = value == .above ? nil : value } }
            )) {
                Text("Higher is worse").tag(MenuBarThresholdDirection.above)
                Text("Lower is worse").tag(MenuBarThresholdDirection.below)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 210)
            HStack(spacing: 6) {
                thresholdField("Warning", $warningText, \.warningAt, unit: unit)
                thresholdField("Danger", $dangerText, \.dangerAt, unit: unit)
            }
            thresholdField(below ? "Show only at or below" : "Show only at or above", $showWhenText, \.showWhen, unit: unit)
            settingsHint(presentation.hasThresholds
                ? "Readings past a threshold turn warning or danger; the widget's own colors no longer apply. Blank turns one off."
                : "Blank uses the widget's own colors. A \"show only\" value hides the item until a reading gets there.")
        }
    }

    /// Text fields that write the draft on every keystroke, so Save right
    /// after typing keeps what was typed. The text is its own state: a field
    /// reformatted from the stored number could not be typed "7.5" into.
    private func thresholdField(
        _ title: String, _ text: Binding<String>,
        _ keyPath: WritableKeyPath<MenuBarPresentation, Double?>, unit: String
    ) -> some View {
        HStack(spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField("", text: Binding(
                get: { text.wrappedValue },
                set: { typed in
                    text.wrappedValue = typed
                    let trimmed = typed.trimmingCharacters(in: .whitespaces)
                    if trimmed.isEmpty {
                        setPresentation { $0[keyPath: keyPath] = nil }
                    } else if let value = Double(trimmed), value.isFinite {
                        setPresentation { $0[keyPath: keyPath] = value }
                    }
                }
            ))
            .textFieldStyle(.roundedBorder)
            .frame(width: 52)
            if !unit.isEmpty {
                Text(unit).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var livePresentation: MenuBarPresentation? {
        runtime.snapshots[widget.id]?.statusPresentation
    }

    private var manifestPresentation: MenuBarPresentation? {
        MenuBarPolicy.effectiveStatusItem(widget.manifest.statusItem).presentation
    }

    private var intervalBinding: Binding<Double> {
        Binding(
            get: { menuBarDraft.interval ?? 0 },
            set: { menuBarDraft.interval = $0 == 0 ? nil : $0 }
        )
    }

    private var widgetIntervalTitle: String {
        guard let seconds = widget.manifest.refresh?.interval else { return "Default" }
        return "Default (\(Self.intervalTitle(seconds).lowercased()))"
    }

    static func intervalTitle(_ seconds: Double) -> String {
        seconds >= 60 && seconds.truncatingRemainder(dividingBy: 60) == 0
            ? "Every \(Int(seconds / 60)) min"
            : seconds == seconds.rounded() ? "Every \(Int(seconds)) s" : "Every \(seconds) s"
    }

    private func metricHiddenBinding(_ key: String) -> Binding<Bool> {
        Binding(
            get: { !(resolvedMetricOverride(key)?.hidden ?? false) },
            set: { shown in
                let inheritedHidden = inheritedMetricOverride(key)?.hidden ?? false
                setMetricOverride(key) { override in
                    // A visible row still needs an explicit `false` when an
                    // author or live update hid it by default.
                    override.hidden = shown ? (inheritedHidden ? false : nil) : true
                }
            }
        )
    }

    private func metricLabelBinding(_ key: String) -> Binding<String> {
        Binding(
            get: { resolvedMetricOverride(key)?.label ?? "" },
            set: { label in
                let inherited = inheritedMetricOverride(key)?.label
                // An emptied field means "back to the default", not "blank":
                // storing "" would wipe the row's own label.
                let trimmed = label.trimmingCharacters(in: .whitespaces)
                setMetricOverride(key) {
                    $0.label = (trimmed.isEmpty || label == inherited) ? nil : label
                }
            }
        )
    }

    private func metricTintBinding(_ key: String) -> Binding<String> {
        Binding(
            get: { resolvedMetricOverride(key)?.tint ?? "automatic" },
            set: { tint in
                let inherited = inheritedMetricOverride(key)?.tint
                setMetricOverride(key) { $0.tint = tint == "automatic" || tint == inherited ? nil : tint }
            }
        )
    }

    /// Resolve each sparse row independently. A draft that changes one row
    /// must not make another row forget its live or author-supplied default.
    private func resolvedMetricOverride(_ key: String) -> MenuBarMetricOverride? {
        let statusItem = MenuBarPolicy.effectiveStatusItem(widget.manifest.statusItem)
        return MenuBarPolicy.resolvedPresentation(
            user: menuBarDraft.presentation,
            global: globalPresentation,
            live: runtime.snapshots[widget.id]?.statusPresentation,
            manifest: statusItem.presentation
        ).metricOverrides?[key]
    }

    private func inheritedMetricOverride(_ key: String) -> MenuBarMetricOverride? {
        inheritedPresentation.metricOverrides?[key]
    }

    private func setPresentation(_ change: (inout MenuBarPresentation) -> Void) {
        var presentation = menuBarDraft.presentation ?? MenuBarPresentation()
        change(&presentation)
        menuBarDraft.presentation = presentation
    }

    private func setMetricOverride(_ key: String, _ change: (inout MenuBarMetricOverride) -> Void) {
        setPresentation { presentation in
            var override = presentation.metricOverrides?[key] ?? MenuBarMetricOverride()
            change(&override)
            if presentation.metricOverrides == nil { presentation.metricOverrides = [:] }
            presentation.metricOverrides?[key] = override
        }
    }

    private func moveMetric(_ key: String, by delta: Int, rows: [(key: String, metric: StatusMetric)]) {
        setPresentation { presentation in
            // Start from what is on screen (unique keys, resolved order), not
            // from a stored order that may be partial or come from elsewhere.
            var order = rows.map(\.key)
            guard let index = order.firstIndex(of: key) else { return }
            let destination = index + delta
            guard order.indices.contains(destination) else { return }
            order.swapAt(index, destination)
            presentation.metricOrder = order
        }
    }

    private func settingsRowLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(width: 52, alignment: .leading)
    }

    private func settingsHint(_ text: String) -> some View {
        MenuBarStyleControls.hint(text)
    }

    // MARK: - Appearance section (R12)

    /// One accent choice: a display name and the stored `accent` value
    /// (nil for the system-accent "Default").
    private struct AccentSwatch {
        let name: String
        let value: String?
    }

    private let accentSwatches: [AccentSwatch] = [
        .init(name: "Default", value: nil),
        .init(name: "Blue", value: "blue"),
        .init(name: "Purple", value: "purple"),
        .init(name: "Pink", value: "pink"),
        .init(name: "Red", value: "red"),
        .init(name: "Orange", value: "orange"),
        .init(name: "Yellow", value: "yellow"),
        .init(name: "Green", value: "green"),
        .init(name: "Gray", value: "gray"),
    ]

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Appearance")
                .font(.system(size: 12, weight: .semibold))

            VStack(alignment: .leading, spacing: 4) {
                Text("Accent").font(.system(size: 11)).foregroundColor(.secondary)
                HStack(spacing: 6) {
                    ForEach(accentSwatches, id: \.name) { swatch in
                        accentButton(swatch)
                    }
                }
                HStack(spacing: 6) {
                    Text("Hex").font(.system(size: 11)).foregroundColor(.secondary)
                    TextField("#RRGGBB", text: hexBinding)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                        .accessibilityLabel("Custom accent hex color")
                }
            }

            HStack {
                Text("Density").font(.system(size: 12))
                Spacer()
                Picker("", selection: densityBinding) {
                    Text("Regular").tag(WidgetAppearance.Density.regular)
                    Text("Compact").tag(WidgetAppearance.Density.compact)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 160)
            }

            HStack {
                Text("Card style").font(.system(size: 12))
                Spacer()
                Picker("", selection: cardStyleBinding) {
                    Text("Plain").tag(WidgetAppearance.CardStyle.plain)
                    Text("Tinted").tag(WidgetAppearance.CardStyle.tinted)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 160)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("Height").font(.system(size: 12))
                    Spacer()
                    Picker("", selection: heightBinding) {
                        Text("Auto").tag(HeightPreset.fit)
                        Text("Short").tag(HeightPreset.small)
                        Text("Medium").tag(HeightPreset.medium)
                        Text("Tall").tag(HeightPreset.large)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 240)
                    .accessibilityLabel("Height")
                }
                Text("Auto grows the card to fit its content. Short, Medium, and Tall fix the height and scroll the rest.")
                    .font(.caption2).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Toggle("Show header", isOn: showHeaderBinding)
                .font(.system(size: 12))

            Button("Reset to widget default") { appearanceDraft = authorBase }
                .controlSize(.small)
        }
    }

    private func accentButton(_ swatch: AccentSwatch) -> some View {
        let selected = isAccentSelected(swatch.value)
        return Button {
            appearanceDraft.accent = swatch.value
        } label: {
            Circle()
                .fill(swatchColor(swatch))
                .frame(width: 18, height: 18)
                .overlay(
                    Circle().stroke(
                        Color.primary.opacity(selected ? 0.9 : 0.15),
                        lineWidth: selected ? 2 : 1
                    )
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(swatch.name) accent")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private func swatchColor(_ swatch: AccentSwatch) -> Color {
        WidgetAppearance(accent: swatch.value).accentColor ?? .accentColor
    }

    private func isAccentSelected(_ value: String?) -> Bool {
        switch (value, appearanceDraft.accent) {
        case (nil, nil): return true
        case let (candidate?, current?):
            return candidate.caseInsensitiveCompare(current) == .orderedSame
        default: return false
        }
    }

    private var hexBinding: Binding<String> {
        Binding(
            get: {
                guard let accent = appearanceDraft.accent, accent.hasPrefix("#") else { return "" }
                return accent
            },
            set: { text in
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty {
                    appearanceDraft.accent = nil
                } else {
                    appearanceDraft.accent = trimmed.hasPrefix("#") ? trimmed : "#" + trimmed
                }
            }
        )
    }

    private var densityBinding: Binding<WidgetAppearance.Density> {
        Binding(
            get: { appearanceDraft.density ?? .regular },
            set: { appearanceDraft.density = $0 }
        )
    }

    private var cardStyleBinding: Binding<WidgetAppearance.CardStyle> {
        Binding(
            get: { appearanceDraft.cardStyle ?? .plain },
            set: { appearanceDraft.cardStyle = $0 }
        )
    }

    private var showHeaderBinding: Binding<Bool> {
        Binding(
            get: { appearanceDraft.showHeader ?? true },
            set: { appearanceDraft.showHeader = $0 }
        )
    }

    /// Fit-to-content or a fixed height preset, backing `appearance.fixedHeight`.
    private enum HeightPreset: Hashable {
        case fit, small, medium, large
        var value: Double? {
            switch self {
            case .fit: return nil
            case .small: return 140
            case .medium: return 220
            case .large: return 320
            }
        }
        init(_ height: Double?) {
            switch height {
            case .none: self = .fit
            case .some(let h) where h <= 160: self = .small
            case .some(let h) where h <= 260: self = .medium
            default: self = .large
            }
        }
    }

    private var heightBinding: Binding<HeightPreset> {
        Binding(
            get: { HeightPreset(appearanceDraft.fixedHeight) },
            set: { appearanceDraft.fixedHeight = $0.value }
        )
    }

    @ViewBuilder
    private func row(for entry: Manifest.Setting, key: String) -> some View {
        let title = entry.title ?? entry.label ?? key
        switch entry.type {
        case "boolean":
            Toggle(title, isOn: Binding(
                get: { values[key]?.boolValue ?? false },
                set: { values[key] = .bool($0) }
            ))
            .font(.system(size: 12))
        case "integer":
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(title).font(.system(size: 12))
                    Spacer()
                    TextField("", text: Binding(
                        get: { values[key]?.numberValue.map { String(Int($0)) } ?? "" },
                        set: { text in
                            let filtered = text.filter { $0.isNumber || $0 == "-" }
                            if filtered.isEmpty {
                                values[key] = nil
                            } else if let number = Double(filtered) {
                                values[key] = .number(number)
                            }
                        }
                    ))
                    .frame(width: 60)
                    .multilineTextAlignment(.trailing)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        if let number = values[key]?.numberValue {
                            values[key] = .number(clampedInteger(number, entry: entry))
                        }
                    }
                    Stepper("", value: integerBinding(key, entry: entry))
                        .labelsHidden()
                        .accessibilityLabel("\(title) stepper")
                }
                if let hint = rangeHint(for: entry) {
                    Text(hint)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        case "enum":
            HStack {
                Text(title).font(.system(size: 12))
                Spacer()
                Picker("", selection: Binding(
                    get: { values[key]?.stringValue ?? "" },
                    set: { values[key] = .string($0) }
                )) {
                    ForEach(entry.options ?? [], id: \.self) { option in
                        Text(Self.optionTitle(option, in: entry)).tag(option)
                    }
                    let extra = dynamicOptions(for: entry, selected: values[key]?.stringValue)
                    if !extra.isEmpty {
                        Divider()
                        ForEach(extra, id: \.value) { option in
                            Text(option.title).tag(option.value)
                        }
                    }
                }
                .labelsHidden()
                .frame(width: entry.optionsSource == nil ? 140 : 190)
            }
        case "directory":
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 12))
                HStack {
                    TextField("~/path", text: stringBinding(key))
                        .textFieldStyle(.roundedBorder)
                    Button("Choose…") { chooseDirectory(for: key) }
                        .controlSize(.small)
                }
            }
        default: // "string"
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 12))
                TextField("", text: stringBinding(key))
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    /// The options an `optionsSource` adds, plus the stored value when this
    /// Mac does not offer it (a sensor another Mac has), so the picker never
    /// shows a blank selection.
    private func dynamicOptions(
        for entry: Manifest.Setting, selected: String?
    ) -> [(value: String, title: String)] {
        guard entry.optionsSource == Manifest.Setting.sensorOptionsSource else { return [] }
        var options = sensorOptions.map { reading in
            (value: "key:\(reading.key)", title: Self.sensorOptionTitle(reading))
        }
        if let selected, let key = SensorSampler.pickedKey(selected),
           !options.contains(where: { $0.value == selected }),
           !(entry.options ?? []).contains(selected) {
            // Only a list that loaded and lacks it says "not on this Mac":
            // still loading, or a build that cannot read sensors, just names it.
            options.insert((selected, sensorOptions.isEmpty ? key : "\(key) (not on this Mac)"), at: 0)
        }
        return options
    }

    /// A made-up recent history, as fractions of the scale, for the preview.
    static let exampleChart: [Double] = [
        0.22, 0.25, 0.31, 0.28, 0.34, 0.47, 0.52, 0.44, 0.38, 0.41, 0.36, 0.33,
        0.39, 0.58, 0.66, 0.61, 0.49, 0.42, 0.37, 0.35, 0.40, 0.45, 0.43, 0.38,
    ]

    static func sensorOptionTitle(_ reading: SensorReading) -> String {
        // Spelled out as °C: the widget may show °F, and a bare "71°" beside
        // a 160°F menu bar reads as a wrong number.
        let value = String(format: reading.kind == .temperature ? "%.0f%@" : "%.0f %@", reading.value, reading.unit)
        return "\(reading.name) · \(value)"
    }

    private func loadDynamicOptions() {
        guard entries.contains(where: { $0.optionsSource == Manifest.Setting.sensorOptionsSource }) else { return }
        Task {
            // A detail sample reads every key (~25 ms): off the main thread.
            let list = await Task.detached(priority: .userInitiated) {
                SensorSampler.shared.sample(detail: true).list
            }.value
            sensorOptions = list
        }
    }

    private func stringBinding(_ key: String) -> Binding<String> {
        Binding(
            get: { values[key]?.stringValue ?? "" },
            set: { values[key] = .string($0) }
        )
    }

    /// Rounds to an integer and clamps to the manifest's declared min/max.
    private func clampedInteger(_ value: Double, entry: Manifest.Setting) -> Double {
        var result = value.rounded()
        if let min = entry.min { result = Swift.max(result, min) }
        if let max = entry.max { result = Swift.min(result, max) }
        return result
    }

    /// Stepper binding that always keeps the stored value inside the declared
    /// range — nudging can never step past min/max.
    private func integerBinding(_ key: String, entry: Manifest.Setting) -> Binding<Int> {
        Binding(
            get: {
                let current = values[key]?.numberValue ?? entry.min ?? 0
                return Int(clampedInteger(current, entry: entry))
            },
            set: { values[key] = .number(clampedInteger(Double($0), entry: entry)) }
        )
    }

    private func rangeHint(for entry: Manifest.Setting) -> String? {
        switch (entry.min, entry.max) {
        case let (min?, max?): return "Range \(Int(min))–\(Int(max))"
        case let (min?, nil): return "Min \(Int(min))"
        case let (nil, max?): return "Max \(Int(max))"
        default: return nil
        }
    }

    @ViewBuilder
    private var clickControls: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("", selection: Binding(
                get: { menuBarDraft.effectiveClickAction },
                set: { menuBarDraft.clickAction = $0 == .card ? nil : $0 }
            )) {
                Text("Show the card").tag(MenuBarClickAction.card)
                Text("Refresh").tag(MenuBarClickAction.refresh)
                Text("Open an app or link").tag(MenuBarClickAction.open)
                Text("Open BarShelf").tag(MenuBarClickAction.hub)
            }
            .labelsHidden()
            .frame(width: 180)
            if menuBarDraft.effectiveClickAction == .open {
                HStack(spacing: 6) {
                    TextField("com.apple.ActivityMonitor or https://…", text: Binding(
                        get: { menuBarDraft.clickTarget ?? "" },
                        set: {
                            menuBarDraft.clickTarget = $0.isEmpty ? nil : $0
                            clickTargetResolves = $0.isEmpty ? nil : StatusItemController.clickTargetURL($0) != nil
                        }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 190)
                    Button("Choose App…") { chooseClickApp() }
                        .controlSize(.small)
                }
                // Resolved when the target changes, not on every render: it is
                // a Launch Services lookup.
                if clickTargetResolves == false {
                    settingsHint("Nothing on this Mac answers to that; a click will show the card instead.")
                }
            }
            settingsHint(usesOwnItem
                ? "A right click always opens the item's menu, which can still show the card."
                : "Clicks belong to items with their own place in the menu bar.")
        }
    }

    /// Presets and "copy from" — whole looks in one step, over what is set.
    @ViewBuilder
    private var styleShortcuts: some View {
        let others = runtime.menuBarCandidates.filter { other in
            other.id != widget.id && runtime.prefs.menuBarPlacements[other.id] != nil
        }
        VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 8) {
            Menu("Apply Preset") {
                ForEach(MenuBarPresentation.presets, id: \.name) { preset in
                    Button(preset.name) {
                        setPresentation { $0 = $0.applying(preset: preset.presentation) }
                    }
                }
            }
            .fixedSize()
            Menu("Copy From") {
                ForEach(others, id: \.id) { other in
                    Button(other.displayName) {
                        menuBarDraft = menuBarDraft.copyingStyle(
                            layout: runtime.resolvedMenuBarStyle(for: other),
                            look: runtime.resolvedMenuBarLook(for: other)
                        )
                        syncAlertTexts()
                    }
                }
            }
            .fixedSize()
            .disabled(others.isEmpty)
        }
        .controlSize(.small)
        // Presets and copies reach past this tab: Minimal hides units, and a
        // copy takes the other item's unit setting.
        settingsHint("Can also change units, on the Readings tab.")
        }
    }

    /// The draft with what `tab` sets cleared back to the widget's own.
    private func resetting(_ tab: MenuBarSettingsTab, _ placement: MenuBarPlacement) -> MenuBarPlacement {
        var placement = placement
        var presentation = placement.presentation ?? MenuBarPresentation()
        switch tab {
        case .look:
            presentation = MenuBarPolicy.clearingGlobalStyle(presentation) ?? MenuBarPresentation()
            presentation.chart = nil
        case .readings:
            presentation.showValues = nil
            presentation.showUnits = nil
            presentation.precision = nil
            presentation.metricOrder = nil
            presentation.metricOverrides = nil
            presentation.warningAt = nil
            presentation.dangerAt = nil
            presentation.thresholdDirection = nil
            presentation.showWhen = nil
        case .behavior:
            placement.clickAction = nil
            placement.clickTarget = nil
            placement.interval = nil
        }
        placement.presentation = presentation == MenuBarPresentation() ? nil : presentation
        return placement
    }

    private func tabHasChoices(_ tab: MenuBarSettingsTab) -> Bool {
        resetting(tab, menuBarDraft) != menuBarDraft
    }

    private func resetTab(_ tab: MenuBarSettingsTab) {
        menuBarDraft = resetting(tab, menuBarDraft)
        syncAlertTexts()
        if tab == .behavior { clickTargetResolves = nil }
    }

    /// The alert fields from the draft — on open, and whenever the draft's
    /// alerts change other than by typing (reset, Copy From).
    /// Plain "." decimals, the same way the fields parse them back.
    private func syncAlertTexts() {
        func text(_ value: Double?) -> String {
            guard let value else { return "" }
            return value == value.rounded() && abs(value) < 1e15 ? String(Int(value)) : String(value)
        }
        warningText = text(menuBarDraft.presentation?.warningAt)
        dangerText = text(menuBarDraft.presentation?.dangerAt)
        showWhenText = text(menuBarDraft.presentation?.showWhen)
    }

    private func chooseClickApp() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        if panel.runModal() == .OK, let url = panel.url {
            // The bundle id survives the app moving or updating; a path is
            // the fallback for an app without one.
            menuBarDraft.clickTarget = Bundle(url: url)?.bundleIdentifier ?? url.path
            clickTargetResolves = true
        }
    }

    private func chooseDirectory(for key: String) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            values[key] = .string(url.path)
        }
    }
}

/// The three tabs of a widget's menu bar settings.
enum MenuBarSettingsTab: CaseIterable {
    case look, readings, behavior

    var title: String {
        switch self {
        case .look: return "Look"
        case .readings: return "Readings"
        case .behavior: return "Behavior"
        }
    }
}

/// A stable object to register undo actions against; SwiftUI views are
/// values and cannot be one.
private final class UndoAnchor {
    static let shared = UndoAnchor()
}
