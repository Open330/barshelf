import SwiftUI

/// One widget's card, shown from its own menu bar item.
///
/// The same `WidgetCardView` the shelf draws, so a widget looks the same
/// wherever it is opened from and nothing has to be maintained twice. What
/// differs is the framing: a fixed, narrow width and a height that follows the
/// content, because this answers a question about one reading rather than
/// presenting a shelf.
struct MenuBarWidgetPopover: View {
    let widget: LoadedWidget
    let runtime: WidgetRuntime

    /// Wide enough for the bundled cards' two-column rows, narrow enough that
    /// it reads as attached to a single menu bar item.
    static let width: CGFloat = 280
    /// Past this the card scrolls rather than growing off the screen — a
    /// widget that lists every sensor it can find would otherwise try to.
    static let maximumHeight: CGFloat = 420

    var body: some View {
        ScrollView(.vertical) {
            WidgetCardView(widget: widget, runtime: runtime)
                .padding(10)
        }
        .frame(width: Self.width)
        .frame(maxHeight: Self.maximumHeight)
    }
}
