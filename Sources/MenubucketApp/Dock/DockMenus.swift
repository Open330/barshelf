import AppKit
import SwiftUI

/// One row of a dock tile's menu. A tile's menu is defined once, as these,
/// and drawn two ways: as the SwiftUI context menu a right-click opens, and
/// as an `NSMenu` for `AXShowMenu`. SwiftUI's context menu does not answer
/// that accessibility action in the dock's non-activating panel, which left
/// VoiceOver (VO-Shift-M) and automation with no way to reach these commands.
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

/// The SwiftUI rendering, for `.contextMenu`.
struct DockMenuContent: View {
    let entries: [DockMenuEntry]

    var body: some View {
        ForEach(entries) { entry in
            switch entry.kind {
            case .divider:
                Divider()
            case .submenu(let children):
                Menu(entry.title) { DockMenuContent(entries: children) }
            case .action(let run):
                if entry.isChecked {
                    Toggle(isOn: Binding(get: { true }, set: { _ in run() })) { label(entry) }
                        .disabled(!entry.isEnabled)
                } else {
                    Button(role: entry.isDestructive ? .destructive : nil, action: run) { label(entry) }
                        .disabled(!entry.isEnabled)
                }
            }
        }
    }

    @ViewBuilder
    private func label(_ entry: DockMenuEntry) -> some View {
        if let symbol = entry.symbol {
            Label(entry.title, systemImage: symbol)
        } else {
            Text(entry.title)
        }
    }
}

/// The AppKit rendering, popped up for `AXShowMenu`.
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

    /// Opens the menu just above the dock, at the pointer's position along
    /// it. An accessibility action has no click to anchor to, and the dock is
    /// where its tiles are.
    static func popUp(_ entries: [DockMenuEntry], over panelFrame: NSRect?) {
        let menu = makeMenu(entries)
        var point = NSEvent.mouseLocation
        if let frame = panelFrame, !frame.contains(point) {
            point = NSPoint(x: frame.midX, y: frame.maxY)
        }
        menu.popUp(positioning: nil, at: point, in: nil)
    }
}

extension View {
    /// A right-click menu and the same menu for `AXShowMenu`.
    func dockMenu(_ entries: @escaping () -> [DockMenuEntry]) -> some View {
        contextMenu { DockMenuContent(entries: entries()) }
            .accessibilityAction(.showMenu) {
                // After the action returns: the menu's tracking loop would
                // otherwise hold the accessibility call open until it closes,
                // and the caller would read that as a failure.
                let built = entries()
                DispatchQueue.main.async {
                    DockMenuPresenter.popUp(built, over: DockPanelController.currentFrame)
                }
            }
    }
}
