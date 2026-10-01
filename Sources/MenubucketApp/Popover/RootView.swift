import AppKit
import MenubucketCore
import SwiftUI
import UniformTypeIdentifiers

/// Popup root: one page per panel group, vertical scroll inside a page,
/// horizontal two-finger swipe / arrow buttons / dots / keyboard for page
/// switching. Pages sit side by side in a sliding strip so swipes track the
/// fingers and snap with a spring.
struct RootView: View {
    @ObservedObject var runtime: WidgetRuntime
    @ObservedObject var pager: PagerState
    @ObservedObject private var toast = ToastCenter.shared
    @State private var searchPresented = false
    @FocusState private var searchButtonFocused: Bool
    @AccessibilityFocusState private var searchButtonAccessibilityFocused: Bool
    /// Widget id whose card border is flashing after a `reveal` request; cleared
    /// ~1.5s later so the accent highlight fades on its own.
    @State private var highlightedID: String?
    /// Changes for every reveal request, including a second request for the
    /// same widget while its highlight is still visible.
    @State private var revealToken = UUID()

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
        // The overlay is a real modal surface: keep the shelf behind it out of
        // both VoiceOver traversal and the keyboard focus chain.
        .accessibilityHidden(searchPresented)
        .disabled(searchPresented)
        .allowsHitTesting(!searchPresented)
        .frame(width: Self.defaultSize.width, height: Self.defaultSize.height)
        // Solid, opaque popup surface — no popover translucency bleeding through.
        .background(Color(nsColor: .controlBackgroundColor))
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
                        .padding(8)
                }
                .transition(.opacity)
            }
        }
        .overlay(alignment: .bottom) { toastOverlay }
        .animation(.easeInOut(duration: 0.2), value: toast.message)
        // ⌘F arrives as the Edit ▸ Find menu command (`AppCommands`).
        .onChange(of: pager.searchRequests) { searchPresented = true }
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
        let displayedPinned = pinnedIDs.filter(enabledIDs.contains).prefix(2)
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
            runtime.widgets.first { $0.id == id && !runtime.prefs.isDisabled(id) }
        }
        if !pinnedWidgets.isEmpty {
            VStack(spacing: 0) {
                ForEach(pinnedWidgets.prefix(2)) { widget in
                    WidgetCardView(widget: widget, runtime: runtime, compactHeight: 120)
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
            }) {
                runtime.reveal(widgetID: target.id)
            }
        } label: {
            Text("+\(hidden) pinned hidden")
                .font(.caption2)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.borderless)
        .help("Jump to the next pinned widget's page")
        .accessibilityLabel("\(hidden) more pinned widgets hidden; jump to page")
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
                    ScrollViewReader { proxy in
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
                                            .id(widget.id)
                                        }
                                    }
                                    if rowIndex < rows.count - 1 { rowSeparator }
                                }
                            }
                            .padding(.bottom, 6)
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
                    .accessibilityLabel("Page \(index + 1) of \(count)")
            }
            Spacer()
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
            .help("Previous page")
            .accessibilityLabel("Previous page")

            Spacer()

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(Array(pages.enumerated()), id: \.element.id) { pageIndex, page in
                            // Size + fill cue (not hue alone) marks the current page.
                            Button {
                                pager.jump(to: pageIndex, pageCount: pages.count)
                            } label: {
                                Circle()
                                    .fill(pageIndex == index ? Color.primary : Color.secondary.opacity(0.35))
                                    .frame(width: pageIndex == index ? 7 : 6,
                                           height: pageIndex == index ? 7 : 6)
                                    .frame(width: 24, height: 24)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .id(page.id)
                            .help(page.group)
                            .accessibilityLabel(page.group)
                            .accessibilityAddTraits(pageIndex == index ? [.isSelected] : [])
                        }
                    }
                }
                .frame(maxWidth: 130, maxHeight: 24)
                .onChange(of: index) { _, newIndex in
                    guard pages.indices.contains(newIndex) else { return }
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(pages[newIndex].id, anchor: .center)
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Page \(index + 1) of \(pages.count)")

            Spacer()

            Button {
                pager.step(1, pageCount: pages.count)
            } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.borderless)
            .disabled(index >= pages.count - 1)
            .help("Next page")
            .accessibilityLabel("Next page")

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
