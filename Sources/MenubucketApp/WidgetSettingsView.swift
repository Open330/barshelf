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
                    appearanceSection
                }
            }
            .frame(maxHeight: 420)

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
        }
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
        dismiss()
        runtime.refresh(widgetID: widget.id)
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
                        Text(option).tag(option)
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
/// current snapshot. Selecting a hit jumps to its page; hits carrying a node
/// action execute it directly.
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
                            onSubmit: { execute(hits: hits) },
                            onCancel: { isPresented = false })
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
        pager.jump(to: hit.pageIndex, pageCount: runtime.pages.count)
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
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard mods == .command, let editor = currentEditor() else {
            return super.performKeyEquivalent(with: event)
        }
        switch event.charactersIgnoringModifiers {
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
    var onSubmit: () -> Void
    var onCancel: () -> Void

    func makeNSView(context: Context) -> NSSearchField {
        let field = KeyEquivSearchField()
        field.delegate = context.coordinator
        field.placeholderString = "Search widgets and items…"
        field.focusRingType = .none
        field.sendsWholeSearchString = false
        field.font = .systemFont(ofSize: 13)
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        if field.stringValue != text { field.stringValue = text }
        // Focus once the field is actually in a window (nil during makeNSView).
        if !context.coordinator.didFocus, let window = field.window {
            context.coordinator.didFocus = true
            DispatchQueue.main.async { window.makeFirstResponder(field) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        let parent: SearchField
        var didFocus = false
        init(_ parent: SearchField) { self.parent = parent }

        func controlTextDidChange(_ note: Notification) {
            if let f = note.object as? NSSearchField { parent.text = f.stringValue }
        }

        func control(_ control: NSControl, textView: NSTextView,
                     doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)): parent.onSubmit(); return true
            case #selector(NSResponder.cancelOperation(_:)): parent.onCancel(); return true
            default: return false
            }
        }
    }
}
