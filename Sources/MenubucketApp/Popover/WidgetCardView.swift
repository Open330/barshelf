import AppKit
import MenubucketCore
import SwiftUI
import UniformTypeIdentifiers

/// A widget card: name header, rendered content, cached-data warning banner
/// on failure, and an updated-at caption. Cached tree is shown while loading.
///
/// Performance (R05): the card observes only its own `WidgetCardModel` — the
/// runtime is held unobserved, so another widget's refresh publishes nothing
/// this card subscribes to and this card's body is not re-evaluated.
struct WidgetCardView: View {
    let widget: LoadedWidget
    let runtime: WidgetRuntime
    /// The pinned strip deliberately uses a compact, fixed footprint. This is
    /// separate from a widget's chosen card height, which remains unchanged in
    /// its regular panel.
    let compactHeight: CGFloat?
    /// When true the card border flashes accent (driven by `pendingReveal`).
    let isHighlighted: Bool
    @ObservedObject private var model: WidgetCardModel
    @State private var showSettings = false
    @State private var showRemoveConfirm = false
    @State private var showNewBucket = false
    @State private var newBucketName = ""
    @State private var removeError: String?
    /// Hovering reveals the per-card refresh button (hidden at rest to reduce
    /// visual noise). The button stays in the accessibility tree either way.
    @State private var isHovering = false
    @FocusState private var controlsFocused: Bool
    @State private var isDropTarget = false
    @Environment(\.colorScheme) private var colorScheme

    /// Effective theming (user override → author default → neutral). Injected
    /// into the rendered tree and used for the card's own chrome.
    private var appearance: WidgetAppearance {
        runtime.prefs.effectiveAppearance(for: widget.manifest, widgetID: widget.id)
    }

    /// The card's own chrome header (icon + name + refresh) is **off by default**
    /// — widgets carry their own header/content, so showing the app chrome too
    /// duplicated the logo and title. Opt in per widget with `showHeader: true`;
    /// refresh stays reachable via the context menu either way.
    private var showsHeader: Bool { appearance.showHeader ?? false }

    /// compact density tightens the card's content insets.
    private var contentInset: CGFloat { appearance.density == .compact ? 8 : 12 }

    /// Accent used for the tinted wash and the reveal highlight.
    private var cardAccent: Color { appearance.accentColor ?? .accentColor }

    /// Opt-in fixed card height (points). `nil` → the card fits its content
    /// (grows to fit) instead of a fixed footprint. Managed per widget via the
    /// manifest/appearance and the widget's Height setting — not a global size.
    private var effectiveFixedHeight: CGFloat? {
        appearance.fixedHeight.map { CGFloat($0) }
    }

    private var displayedFixedHeight: CGFloat? {
        compactHeight ?? effectiveFixedHeight
    }

    init(
        widget: LoadedWidget,
        runtime: WidgetRuntime,
        isHighlighted: Bool = false,
        compactHeight: CGFloat? = nil
    ) {
        self.widget = widget
        self.runtime = runtime
        self.isHighlighted = isHighlighted
        self.compactHeight = compactHeight
        _model = ObservedObject(wrappedValue: runtime.cardModel(for: widget.id))
    }

