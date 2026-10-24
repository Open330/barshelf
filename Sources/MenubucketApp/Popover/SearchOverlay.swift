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
    /// True while an input method (Korean, Japanese, …) has uncommitted text.
    @State private var isComposing = false
    /// Focus stays in the field, so VoiceOver would otherwise hear neither the
    /// result count nor which row ↑/↓ selected.
    @State private var announcements: SearchAnnouncements
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        runtime: WidgetRuntime,
        pager: PagerState,
        isPresented: Binding<Bool>,
        announcer: AccessibilityAnnouncing? = nil
    ) {
        self.runtime = runtime
        self.pager = pager
        _isPresented = isPresented
        _announcements = State(initialValue: SearchAnnouncements(
            announcer: announcer ?? AccessibilityAnnouncer.shared
        ))
    }

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
                            isComposing: $isComposing,
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
                // Not while an input method is composing: there Escape
                // cancels the composition, not the search.
                .keyboardShortcut(isComposing ? nil : .cancelAction)
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
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) {
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
        .onChange(of: query) {
            selection = 0
            announceResults()
        }
        .onChange(of: isComposing) { announceResults() }
        .onDisappear { announcements.cancelAll() }
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
        let target = min(max(selection + delta, 0), hits.count - 1)
        guard target != selection else { return }
        selection = target
        let hit = hits[target]
        announcements.selectionMoved(AccessibilityMessages.searchSelection(
            text: hit.text, widgetName: hit.widgetName, index: target, count: hits.count
        ))
    }

    /// The count and the row Return would now activate (the first, since a
    /// new query resets the selection). Nothing for an empty query.
    private func announceResults() {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            announcements.resultsChanged(nil, isComposing: isComposing)
            return
        }
        let hits = self.hits
        announcements.resultsChanged(AccessibilityMessages.searchResults(
            count: hits.count,
            firstText: hits.first?.text,
            firstWidgetName: hits.first?.widgetName
        ), isComposing: isComposing)
    }

    private var hits: [SearchHit] {
        Self.searchHits(query: query, pages: runtime.pages, snapshots: runtime.snapshots)
    }

    static func searchHits(
        query: String, pages: [WidgetPage], snapshots: [String: WidgetSnapshot]
    ) -> [SearchHit] {
        let needle = SearchMatcher(query)
        guard !needle.isEmpty else { return [] }
        var results: [SearchHit] = []
        // A reading shown twice (a list and its summary) is one result.
        var seen: Set<String> = []
        for (pageIndex, page) in pages.enumerated() {
            for widget in page.widgets {
                let name = widget.displayName
                // The name in every language the widget carries, so "시스템"
                // finds System while BarShelf is shown in English.
                let names: [String?] = [name, widget.manifest.name]
                    + (widget.manifest.localizations?.allTranslations(of: widget.manifest.name) ?? [])
                let nameMatches = needle.matches(any: names)
                if nameMatches {
                    results.append(SearchHit(
                        id: "widget-\(widget.id)", widgetID: widget.id,
                        widgetName: name, pageIndex: pageIndex,
                        text: name, action: nil
                    ))
                }
                if let tree = snapshots[widget.id]?.viewTree {
                    collect(node: tree, needle: needle, widget: widget, names: names, nameMatches: nameMatches,
                            pageIndex: pageIndex, seen: &seen, into: &results)
                }
            }
        }
        return Array(results.prefix(30))
    }

    private static func collect(
        node: UINode, needle: SearchMatcher, widget: LoadedWidget, names: [String?], nameMatches: Bool,
        pageIndex: Int, seen: inout Set<String>, into results: inout [SearchHit]
    ) {
        if let text = node.text,
           needle.matches(text) || (!nameMatches && needle.matches(any: [text] + names)),
           seen.insert("\(widget.id)\u{0}\(text)").inserted {
            results.append(SearchHit(
                id: "\(widget.id)-\(node.id ?? text)-\(results.count)",
                widgetID: widget.id, widgetName: widget.displayName,
                pageIndex: pageIndex, text: text, action: node.action
            ))
        }
        for child in (node.children ?? []) + (node.items ?? []) {
            collect(node: child, needle: needle, widget: widget, names: names, nameMatches: nameMatches,
                    pageIndex: pageIndex, seen: &seen, into: &results)
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

/// What search says to VoiceOver, and when.
///
/// The results shown are announced once typing pauses. While an input method
/// holds uncommitted text the pause must be longer: Korean keeps the last
/// syllable marked until the next key, so a query can rest mid-composition
/// indefinitely — it must still be announced, but not on every jamo. Each
/// keystroke restarts the wait, so a burst says only its last state.
@MainActor
final class SearchAnnouncements {
    private let settled: AnnouncementDebouncer
    private let composing: AnnouncementDebouncer
    private let selection: AnnouncementDebouncer

    init(
        announcer: AccessibilityAnnouncing,
        settledDelay: Duration = .milliseconds(500),
        composingDelay: Duration = .milliseconds(1200),
        selectionDelay: Duration = .milliseconds(150)
    ) {
        settled = AnnouncementDebouncer(announcer: announcer, delay: settledDelay)
        composing = AnnouncementDebouncer(announcer: announcer, delay: composingDelay)
        selection = AnnouncementDebouncer(announcer: announcer, delay: selectionDelay)
    }

    /// The results changed. `message` is nil for an empty query: nothing to say.
    func resultsChanged(_ message: String?, isComposing: Bool) {
        selection.cancel()
        settled.cancel()
        composing.cancel()
        guard let message else { return }
        (isComposing ? composing : settled).schedule(message)
    }

    /// ↑/↓ chose another row. A pending count would describe the first row.
    func selectionMoved(_ message: String) {
        settled.cancel()
        composing.cancel()
        selection.schedule(message)
    }

    func cancelAll() {
        settled.cancel()
        composing.cancel()
        selection.cancel()
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
    /// Set while the field editor holds marked (uncommitted IME) text.
    var isComposing: Binding<Bool>?
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
            guard let f = note.object as? NSSearchField else { return }
            if let isComposing = parent.isComposing {
                let composing = (f.currentEditor() as? NSTextView)?.hasMarkedText() ?? false
                if isComposing.wrappedValue != composing { isComposing.wrappedValue = composing }
            }
            parent.text = f.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView,
                     doCommandBy selector: Selector) -> Bool {
            // Uncommitted input-method text: Return, Escape and the arrows
            // belong to the input method (commit, cancel, choose), not to
            // search. Search sees them again once the text is committed.
            if textView.hasMarkedText() { return false }
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
