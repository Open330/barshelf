import AppKit
import MenubucketCore
import SwiftUI
import UniformTypeIdentifiers

/// Pager selection, shared with StatusItemController so keyboard events
/// (←/→, ⌘1..9) and trackpad swipes captured at the AppKit layer can drive
/// the SwiftUI pager.
final class PagerState: ObservableObject {
    @Published var index: Int = 0
    /// Live horizontal offset while a two-finger swipe is in progress.
    @Published var dragOffset: CGFloat = 0
    /// True during an active swipe — disables the snap animation so content
    /// tracks the fingers 1:1.
    @Published private(set) var isSwiping = false

    /// Width of one page (popup content width).
    var pageWidth: CGFloat = RootView.defaultSize.width
    /// Fraction of the page width that commits a page change on release.
    static let snapThresholdFraction: CGFloat = 1.0 / 3.0
    /// Rubber-band resistance beyond the first/last page.
    static let rubberBandFactor: CGFloat = 0.25

    func clamp(to pageCount: Int) {
        if pageCount == 0 {
            index = 0
        } else if index >= pageCount {
            index = pageCount - 1
        } else if index < 0 {
            index = 0
        }
    }

    func step(_ delta: Int, pageCount: Int) {
        guard pageCount > 0 else { return }
        index = min(max(index + delta, 0), pageCount - 1)
    }

    func jump(to target: Int, pageCount: Int) {
        guard pageCount > 0, (0..<pageCount).contains(target) else { return }
        index = target
    }

    // MARK: - Trackpad swipe (driven by the scroll-wheel monitor)

    func beginSwipe() {
        isSwiping = true
        dragOffset = 0
    }

    /// `totalDeltaX` follows the fingers (natural scrolling: accumulated
    /// `scrollingDeltaX`). Overscroll past the first/last page is dampened.
    func updateSwipe(totalDeltaX: CGFloat, pageCount: Int) {
        guard isSwiping else { return }
        var offset = totalDeltaX
        let overscrollLeading = index == 0 && offset > 0
        let overscrollTrailing = index >= pageCount - 1 && offset < 0
        if overscrollLeading || overscrollTrailing {
            offset *= Self.rubberBandFactor
        }
        dragOffset = offset
    }

    /// Snap: past 1/3 of the page width commits the neighboring page,
    /// otherwise the current page springs back.
    func endSwipe(pageCount: Int) {
        guard isSwiping else { return }
        let threshold = pageWidth * Self.snapThresholdFraction
        isSwiping = false
        if dragOffset <= -threshold {
            step(1, pageCount: pageCount)
        } else if dragOffset >= threshold {
            step(-1, pageCount: pageCount)
        }
        dragOffset = 0
    }

    func cancelSwipe() {
        guard isSwiping else { return }
        isSwiping = false
        dragOffset = 0
    }
}

/// Popup root: one page per panel group, vertical scroll inside a page,
/// horizontal two-finger swipe / arrow buttons / dots / keyboard for page
/// switching. Pages sit side by side in a sliding strip so swipes track the
/// fingers and snap with a spring.
struct RootView: View {
    @ObservedObject var runtime: WidgetRuntime
    @ObservedObject var pager: PagerState
    @ObservedObject private var toast = ToastCenter.shared
    @State private var searchPresented = false
    /// Widget id whose card border is flashing after a `reveal` request; cleared
    /// ~1.5s later so the accent highlight fades on its own.
    @State private var highlightedID: String?

    static let defaultSize = CGSize(width: 360, height: 480)

