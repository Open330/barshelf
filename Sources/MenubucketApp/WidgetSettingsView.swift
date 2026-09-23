import AppKit
import MenubucketCore
import SwiftUI

/// Auto-generated settings form from the manifest's `settings[]` entries
/// (string / integer / boolean / enum / directory). Saving stores overrides
/// in `WidgetPrefs` and reloads the widget.
struct WidgetSettingsView: View {
    let widget: LoadedWidget
    @ObservedObject var runtime: WidgetRuntime
    @Environment(\.dismiss) private var dismiss

    @State private var values: [String: JSONValue] = [:]
    /// The theming override being edited (R12). Loaded from the effective
    /// appearance so the controls reflect the widget's current look.
    @State private var appearanceDraft = WidgetAppearance()
    /// Menu-bar promotion being edited.
    @State private var menuBarDraft = MenuBarPlacement(enabled: false)
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
        VStack(alignment: .leading, spacing: 12) {
            Text("\(widget.displayName) Settings")
                .font(.system(size: 13, weight: .semibold))

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if entries.isEmpty {
                        Text("This widget has no settings.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(entries, id: \.key) { entry in
                            row(for: entry, key: entry.key ?? "")
                        }
                    }

                    Divider()
                    menuBarSection

                    Divider()
                    appearanceSection
                }
            }
            .frame(maxHeight: Self.scrollMaxHeight)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 320)
        .onAppear {
            values = runtime.prefs.effectiveSettings(
                for: widget.manifest, widgetID: widget.id
            ).objectValue ?? [:]
            appearanceDraft = runtime.prefs.effectiveAppearance(
                for: widget.manifest, widgetID: widget.id
            )
            menuBarDraft = runtime.prefs.menuBarPlacement(
                for: widget.manifest, widgetID: widget.id
            )
        }
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

    private func save() {
        for entry in entries {
            guard let key = entry.key else { continue }
            // Enforce integer min/max on commit so free-typed out-of-range
            // values never reach the widget.
            if entry.type == "integer", let number = values[key]?.numberValue {
                values[key] = .number(clampedInteger(number, entry: entry))
            }
            runtime.prefs.setSetting(widgetID: widget.id, key: key, value: values[key])
        }
        // Editing everything back to the author default clears the override.
        let base = authorBase
        runtime.prefs.setAppearanceOverride(
            appearanceDraft == base ? nil : appearanceDraft, for: widget.id
        )
        // Same rule as the appearance override above: storing a placement that
        // matches the default would pin the widget away from it forever.
        let menuBarBase = MenuBarPolicy.resolvedPlacement(
            stored: nil, statusItem: widget.manifest.statusItem
        )
        runtime.setMenuBarPlacement(
            menuBarDraft == menuBarBase ? nil : menuBarDraft, for: widget.id
        )
        dismiss()
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
            global: runtime.appPrefs.preferences.menuBarPresentation,live: snapshot?.statusPresentation,
            manifest: statusItem.presentation
        )
        return MenuBarPolicy.applyingPresentation(presentation, to: entry)
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
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.primary.opacity(0.07))
                )
            Spacer(minLength: 0)
        }
    }

    /// One row per question, each with its own heading — the controls used to
    /// be two unlabelled radio groups in a row, which gave four buttons and no
    /// way to tell which question either pair answered.
    private var menuBarControls: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 10) {
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
                settingsRowLabel("Color")
                styleControls.color
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

            if !editableMetricRows.isEmpty {
                GridRow {
                    settingsRowLabel("Metrics")
                    metricPresentationControls
                }
            }

            if menuBarDraft.presentation != nil {
                GridRow {
                    settingsRowLabel("Presentation")
                    Button("Reset menu presentation") { menuBarDraft.presentation = nil }
                        .controlSize(.small)
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
            global: runtime.appPrefs.preferences.menuBarPresentation,live: snapshot?.statusPresentation,
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
            global: runtime.appPrefs.preferences.menuBarPresentation,live: runtime.snapshots[widget.id]?.statusPresentation,
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
            user: menuBarDraft.presentation, live: livePresentation, manifest: manifestPresentation
        )
    }

    private var styleControls: MenuBarStyleControls {
        MenuBarStyleControls(
            shown: shownPresentation,
            inherited: inheritedPresentation,
            stored: menuBarDraft.presentation,
            usesOwnItem: usesOwnItem,
            change: { setPresentation($0) }
        )
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
            global: runtime.appPrefs.preferences.menuBarPresentation,live: runtime.snapshots[widget.id]?.statusPresentation,
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
        Text(text)
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
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
                        Text("Fit").tag(HeightPreset.fit)
                        Text("S").tag(HeightPreset.small)
                        Text("M").tag(HeightPreset.medium)
                        Text("L").tag(HeightPreset.large)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 200)
                }
                Text("Fit grows the card to its content; S/M/L give a fixed height that scrolls.")
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
                }
                .labelsHidden()
                .frame(width: 140)
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

