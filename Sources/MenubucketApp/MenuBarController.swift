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

    /// Widget ids actually promoted — the set the scheduler keeps polling
    /// while the popup is closed.
    ///
    /// Capped the same way the renderer caps, so a widget past `maxEntries`
    /// never holds the closed-popup exemption for a value nobody can see.
    var promotedWidgetIDs: Set<String> {
        Set(MenuBarPolicy.promoted(entries).map(\.widgetID))
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

    /// Whether an icon override names an SF Symbol or is literal text.
    ///
    /// This is the one question Core cannot answer — it needs AppKit to know
    /// whether a symbol by that name exists — so the split happens here. A
    /// name that resolves becomes a tinted template image; anything else is
    /// drawn as text, which is how an emoji gets into the menu bar.
    static func symbolImage(named name: String, describedAs description: String) -> NSImage? {
        guard !name.isEmpty else { return nil }
        guard let image = NSImage(
            systemSymbolName: name, accessibilityDescription: description
        ) else { return nil }
        image.isTemplate = true
        return image
    }

    /// The literal glyph an entry contributes, or nil when its icon is a
    /// symbol (or absent).
    static func textGlyph(for entry: MenuBarEntry) -> String? {
        guard let override = entry.iconOverride, !override.isEmpty else { return nil }
        return symbolImage(named: override, describedAs: entry.name) == nil ? override : nil
    }

    /// The shared strip is text only — one cell per widget, separated by a
    /// middle dot. SF Symbol icons belong to the separate items, where AppKit
    /// tints a template image for free; an emoji is text, so it is drawn here
    /// like any other characters.
    ///
    /// Colors stay dynamic (`labelColor` and friends) so the menu bar resolves
    /// them for its own appearance at draw time. Stale entries drop to the
    /// tertiary color: a frozen reading must not pass for a live one.
    static func attributedStrip(_ entries: [MenuBarEntry]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for entry in entries {
            let cell = MenuBarPolicy.stripCell(entry, glyph: textGlyph(for: entry))
            guard !cell.isEmpty else { continue }
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
                string: cell,
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
            // The override wins over the widget's own symbol, and an empty
            // override means the user asked for no icon at all.
            let symbol: String? = entry.iconOverride.map { $0.isEmpty ? nil : $0 }
                ?? entry.symbol
            button.image = symbol.flatMap {
                Self.symbolImage(named: $0, describedAs: entry.name)
            }
            let label = MenuBarPolicy.stripCell(
                entry, glyph: button.image == nil ? Self.textGlyph(for: entry) : nil
            )
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
