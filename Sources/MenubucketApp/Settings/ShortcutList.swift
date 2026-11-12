import MenubucketCore

/// Every key BarShelf answers to, for Settings ▸ Shortcuts. Built from the
/// main-menu commands (`MainMenuCommand`) and the keys the popup, the Shelf
/// board and the Dock handle themselves, so a command added to the menu
/// shows up here without a second list to keep in step.
enum ShortcutList {
    struct Item: Hashable {
        let title: String
        /// Keycaps separated by spaces: "⌘F", "← →", "⌘1 … ⌘9".
        let keys: String
    }

    struct Section: Hashable {
        let title: String
        let footer: String?
        let items: [Item]
    }

    /// The main menu's keys as keycaps: "⌘,".
    static func keys(for command: MainMenuCommand) -> String? {
        guard !command.key.isEmpty else { return nil }
        return "⌘" + command.key.uppercased()
    }

    static func sections(dockProfileKeys: Bool = true) -> [Section] {
        let commands = MainMenuCommand.allCases.compactMap { command in
            keys(for: command).map { (command, $0) }
        }
        let everywhere = commands.filter { !$0.0.isPopupOnly }.map { Item(title: $0.0.shortcutTitle, keys: $0.1) }
        let popupCommands = commands.filter { $0.0.isPopupOnly }.map { Item(title: $0.0.shortcutTitle, keys: $0.1) }

        var result = [
            Section(
                title: String(localized: "In BarShelf"),
                footer: String(localized: "These work in the popup and in this window."),
                items: everywhere
            ),
            Section(
                title: String(localized: "In the Popup", comment: "Shortcuts section: keys the popup answers to"),
                footer: nil,
                items: popupCommands + [
                    Item(title: String(localized: "Go to page 1–9"), keys: "⌘1 … ⌘9"),
                    Item(title: String(localized: "Previous or next page"), keys: "← →"),
                ]
            ),
            Section(
                title: String(localized: "On the Shelf", comment: "Shortcuts section: keys the Shelf board answers to"),
                footer: String(localized: "Click a widget on the Shelf first, so the board has the keyboard."),
                items: [
                    Item(title: String(localized: "Choose a widget"), keys: "← → ↑ ↓"),
                    Item(title: String(localized: "Move the chosen widget"), keys: "⌥⌘ ← → ↑ ↓"),
                    Item(title: String(localized: "Show or hide its settings"), keys: "↩"),
                    Item(title: String(localized: "Remove it…"), keys: "⌫"),
                    Item(title: String(localized: "Clear the choice"), keys: "esc"),
                ]
            ),
        ]
        var dock: [Item] = []
        if dockProfileKeys {
            dock.append(Item(
                title: String(localized: "Switch to Dock profile 1–\(DockConfiguration.hotkeyProfileLimit)"),
                keys: "⌃⌥1 … ⌃⌥\(DockConfiguration.hotkeyProfileLimit)"
            ))
        }
        dock.append(Item(title: String(localized: "Back to the folder above", comment: "Shortcuts list: in a Dock folder stack"), keys: "⌘["))
        result.append(Section(
            title: String(localized: "In the Dock", comment: "Shortcuts section: keys the BarShelf Dock answers to"),
            footer: dockProfileKeys ? nil : String(localized: "Profile keys are off. Turn them on in Dock settings."),
            items: dock
        ))
        return result
    }
}
