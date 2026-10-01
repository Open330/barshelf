import AppKit
import MenubucketCore
import SwiftUI
import UniformTypeIdentifiers

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
                            placeholder: String(localized: "Search widgets and items…"),
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
                    .onChange(of: selection) { _, newValue in
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
        .onChange(of: query) { selection = 0 }
        // ↑/↓ move the highlighted result and ⏎ activates it: the search
        // field's delegate turns them into moveUp/moveDown/insertNewline.
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
    var placeholder: String = String(localized: "Search")
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
