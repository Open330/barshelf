import MenubucketCore
import SwiftUI

/// The popup's ⋯ menu: `AppMenu.sections`, the same list the status item's
/// right-click menu is built from (`StatusItemController.makeAppMenu`).
struct ShelfMoreMenu: View {
    let runtime: WidgetRuntime
    let onCommand: (AppMenuCommand) -> Void
    /// So "Check for Updates…" turns into "Update to BarShelf X…".
    @ObservedObject private var updates = UpdateStatus.shared
    @ObservedObject private var dockStore = DockStore.shared

    var body: some View {
        Menu {
            ForEach(Array(AppMenu.sections.enumerated()), id: \.offset) { index, section in
                if index > 0 { Divider() }
                ForEach(section, id: \.self) { command in
                    item(for: command)
                }
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.button)
        .buttonStyle(.icon)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("More")
    }

    @ViewBuilder
    private func item(for command: AppMenuCommand) -> some View {
        if command == .menuBar {
            let toggles = AppMenu.menuBarToggles(runtime: runtime)
            if !toggles.isEmpty {
                Menu {
                    ForEach(toggles) { toggle in
                        Toggle(toggle.title, isOn: Binding(
                            get: { toggle.isOn },
                            set: { _ in AppMenu.toggleMenuBar(widgetID: toggle.id, runtime: runtime) }
                        ))
                        .help(toggle.help)
                    }
                } label: {
                    Label(command.title, systemImage: command.symbol)
                }
            }
        } else if command == .dock {
            Menu {
                let rows = AppMenu.dockProfiles(store: dockStore)
                ForEach(rows) { row in
                    Toggle(isOn: Binding(
                        get: { row.isActive },
                        set: { _ in dockStore.activate(profileID: row.id) }
                    )) {
                        Label(row.title, systemImage: row.symbol)
                    }
                }
                if !rows.isEmpty { Divider() }
                Button(AppMenuCommand.focusDock.title) { onCommand(.focusDock) }
                    .disabled(!dockStore.configuration.mode.showsDock)
                Button(AppMenu.dockSettingsTitle) { onCommand(.dock) }
            } label: {
                Label(command.title, systemImage: command.symbol)
            }
        } else {
            Button { onCommand(command) } label: {
                Label(command.title, systemImage: command.symbol)
            }
            .modifier(ShortcutHint(key: command.keyEquivalent))
        }
    }
}

/// Shows a ⌘-key beside a menu item. The key itself is handled by the main
/// menu (`installCommands`), so this is the hint, not a second binding.
struct ShortcutHint: ViewModifier {
    let key: String

    func body(content: Content) -> some View {
        if let character = key.first {
            content.keyboardShortcut(KeyEquivalent(character), modifiers: .command)
        } else {
            content
        }
    }
}

/// The page name in the header, as a menu of every page: the quickest way to
/// a page that is not next door, with its ⌘1…⌘9 shortcut beside it.
struct PageMenu: View {
    let pages: [WidgetPage]
    let index: Int
    let jump: (Int) -> Void
    /// For the page's own commands: removing it, and the Shelf for the rest.
    var runtime: WidgetRuntime?
    var onCommand: (AppMenuCommand) -> Void = { _ in }

    var body: some View {
        let current = pages[index]
        Menu {
            ForEach(Array(pages.enumerated()), id: \.element.id) { pageIndex, page in
                Toggle(PageName.label(page.group), isOn: Binding(
                    get: { pageIndex == index },
                    set: { _ in jump(pageIndex) }
                ))
                .modifier(ShortcutHint(key: pageIndex < 9 ? String(pageIndex + 1) : ""))
            }
            if let runtime {
                Divider()
                pageCommands(current.group, runtime: runtime)
            }
        } label: {
            HStack(spacing: Spacing.xxs) {
                Text(PageName.label(current.group))
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Go to a page")
        .accessibilityLabel("Page: \(PageName.label(current.group))")
        .accessibilityHint("Choose a page to show")
    }

    /// Removing the page shown: at once when it is empty, otherwise by
    /// choosing where its widgets go (none is uninstalled). Renaming, new
    /// pages and the rest need typing or dragging, so they are on the Shelf.
    @ViewBuilder
    private func pageCommands(_ page: String, runtime: WidgetRuntime) -> some View {
        let shelf = runtime.shelfPages
        let others = shelf.map(\.group).filter { $0 != page }
        let isEmpty = shelf.first { $0.group == page }?.widgets.isEmpty ?? true
        if isEmpty {
            Button("Remove This Page", role: .destructive) { runtime.removeEmptyPage(page) }
        } else if !others.isEmpty {
            Menu("Remove This Page") {
                Section("Move its widgets to") {
                    ForEach(others, id: \.self) { other in
                        Button(PageName.label(other)) { runtime.renamePage(page, to: other) }
                    }
                }
            }
        }
        Button("Edit Pages…") { onCommand(.openBarShelf) }
    }
}
