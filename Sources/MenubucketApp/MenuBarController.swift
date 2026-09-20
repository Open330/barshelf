import AppKit
import Combine
import MenubucketCore

/// Live menu-bar text for promoted widgets.
///
/// The published entries are what the menu bar draws; they are recomputed on
/// every snapshot of a promoted widget. This is deliberately *not* part of
/// `WidgetRuntime`'s own `objectWillChange`: a 2 s status refresh must not
/// invalidate the popup's view tree (R05 perf), so the menu bar observes its
/// own small store.
final class MenuBarStatusStore: ObservableObject {
    @Published private(set) var entries: [MenuBarEntry] = []

    /// Widget ids currently drawn in the menu bar — the set the scheduler
    /// keeps polling while the popup is closed.
    var promotedWidgetIDs: Set<String> {
        Set(entries.map(\.widgetID))
    }

    func apply(_ entries: [MenuBarEntry]) {
        guard self.entries != entries else { return }
        self.entries = entries
    }
}

/// Owns every menu-bar status item: the main BarShelf item, whose title is the
/// shared live strip, and one extra item per widget the user split out.
///
/// Click handling for the main item stays in `StatusItemController` — this
/// class only draws into it, so the popup toggle keeps a single owner.
///
/// Like `Scheduler`, every entry point runs on the main queue; the owning
/// `StatusItemController` is constructed in `applicationDidFinishLaunching`
/// and the entry subscription is delivered on `RunLoop.main`.
final class MenuBarController {
    /// Width of the main item when it shows the mark alone.
    static let iconOnlyLength: CGFloat = 28

    /// A promoted widget's own item was clicked — reveal it in the popup.
    var onSelect: ((String) -> Void)?
    /// Right-click on one of the separate items. The button is passed so the
    /// caller can anchor a context menu to the item that was clicked.
    var onContextMenu: ((NSEvent, String, NSStatusBarButton) -> Void)?

    private let mainItem: NSStatusItem
    /// Extra status items, keyed by widget id.
    private var separateItems: [String: NSStatusItem] = [:]
    private var mainSymbol: String = AppPreferences.defaultMenuBarSymbol
    /// Symbol the main button currently carries. The brand mark is drawn into
    /// a bitmap, so it is only rebuilt when the choice actually changes — not
    /// on every 2 s strip redraw.
    private var appliedSymbol: String?
    private var currentEntries: [MenuBarEntry] = []

    init(mainItem: NSStatusItem) {
        self.mainItem = mainItem
    }

    /// The SF Symbol / brand mark shown on the main item (app preference).
    func setMainSymbol(_ symbol: String) {
        mainSymbol = symbol
        redraw()
    }

    func apply(_ entries: [MenuBarEntry]) {
        guard currentEntries != entries else { return }
        currentEntries = entries
        redraw()
    }

    private func redraw() {
        let (strip, separate) = MenuBarPolicy.partition(currentEntries)
        applyStrip(strip)
        applySeparateItems(separate)
    }

    // MARK: - Main item (shared strip)

    private func applyStrip(_ entries: [MenuBarEntry]) {
        guard let button = mainItem.button else { return }
        if appliedSymbol != mainSymbol {
            BarShelfStatusIcon.configure(
                button, symbol: mainSymbol, fallback: AppPreferences.defaultMenuBarSymbol
            )
            appliedSymbol = mainSymbol
        }
        guard !entries.isEmpty else {
            mainItem.length = Self.iconOnlyLength
            button.attributedTitle = NSAttributedString(string: "")
            button.imagePosition = .imageOnly
            button.toolTip = nil
            button.setAccessibilityLabel(BarShelfStatusIcon.accessibilityName)
            return
        }
        mainItem.length = NSStatusItem.variableLength
        button.imagePosition = .imageLeading
        button.attributedTitle = Self.attributedStrip(entries)
        button.toolTip = MenuBarPolicy.tooltip(for: entries)
        button.setAccessibilityLabel(
            "\(BarShelfStatusIcon.accessibilityName), \(MenuBarPolicy.stripText(entries))"
        )
    }

