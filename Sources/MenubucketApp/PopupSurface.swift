import AppKit
import SwiftUI

/// Abstraction over the popup presentation surface.
///
/// M0 uses `NSPopover` (`PopoverSurface`); M1 may swap in a non-activating
/// `NSPanel` implementation behind the same protocol (spec D5).
protocol PopupSurface: AnyObject {
    var isShown: Bool { get }
    /// The window that owns popup-scoped input. Local event monitors receive
    /// events for every BarShelf window, so callers must use this to avoid
    /// stealing navigation keys from the hub or another panel.
    var eventWindow: NSWindow? { get }
    var onShow: (() -> Void)? { get set }
    var onHide: (() -> Void)? { get set }

    func show(relativeTo button: NSStatusBarButton)
    func hide()
}

/// Keeps input handling tied to the popup that is actually key. This stays
/// independent of AppKit event construction so routing can be tested without
/// a WindowServer session.
enum PopupEventRouting {
    static func belongsToPopup(eventWindow: AnyObject?, popupWindow: AnyObject?) -> Bool {
        guard let eventWindow, let popupWindow else { return false }
        return eventWindow === popupWindow
    }
}

/// NSPopover-backed popup surface (behavior `.transient`).
final class PopoverSurface: NSObject, PopupSurface, NSPopoverDelegate {
    private let popover = NSPopover()

    var onShow: (() -> Void)?
    var onHide: (() -> Void)?

    /// - Parameter fitsContent: sizes the popover to what the view asks for
    ///   instead of to `contentSize`. A single widget card has no business
    ///   being as tall as the whole shelf.
    init<Content: View>(
        rootView: Content,
        contentSize: CGSize = RootView.defaultSize,
        fitsContent: Bool = false
    ) {
        super.init()
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = contentSize
        let controller = NSHostingController(rootView: rootView)
        if fitsContent {
            controller.sizingOptions = [.preferredContentSize]
        }
        popover.contentViewController = controller
        popover.delegate = self
    }

    var isShown: Bool {
        popover.isShown
    }

    var eventWindow: NSWindow? {
        popover.contentViewController?.view.window
    }

    func show(relativeTo button: NSStatusBarButton) {
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // Make the popover window key so its text fields receive keyboard input
        // and standard editing key equivalents (⌘A/⌘C/⌘V/⌘X).
        popover.contentViewController?.view.window?.makeKey()
        onShow?()
    }

    func hide() {
        popover.performClose(nil)
    }

    // MARK: - NSPopoverDelegate

    func popoverDidClose(_ notification: Notification) {
        onHide?()
    }
}
