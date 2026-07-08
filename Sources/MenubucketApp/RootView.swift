import MenubucketCore
import SwiftUI

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

/// Popup root: one page per bucket group, vertical scroll inside a page,
/// horizontal two-finger swipe / arrow buttons / dots / keyboard for page
/// switching. Pages sit side by side in a sliding strip so swipes track the
/// fingers and snap with a spring.
struct RootView: View {
    @ObservedObject var runtime: WidgetRuntime
    @ObservedObject var pager: PagerState
    @State private var searchPresented = false

    static let defaultSize = CGSize(width: 360, height: 480)

    var body: some View {
        let pages = runtime.pages
        VStack(spacing: 0) {
            if pages.isEmpty {
                emptyState
            } else {
                let index = min(max(pager.index, 0), pages.count - 1)

                header(for: pages[index])
                Divider()
                pinnedRow
                pagerStrip(pages: pages, index: index)
                Divider()
                footer(pages: pages, index: index)
            }
        }
        .frame(width: Self.defaultSize.width, height: Self.defaultSize.height)
        .overlay(alignment: .top) {
            if searchPresented {
                SearchOverlay(runtime: runtime, pager: pager, isPresented: $searchPresented)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .shadow(radius: 8)
                    .padding(8)
            }
        }
        .background( // ⌘F without stealing layout space
            Button("") { searchPresented.toggle() }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
        )
        .onReceive(runtime.objectWillChange) { _ in
            DispatchQueue.main.async {
                pager.clamp(to: runtime.pages.count)
            }
        }
    }

    /// Pinned widgets stay above the pager on every page (invariant: at most
    /// a compact strip — full cards live in their bucket).
    @ViewBuilder
    private var pinnedRow: some View {
        let pinnedWidgets = runtime.prefs.pinned.compactMap { id in
            runtime.widgets.first { $0.id == id }
        }
        if !pinnedWidgets.isEmpty {
            VStack(spacing: 6) {
                ForEach(pinnedWidgets.prefix(2)) { widget in
                    WidgetCardView(widget: widget, runtime: runtime)
                        .frame(maxHeight: 120)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            Divider()
        }
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
                    ScrollView {
                        VStack(spacing: 10) {
                            ForEach(page.widgets) { widget in
                                WidgetCardView(widget: widget, runtime: runtime)
                            }
                        }
                        .padding(10)
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

    private func header(for page: WidgetPage) -> some View {
        HStack {
            Text(page.group)
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Button {
                searchPresented.toggle()
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help("Search (⌘F)")
            Button {
                runtime.refreshAll()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh All")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func footer(pages: [WidgetPage], index: Int) -> some View {
        HStack(spacing: 8) {
            Button {
                pager.step(-1, pageCount: pages.count)
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.borderless)
            .disabled(index == 0)

            Spacer()

            HStack(spacing: 6) {
                ForEach(Array(pages.enumerated()), id: \.element.id) { pageIndex, page in
                    Circle()
                        .fill(pageIndex == index ? Color.primary : Color.secondary.opacity(0.35))
                        .frame(width: 6, height: 6)
                        .onTapGesture {
                            pager.jump(to: pageIndex, pageCount: pages.count)
                        }
                        .help(page.group)
                }
            }

            Spacer()

            Button {
                pager.step(1, pageCount: pages.count)
            } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.borderless)
            .disabled(index >= pages.count - 1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "tray")
                .font(.system(size: 28))
                .foregroundColor(.secondary)
            Text("No widgets installed")
                .font(.system(size: 13, weight: .semibold))
            Text("Put widgets in ./widgets/ or\n~/Library/Application Support/menubucket/widgets/")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
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
    @ObservedObject private var model: WidgetCardModel
    @State private var showSettings = false

    init(widget: LoadedWidget, runtime: WidgetRuntime) {
        self.widget = widget
        self.runtime = runtime
        _model = ObservedObject(wrappedValue: runtime.cardModel(for: widget.id))
    }

    var body: some View {
        let snapshot = model.snapshot
        VStack(alignment: .leading, spacing: 8) {
            cardHeader(snapshot: snapshot)

            if let overlay = model.overlay {
                // Host-generated card (permission approval / restart) replaces
                // the widget content until resolved.
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
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Loading…").font(.caption).foregroundColor(.secondary)
                }
            } else {
                Text("No data yet").font(.caption).foregroundColor(.secondary)
            }

            if let updatedAt = snapshot.updatedAt {
                Text("Updated \(Self.relativeFormatter.localizedString(for: updatedAt, relativeTo: Date()))")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)
        )
        .contextMenu {
            Button(runtime.prefs.isPinned(widget.id) ? "Unpin" : "Pin") {
                runtime.prefs.togglePin(widget.id)
                runtime.objectWillChange.send() // pinned row lives in RootView
            }
            Button("Settings…") { showSettings = true }
            Button("Refresh") { runtime.refresh(widgetID: widget.id) }
        }
        .sheet(isPresented: $showSettings) {
            WidgetSettingsView(widget: widget, runtime: runtime)
        }
    }

    private var actionContext: ActionContext {
        ActionContext(widgetID: widget.id) { [weak runtime] action in
            ActionRouter.perform(action, widgetID: widget.id, runtime: runtime)
        }
    }

    private func cardHeader(snapshot: WidgetSnapshot) -> some View {
        HStack(spacing: 6) {
            if let icon = widget.manifest.icon {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            Text(widget.manifest.name)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
            Spacer()
            if snapshot.isLoading {
                ProgressView().controlSize(.mini)
            }
            Button {
                runtime.refresh(widgetID: widget.id)
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10))
            }
            .buttonStyle(.borderless)
            .help("Refresh \(widget.manifest.name)")
        }
    }

    private func staleBanner(error: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
            Text("Showing cached data: \(error)")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.12)))
    }

    private func failureState(error: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "xmark.octagon.fill")
                .foregroundColor(.red)
            Text(error)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.red.opacity(0.1)))
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}
