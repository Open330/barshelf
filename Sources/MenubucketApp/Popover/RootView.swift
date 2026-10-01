import AppKit
import MenubucketCore
import SwiftUI
import UniformTypeIdentifiers

/// Popup root: one page per panel group, vertical scroll inside a page,
/// horizontal two-finger swipe / page menu / dots / keyboard for page
/// switching. Pages sit side by side in a sliding strip so swipes track the
/// fingers and snap with a spring.
///
/// 360 points wide; as tall as its tallest page, up to what the status item's
/// screen allows (`PagerState.maxHeight`).
struct RootView: View {
    @ObservedObject var runtime: WidgetRuntime
    @ObservedObject var pager: PagerState
    /// Runs an app-menu command (⋯ menu, edit mode's Add Widget).
    let onCommand: (AppMenuCommand) -> Void
    @State private var searchPresented = false
    @FocusState private var searchButtonFocused: Bool
    @AccessibilityFocusState private var searchButtonAccessibilityFocused: Bool
    /// Widget id whose card border is flashing after a `reveal` request; cleared
    /// ~1.5s later so the accent highlight fades on its own.
    @State private var highlightedID: String?
    /// Changes for every reveal request, including a second request for the
    /// same widget while its highlight is still visible.
    @State private var revealToken = UUID()
    /// Measured natural heights: each page's cards, and the chrome around them.
    @State private var pageContentHeights: [String: CGFloat] = [:]
    @State private var topChromeHeight: CGFloat = 0
    @State private var footerHeight: CGFloat = 0
    /// The page dot a dragged card is hovering over.
    @State private var dropTargetPageID: String?

    static let defaultSize = CGSize(width: 360, height: 480)
    /// Short enough for a single small card; tall enough that the empty
    /// state and the search overlay still fit.
    static let minimumHeight: CGFloat = 240
    /// Room kept free below the popup on the status item's screen.
    static let screenMargin: CGFloat = 40

    init(
        runtime: WidgetRuntime,
        pager: PagerState,
        onCommand: @escaping (AppMenuCommand) -> Void = { _ in }
    ) {
        self.runtime = runtime
        self.pager = pager
        self.onCommand = onCommand
    }

