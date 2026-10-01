import SwiftUI
import UniformTypeIdentifiers

private struct ShelfEditingKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True while the shelf is in edit mode (`PagerState.isEditing`): cards
    /// show their drag handle, width and remove controls, and their content
    /// stops taking clicks so a drag never presses a widget's button.
    var shelfIsEditing: Bool {
        get { self[ShelfEditingKey.self] }
        set { self[ShelfEditingKey.self] = newValue }
    }
}

/// Where a card is drawn, which decides which of its controls make sense.
enum CardPlacement {
    /// On a shelf page: every control, including reorder and page moves.
    case shelf
    /// Alone, from its own menu bar item: nothing about pages or pins.
    case single
}

/// Pinning rules. The pinned strip above the pages has room for two compact
/// cards; a third would push the pages themselves off the popup.
enum PinnedShelf {
    static let capacity = 2

    /// Pinned widgets that are actually shown: enabled, in pin order, capped.
    static func displayedIDs(pinned: [String], enabledIDs: Set<String>) -> [String] {
        Array(pinned.filter(enabledIDs.contains).prefix(capacity))
    }

    /// Pinned and enabled, beyond the cap. Only reachable through older
    /// preferences or a duplicated pinned widget, since Pin is disabled at
    /// the cap — but those exist, so they are still accounted for.
    static func overflowIDs(pinned: [String], enabledIDs: Set<String>) -> [String] {
        Array(pinned.filter(enabledIDs.contains).dropFirst(capacity))
    }

    /// Whether `id` can be pinned right now (always true for an unpin).
    static func canPin(_ id: String, pinned: [String], enabledIDs: Set<String>) -> Bool {
        pinned.contains(id) || pinned.filter(enabledIDs.contains).count < capacity
    }
}

extension WidgetRuntime {
    /// Ids of widgets currently on a page (enabled).
    var enabledWidgetIDs: Set<String> {
        Set(widgets.filter { !prefs.isDisabled($0.id) }.map(\.id))
    }

    func canPin(_ id: String) -> Bool {
        PinnedShelf.canPin(id, pinned: prefs.pinned, enabledIDs: enabledWidgetIDs)
    }
}

/// The pasteboard type a dragged card carries: its widget id as plain text,
/// which is what card and page-dot drop targets read.
enum CardDrag {
    static let types: [UTType] = [.plainText]

    static func provider(for widgetID: String) -> NSItemProvider {
        NSItemProvider(object: widgetID as NSString)
    }

    /// Reads the dragged widget id and hands it over on the main queue.
    static func receive(_ providers: [NSItemProvider], perform: @escaping (String) -> Void) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let id = object as? String else { return }
            DispatchQueue.main.async { perform(id) }
        }
        return true
    }
}