    var body: some View {
        let pages = runtime.pages
        VStack(spacing: 0) {
            if pages.isEmpty {
                emptyState
            } else {
                let index = min(max(pager.index, 0), pages.count - 1)

                header(for: pages[index], index: index, count: pages.count)
                Divider()
                pinnedRow
                pagerStrip(pages: pages, index: index)
                Divider()
                footer(pages: pages, index: index)
            }
        }
        .frame(width: Self.defaultSize.width, height: Self.defaultSize.height)
        // Solid, opaque popup surface — no popover translucency bleeding through.
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .top) {
            if searchPresented {
                SearchOverlay(runtime: runtime, pager: pager, isPresented: $searchPresented)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .shadow(radius: 8)
                    .padding(8)
            }
        }
        .overlay(alignment: .bottom) { toastOverlay }
        .animation(.easeInOut(duration: 0.2), value: toast.message)
        .background( // ⌘F without stealing layout space
            Button("") { searchPresented.toggle() }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
        )
        .onAppear { publishVisibleWidgets(pages: pages) }
        .onChange(of: pager.index) { _ in publishVisibleWidgets(pages: runtime.pages) }
        .onReceive(runtime.objectWillChange) { _ in
            DispatchQueue.main.async {
                let updatedPages = runtime.pages
                pager.clamp(to: updatedPages.count)
                publishVisibleWidgets(pages: updatedPages)
            }
        }
        .onReceive(runtime.$pendingReveal) { id in
            guard let id else { return }
            revealAndFlash(id)
        }
    }

    /// The selected page is the actual visibility source of truth. All pages
    /// coexist in the horizontal HStack for swipe animation, so card
    /// `onAppear` callbacks cannot distinguish onscreen from offscreen pages.
    private func publishVisibleWidgets(pages: [WidgetPage]) {
        runtime.setVisibleWidgetIDs(Self.visibleWidgetIDs(
            pages: pages,
            index: pager.index,
            pinned: Set(runtime.prefs.pinned)
        ))
    }

    static func visibleWidgetIDs(
        pages: [WidgetPage],
        index: Int,
        pinned: Set<String>
    ) -> Set<String> {
        guard !pages.isEmpty else { return [] }
        let safeIndex = min(max(index, 0), pages.count - 1)
        return Set(pages[safeIndex].widgets.map(\.id)).union(pinned)
    }

    /// Jumps the pager to the page holding `id`, flashes that card's border, and
    /// consumes `pendingReveal` so a repeat reveal of the same id fires again.
    private func revealAndFlash(_ id: String) {
        let pages = runtime.pages
        if let target = pages.firstIndex(where: { $0.widgets.contains { $0.id == id } }) {
            pager.jump(to: target, pageCount: pages.count)
        }
        highlightedID = id
        runtime.pendingReveal = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if highlightedID == id { highlightedID = nil }
        }
    }

    /// Bottom-center transient confirmation capsule (copy/toast feedback).
    @ViewBuilder
    private var toastOverlay: some View {
        if let message = toast.message {
            Text(message)
                .font(.caption)
                .fontWeight(.medium)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .modifier(ControlCapsule())
                .padding(.bottom, 46)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
                .accessibilityLabel(message)
        }
    }

    /// Pinned widgets stay above the pager on every page (invariant: at most
    /// a compact strip — full cards live in their panel).
    @ViewBuilder
    private var pinnedRow: some View {
        let pinnedWidgets = runtime.prefs.pinned.compactMap { id in
            runtime.widgets.first { $0.id == id }
        }
        if !pinnedWidgets.isEmpty {
            VStack(spacing: 0) {
                ForEach(pinnedWidgets.prefix(2)) { widget in
                    WidgetCardView(widget: widget, runtime: runtime)
                        .frame(maxHeight: 120)
                }
                if pinnedWidgets.count > 2 {
                    pinnedOverflow(pinnedWidgets: pinnedWidgets)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 4)
                }
            }
            Divider()
        }
    }

    /// "+N pinned hidden" caption below the two-card pinned strip: jumps to the
    /// panel page of the first still-visible pinned widget beyond the strip.
    private func pinnedOverflow(pinnedWidgets: [LoadedWidget]) -> some View {
        let hidden = pinnedWidgets.count - 2
        return Button {
            let pages = runtime.pages
            if let target = pinnedWidgets.dropFirst(2).first(where: { widget in
                pages.contains { $0.widgets.contains { $0.id == widget.id } }
            }), let index = pages.firstIndex(where: {
                $0.widgets.contains { $0.id == target.id }
            }) {
                pager.jump(to: index, pageCount: pages.count)
            }
        } label: {
            Text("+\(hidden) pinned hidden")
                .font(.caption2)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.borderless)
        .help("Jump to the next pinned widget's panel")
        .accessibilityLabel("\(hidden) more pinned widgets hidden; jump to panel")
    }

    /// All pages laid out horizontally; offset = current page + live drag.
    /// During a swipe the offset follows the fingers (no animation); on
    /// release the spring snaps to the committed page (rubber band at edges).
    /// One row of the native-style card grid: two adjacent `S` widgets pair up
    /// (like native small widgets); every other size is a full-width row.
    private struct CardRow: Identifiable {
        let widgets: [LoadedWidget]
        var id: String { widgets.map(\.id).joined(separator: "|") }
    }

    private func cardRows(_ widgets: [LoadedWidget]) -> [CardRow] {
        var rows: [CardRow] = []
        var pendingSmall: LoadedWidget?
        for widget in widgets {
            if runtime.effectiveSize(for: widget.id).uppercased() == "S" {
                if let pending = pendingSmall {
                    rows.append(CardRow(widgets: [pending, widget]))
                    pendingSmall = nil
                } else {
                    pendingSmall = widget
                }
            } else {
                if let pending = pendingSmall {
                    rows.append(CardRow(widgets: [pending]))
                    pendingSmall = nil
                }
                rows.append(CardRow(widgets: [widget]))
            }
        }
        if let pending = pendingSmall { rows.append(CardRow(widgets: [pending])) }
        return rows
    }

    private func pagerStrip(pages: [WidgetPage], index: Int) -> some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let offset = -CGFloat(index) * width + pager.dragOffset

            HStack(spacing: 0) {
                ForEach(pages) { page in
                    ScrollView {
                        VStack(spacing: 0) {
                            if runtime.prefs.welcomePending,
                               page.id == Self.welcomePageID(pages: pages) {
                                WelcomeCardView {
                                    runtime.prefs.dismissWelcome()
                                    runtime.objectWillChange.send()
                                }
                                rowSeparator
                            }
                            let rows = cardRows(page.widgets)
                            ForEach(Array(rows.enumerated()), id: \.element.id) { rowIndex, row in
                                HStack(alignment: .top, spacing: 0) {
                                    ForEach(Array(row.widgets.enumerated()), id: \.element.id) { widgetIndex, widget in
                                        if widgetIndex > 0 { Divider() }
                                        WidgetCardView(
                                            widget: widget,
                                            runtime: runtime,
                                            isHighlighted: widget.id == highlightedID
                                        )
                                        .frame(maxWidth: .infinity)
                                    }
                                }
                                if rowIndex < rows.count - 1 { rowSeparator }
                            }
                        }
                        .padding(.bottom, 6)
                    }
                    .frame(width: width, height: geometry.size.height)
                }
            }
            .offset(x: offset)
            .animation(
                pager.isSwiping ? nil : .spring(response: 0.32, dampingFraction: 0.85),
                value: offset
            )
            .onAppear { pager.pageWidth = width }
            .onChange(of: width) { pager.pageWidth = $0 }
        }
        .clipped()
    }

    /// Inset hairline between widget sections — separation without boxes.
    private var rowSeparator: some View {
        Divider().padding(.horizontal, 12)
    }

    /// Composed toolbar: panel title + inline page indicator on the left,
    /// search/refresh on the right, all on `.bar` material so header and footer
    /// read as one continuous chrome around the scrolling cards.
    private func header(for page: WidgetPage, index: Int, count: Int) -> some View {
        HStack(spacing: 8) {
            Text(page.group)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
            if count > 1 {
                Text("\(index + 1) of \(count)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .accessibilityLabel("Panel \(index + 1) of \(count)")
            }
            Spacer()
            Button {
                searchPresented.toggle()
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help("Search (⌘F)")
            .accessibilityLabel("Search")
            Button {
                runtime.refreshAll()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh All")
            .accessibilityLabel("Refresh all widgets")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func footer(pages: [WidgetPage], index: Int) -> some View {
        HStack(spacing: 6) {
            addWidgetMenu

            Button {
                pager.step(-1, pageCount: pages.count)
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.borderless)
            .disabled(index == 0)
            .help("Previous panel")
            .accessibilityLabel("Previous panel")

            Spacer()

            HStack(spacing: 6) {
                ForEach(Array(pages.enumerated()), id: \.element.id) { pageIndex, page in
                    // Size + fill cue (not hue alone) marks the current page.
                    Circle()
                        .fill(pageIndex == index ? Color.primary : Color.secondary.opacity(0.35))
                        .frame(width: pageIndex == index ? 7 : 6,
                               height: pageIndex == index ? 7 : 6)
                        .onTapGesture {
                            pager.jump(to: pageIndex, pageCount: pages.count)
                        }
                        .help(page.group)
                        .accessibilityLabel(page.group)
                        .accessibilityAddTraits(pageIndex == index ? [.isSelected] : [])
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Panel \(index + 1) of \(pages.count)")

            Spacer()

            Button {
                pager.step(1, pageCount: pages.count)
            } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.borderless)
            .disabled(index >= pages.count - 1)
            .help("Next panel")
            .accessibilityLabel("Next panel")

            Button {
                Task { @MainActor in
                    AppSettingsWindowController.shared.show(runtime: runtime)
                }
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Settings")
            .accessibilityLabel("Open settings")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// Footer "+" entry point: add widgets from the gallery, a URL, or the
    /// no-code builder. Mirrors the first-run empty-state CTAs.
    private var addWidgetMenu: some View {
        Menu {
            Button {
                Task { @MainActor in GalleryWindowController.shared.show() }
            } label: {
                Label("Widget Gallery…", systemImage: "square.grid.2x2")
            }
            Button {
                WidgetInstaller.shared.promptForURL()
            } label: {
                Label("Install from URL…", systemImage: "link")
            }
            Button {
                Task { @MainActor in WidgetBuilderController.shared.show(runtime: runtime) }
            } label: {
                Label("Create Widget…", systemImage: "wand.and.stars")
            }
        } label: {
            Image(systemName: "plus")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Add a widget")
        .accessibilityLabel("Add a widget")
    }

    /// GETTING-STARTED guide on GitHub (opened from onboarding CTAs).
    static let gettingStartedURL = URL(
        string: "https://github.com/Open330/barshelf/blob/main/docs/GETTING-STARTED.md"
    )!

    /// The welcome card sits above the seeded `hello` widget ("Demo" panel);
    /// if that page is gone (starter deleted) it falls back to the first page.
    private static func welcomePageID(pages: [WidgetPage]) -> String? {
        let helloPage = pages.first { page in
            page.widgets.contains { $0.id == "dev.barshelf.today" }
        }
        return (helloPage ?? pages.first)?.id
    }

    /// First-run onboarding shown instead of a blank popup: a short pitch and
    /// three CTAs (gallery, URL install, docs).
    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "tray.full")
                .font(.system(size: 32))
                .foregroundColor(.accentColor)
                .accessibilityHidden(true)
            Text("Time to tidy up your menu bar")
                .font(.system(size: 14, weight: .semibold))
            Text("BarShelf collects your menu bar extras\ninto one popup of widgets.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            VStack(spacing: 6) {
                Button {
                    Task { @MainActor in
                        GalleryWindowController.shared.show()
                    }
                } label: {
                    Label("Open Widget Gallery", systemImage: "square.grid.2x2")
                        .frame(maxWidth: .infinity)
                }
                .keyboardShortcut(.defaultAction)
                Button {
                    Task { @MainActor in
                        WidgetBuilderController.shared.show(runtime: runtime)
                    }
                } label: {
                    Label("Create Your Own Widget", systemImage: "wand.and.stars")
                        .frame(maxWidth: .infinity)
                }
                Button {
                    WidgetInstaller.shared.promptForURL()
                } label: {
                    Label("Install Widget from URL…", systemImage: "link")
                        .frame(maxWidth: .infinity)
                }
                Button {
                    NSWorkspace.shared.open(Self.gettingStartedURL)
                } label: {
                    Label("View the Getting Started guide", systemImage: "book")
                        .frame(maxWidth: .infinity)
                }
            }
            .controlSize(.large)
            .padding(.horizontal, 48)
            .padding(.top, 4)
            Spacer()
            Text("Widgets live in ~/Library/Application Support/barshelf/widgets/")
                .font(.caption2)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Capsule chrome for floating controls: a solid, opaque surface with a
/// hairline border — no translucency.
struct ControlCapsule: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Capsule().fill(Color(nsColor: .windowBackgroundColor)))
            .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.25), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.10), radius: 2, y: 1)
    }
}

/// One-time welcome card shown above the seeded starter widgets after the
/// first-run seeding pass. The close button records the dismissal in prefs,
/// so the card never returns.
struct WelcomeCardView: View {
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .foregroundColor(.accentColor)
                    .accessibilityHidden(true)
            Text("Welcome to BarShelf")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Dismiss")
                .accessibilityLabel("Dismiss welcome card")
            }
            Text("We installed a couple of starter widgets so this popup isn't empty. Browse the gallery for more — like usage meters and OTP codes — or remove the starters anytime.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Open Widget Gallery") {
                    Task { @MainActor in
                        GalleryWindowController.shared.show()
                    }
                }
                .controlSize(.small)
                Button("Getting Started") {
                    NSWorkspace.shared.open(RootView.gettingStartedURL)
                }
                .controlSize(.small)
            }
            Text("Tip: right-click the menu bar icon for Settings — swipe with two fingers to switch panels.")
                .font(.caption2)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.07))
    }
}

