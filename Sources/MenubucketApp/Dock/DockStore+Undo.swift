import BarShelfDock
import Foundation
import MenubucketCore

// The store itself lives in BarShelfDock, which has no views; the toast that
// offers Undo is the app's.
extension DockStore {
    /// Removes an item and offers Undo on `surface` for a few seconds: the
    /// Dock has no Edit menu to undo from, and a dragged-out icon is easy to
    /// lose by accident.
    @MainActor
    func removeItemOfferingUndo(_ item: DockItem, profileID: String? = nil, surface: ToastSurface) {
        guard let removed = removeItem(item.id, profileID: profileID) else { return }
        ToastCenter.shared.show(
            String(localized: "Removed \(DockActions.displayName(for: item)) from the Dock"),
            on: surface,
            action: Toast.Action(title: String(localized: "Undo")) { [weak self] in self?.restoreItem(removed) }
        )
    }
}