    /// The shared strip is text only — one label per widget, separated by a
    /// middle dot. Per-widget icons belong to the separate items, where AppKit
    /// tints a template image for free; a widget whose mode is icon-only is
    /// therefore never routed into the strip.
    ///
    /// Colors stay dynamic (`labelColor` and friends) so the menu bar resolves
    /// them for its own appearance at draw time. Stale entries drop to the
    /// tertiary color: a frozen reading must not pass for a live one.
    static func attributedStrip(_ entries: [MenuBarEntry]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for entry in entries {
            guard let label = entry.label, !label.isEmpty else { continue }
            if result.length > 0 {
                result.append(NSAttributedString(
                    string: MenuBarPolicy.stripSeparator,
                    attributes: [
                        .font: statusFont,
                        .foregroundColor: NSColor.tertiaryLabelColor,
                    ]
                ))
            }
            result.append(NSAttributedString(
                string: label,
                attributes: [
                    .font: statusFont,
                    .foregroundColor: color(for: entry),
                ]
            ))
        }
        return result
    }

    // MARK: - Separate items

    private func applySeparateItems(_ entries: [MenuBarEntry]) {
        let live = Set(entries.map(\.widgetID))
        for (id, item) in separateItems where !live.contains(id) {
            NSStatusBar.system.removeStatusItem(item)
            separateItems.removeValue(forKey: id)
        }
        for entry in entries {
            let item = separateItems[entry.widgetID] ?? makeSeparateItem(for: entry.widgetID)
            separateItems[entry.widgetID] = item
            guard let button = item.button else { continue }
            item.length = NSStatusItem.variableLength
            if let symbol = entry.symbol,
               let image = NSImage(
                   systemSymbolName: symbol, accessibilityDescription: entry.name
               ) {
                image.isTemplate = true
                button.image = image
            } else {
                button.image = nil
            }
            let label = entry.label ?? ""
            button.attributedTitle = NSAttributedString(
                string: label,
                attributes: [.font: Self.statusFont, .foregroundColor: Self.color(for: entry)]
            )
            button.imagePosition = Self.imagePosition(
                hasImage: button.image != nil, hasLabel: !label.isEmpty
            )
            button.toolTip = MenuBarPolicy.tooltip(for: [entry])
            button.setAccessibilityLabel(
                label.isEmpty ? entry.name : "\(entry.name), \(label)"
            )
        }
    }

    static func imagePosition(hasImage: Bool, hasLabel: Bool) -> NSControl.ImagePosition {
        switch (hasImage, hasLabel) {
        case (true, true): return .imageLeading
        case (true, false): return .imageOnly
        default: return .noImage
        }
    }

    private func makeSeparateItem(for widgetID: String) -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.target = self
            button.action = #selector(separateItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imageScaling = .scaleProportionallyDown
            // The button carries the widget id so one action serves every item.
            button.identifier = NSUserInterfaceItemIdentifier(widgetID)
        }
        return item
    }

    @objc private func separateItemClicked(_ sender: Any?) {
        guard let button = sender as? NSStatusBarButton,
              let widgetID = button.identifier?.rawValue
        else { return }
        let event = NSApp.currentEvent
        let isRightClick = event?.type == .rightMouseUp
            || (event?.type == .leftMouseUp
                && event?.modifierFlags.contains(.control) == true)
        if isRightClick, let event {
            onContextMenu?(event, widgetID, button)
        } else {
            onSelect?(widgetID)
        }
    }

    // MARK: - Drawing helpers

    /// The menu bar's own text size — matching it keeps a promoted widget from
    /// looking like a different app's status item.
    static let statusFont = NSFont.menuBarFont(ofSize: 0)

    static func color(for entry: MenuBarEntry) -> NSColor {
        entry.isStale ? .tertiaryLabelColor : .labelColor
    }
}
