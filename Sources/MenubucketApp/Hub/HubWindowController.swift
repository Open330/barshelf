import AppKit
import Combine
import MenubucketCore
import SwiftUI

/// The four top-level sections of the hub window's sidebar. Raw values are
/// stable identifiers used by the back-compat shims and deep links.
enum HubTab: String, CaseIterable, Identifiable {
    case widgets, gallery, create, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .widgets: return "Widgets"
        case .gallery: return "Gallery"
        case .create: return "Create"
        case .settings: return "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .widgets: return "square.grid.2x2"
        case .gallery: return "sparkles.rectangle.stack"
        case .create: return "wand.and.stars"
        case .settings: return "gearshape"
        }
    }

    var subtitle: String {
        switch self {
        case .widgets: return "Arrange, theme, and maintain installed widgets."
        case .gallery: return "Install curated examples and production-ready starters."
        case .create: return "Build a widget from command, HTTP JSON, pasted JSON, folder, or text."
        case .settings: return "Tune BarShelf behavior, performance, and diagnostics."
        }
    }
}

/// Sidebar selection shared between `HubWindowController` and `HubView`, so a
/// repeated `show(tab:)` while the hub is already open just switches sections
/// instead of spawning a second window.
@MainActor
final class HubModel: ObservableObject {
    @Published var tab: HubTab
    init(tab: HubTab) { self.tab = tab }
}

/// Owns the single standalone "BarShelf" hub window (settings / create /
/// manage / gallery). One resizable NSWindow with a sidebar; while it is open
/// the app switches to `.regular` so it earns a Dock icon and ⌘-Tab entry, and
/// restores `.accessory` on close (only when no other titled window remains).
@MainActor
final class HubWindowController: NSObject, NSWindowDelegate {
    static let shared = HubWindowController()

    private var window: NSWindow?
    private var model: HubModel?

    /// The app's single `WidgetRuntime`, registered at launch so runtime-less
    /// shims (e.g. `GalleryWindowController.show()`) can still open the hub.
    private weak var registeredRuntime: WidgetRuntime?

    /// Called once at launch by `StatusItemController` so `show(tab:)` works.
    func register(runtime: WidgetRuntime) {
        registeredRuntime = runtime
    }

    /// Convenience for shims that carry no runtime — uses the registered one.
    func show(tab: HubTab) {
        guard let runtime = registeredRuntime else { return }
        show(runtime: runtime, tab: tab)
    }

    /// Opens the hub at `tab`, or brings the existing window forward and
    /// switches to `tab` if it is already open.
    func show(runtime: WidgetRuntime, tab: HubTab) {
        registeredRuntime = runtime
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        if let window, let model {
            model.tab = tab
            window.makeKeyAndOrderFront(nil)
            return
        }

        let model = HubModel(tab: tab)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "BarShelf"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 840, height: 560)
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.delegate = self
        window.contentView = NSHostingView(
            rootView: HubView(runtime: runtime, appPrefs: .shared, model: model)
        )
        window.center()
        window.makeKeyAndOrderFront(nil)

        self.window = window
        self.model = model
    }

    // MARK: - NSWindowDelegate

    /// Drops references and restores `.accessory` once the hub is gone —
    /// guarded so a still-open titled window (should not normally exist, since
    /// gallery/create/settings all route into the hub) keeps the Dock presence.
    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === window else {
            return
        }
        window = nil
        model = nil
        DispatchQueue.main.async {
            let othersOpen = NSApp.windows.contains { win in
                win !== closing && win.isVisible && win.styleMask.contains(.titled)
            }
            if !othersOpen {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }
}