// MARK: - Search (⌘F)

/// One flattened, actionable row of the search index.
struct SearchHit: Identifiable {
    let id: String
    let widgetID: String
    let widgetName: String
    let pageIndex: Int
    let text: String
    let action: NodeAction?
}

/// Unified search over widget names and the text nodes of each widget's
/// current snapshot. Selecting a hit reveals its card on the correct page and
/// scrolls it into view; hits carrying a node action execute it directly.
struct SearchOverlay: View {
    @ObservedObject var runtime: WidgetRuntime
    @ObservedObject var pager: PagerState
    @Binding var isPresented: Bool
    @State private var query = ""
    @State private var selection = 0

    var body: some View {
        let hits = self.hits
        return VStack(spacing: 0) {
            HStack(spacing: 6) {
                // AppKit-backed field: native ⌘A/⌘C/⌘V/⌘X via the field editor
                // (a .accessory menu-bar app in an NSPopover has no Edit menu, so a
                // plain SwiftUI TextField can't route those), plus autofocus and a
                // built-in search icon + clear button.
                SearchField(text: $query,
                            placeholder: "Search widgets and items…",
                            autofocus: true,
                            onSubmit: { execute(hits: hits) },
                            onCancel: { isPresented = false },
                            onMoveSelection: { moveSelection($0, hits: hits) })
                    .frame(height: 22)
                    .accessibilityLabel("Search widgets and items")
                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Close search")
            }
            .padding(10)
            Divider()
            if hits.isEmpty {
                Text(query.isEmpty ? "Type to search" : "No matches")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 1) {
                            ForEach(Array(hits.enumerated()), id: \.element.id) { index, hit in
                                resultRow(index: index, hit: hit, hits: hits)
                                    .id(hit.id)
                            }
                        }
                    }
                    .frame(maxHeight: 220)
                    .onChange(of: selection) { newValue in
                        guard hits.indices.contains(newValue) else { return }
                        withAnimation(.easeOut(duration: 0.12)) {
                            proxy.scrollTo(hits[newValue].id, anchor: .center)
                        }
                    }
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        // RootView hides and disables the shelf under this overlay. Keeping the
        // search surface as one contained accessibility region prevents its
        // result rows from being interleaved with background controls.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Widget search")
        .onChange(of: query) { _ in selection = 0 }
        // ↑/↓ move the highlighted result while the search field keeps focus;
        // hidden zero-size buttons capture the arrow keys on macOS 13 (no
        // `.onKeyPress`). ⏎ (onSubmit) activates the current selection.
        .background(
            VStack(spacing: 0) {
                Button("") { moveSelection(-1, hits: hits) }
                    .keyboardShortcut(.upArrow, modifiers: [])
                Button("") { moveSelection(1, hits: hits) }
                    .keyboardShortcut(.downArrow, modifiers: [])
            }
            .opacity(0)
            .accessibilityHidden(true)
        )
    }

    private func resultRow(index: Int, hit: SearchHit, hits: [SearchHit]) -> some View {
        Button {
            selection = index
            execute(hits: hits)
        } label: {
            HStack {
                Text(hit.text)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                Text(hit.widgetName)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                index == selection
                    ? Color.accentColor.opacity(0.15) : .clear
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(hit.text), \(hit.widgetName)")
        .accessibilityAddTraits(index == selection ? [.isSelected] : [])
    }

    private func moveSelection(_ delta: Int, hits: [SearchHit]) {
        guard !hits.isEmpty else { return }
        selection = min(max(selection + delta, 0), hits.count - 1)
    }

    private var hits: [SearchHit] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return [] }
        var results: [SearchHit] = []
        let pages = runtime.pages
        for (pageIndex, page) in pages.enumerated() {
            for widget in page.widgets {
                let name = widget.displayName
                if name.lowercased().contains(needle) {
                    results.append(SearchHit(
                        id: "widget-\(widget.id)", widgetID: widget.id,
                        widgetName: name, pageIndex: pageIndex,
                        text: name, action: nil
                    ))
                }
                if let tree = runtime.snapshots[widget.id]?.viewTree {
                    collect(node: tree, needle: needle, widget: widget,
                            pageIndex: pageIndex, into: &results)
                }
            }
        }
        return Array(results.prefix(30))
    }

