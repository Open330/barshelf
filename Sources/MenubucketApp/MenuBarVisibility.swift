import AppKit
import Combine

/// Whether BarShelf's menu bar items can actually be seen.
///
/// macOS gives no notice when it has no room for a status item. On a full
/// menu bar it moves the item's window off every screen; on a MacBook with a
/// notch the item can also land in the gap the notch covers. Either way the
/// item is "there" to AppKit and gone for the person — and BarShelf has no
/// Dock icon, so a hidden main item leaves a new user with no way in. This
/// notices, so the BarShelf window can say so.
final class MenuBarVisibility: ObservableObject {
    static let shared = MenuBarVisibility()

    /// The main BarShelf item is hidden.
    @Published private(set) var mainHidden = false
    /// Widgets shown as their own menu bar item that are hidden.
    @Published private(set) var hiddenWidgetIDs: [String] = []

    /// What a screen offers status items: its frame, and on a Mac with a
    /// notch, the menu bar areas either side of it (`auxiliaryTopLeftArea`,
    /// `auxiliaryTopRightArea`).
    struct ScreenArea: Equatable {
        var frame: NSRect
        var leftOfNotch: NSRect?
        var rightOfNotch: NSRect?
    }

    /// An item is visible when its center is on a screen and, on a screen
    /// with a notch, it sits wholly in the menu bar either side of it.
    /// macOS 26 parks items it has no room for at the notch's edge, stacked
    /// on one another and mostly under it (seen: three at x 927–998 against
    /// a notch spanning 751–959), so any overlap with the notch counts.
    static func isVisible(itemFrame: NSRect, screens: [ScreenArea]) -> Bool {
        guard itemFrame.width > 0 else { return false }
        let center = NSPoint(x: itemFrame.midX, y: itemFrame.midY)
        guard let screen = screens.first(where: { $0.frame.contains(center) }) else { return false }
        if let left = screen.leftOfNotch, let right = screen.rightOfNotch {
            let slack: CGFloat = 1
            return itemFrame.minX >= right.minX - slack || itemFrame.maxX <= left.maxX + slack
        }
        return true
    }

    static func currentScreens() -> [ScreenArea] {
        NSScreen.screens.map { screen in
            ScreenArea(frame: screen.frame,
                       leftOfNotch: screen.auxiliaryTopLeftArea,
                       rightOfNotch: screen.auxiliaryTopRightArea)
        }
    }

    /// Re-reads the items' positions. Unknown while the menu bar itself is
    /// hidden (a full-screen app, or "Automatically hide and show the menu
    /// bar"): every item is off screen then, by design, so nothing changes.
    func update(main: NSStatusItem, widgets: [String: NSStatusItem]) {
        guard NSMenu.menuBarVisible() else { return }
        let screens = Self.currentScreens()
        func hidden(_ item: NSStatusItem) -> Bool {
            guard item.isVisible, let window = item.button?.window else { return false }
            return !Self.isVisible(itemFrame: window.frame, screens: screens)
        }
        let main = hidden(main)
        let widgetIDs = widgets.filter { hidden($0.value) }.map(\.key).sorted()
        if main != mainHidden { mainHidden = main }
        if widgetIDs != hiddenWidgetIDs { hiddenWidgetIDs = widgetIDs }
    }
}

import SwiftUI

/// Says which BarShelf menu bar items macOS has no room for, and what to do.
/// Empty while everything is visible.
struct MenuBarHiddenBanner: View {
    @ObservedObject var visibility = MenuBarVisibility.shared
    /// Inset for a page that is not a form (the shelf board).
    var padded = false
    let widgetName: (String) -> String?

    var body: some View {
        if visibility.mainHidden {
            StatusBanner(
                tone: .warning,
                message: String(localized: "The BarShelf icon is hidden: the menu bar is full, or the icon is behind the camera notch. Hold ⌘ and drag other icons out of the menu bar to make room, or quit apps that put icons there. Opening BarShelf from Finder or Spotlight always brings back this window."),
                symbol: "menubar.rectangle"
            ) { EmptyView() }
            .padding(padded ? [.horizontal, .top] : [], Spacing.m)
        }
        let names = visibility.hiddenWidgetIDs.compactMap(widgetName)
        if !names.isEmpty {
            StatusBanner(
                tone: .warning,
                message: String(localized: "No room in the menu bar for \(names.formatted(.list(type: .and))). Make room by holding ⌘ and dragging other icons out, or set their placement to “Next to the BarShelf icon” on the Menu Bar page."),
                symbol: "menubar.rectangle"
            ) { EmptyView() }
            .padding(padded ? [.horizontal, .top] : [], Spacing.m)
        }
    }
}
