import AppKit

/// The commands the popup's ⋯ menu and the status item's right-click menu
/// share. Both menus are built from `AppMenu.sections`, so the two cannot
/// drift apart: a command added here appears in both.
enum AppMenuCommand: Hashable {
    case editShelf, addWidget, menuBar, dock, openBarShelf, settings, checkForUpdates, quit

    var title: String {
        switch self {
        case .editShelf: return String(localized: "Edit Shelf")
        case .addWidget: return String(localized: "Add Widget…")
        case .menuBar: return String(localized: "Menu Bar")
        case .dock: return String(localized: "Dock", comment: "App menu: the BarShelf Dock submenu")
        case .openBarShelf: return String(localized: "Open BarShelf…")
        case .settings: return String(localized: "Settings…")
        case .checkForUpdates:
            // Built on the main thread by both menus; once a check has found a
            // release, the item says so and opens it.
            let available = MainActor.assumeIsolated { UpdateStatus.shared.available }
            if let available { return String(localized: "Update to BarShelf \(available)…") }
            return String(localized: "Check for Updates…")
        case .quit: return String(localized: "Quit BarShelf")
        }
    }

    /// The ⌘-key shown beside the item; empty for none. The same keys are
    /// main-menu commands (`installCommands`), which is what makes them work
    /// while no menu is open.
    var keyEquivalent: String {
        switch self {
        case .editShelf: return "e"
        case .settings: return ","
        case .quit: return "q"
        case .addWidget, .menuBar, .dock, .openBarShelf, .checkForUpdates: return ""
        }
    }

    var symbol: String {
        switch self {
        case .editShelf: return "pencil"
        case .addWidget: return "plus"
        case .menuBar: return "menubar.rectangle"
        case .dock: return "dock.rectangle"
        case .openBarShelf: return "macwindow"
        case .settings: return "gearshape"
        case .checkForUpdates: return "arrow.down.circle"
        case .quit: return "power"
        }
    }
}

enum AppMenu {
    /// Groups, in order; a separator goes between groups.
    static let sections: [[AppMenuCommand]] = [
        [.editShelf, .addWidget, .menuBar, .dock],
        [.openBarShelf, .settings, .checkForUpdates],
        [.quit],
    ]

    /// One row of "Menu Bar ▸": a widget that can show a live value, checked
    /// while it is on the bar.
    struct MenuBarToggle: Identifiable, Equatable {
        let id: String
        let title: String
        let isOn: Bool
        let help: String
    }

    /// "Menu Bar ▸" — the picker for which widgets show a live value.
    ///
    /// It lists the widgets that offer one, checked when they are on the bar.
    /// This is both how a widget sharing the strip (which has no status item of
    /// its own to right-click) gets taken off, and how the feature is found in
    /// the first place, since promotion is off until the user asks for it.
    /// Empty when no widget offers a value; the submenu is hidden then.
    static func menuBarToggles(runtime: WidgetRuntime) -> [MenuBarToggle] {
        let shown = runtime.menuBarWidgetIDs
        let labels = Dictionary(
            runtime.menuBar.entries.map { ($0.widgetID, $0.label) },
            uniquingKeysWith: { first, _ in first }
        )
        return runtime.menuBarCandidates.map { widget in
            let isOn = shown.contains(widget.id)
            // A checked item with nothing in the bar reads as broken; say why.
            let value = runtime.dormantMenuBarWidgetIDs.contains(widget.id)
                ? String(localized: "hidden until its reading gets there")
                : isOn ? (labels[widget.id] ?? nil) : nil
            return MenuBarToggle(
                id: widget.id,
                title: value.map { "\(widget.displayName) — \($0)" } ?? widget.displayName,
                isOn: isOn,
                help: isOn
                    ? String(localized: "Remove \(widget.displayName) from the menu bar")
                    : String(localized: "Show \(widget.displayName) in the menu bar")
            )
        }
    }

    static func toggleMenuBar(widgetID: String, runtime: WidgetRuntime) {
        let isOn = runtime.menuBarWidgetIDs.contains(widgetID)
        runtime.updateMenuBarPlacement(for: widgetID) { $0.enabled = !isOn }
    }

    /// One row of "Dock ▸": a profile, checked while active (R15).
    struct DockProfileRow: Identifiable, Equatable {
        let id: String
        let title: String
        let symbol: String
        let isActive: Bool
    }

    /// "Dock ▸" lists the profiles once there is more than one to pick from;
    /// the submenu always offers the dock's settings, which is where the
    /// feature is found in the first place.
    static func dockProfiles(store: DockStore) -> [DockProfileRow] {
        let config = store.configuration
        guard config.profiles.count > 1 else { return [] }
        return config.profiles.enumerated().map { index, profile in
            let hotkey = config.profileHotkeysEnabled ? DockHotkeys.label(forPosition: index + 1) : nil
            return DockProfileRow(
                id: profile.id,
                title: hotkey.map { "\(profile.name)  \($0)" } ?? profile.name,
                symbol: profile.symbol,
                isActive: profile.id == config.activeProfileID
            )
        }
    }

    static var dockSettingsTitle: String { String(localized: "Dock Settings…") }
}