    private func collect(
        node: UINode, needle: String, widget: LoadedWidget,
        pageIndex: Int, into results: inout [SearchHit]
    ) {
        if let text = node.text, text.lowercased().contains(needle) {
            results.append(SearchHit(
                id: "\(widget.id)-\(node.id ?? text)-\(results.count)",
                widgetID: widget.id, widgetName: widget.displayName,
                pageIndex: pageIndex, text: text, action: node.action
            ))
        }
        for child in (node.children ?? []) + (node.items ?? []) {
            collect(node: child, needle: needle, widget: widget,
                    pageIndex: pageIndex, into: &results)
        }
    }

    private func execute(hits: [SearchHit]) {
        guard hits.indices.contains(selection) else { return }
        let hit = hits[selection]
        // Go through the runtime so RootView can both select the page and
        // scroll/flash the card. This also makes repeated selections of the
        // same result observable as separate reveal requests.
        runtime.reveal(widgetID: hit.widgetID)
        if let action = hit.action {
            ActionRouter.perform(action, widgetID: hit.widgetID, runtime: runtime)
        }
        isPresented = false
    }
}

/// `NSSearchField` that guarantees the standard editing shortcuts even when the
/// popover isn't the key window and the (`.accessory`) app has no Edit menu —
/// the usual reason ⌘A/⌘C/⌘V do nothing in a menu-bar app's text fields.
final class KeyEquivSearchField: NSSearchField {
    var onWindowAvailable: ((KeyEquivSearchField) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { onWindowAvailable?(self) }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard mods == .command, let ch = event.charactersIgnoringModifiers,
              let editor = currentEditor() else {
            return super.performKeyEquivalent(with: event)
        }
        switch ch {
        case "a": editor.selectAll(nil); return true
        case "c": editor.copy(nil); return true
        case "v": editor.paste(nil); return true
        case "x": editor.cut(nil); return true
        default: return super.performKeyEquivalent(with: event)
        }
    }
}

/// SwiftUI wrapper around `NSSearchField`: native selection/clipboard behavior,
/// a built-in magnifier + clear button, and autofocus when it appears.
struct SearchField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String = "Search"
    var autofocus: Bool = false
    var onSubmit: () -> Void = {}
    var onCancel: () -> Void = {}
    var onMoveSelection: ((Int) -> Void)?

    func makeNSView(context: Context) -> NSSearchField {
        let field = KeyEquivSearchField()
        field.delegate = context.coordinator
        field.onWindowAvailable = { [weak coordinator = context.coordinator] field in
            coordinator?.focusIfNeeded(field)
        }
        field.placeholderString = placeholder
        // Preserve AppKit's standard focus ring. Search is opened by ⌘F, so a
        // clear keyboard-focus cue is more useful than blending into the
        // popover chrome.
        field.focusRingType = .default
        field.sendsWholeSearchString = false
        field.font = .systemFont(ofSize: 13)
        field.isEnabled = context.environment.isEnabled
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        // SwiftUI retains coordinators between updates. Refresh the callbacks
        // so Enter/arrow keys use the current query, results, and selection.
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        if field.placeholderString != placeholder { field.placeholderString = placeholder }
        // SwiftUI's disabled environment does not automatically disable an
        // AppKit-backed field. Mirror it so an offscreen/blocked widget search
        // cannot stay in the native keyboard focus chain.
        field.isEnabled = context.environment.isEnabled
        context.coordinator.focusIfNeeded(field)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: SearchField
        var didFocus = false
        init(_ parent: SearchField) { self.parent = parent }

        func focusIfNeeded(_ field: NSSearchField) {
            guard parent.autofocus, !didFocus, field.isEnabled,
                  let window = field.window else { return }
            // Attachment can happen after updateNSView; retry on attachment,
            // and re-check before a queued focus request touches a new modal.
            DispatchQueue.main.async { [weak self, weak field, weak window] in
                guard let self, let field, let window,
                      self.parent.autofocus, !self.didFocus, field.isEnabled,
                      field.window === window else { return }
                self.didFocus = window.makeFirstResponder(field)
            }
        }

        func controlTextDidChange(_ note: Notification) {
            if let f = note.object as? NSSearchField { parent.text = f.stringValue }
        }

        func control(_ control: NSControl, textView: NSTextView,
                     doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)): parent.onSubmit(); return true
            case #selector(NSResponder.cancelOperation(_:)): parent.onCancel(); return true
            case #selector(NSResponder.moveUp(_:)):
                guard let move = parent.onMoveSelection else { return false }
                move(-1)
                return true
            case #selector(NSResponder.moveDown(_:)):
                guard let move = parent.onMoveSelection else { return false }
                move(1)
                return true
            default: return false
            }
        }
    }
}
