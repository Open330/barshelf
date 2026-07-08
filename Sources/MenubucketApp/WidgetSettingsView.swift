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

    private var entries: [Manifest.Setting] {
        (widget.manifest.settings ?? []).filter { $0.key != nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(widget.manifest.name) Settings")
                .font(.system(size: 13, weight: .semibold))

            if entries.isEmpty {
                Text("This widget has no settings.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                ForEach(entries, id: \.key) { entry in
                    row(for: entry, key: entry.key ?? "")
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    for entry in entries {
                        guard let key = entry.key else { continue }
                        // Enforce integer min/max on commit so free-typed
                        // out-of-range values never reach the widget.
                        if entry.type == "integer",
                           let number = values[key]?.numberValue {
                            values[key] = .number(clampedInteger(number, entry: entry))
                        }
                        runtime.prefs.setSetting(
                            widgetID: widget.id, key: key, value: values[key]
                        )
                    }
                    dismiss()
                    runtime.refresh(widgetID: widget.id)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(entries.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 300)
        .onAppear {
            values = runtime.prefs.effectiveSettings(for: widget.manifest).objectValue ?? [:]
        }
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
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                    .accessibilityHidden(true)
                TextField("Search widgets and items…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .onSubmit { execute(hits: hits) }
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
        .background(.regularMaterial)
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
                let name = widget.manifest.name
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
                widgetID: widget.id, widgetName: widget.manifest.name,
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
