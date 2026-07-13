import AppKit
import SwiftUI

/// Abstraction over the popup presentation surface.
///
/// M0 uses `NSPopover` (`PopoverSurface`); M1 may swap in a non-activating
/// `NSPanel` implementation behind the same protocol (spec D5).
protocol PopupSurface: AnyObject {
    var isShown: Bool { get }
    var onShow: (() -> Void)? { get set }
    var onHide: (() -> Void)? { get set }

    func show(relativeTo button: NSStatusBarButton)
    func hide()
}

/// NSPopover-backed popup surface (behavior `.transient`).
final class PopoverSurface: NSObject, PopupSurface, NSPopoverDelegate {
    private let popover = NSPopover()

    var onShow: (() -> Void)?
    var onHide: (() -> Void)?

    init<Content: View>(rootView: Content, contentSize: CGSize = RootView.defaultSize) {
        super.init()
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = contentSize
        popover.contentViewController = NSHostingController(rootView: rootView)
        popover.delegate = self
    }

    var isShown: Bool {
        popover.isShown
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