/// A widget card: name header, rendered content, cached-data warning banner
/// on failure, and an updated-at caption. Cached tree is shown while loading.
///
/// Performance (R05): the card observes only its own `WidgetCardModel` — the
/// runtime is held unobserved, so another widget's refresh publishes nothing
/// this card subscribes to and this card's body is not re-evaluated.
struct WidgetCardView: View {
    let widget: LoadedWidget
    let runtime: WidgetRuntime
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

    init(widget: LoadedWidget, runtime: WidgetRuntime, isHighlighted: Bool = false) {
        self.widget = widget
        self.runtime = runtime
        self.isHighlighted = isHighlighted
        _model = ObservedObject(wrappedValue: runtime.cardModel(for: widget.id))
    }

    var body: some View {
        let snapshot = model.snapshot
        cardStack(snapshot: snapshot)
            .padding(.horizontal, contentInset + 2)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .modifier(OptionalHeight(height: effectiveFixedHeight))
            .environment(\.widgetAppearance, appearance)
            .environment(\.remoteImageHosts, widget.manifest.permissions?.network ?? [])
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
        VStack(alignment: .leading, spacing: 6) {
            if showsHeader {
                cardHeader(snapshot: snapshot)
            }
            if effectiveFixedHeight != nil {
                // Fixed footprint: content taller than the card scrolls inside.
                ScrollView(.vertical, showsIndicators: false) {
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
        if isHovering {
            HStack(spacing: 2) {
                Button { runtime.refresh(widgetID: widget.id) } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 20)
                }
                .buttonStyle(.plain)
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
                .help("Widget settings")
                .accessibilityLabel("Settings for \(widget.displayName)")
            }
            .padding(.horizontal, 3)
            .padding(.vertical, 2)
            .modifier(ControlCapsule())
            .padding(6)
            .transition(.opacity)
        }
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