    var body: some View {
        let pages = runtime.pages
        VStack(spacing: 0) {
            if pages.isEmpty {
                emptyState
            } else {
                let index = min(max(pager.index, 0), pages.count - 1)

                VStack(spacing: 0) {
                    header(pages: pages, index: index)
                    Divider()
                    if !pager.isEditing { pinnedRow }
                }
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { topChromeHeight = $0 }
                pagerStrip(pages: pages, index: index)
                if pages.count > 1 {
                    VStack(spacing: 0) {
                        Divider()
                        footer(pages: pages, index: index)
                    }
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { footerHeight = $0 }
                }
            }
        }
        // The overlay is a real modal surface: keep the shelf behind it out of
        // both VoiceOver traversal and the keyboard focus chain.
        .accessibilityHidden(searchPresented)
        .disabled(searchPresented)
        .allowsHitTesting(!searchPresented)
        .frame(width: Self.defaultSize.width, height: popupHeight(pages: pages))
        // Solid, opaque popup surface — no popover translucency bleeding through.
        .background(Color(nsColor: .controlBackgroundColor))
        .environment(\.shelfIsEditing, pager.isEditing)
        .overlay(alignment: .top) {
            if searchPresented {
                ZStack(alignment: .top) {
                    // Modal scrim: absorbs hover + clicks on the content behind the
                    // search bar, so widget cards don't reveal their top-trailing
                    // hover controls over the close button. Tap outside to dismiss.
                    Rectangle()
                        .fill(Color.black.opacity(0.12))
                        .contentShape(Rectangle())
                        .onTapGesture { searchPresented = false }
                    SearchOverlay(runtime: runtime, pager: pager, isPresented: $searchPresented)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.control))
                        .shadow(radius: 8)
                        .padding(Spacing.xs)
                }
                .transition(.opacity)
            }
        }
        .overlay { ToastOverlay(bottomInset: pages.count > 1 ? 46 : Spacing.s) }
        .animation(.easeInOut(duration: 0.2), value: pager.isEditing)
        // ⌘F arrives as the Edit ▸ Find menu command (`AppCommands`).
        .onChange(of: pager.searchRequests) { searchPresented = true }
        .onChange(of: pager.isEditing) { _, editing in
            if editing { searchPresented = false }
        }
        .onAppear {
            pager.setSearchPresented(searchPresented)
            publishVisibleWidgets(pages: pages)
        }
        .onDisappear { pager.setSearchPresented(false) }
        .onChange(of: searchPresented) { _, presented in
            pager.setSearchPresented(presented)
            if !presented {
                // Return keyboard users to the control that opened the modal.
                DispatchQueue.main.async {
                    // Ignore a queued restoration if the user already opened a
                    // fresh search modal (for example by pressing ⌘F twice).
                    guard !searchPresented else { return }
                    searchButtonFocused = true
                    searchButtonAccessibilityFocused = true
                }
            }
        }
        .onChange(of: pager.index) { publishVisibleWidgets(pages: runtime.pages) }
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

    // MARK: - Height

    private func popupHeight(pages: [WidgetPage]) -> CGFloat {
        guard !pages.isEmpty else { return min(Self.defaultSize.height, pager.maxHeight) }
        let measured = pages.compactMap { pageContentHeights[$0.id] }
        return Self.popupHeight(
            chrome: topChromeHeight + (pages.count > 1 ? footerHeight : 0),
            content: measured.max(),
            maxHeight: pager.maxHeight
        )
    }

    /// Chrome plus the tallest page, between `minimumHeight` and `maxHeight`.
    /// The tallest page rather than the current one, so swiping between pages
    /// does not make the popup jump; a taller page scrolls inside.
    static func popupHeight(chrome: CGFloat, content: CGFloat?, maxHeight: CGFloat) -> CGFloat {
        let ceiling = max(maxHeight, minimumHeight)
        guard let content else { return min(defaultSize.height, ceiling) }
        return min(max(chrome + content, minimumHeight), ceiling)
    }

    /// The tallest the popup may be on a screen whose visible frame (menu bar
    /// and Dock excluded) is `screenVisibleHeight` tall.
    static func maximumHeight(screenVisibleHeight: CGFloat) -> CGFloat {
        max(minimumHeight, screenVisibleHeight - screenMargin)
    }

    // MARK: - Visibility

    /// The selected page is the actual visibility source of truth. All pages
    /// coexist in the horizontal HStack for swipe animation, so card
    /// `onAppear` callbacks cannot distinguish onscreen from offscreen pages.
    private func publishVisibleWidgets(pages: [WidgetPage]) {
        runtime.setVisibleWidgetIDs(Self.visibleWidgetIDs(
            pages: pages,
            index: pager.index,
            pinnedIDs: runtime.prefs.pinned
        ))
    }

    static func visibleWidgetIDs(
        pages: [WidgetPage],
        index: Int,
        pinnedIDs: [String]
    ) -> Set<String> {
        guard !pages.isEmpty else { return [] }
        let safeIndex = min(max(index, 0), pages.count - 1)
        // A disabled widget is absent from `pages`, so it cannot keep doing
        // visible-only work merely because it remains in the pin preference.
        let enabledIDs = Set(pages.flatMap(\.widgets).map(\.id))
        let displayedPinned = PinnedShelf.displayedIDs(pinned: pinnedIDs, enabledIDs: enabledIDs)
        return Set(pages[safeIndex].widgets.map(\.id)).union(displayedPinned)
    }

    /// Pager pages remain mounted for swipe geometry, but only the selected
    /// page may run timelines or initiate image/thumbnail work.
    static func pageContentIsActive(pageID: String, selectedPageID: String) -> Bool {
        pageID == selectedPageID
    }

    /// Jumps the pager to the page holding `id`, flashes that card's border, and
    /// consumes `pendingReveal` so a repeat reveal of the same id fires again.
    private func revealAndFlash(_ id: String) {
        let pages = runtime.pages
        if let target = pages.firstIndex(where: { $0.widgets.contains { $0.id == id } }) {
            pager.jump(to: target, pageCount: pages.count)
        }
        highlightedID = id
        let token = UUID()
        revealToken = token
        runtime.pendingReveal = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            // A later reveal of the same card gets its own full flash.
            if highlightedID == id, revealToken == token { highlightedID = nil }
        }
    }

    // MARK: - Pinned

    /// Pinned widgets stay above the pager on every page (invariant: at most
    /// a compact strip — full cards live in their panel). Hidden while editing:
    /// they are copies, and edit mode works on the cards in their pages.
    @ViewBuilder
    private var pinnedRow: some View {
        let enabledIDs = runtime.enabledWidgetIDs
        let shown = PinnedShelf.displayedIDs(pinned: runtime.prefs.pinned, enabledIDs: enabledIDs)
        let overflow = PinnedShelf.overflowIDs(pinned: runtime.prefs.pinned, enabledIDs: enabledIDs)
        let pinnedWidgets = shown.compactMap { id in runtime.widgets.first { $0.id == id } }
        if !pinnedWidgets.isEmpty {
            VStack(spacing: 0) {
                ForEach(pinnedWidgets) { widget in
                    WidgetCardView(widget: widget, runtime: runtime, compactHeight: 120)
                }
                if !overflow.isEmpty {
                    pinnedOverflow(overflowIDs: overflow)
                        .padding(.horizontal, Spacing.s)
                        .padding(.vertical, Spacing.xxs)
                }
            }
            Divider()
        }
    }

    /// Only reachable through older preferences or a duplicated pinned widget
    /// (Pin is disabled at the cap), so it says plainly what happened and
    /// jumps to the first one left out.
    private func pinnedOverflow(overflowIDs: [String]) -> some View {
        Button {
            if let target = overflowIDs.first { runtime.reveal(widgetID: target) }
        } label: {
            Text("\(overflowIDs.count) more pinned — only \(PinnedShelf.capacity) fit here. Show")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.borderless)
        .help("Jump to the next pinned widget's page")
    }

    // MARK: - Pages

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

    /// All pages laid out horizontally; offset = current page + live drag.
    /// During a swipe the offset follows the fingers (no animation); on
    /// release the spring snaps to the committed page (rubber band at edges).
    private func pagerStrip(pages: [WidgetPage], index: Int) -> some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let offset = -CGFloat(index) * width + pager.dragOffset

            HStack(spacing: 0) {
                ForEach(pages) { page in
                    ScrollViewReader { proxy in
                        ScrollView {
                            pageContent(page, pages: pages)
                                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height in
                                    pageContentHeights[page.id] = height
                                }
                        }
                        .onChange(of: revealToken) {
                            guard let id = highlightedID,
                                  page.widgets.contains(where: { $0.id == id }) else { return }
                            // The pager first moves this page onscreen. Deferring one
                            // run-loop lets ScrollViewReader resolve its card anchor.
                            DispatchQueue.main.async {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    proxy.scrollTo(id, anchor: .center)
                                }
                            }
                        }
                    }
                    .frame(width: width, height: geometry.size.height)
                    // Pages remain laid out for the horizontal swipe, but an
                    // offscreen page must not be reachable by VoiceOver, Tab,
                    // or controls embedded in a widget tree.
                    .accessibilityHidden(page.id != pages[index].id)
                    .disabled(page.id != pages[index].id)
                    .allowsHitTesting(page.id == pages[index].id)
                    .environment(
                        \.widgetContentIsActive,
                        Self.pageContentIsActive(
                            pageID: page.id,
                            selectedPageID: pages[index].id
                        )
                    )
                }
            }
            .offset(x: offset)
            .animation(
                pager.isSwiping ? nil : .spring(response: 0.32, dampingFraction: 0.85),
                value: offset
            )
            .onAppear { pager.pageWidth = width }
            .onChange(of: width) { _, newValue in pager.pageWidth = newValue }
        }
        .clipped()
    }

    private func pageContent(_ page: WidgetPage, pages: [WidgetPage]) -> some View {
        VStack(spacing: 0) {
            if runtime.prefs.welcomePending, !pager.isEditing,
               page.id == Self.welcomePageID(pages: pages) {
                WelcomeCardView(addWidget: { onCommand(.addWidget) }) {
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
                        .id(widget.id)
                    }
                }
                if rowIndex < rows.count - 1 { rowSeparator }
            }
            if pager.isEditing {
                rowSeparator
                Button { onCommand(.addWidget) } label: {
                    Label("Add Widget…", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .padding(Spacing.s)
            }
        }
        .padding(.bottom, 6)
    }

    /// Inset hairline between widget sections — separation without boxes.
    private var rowSeparator: some View {
        Divider().padding(.horizontal, Spacing.s)
    }

    // MARK: - Header and footer

    /// Page menu on the left; search, refresh and ⋯ on the right — or, while
    /// editing, Done.
    private func header(pages: [WidgetPage], index: Int) -> some View {
        HStack(spacing: Spacing.xs) {
            PageMenu(pages: pages, index: index) { target in
                pager.jump(to: target, pageCount: pages.count)
            }
            if pages.count > 1 {
                Text("\(index + 1) of \(pages.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Page \(index + 1) of \(pages.count)")
            }
            Spacer()
            if pager.isEditing {
                Button("Done") { pager.isEditing = false }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .help("Finish editing (Esc)")
            } else {
                Button {
                    searchPresented = true
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.borderless)
                .focused($searchButtonFocused)
                .accessibilityFocused($searchButtonAccessibilityFocused)
                .help("Search (⌘F)")
                .accessibilityLabel("Search")
                Button {
                    runtime.refreshAll()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh All (⌘R)")
                .accessibilityLabel("Refresh all widgets")
                ShelfMoreMenu(runtime: runtime, onCommand: onCommand)
            }
        }
        .padding(.horizontal, Spacing.s)
        .padding(.vertical, Spacing.xs)
        .frame(minHeight: 36)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// Page dots. Each is also a drop target: a card dragged onto a dot moves
    /// to that page.
    private func footer(pages: [WidgetPage], index: Int) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(Array(pages.enumerated()), id: \.element.id) { pageIndex, page in
                        pageDot(page: page, pageIndex: pageIndex, index: index, pageCount: pages.count)
                    }
                }
            }
            .frame(maxWidth: 220, maxHeight: 24)
            .fixedSize(horizontal: true, vertical: false)
            .onChange(of: index) { _, newIndex in
                guard pages.indices.contains(newIndex) else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(pages[newIndex].id, anchor: .center)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Page \(index + 1) of \(pages.count)")
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Spacing.s)
        .padding(.vertical, 6)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func pageDot(page: WidgetPage, pageIndex: Int, index: Int, pageCount: Int) -> some View {
        let isCurrent = pageIndex == index
        let isDropTarget = dropTargetPageID == page.id
        // Size + fill cue (not hue alone) marks the current page.
        return Button {
            pager.jump(to: pageIndex, pageCount: pageCount)
        } label: {
            Circle()
                .fill(isDropTarget ? Color.accentColor
                    : isCurrent ? Color.primary : Color.secondary.opacity(0.35))
                .frame(width: isDropTarget ? 10 : isCurrent ? 7 : 6,
                       height: isDropTarget ? 10 : isCurrent ? 7 : 6)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(page.id)
        .help(page.group)
        .accessibilityLabel(page.group)
        .accessibilityAddTraits(isCurrent ? [.isSelected] : [])
        .onDrop(of: CardDrag.types, isTargeted: Binding(
            get: { dropTargetPageID == page.id },
            set: { targeted in
                if targeted {
                    dropTargetPageID = page.id
                } else if dropTargetPageID == page.id {
                    dropTargetPageID = nil
                }
            }
        )) { providers in
            CardDrag.receive(providers) { widgetID in
                guard runtime.effectiveGroup(for: widgetID) != page.group else { return }
                runtime.moveWidget(id: widgetID, toGroup: page.group)
                ToastCenter.shared.show(String(localized: "Moved to \(page.group)"))
            }
        }
    }

    // MARK: - Empty state

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
    /// the ways to get a first widget.
    private var emptyState: some View {
        VStack(spacing: Spacing.s) {
            HStack {
                Spacer()
                ShelfMoreMenu(runtime: runtime, onCommand: onCommand)
            }
            .padding(.horizontal, Spacing.s)
            .padding(.top, Spacing.xs)
            Spacer()
            Image(systemName: "tray.full")
                .font(.largeTitle)
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            Text("Time to tidy up your menu bar")
                .font(.headline)
            Text("BarShelf collects your menu bar extras\ninto one popup of widgets.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            VStack(spacing: 6) {
                Button { onCommand(.addWidget) } label: {
                    Label("Add Widget…", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .keyboardShortcut(.defaultAction)
                Button {
                    Task { @MainActor in HubWindowController.shared.show(tab: .create) }
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
            .padding(.top, Spacing.xxs)
            Spacer()
            Text("Widgets live in ~/Library/Application Support/barshelf/widgets/")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Spacing.s)
                .padding(.bottom, 10)
        }
        .frame(maxWidth: .infinity)
    }
}
