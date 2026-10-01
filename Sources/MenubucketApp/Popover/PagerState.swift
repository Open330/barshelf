import AppKit
import MenubucketCore
import SwiftUI
import UniformTypeIdentifiers

/// Pager selection, shared with StatusItemController so keyboard events
/// (←/→, ⌘1..9) and trackpad swipes captured at the AppKit layer can drive
/// the SwiftUI pager.
final class PagerState: ObservableObject {
    @Published var index: Int = 0
    /// Shared with the AppKit event monitor so page-navigation shortcuts do
    /// not escape through the modal search surface.
    @Published var searchIsPresented = false
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

    /// Opening the modal interrupts a horizontal gesture. The AppKit scroll
    /// monitor deliberately stops handling events during search, so waiting for
    /// a later scroll-end event would leave the pager offset in mid-swipe.
    /// Bumped by the Find menu command; the popup opens its search overlay
    /// on each change. A counter rather than a flag, so asking twice while it
    /// is already open is harmless and asking again after closing works.
    @Published private(set) var searchRequests = 0

    func requestSearch() {
        searchRequests += 1
    }

    func setSearchPresented(_ presented: Bool) {
        searchIsPresented = presented
        if presented { cancelSwipe() }
    }
}
