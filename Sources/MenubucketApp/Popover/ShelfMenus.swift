import MenubucketCore
import SwiftUI

/// The popup's ⋯ menu: `AppMenu.sections`, the same list the status item's
/// right-click menu is built from (`StatusItemController.makeAppMenu`).
struct ShelfMoreMenu: View {
    let runtime: WidgetRuntime
    let onCommand: (AppMenuCommand) -> Void

    var body: some View {
        Menu {
            ForEach(Array(AppMenu.sections.enumerated()), id: \.offset) { index, section in
                if index > 0 { Divider() }
                ForEach(section, id: \.self) { command in
                    item(for: command)
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More")
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

    var body: some View {
        let current = pages[index]
        Menu {
            ForEach(Array(pages.enumerated()), id: \.element.id) { pageIndex, page in
                Toggle(page.group, isOn: Binding(
                    get: { pageIndex == index },
                    set: { _ in jump(pageIndex) }
                ))
                .modifier(ShortcutHint(key: pageIndex < 9 ? String(pageIndex + 1) : ""))
            }
        } label: {
            HStack(spacing: Spacing.xxs) {
                Text(current.group)
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
        .accessibilityLabel("Page: \(current.group)")
        .accessibilityHint("Choose a page to show")
    }
}
