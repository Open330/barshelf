import AppKit
import Combine
import MenubucketCore
import SwiftUI

/// Every page of the hub window's sidebar, in two groups (R13 §3.2): the
/// workspace — what you build and arrange — and the app's own settings, one
/// grouped form per page. Raw values are stable identifiers for deep links;
/// `widgets` keeps the Shelf's historical one.
enum HubTab: String, CaseIterable, Identifiable {
    case shelf = "widgets"
    case menuBar, gallery, create, automation
    case general, shortcuts, updates, privacy, advanced

    /// Former names, kept so existing callers read naturally.
    static let widgets = HubTab.shelf
    static let settings = HubTab.general

    static let workspace: [HubTab] = [.shelf, .menuBar, .gallery, .create, .automation]
    static let settingsPages: [HubTab] = [.general, .shortcuts, .updates, .privacy, .advanced]

    var id: String { rawValue }

    var title: String {
        switch self {
        case .shelf: return "Shelf"
        case .menuBar: return "Menu Bar"
        case .gallery: return "Gallery"
        case .create: return "Create"
        case .automation: return "Automation"
        case .general: return "General"
        case .shortcuts: return "Shortcuts"
        case .updates: return "Updates"
        case .privacy: return "Privacy"
        case .advanced: return "Advanced"
        }
    }

    var symbol: String {
        switch self {
        case .shelf: return "square.grid.2x2"
        case .menuBar: return "menubar.rectangle"
        case .gallery: return "sparkles.rectangle.stack"
        case .create: return "wand.and.stars"
        case .automation: return "keyboard"
        case .general: return "gearshape"
        case .shortcuts: return "command"
        case .updates: return "arrow.down.circle"
        case .privacy: return "hand.raised"
        case .advanced: return "slider.horizontal.3"
        }
    }

    var subtitle: String {
        switch self {
        case .shelf: return "Arrange your pages and widgets."
        case .menuBar: return "Choose what shows in the menu bar and how it looks."
        case .gallery: return "Find and install widgets."
        case .create: return "Build a widget from a command, a URL, a folder, or text."
        case .automation: return "Keyboard shortcuts and window control, imported from Hammerspoon."
        case .general: return "Icon, login, and sounds."
        case .shortcuts: return "Keyboard shortcuts for BarShelf."
        case .updates: return "How BarShelf keeps itself up to date."
        case .privacy: return "What each widget is allowed to do."
        case .advanced: return "Refresh speed, battery use, and diagnostics."
        }
    }
}

/// Sidebar selection shared between `HubWindowController` and `HubView`, so a
/// repeated `show(tab:)` while the hub is already open just switches sections
/// instead of spawning a second window.
@MainActor
final class HubModel: ObservableObject {
    @Published var tab: HubTab
    /// A widget whose settings should be shown, set by
    /// `HubWindowController.showWidgetSettings(widgetID:)`. The Widgets page
    /// opens that widget's settings and clears it.
    @Published var settingsWidgetID: String?
    /// Which part of those settings to open on.
    var settingsPage: WidgetSettingsView.InspectorTab = .general
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

    /// The app's runtime, once `StatusItemController` has registered it.
    var runtime: WidgetRuntime? { registeredRuntime }

    /// Called once at launch by `StatusItemController` so `show(tab:)` works.
    func register(runtime: WidgetRuntime) {
        registeredRuntime = runtime
    }

    /// Convenience for shims that carry no runtime — uses the registered one.
    func show(tab: HubTab) {
        guard let runtime = registeredRuntime else { return }
        show(runtime: runtime, tab: tab)
    }

    /// Opens the hub on one widget's settings. The single route every "Widget
    /// Settings…" entry point uses — popup card, card menu, menu bar item —
    /// so they all land in the same place.
    func showWidgetSettings(widgetID: String, page: WidgetSettingsView.InspectorTab = .general) {
        show(tab: .widgets)
        model?.settingsPage = page
        model?.settingsWidgetID = widgetID
    }

    /// Opens the hub at `tab`, or brings the existing window forward and
    /// switches to `tab` if it is already open.
    func show(runtime: WidgetRuntime, tab: HubTab) {
        registeredRuntime = runtime
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()

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

/// Back-compat shim: settings live in the hub's Settings pages. Keeps the
/// historical signature so older call sites need no edits.
@MainActor
final class AppSettingsWindowController {
    static let shared = AppSettingsWindowController()

    func show(runtime: WidgetRuntime, appPrefs: AppPrefs = .shared) {
        _ = appPrefs
        HubWindowController.shared.show(runtime: runtime, tab: .settings)
    }
}
