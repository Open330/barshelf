import AppKit

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
        let widgets = NSMenu(title: "Widgets")
        widgetsItem.submenu = widgets
        widgets.addItem(command("Refresh All", #selector(refreshAll(_:)), "r"))
        widgets.addItem(command("Create Widget…", #selector(openWidgetBuilder(_:)), "n"))
        mainMenu.addItem(widgetsItem)

        if let edit = mainMenu.items.first(where: { $0.submenu?.title == "Edit" })?.submenu {
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

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(findInPopup(_:)) { return popupIsKey }
        return true
    }

    private var popupIsKey: Bool {
        popup.isShown && popup.eventWindow?.isKeyWindow == true
    }

    private func command(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }
}
