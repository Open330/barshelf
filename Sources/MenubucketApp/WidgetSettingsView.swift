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
            HStack {
                Text(title).font(.system(size: 12))
                Spacer()
                TextField("", text: Binding(
                    get: { values[key]?.numberValue.map { String(Int($0)) } ?? "" },
                    set: { text in
                        if let number = Double(text) { values[key] = .number(number) }
                    }
                ))
                .frame(width: 70)
                .multilineTextAlignment(.trailing)
                .textFieldStyle(.roundedBorder)
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
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search widgets and items…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .onSubmit { execute(hits: hits) }
                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
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
                ScrollView {
                    VStack(spacing: 1) {
                        ForEach(Array(hits.enumerated()), id: \.element.id) { index, hit in
                            Button {
                                selection = index
                                execute(hits: hits)
                            } label: {
                                HStack {
                                    Text(hit.text)
                                        .font(.system(size: 12))
                                        .lineLimit(1)
                                    Spacer()
                                    Text(hit.widgetName)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
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
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
        }
        .background(.regularMaterial)
        .onChange(of: query) { _ in selection = 0 }
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