/// The app's commands as real main-menu items, so their shortcuts work in
/// every BarShelf window — the popup, a widget card, the hub — instead of
/// only while the status item's menu happens to be open.
///
/// The main menu is invisible while BarShelf is an accessory app, but AppKit
/// still routes key equivalents through it whenever the app is active. While
/// the hub is open the app is `.regular` and this is the menu bar the user
/// sees, which is why the first item has to be a proper application menu:
/// AppKit treats whatever comes first as one.
extension StatusItemController: NSMenuItemValidation {
    func installCommands(in mainMenu: NSMenu) {
        let appItem = NSMenuItem()
        let app = NSMenu(title: "BarShelf")
        appItem.submenu = app
        app.addItem(command("Settings…", #selector(openSettings(_:)), ","))
        app.addItem(command("Check for Updates…", #selector(checkForUpdates(_:)), ""))
        app.addItem(.separator())
        app.addItem(command("Quit BarShelf", #selector(terminateApp(_:)), "q"))
        mainMenu.insertItem(appItem, at: 0)

        let widgetsItem = NSMenuItem()
        let widgets = NSMenu(title: String(localized: "Widgets"))
        widgetsItem.submenu = widgets
        widgets.addItem(command("Refresh All", #selector(refreshAll(_:)), "r"))
        widgets.addItem(command("Edit Shelf", #selector(toggleEditShelf(_:)), "e"))
        widgets.addItem(command("Create Widget…", #selector(openWidgetBuilder(_:)), "n"))
        mainMenu.addItem(widgetsItem)

        if let edit = mainMenu.items.first(where: { $0.submenu?.title == AppDelegate.editMenuTitle })?.submenu {
            edit.addItem(.separator())
            edit.addItem(command("Find…", #selector(findInPopup(_:)), "f"))
        }
    }

    /// Opens the popup's search. Only while the popup is the key window: in
    /// the hub ⌘F belongs to whatever search field that page has.
    @objc func findInPopup(_ sender: Any?) {
        guard popupIsKey else { return }
        pager.requestSearch()
    }

    /// ⌘E: in and out of the popup's edit mode. Popup-only, like Find.
    @objc func toggleEditShelf(_ sender: Any?) {
        guard popupIsKey else { return }
        pager.toggleEditing()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(findInPopup(_:))
            || menuItem.action == #selector(toggleEditShelf(_:)) {
            return popupIsKey
        }
        return true
    }

    private var popupIsKey: Bool {
        popup.isShown && popup.eventWindow?.isKeyWindow == true
    }

    /// The title is a localization key, so the catalog picks up each literal.
    private func command(_ title: String.LocalizationValue, _ action: Selector, _ key: String) -> NSMenuItem {
        let item = NSMenuItem(title: String(localized: title), action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    // MARK: - Shared app menu (status item right-click)

    /// The status item's right-click menu, built from `AppMenu.sections` —
    /// the same definition the popup's ⋯ menu draws.
    func makeAppMenu() -> NSMenu {
        let menu = NSMenu()
        // Explicit enablement: with automatic validation AppKit re-enables any
        // item whose target responds to its action, overriding `isEnabled`.
        menu.autoenablesItems = false
        for (index, section) in AppMenu.sections.enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            for command in section {
                if command == .menuBar {
                    if let item = makeMenuBarSubmenuItem() { menu.addItem(item) }
                    continue
                }
                if command == .dock {
                    menu.addItem(makeDockSubmenuItem())
                    continue
                }
                let item = NSMenuItem(
                    title: command.title,
                    action: #selector(performAppMenuItem(_:)),
                    keyEquivalent: command.keyEquivalent
                )
                item.target = self
                item.representedObject = command
                item.image = NSImage(systemSymbolName: command.symbol, accessibilityDescription: nil)
                menu.addItem(item)
            }
        }
        return menu
    }

    /// nil when no widget can go on the menu bar, so the menu does not offer
    /// an empty submenu.
    private func makeMenuBarSubmenuItem() -> NSMenuItem? {
        let toggles = AppMenu.menuBarToggles(runtime: shelfRuntime)
        guard !toggles.isEmpty else { return nil }
        let item = NSMenuItem(title: AppMenuCommand.menuBar.title, action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: AppMenuCommand.menuBar.symbol, accessibilityDescription: nil)
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for toggle in toggles {
            let row = NSMenuItem(
                title: toggle.title,
                action: #selector(toggleMenuBarWidget(_:)),
                keyEquivalent: ""
            )
            row.target = self
            row.representedObject = toggle.id
            row.state = toggle.isOn ? .on : .off
            row.toolTip = toggle.help
            submenu.addItem(row)
        }
        item.submenu = submenu
        return item
    }

    @objc private func performAppMenuItem(_ sender: NSMenuItem) {
        guard let command = sender.representedObject as? AppMenuCommand else { return }
        perform(command, fromPopup: false)
    }

    private func makeDockSubmenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: AppMenuCommand.dock.title, action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: AppMenuCommand.dock.symbol, accessibilityDescription: nil)
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let rows = AppMenu.dockProfiles(store: DockStore.shared)
        for row in rows {
            let entry = NSMenuItem(title: row.title, action: #selector(activateDockProfile(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = row.id
            entry.state = row.isActive ? .on : .off
            entry.image = NSImage(systemSymbolName: row.symbol, accessibilityDescription: nil)
            submenu.addItem(entry)
        }
        if !rows.isEmpty { submenu.addItem(.separator()) }
        let settings = NSMenuItem(title: AppMenu.dockSettingsTitle, action: #selector(openDockSettings(_:)), keyEquivalent: "")
        settings.target = self
        submenu.addItem(settings)
        item.submenu = submenu
        return item
    }

    @objc private func activateDockProfile(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        DockStore.shared.activate(profileID: id)
    }

    @objc func openDockSettings(_ sender: Any?) {
        perform(.dock, fromPopup: false)
    }

    @objc private func toggleMenuBarWidget(_ sender: NSMenuItem) {
        guard let widgetID = sender.representedObject as? String else { return }
        AppMenu.toggleMenuBar(widgetID: widgetID, runtime: shelfRuntime)
    }
}