    var body: some View {
        let snapshot = model.snapshot
        cardStack(snapshot: snapshot)
            .padding(.horizontal, contentInset + 2)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .modifier(OptionalHeight(height: displayedFixedHeight))
            .environment(\.widgetAppearance, appearance)
            .environment(\.remoteImageHosts, widget.manifest.permissions?.network ?? [])
            .environment(\.localFileReadPaths, runtime.effectiveReadPaths(for: widget))
        .background(sectionBackground)
        .overlay(alignment: .topTrailing) { cardControls }
        // Insertion indicator while a dragged card hovers over this one.
        .overlay(alignment: .leading) {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.accentColor)
                    .frame(width: 4)
                    .padding(.vertical, 6)
                    .transition(.opacity)
            }
        }
        .contentShape(Rectangle())
        // Drop target: another card dropped here reorders it before this one.
        .onDrop(of: [UTType.plainText], isTargeted: $isDropTarget.animation(.easeInOut(duration: 0.12))) { providers in
            reorderDrop(providers)
        }
        .animation(.easeInOut(duration: 0.4), value: isHighlighted)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) { isHovering = hovering }
        }
        .accessibilityAction(named: Text("Refresh")) {
            runtime.refresh(widgetID: widget.id)
        }
        .accessibilityAction(named: Text("Open settings")) {
            showSettings = true
        }
        .accessibilityAction(named: Text("Move up")) { moveWithinPanel(by: -1) }
        .accessibilityAction(named: Text("Move down")) { moveWithinPanel(by: 1) }
        .accessibilityAction(named: Text(runtime.prefs.isPinned(widget.id) ? "Unpin" : "Pin")) {
            runtime.prefs.togglePin(widget.id)
            runtime.objectWillChange.send()
        }
        .contextMenu { cardContextMenu }
        .sheet(isPresented: $showSettings) {
            WidgetSettingsView(widget: widget, runtime: runtime)
        }
        .alert("Move to a new panel", isPresented: $showNewBucket) {
            TextField("Panel name", text: $newBucketName)
            Button("Cancel", role: .cancel) { newBucketName = "" }
            Button("Move") {
                let name = newBucketName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty { runtime.moveWidget(id: widget.id, toGroup: name) }
                newBucketName = ""
            }
        } message: {
            Text("Enter a name for the panel to move \(widget.displayName) into.")
        }
        .alert("Remove \(widget.displayName)?", isPresented: $showRemoveConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) {
                do { try runtime.removeWidget(id: widget.id) }
                catch { removeError = error.localizedDescription }
            }
        } message: {
            Text("This deletes the widget's files and settings and cannot be undone.")
        }
        .alert(
            "Couldn't remove widget",
            isPresented: Binding(
                get: { removeError != nil },
                set: { if !$0 { removeError = nil } }
            )
        ) {
            Button("OK") {}
        } message: {
            Text(removeError ?? "")
        }
    }

    @ViewBuilder
    private func cardStack(snapshot: WidgetSnapshot) -> some View {
        if compactHeight != nil {
            // Pinned cards cannot grow the popup. Scroll the whole card body so
            // the update caption and long widget content remain reachable.
            ScrollView(.vertical, showsIndicators: true) {
                cardContents(snapshot: snapshot, scrollFixedContent: false)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            cardContents(
                snapshot: snapshot,
                scrollFixedContent: effectiveFixedHeight != nil
            )
        }
    }

    @ViewBuilder
    private func cardContents(snapshot: WidgetSnapshot, scrollFixedContent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if showsHeader {
                cardHeader(snapshot: snapshot)
            }
            if scrollFixedContent {
                // Fixed footprint: content taller than the card scrolls inside.
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 8) { cardContent(snapshot: snapshot) }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                // Fit to content: the card grows to fit.
                VStack(alignment: .leading, spacing: 8) { cardContent(snapshot: snapshot) }
            }
            if let updatedAt = snapshot.updatedAt {
                Text("Updated \(Self.relativeFormatter.localizedString(for: updatedAt, relativeTo: Date()))")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder
    private func cardContent(snapshot: WidgetSnapshot) -> some View {
        if let overlay = model.overlay {
            // Host-generated card (permission approval / restart) replaces the
            // widget content until resolved.
            ViewTreeRenderer(node: overlay)
                .environment(\.actionContext, actionContext)
        } else if let tree = snapshot.viewTree {
            if let error = snapshot.error {
                staleBanner(error: error)
            }
            ViewTreeRenderer(node: tree)
                .environment(\.actionContext, actionContext)
        } else if let error = snapshot.error {
            failureState(error: error)
        } else if snapshot.isLoading {
            loadingState
        } else {
            Text("No data yet")
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 8)
        }
    }

    /// Card right-click actions: pin/refresh/settings plus R11 management —
    /// disable, move to a panel, reveal on disk, and destructive removal.
    @ViewBuilder
    private var cardContextMenu: some View {
        Button(runtime.prefs.isPinned(widget.id) ? "Unpin" : "Pin") {
            runtime.prefs.togglePin(widget.id)
            runtime.objectWillChange.send() // pinned row lives in RootView
        }
        Button("Settings…") { showSettings = true }
        Button("Refresh") { runtime.refresh(widgetID: widget.id) }

        Button("Move Up") { moveWithinPanel(by: -1) }
            .disabled(adjacentWidget(by: -1) == nil)
        Button("Move Down") { moveWithinPanel(by: 1) }
            .disabled(adjacentWidget(by: 1) == nil)

        Divider()

        Button(runtime.prefs.isDisabled(widget.id) ? "Enable" : "Disable") {
            runtime.setWidgetDisabled(widget.id, !runtime.prefs.isDisabled(widget.id))
        }
        Menu("Move to Panel") {
            ForEach(runtime.allGroups, id: \.self) { group in
                Button(group) { runtime.moveWidget(id: widget.id, toGroup: group) }
            }
            Divider()
            Button("New Panel…") { showNewBucket = true }
        }
        Button("Reveal in Finder") {
            if let directory = runtime.widgetDirectory(for: widget.id) {
                NSWorkspace.shared.activateFileViewerSelecting([directory])
            }
        }

        Divider()

        Button("Remove Widget…", role: .destructive) { showRemoveConfirm = true }
    }

    private func adjacentWidget(by offset: Int) -> LoadedWidget? {
        guard let page = runtime.pages.first(where: { $0.widgets.contains { $0.id == widget.id } }),
              let index = page.widgets.firstIndex(where: { $0.id == widget.id }),
              page.widgets.indices.contains(index + offset) else { return nil }
        return page.widgets[index + offset]
    }

    private func moveWithinPanel(by offset: Int) {
        guard let adjacent = adjacentWidget(by: offset) else { return }
        if offset < 0 {
            runtime.reorderWidget(id: widget.id, before: adjacent.id)
        } else {
            runtime.reorderWidget(id: adjacent.id, before: widget.id)
        }
        runtime.reveal(widgetID: widget.id)
    }

    private var actionContext: ActionContext {
        ActionContext(widgetID: widget.id) { [weak runtime] action in
            ActionRouter.perform(action, widgetID: widget.id, runtime: runtime)
        }
    }

    /// Quieter header: `.caption` secondary so the widget name recedes and the
    /// content reads first. The refresh button is revealed on hover only.
    private func cardHeader(snapshot: WidgetSnapshot) -> some View {
        HStack(spacing: 6) {
            if let icon = widget.manifest.icon {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .accessibilityHidden(true)
            }
            Text(widget.displayName)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            if snapshot.isLoading {
                ProgressView().controlSize(.mini)
                    .accessibilityLabel("Refreshing")
            }
        }
    }

    /// Centered progress + caption while the first data load is in flight.
    private var loadingState: some View {
        VStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text("Loading…").font(.caption).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Loading")
    }

    /// Hover controls at the widget's top-right — refresh, a drag handle to
    /// move/reorder, and settings — grouped in one glass capsule.
    @ViewBuilder
    private var cardControls: some View {
        HStack(spacing: 2) {
            Button { runtime.refresh(widgetID: widget.id) } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 20)
            }
            .buttonStyle(.plain)
            .focused($controlsFocused)
            .help("Refresh \(widget.displayName)")
            .accessibilityLabel("Refresh \(widget.displayName)")
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 20)
                .onDrag {
                    NSItemProvider(object: widget.id as NSString)
                } preview: {
                    dragPreview
                }
                .help("Drag to move")
                .accessibilityLabel("Move \(widget.displayName)")
            Button { showSettings = true } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 20)
            }
            .buttonStyle(.plain)
            .focused($controlsFocused)
            .help("Widget settings")
            .accessibilityLabel("Settings for \(widget.displayName)")
        }
        .padding(.horizontal, 3)
        .padding(.vertical, 2)
        .modifier(ControlCapsule())
        .padding(6)
        // Keep the controls in the focus order even while visually quiet; a
        // keyboard focus immediately reveals them without making the whole
        // card (and its embedded text fields) a separate focus target.
        .opacity(isHovering || controlsFocused ? 1 : 0)
    }

    /// The card's drag proxy — a labeled chip so you can see what you're moving.
    private var dragPreview: some View {
        HStack(spacing: 6) {
            Image(systemName: widget.manifest.icon ?? "square.grid.2x2")
                .foregroundStyle(cardAccent)
            Text(widget.displayName)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(cardAccent.opacity(0.4), lineWidth: 1)
        )
    }

    private func reorderDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let draggedId = object as? String else { return }
            DispatchQueue.main.async {
                runtime.reorderWidget(id: draggedId, before: widget.id)
            }
        }
        return true
    }

    /// Applies a fixed height only when one is set; otherwise leaves the view to
    /// size itself (fit-to-content).
    private struct OptionalHeight: ViewModifier {
        let height: CGFloat?
        @ViewBuilder
        func body(content: Content) -> some View {
            if let height {
                content.frame(height: height)
            } else {
                // Fit-to-content, but never collapse below a row-like floor so
                // short widgets don't read as broken.
                content.frame(minHeight: 56, alignment: .topLeading)
            }
        }
    }

    /// Flat, edge-to-edge section fill. The popup's glass shows through at
    /// rest; hover gets a whisper of contrast, a `tinted` widget a flat accent
    /// wash, and the reveal flash a stronger accent — no gradients, no boxes.
    private var sectionBackground: some View {
        let tinted = appearance.cardStyle == .tinted
        let dark = colorScheme == .dark
        return Rectangle()
            .fill(
                isHighlighted
                    ? cardAccent.opacity(dark ? 0.22 : 0.16)
                    : tinted
                        ? cardAccent.opacity(dark ? 0.12 : 0.07)
                        : isHovering
                            ? Color.primary.opacity(dark ? 0.06 : 0.04)
                            : Color.clear
            )
    }

    private func staleBanner(error: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
            Text("Showing cached data: \(error)")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.orange.opacity(0.35), lineWidth: 1))
    }

    private func failureState(error: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "xmark.octagon.fill")
                .foregroundColor(.red)
            Text(error)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.red.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.red.opacity(0.35), lineWidth: 1))
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}
