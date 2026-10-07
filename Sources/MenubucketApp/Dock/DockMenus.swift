import AppKit
import SwiftUI

/// One row of a dock tile's menu. A tile's menu is defined once, as these,
/// and offered two ways: as an `NSMenu` on right-click, and as named
/// accessibility actions. SwiftUI's context menu could not be opened through
/// accessibility in the dock's non-activating panel (AXShowMenu reached
/// neither it nor an action of our own), which left VoiceOver with no way to
/// reach these commands.
struct DockMenuEntry: Identifiable {
    enum Kind {
        case action(() -> Void)
        case submenu([DockMenuEntry])
        case divider
    }

    let id = UUID()
    let title: String
    var symbol: String?
    var isChecked = false
    var isEnabled = true
    var isDestructive = false
    let kind: Kind

    static func action(
        _ title: String, symbol: String? = nil, checked: Bool = false,
        enabled: Bool = true, destructive: Bool = false, _ run: @escaping () -> Void
    ) -> DockMenuEntry {
        DockMenuEntry(
            title: title, symbol: symbol, isChecked: checked, isEnabled: enabled,
            isDestructive: destructive, kind: .action(run)
        )
    }

    static func submenu(_ title: String, _ entries: [DockMenuEntry]) -> DockMenuEntry {
        DockMenuEntry(title: title, kind: .submenu(entries))
    }

    static var divider: DockMenuEntry { DockMenuEntry(title: "", kind: .divider) }

    /// Every enabled command, submenus spelled out ("Profile: Work"), for
    /// the accessibility actions list.
    struct Flat: Identifiable {
        let id = UUID()
        let title: String
        let run: () -> Void
    }

    static func flattened(_ entries: [DockMenuEntry], prefix: String? = nil) -> [Flat] {
        entries.flatMap { entry -> [Flat] in
            switch entry.kind {
            case .divider:
                return []
            case .submenu(let children):
                return flattened(children, prefix: entry.title)
            case .action(let run):
                guard entry.isEnabled else { return [] }
                return [Flat(title: prefix.map { "\($0): \(entry.title)" } ?? entry.title, run: run)]
            }
        }
    }

    /// Leading, trailing, and doubled dividers dropped, so optional groups can
    /// be appended without bookkeeping.
    static func tidy(_ entries: [DockMenuEntry]) -> [DockMenuEntry] {
        var out: [DockMenuEntry] = []
        for entry in entries {
            if case .divider = entry.kind {
                if out.isEmpty { continue }
                if case .divider = out.last!.kind { continue }
            }
            out.append(entry)
        }
        if let last = out.last, case .divider = last.kind { out.removeLast() }
        return out
    }
}

/// The menu itself, for a right-click.
enum DockMenuPresenter {
    /// Keeps the closures alive while the menu is open.
    private final class Target: NSObject {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
        @objc func fire(_ sender: Any?) { run() }
    }

    static func makeMenu(_ entries: [DockMenuEntry]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for entry in entries {
            switch entry.kind {
            case .divider:
                menu.addItem(.separator())
            case .submenu(let children):
                let item = NSMenuItem(title: entry.title, action: nil, keyEquivalent: "")
                item.submenu = makeMenu(children)
                menu.addItem(item)
            case .action(let run):
                let target = Target(run)
                let item = NSMenuItem(title: entry.title, action: #selector(Target.fire(_:)), keyEquivalent: "")
                item.target = target
                item.representedObject = target
                item.isEnabled = entry.isEnabled
                item.state = entry.isChecked ? .on : .off
                if let symbol = entry.symbol {
                    item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
                }
                menu.addItem(item)
            }
        }
        return menu
    }
}

/// Which menu a right-click opens: the tile under the pointer, else the
/// bar's. The dock opens its menus itself (`DockHostingView`) rather than
/// through SwiftUI's context menu.
final class DockMenuRouter {
    static let shared = DockMenuRouter()

    private var hovered: (id: String, entries: () -> [DockMenuEntry])?
    var bar: (() -> [DockMenuEntry])?

    func enter(_ id: String, entries: @escaping () -> [DockMenuEntry]) {
        hovered = (id, entries)
    }

    func exit(_ id: String) {
        if hovered?.id == id { hovered = nil }
    }

    /// The entries for a right-click right now.
    var current: [DockMenuEntry]? {
        if let hovered { return hovered.entries() }
        return bar?()
    }
}

extension View {
    /// A tile's menu: on right-click (through `DockMenuRouter`), and as named
    /// accessibility actions, the way VoiceOver offers a SwiftUI view's
    /// commands (VO-Command-Space).
    func dockMenu(id: String, _ entries: @escaping () -> [DockMenuEntry]) -> some View {
        accessibilityActions {
            ForEach(DockMenuEntry.flattened(entries())) { entry in
                Button(entry.title) { entry.run() }
            }
        }
        .onHover { inside in
            if inside {
                DockMenuRouter.shared.enter(id, entries: entries)
            } else {
                DockMenuRouter.shared.exit(id)
            }
        }
    }
}
