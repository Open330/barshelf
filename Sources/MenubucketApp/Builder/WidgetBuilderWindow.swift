import AppKit
import MenubucketCore
import SwiftUI

// MARK: - Window controller (C2 contract)

/// Owns the standalone "Create Widget" window — a Shortcuts-style 3-step
/// wizard (source → display → details). A real window, not the popover, so
/// the live preview and field mapping get room.
@MainActor
final class WidgetBuilderController {
    static let shared = WidgetBuilderController()

    private var window: NSWindow?

    /// `runtime` is used only to enumerate existing bucket groups for the
    /// details step; the created widget lands via hot reload.
    func show(runtime: WidgetRuntime) {
        NSApp.activate(ignoringOtherApps: true)
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let model = WidgetBuilderModel(existingGroups: runtime.bucketGroups)
        model.onClose = { [weak self] in self?.window?.close() }
        model.onCreated = { [weak runtime] in runtime?.loadWidgets() }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Create Widget"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 560, height: 460)
        window.contentView = NSHostingView(rootView: WidgetBuilderView(model: model))
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }
}
