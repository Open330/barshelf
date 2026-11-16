import Combine
import Foundation
import MenubucketCore

/// Per-widget observable state: only the card whose snapshot/overlay changed
/// re-renders (R05 perf) — `WidgetRuntime.objectWillChange` no longer fires on
/// snapshot updates, so one widget refreshing does not invalidate the whole
/// popup view tree.
final class WidgetCardModel: ObservableObject {
    @Published fileprivate(set) var snapshot: WidgetSnapshot
    @Published fileprivate(set) var overlay: CardOverlay?

    fileprivate init(snapshot: WidgetSnapshot, overlay: CardOverlay?) {
        self.snapshot = snapshot
        self.overlay = overlay
    }
}

/// The runtime's side of the store: whether a snapshot may be written at
/// all, and where a change goes.
@MainActor
protocol SnapshotStoreHost: AnyObject {
    /// False while a staged preview is showing and is not itself writing:
    /// the snapshots are then left exactly as staged.
    var acceptsSnapshotWrites: Bool { get }
    /// The widget's snapshot changed from `previous` (nil: it had none) to
    /// `snapshot`. Called once per change, after the store holds the new
    /// value and the widget's card model has published it.
    func snapshotDidChange(widgetID: String, from previous: WidgetSnapshot?, to snapshot: WidgetSnapshot)
}

/// The renders: owns each widget's current snapshot and the card model the
/// popup observes for it. Every change to a snapshot goes through one write
/// path, which publishes to that widget's card model only and reports to
/// the host only when the snapshot differs.
///
/// Main-actor isolated, like the runtime it reports to.
@MainActor
final class SnapshotStore {
    /// The runtime. Weak: the runtime owns the store. With none, writes
    /// land and nobody is told.
    weak var host: SnapshotStoreHost?

    /// Source of truth for renders. Deliberately not published: updates
    /// are routed to the affected widget's `WidgetCardModel` only (publish
    /// suppressed when the snapshot is unchanged, `Equatable`).
    private(set) var snapshots: [String: WidgetSnapshot] = [:]
    private var cardModels: [String: WidgetCardModel] = [:]

    // MARK: - Card models

    /// The card model the popup UI observes for this widget. Created lazily so
    /// closed-popup refreshes don't allocate view models; a new one starts
    /// from the widget's snapshot and `overlay`, the card it shows now.
    func cardModel(for widgetID: String, overlay: CardOverlay?) -> WidgetCardModel {
        if let existing = cardModels[widgetID] { return existing }
        let model = WidgetCardModel(
            snapshot: snapshots[widgetID] ?? WidgetSnapshot(widgetID: widgetID),
            overlay: overlay
        )
        cardModels[widgetID] = model
        return model
    }

    /// The widget's host-generated card changed (nil: its own content
    /// again): its card model, if anyone asked for one, publishes it.
    func setOverlay(_ overlay: CardOverlay?, for widgetID: String) {
        cardModels[widgetID]?.overlay = overlay
    }

    // MARK: - Snapshots

    /// Single write path for snapshots: no-op (publish suppressed) when the
    /// snapshot is unchanged; otherwise only the affected card model publishes.
    func set(_ snapshot: WidgetSnapshot, for id: String) {
        // A staged preview shows only what was staged.
        if let host, !host.acceptsSnapshotWrites { return }
        guard snapshots[id] != snapshot else { return }
        let previous = snapshots[id]
        snapshots[id] = snapshot
        cardModels[id]?.snapshot = snapshot
        host?.snapshotDidChange(widgetID: id, from: previous, to: snapshot)
    }

    /// Changes the widget's snapshot in place, starting from an empty one
    /// when it has none.
    func update(_ id: String, mutate: (inout WidgetSnapshot) -> Void) {
        var snapshot = snapshots[id] ?? WidgetSnapshot(widgetID: id)
        mutate(&snapshot)
        set(snapshot, for: id)
    }

    // MARK: - Housekeeping

    /// Drops the snapshots and card models of widgets that are gone. Not a
    /// write: the host is not told, and a staged preview does not hold it
    /// back.
    func forget(notIn liveIDs: Set<String>) {
        snapshots = snapshots.filter { liveIDs.contains($0.key) }
        cardModels = cardModels.filter { liveIDs.contains($0.key) }
    }
}
