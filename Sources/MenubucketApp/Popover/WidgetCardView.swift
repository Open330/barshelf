import AppKit
import MenubucketCore
import SwiftUI
import UniformTypeIdentifiers

/// A widget card: header (name, refresh state, last update), rendered
/// content, and whichever state the widget is in when it has nothing to show
/// (`CardStateViews`). The cached tree stays on screen while reloading.
///
/// Performance (R05): the card observes only its own `WidgetCardModel` — the
/// runtime is held unobserved, so another widget's refresh publishes nothing
/// this card subscribes to and this card's body is not re-evaluated.
struct WidgetCardView: View {
    @Environment(\.undoManager) private var undoManager
    let widget: LoadedWidget
    let runtime: WidgetRuntime
    /// The pinned strip deliberately uses a compact, fixed footprint. This is
    /// separate from a widget's chosen card height, which remains unchanged in
    /// its regular panel.
    let compactHeight: CGFloat?
    /// When true the card border flashes accent (driven by `pendingReveal`).
    let isHighlighted: Bool
    let placement: CardPlacement
    @ObservedObject private var model: WidgetCardModel
    @State private var showRemoveConfirm = false
    @State private var showNewBucket = false
    @State private var newBucketName = ""
    @State private var removeError: String?
    /// Hovering reveals the card's quick controls (hidden at rest to reduce
    /// visual noise); keyboard focus reveals them too.
    @State private var isHovering = false
    @FocusState private var controlsFocused: Bool
    @State private var isDropTarget = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.shelfIsEditing) private var shelfIsEditing

    /// Effective theming (user override → author default → neutral). Injected
    /// into the rendered tree and used for the card's own chrome.
    private var appearance: WidgetAppearance {
        runtime.prefs.effectiveAppearance(for: widget.manifest, widgetID: widget.id)
    }

    /// The card's own header is on by default — it is how a reading, or an
    /// error, is traced to its widget — unless the widget's appearance turns
    /// it off.
    private var showsHeader: Bool { appearance.showsHeader }

    /// Edit controls only make sense on a shelf page.
    private var isEditing: Bool { shelfIsEditing && placement == .shelf && compactHeight == nil }

    /// compact density tightens the card's content insets.
    private var contentInset: CGFloat { appearance.density == .compact ? Spacing.xs : Spacing.s }

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
        compactHeight: CGFloat? = nil,
        placement: CardPlacement = .shelf
    ) {
        self.widget = widget
        self.runtime = runtime
        self.isHighlighted = isHighlighted
        self.compactHeight = compactHeight
        self.placement = placement
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
        .overlay(alignment: .topTrailing) {
            if !isEditing { cardControls }
        }
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
        .onDrop(of: CardDrag.types, isTargeted: $isDropTarget.animation(.easeInOut(duration: 0.12))) { providers in
            guard placement == .shelf else { return false }
            return CardDrag.receive(providers) { draggedID in
                runtime.changeLayout(String(localized: "Move Widget"), undoManager: undoManager) {
                    runtime.reorderWidget(id: draggedID, before: widget.id)
                }
            }
        }
        .animation(.easeInOut(duration: 0.4), value: isHighlighted)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) { isHovering = hovering }
        }
        .modifier(CardAccessibilityActions(card: self))
        .contextMenu { cardContextMenu }
        .alert("Move to a new page", isPresented: $showNewBucket) {
            TextField("Page name", text: $newBucketName)
            Button("Cancel", role: .cancel) { newBucketName = "" }
            Button("Move") {
                let name = newBucketName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty {
                    runtime.changeLayout(String(localized: "Move Widget"), undoManager: undoManager) {
                        runtime.moveWidget(id: widget.id, toGroup: name)
                    }
                }
                newBucketName = ""
            }
        } message: {
            Text("Enter a name for the page to move \(widget.displayName) to.")
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
            if isEditing {
                editBar
            }
            if showsHeader {
                cardHeader(snapshot: snapshot)
            }
            Group {
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
            }
            // While editing, a drag must never press one of the widget's buttons.
            .allowsHitTesting(!isEditing)
            if !showsHeader, model.overlay == nil, let updatedAt = snapshot.updatedAt {
                FreshnessText(updatedAt: updatedAt)
            }
        }
    }

    @ViewBuilder
    private func cardContent(snapshot: WidgetSnapshot) -> some View {
        if let overlay = model.overlay {
            // Host-owned state (permission decision / crash stop) replaces the
            // widget content until resolved.
            overlayView(overlay)
        } else if let tree = snapshot.viewTree {
            if let error = snapshot.error, !showsHeader {
                // No header to carry the badge: keep it above the content.
                CachedBadge(error: error, onRetry: retry)
            }
            ViewTreeRenderer(node: tree)
                .environment(\.actionContext, actionContext)
        } else if let error = snapshot.error {
            CardErrorView(error: error, onRetry: retry, onSettings: openSettings)
        } else if snapshot.isLoading {
            CardSkeleton()
        } else {
            CardEmptyView(onRefresh: retry)
        }
    }

    @ViewBuilder
    private func overlayView(_ overlay: CardOverlay) -> some View {
        switch overlay {
        case let .approvalNeeded(requests):
            PermissionApprovalView(
                widgetName: widget.displayName,
                requests: requests,
                onAllow: { runtime.approvePermissions(widgetID: widget.id) },
                onDeny: { runtime.denyPermissions(widgetID: widget.id) }
            )
        case let .denied(requests):
            PermissionDeniedView(
                widgetName: widget.displayName,
                requests: requests,
                onAllow: { runtime.approvePermissions(widgetID: widget.id) },
                onRemove: { showRemoveConfirm = true }
            )
        case let .disabled(reason):
            CrashDisabledView(
                reason: reason,
                onRestart: { runtime.restartScriptWidget(widgetID: widget.id) },
                onOpenLogs: { CrashDisabledView.openLogs(widgetID: widget.id) }
            )
        }
    }

    // MARK: - Actions

    fileprivate func retry() {
        runtime.refresh(widgetID: widget.id)
    }

    /// The one route to a widget's settings: the hub, on this widget.
    fileprivate func openSettings() {
        let id = widget.id
        Task { @MainActor in HubWindowController.shared.showWidgetSettings(widgetID: id) }
    }

    fileprivate func togglePin() {
        runtime.prefs.togglePin(widget.id)
        runtime.objectWillChange.send() // pinned row lives in RootView
    }

    /// "Pin", "Unpin", or — at the cap — why it cannot be pinned.
    fileprivate var pinTitle: String {
        if runtime.prefs.isPinned(widget.id) { return String(localized: "Unpin") }
        return runtime.canPin(widget.id)
            ? String(localized: "Pin")
            : String(localized: "Pin (\(PinnedShelf.capacity) max — unpin one first)")
    }

    // MARK: - Context menu

    /// Card right-click actions. Shortcuts only: every one is also reachable
    /// from visible UI (hover controls, edit mode, the hub).
    @ViewBuilder
    private var cardContextMenu: some View {
        if placement == .shelf {
            Button(pinTitle, action: togglePin)
                .disabled(!runtime.canPin(widget.id))
        }
        Button("Settings…", action: openSettings)
        Button("Refresh", action: retry)

        if placement == .shelf {
            Button("Move Up") { moveWithinPanel(by: -1) }
                .disabled(adjacentWidget(by: -1) == nil)
            Button("Move Down") { moveWithinPanel(by: 1) }
                .disabled(adjacentWidget(by: 1) == nil)

            Divider()

            Button(runtime.prefs.isDisabled(widget.id) ? "Enable" : "Disable") {
                runtime.setWidgetDisabled(widget.id, !runtime.prefs.isDisabled(widget.id))
            }
            Menu("Move to Page") {
                ForEach(runtime.allGroups, id: \.self) { group in
                    Button(group) {
                        runtime.changeLayout(String(localized: "Move Widget"), undoManager: undoManager) {
                            runtime.moveWidget(id: widget.id, toGroup: group)
                        }
                    }
                }
                Divider()
                Button("New Page…") { showNewBucket = true }
            }
        }
        Button("Reveal in Finder") {
            if let directory = runtime.widgetDirectory(for: widget.id) {
                NSWorkspace.shared.activateFileViewerSelecting([directory])
            }
        }

        if placement == .shelf {
            Divider()
            Button("Remove Widget…", role: .destructive) { showRemoveConfirm = true }
        }
    }

    private func adjacentWidget(by offset: Int) -> LoadedWidget? {
        guard let page = runtime.pages.first(where: { $0.widgets.contains { $0.id == widget.id } }),
              let index = page.widgets.firstIndex(where: { $0.id == widget.id }),
              page.widgets.indices.contains(index + offset) else { return nil }
        return page.widgets[index + offset]
    }

    fileprivate func moveWithinPanel(by offset: Int) {
        guard let adjacent = adjacentWidget(by: offset) else { return }
        runtime.changeLayout(String(localized: "Move Widget"), undoManager: undoManager) {
            if offset < 0 {
                runtime.reorderWidget(id: widget.id, before: adjacent.id)
            } else {
                runtime.reorderWidget(id: adjacent.id, before: widget.id)
            }
        }
        runtime.reveal(widgetID: widget.id)
    }

    private var actionContext: ActionContext {
        ActionContext(widgetID: widget.id) { [weak runtime] action in
            ActionRouter.perform(action, widgetID: widget.id, runtime: runtime)
        }
    }

    // MARK: - Header

    /// Name on the left; the cached badge, a refreshing indicator and the
    /// last-update time on the right. Quiet (`.caption`, secondary) so the
    /// content reads first.
    private func cardHeader(snapshot: WidgetSnapshot) -> some View {
        HStack(spacing: 6) {
            if let icon = widget.manifest.icon {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundStyle(cardAccent)
                    .accessibilityHidden(true)
            }
            Text(widget.displayName)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .accessibilityAddTraits(.isHeader)
            if model.overlay == nil, snapshot.viewTree != nil, let error = snapshot.error {
                CachedBadge(error: error, onRetry: retry)
            }
            Spacer(minLength: Spacing.xxs)
            if snapshot.isLoading, snapshot.viewTree != nil {
                ProgressView()
                    .controlSize(.mini)
                    .accessibilityLabel("Refreshing")
            }
            if model.overlay == nil, let updatedAt = snapshot.updatedAt {
                FreshnessText(updatedAt: updatedAt)
                    .layoutPriority(-1)
            }
        }
    }

    // MARK: - Edit mode

    /// Always visible while editing: drag handle, width, remove.
    private var editBar: some View {
        let isHalf = runtime.effectiveSize(for: widget.id) == "S"
        return HStack(spacing: Spacing.xs) {
            Image(systemName: "line.3.horizontal")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
                .onDrag { CardDrag.provider(for: widget.id) } preview: { dragPreview }
                .help("Drag to reorder, or onto a page dot to move it to that page")
                .accessibilityLabel("Reorder \(widget.displayName)")
            if !showsHeader {
                Text(widget.displayName)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Button(LayoutSizeName.name(isHalf ? "S" : "M")) {
                // Back to the widget's own size when that is a full-width
                // one (Strip, Full Width, Tall), so the switch does not lose it.
                let own = widget.size.uppercased()
                let target: String? = isHalf ? (own == "S" ? "M" : nil) : "S"
                runtime.changeLayout(String(localized: "Change Size"), undoManager: undoManager) {
                    runtime.resizeWidget(id: widget.id, toSize: target)
                }
            }
            .controlSize(.small)
            .help(isHalf ? "Make this card full width" : "Make this card half width")
            .accessibilityLabel("Width: \(LayoutSizeName.name(isHalf ? "S" : "M"))")
            .accessibilityHint(isHalf ? "Switches to Full Width" : "Switches to Half Width")
            Button { showRemoveConfirm = true } label: {
                Image(systemName: "minus.circle.fill")
                    .font(.callout)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, StatusTone.critical.color)
            }
            .buttonStyle(.plain)
            .help("Remove Widget…")
            .accessibilityLabel("Remove \(widget.displayName)")
        }
    }

    // MARK: - Hover controls

    /// Hover controls at the widget's top-right — refresh, a drag handle to
    /// move/reorder, and settings — grouped in one capsule. Out of the
    /// accessibility tree while invisible; the card's accessibility actions
    /// offer the same things.
    private var cardControls: some View {
        let visible = isHovering || controlsFocused
        return HStack(spacing: 2) {
            Button(action: retry) {
                Image(systemName: "arrow.clockwise")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 20)
            }
            .buttonStyle(.plain)
            .focused($controlsFocused)
            .help("Refresh \(widget.displayName)")
            .accessibilityLabel("Refresh \(widget.displayName)")
            if placement == .shelf {
                Image(systemName: "line.3.horizontal")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 20)
                    .onDrag { CardDrag.provider(for: widget.id) } preview: { dragPreview }
                    .help("Drag to move")
                    .accessibilityLabel("Move \(widget.displayName)")
            }
            Button(action: openSettings) {
                Image(systemName: "slider.horizontal.3")
                    .font(.caption2.weight(.semibold))
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
        .opacity(visible ? 1 : 0)
        .accessibilityHidden(!visible)
    }

    /// The card's drag proxy — a labeled chip so you can see what you're moving.
    private var dragPreview: some View {
        HStack(spacing: 6) {
            Image(systemName: widget.manifest.icon ?? "square.grid.2x2")
                .foregroundStyle(cardAccent)
            Text(widget.displayName)
                .font(.callout)
                .fontWeight(.semibold)
                .lineLimit(1)
        }
        .padding(.horizontal, Spacing.s)
        .padding(.vertical, Spacing.xs)
        .background(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(cardAccent.opacity(0.4), lineWidth: 1)
        )
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
                        : isHovering || isEditing
                            ? Color.primary.opacity(dark ? 0.06 : 0.04)
                            : Color.clear
            )
    }
}

/// The card's VoiceOver actions — the same things the hover controls and the
/// context menu offer, for when neither is visible.
private struct CardAccessibilityActions: ViewModifier {
    let card: WidgetCardView

    func body(content: Content) -> some View {
        let base = content
            .accessibilityAction(named: Text("Refresh")) { card.retry() }
            .accessibilityAction(named: Text("Open settings")) { card.openSettings() }
        if card.placement == .shelf {
            base
                .accessibilityAction(named: Text("Move up")) { card.moveWithinPanel(by: -1) }
                .accessibilityAction(named: Text("Move down")) { card.moveWithinPanel(by: 1) }
                .accessibilityAction(named: Text(card.pinTitle)) {
                    guard card.runtime.canPin(card.widget.id) else { return }
                    card.togglePin()
                }
        } else {
            base
        }
    }
}
