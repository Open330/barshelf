import Foundation
import MenubucketCore
import Security
import WidgetKit

/// Keeps the macOS widget extension's view of BarShelf current (R14): the
/// list of widgets it may show and each one's last render, written into the
/// shared App Group container, and a nudge to WidgetKit when they change.
///
/// Inert in builds that do not carry the App Group entitlement (ad-hoc dev
/// builds): touching a group container without it would make macOS ask the
/// user for access to "data from other apps".
///
/// Used from the main thread only, like the runtime that owns it.
final class SharedShelfPublisher {
    /// macOS budgets widget reloads (roughly 40–70 a day). Changes inside the
    /// window are folded into one reload at its end.
    static let minimumReloadInterval: TimeInterval = 15 * 60

    private let container: URL?
    private var lastReload: Date?
    private var pendingReload: DispatchWorkItem?
    private var lastIndex: SharedShelf.Index?

    init(container: URL? = SharedShelfPublisher.entitledContainer()) {
        self.container = container
    }

    var isEnabled: Bool { container != nil }

    /// The list a user picks from when configuring a widget. Returns whether
    /// it changed.
    @discardableResult
    func publishIndex(_ entries: [SharedShelf.Entry]) -> Bool {
        guard let container else { return false }
        let index = SharedShelf.Index(entries: entries)
        guard index != lastIndex else { return false }
        lastIndex = index
        do {
            try SharedShelf.writeIndex(index, to: container)
            SharedShelf.pruneSnapshots(keeping: Set(entries.map(\.id)), in: container)
        } catch {
            NSLog("barshelf: could not write the widget index: \(error)")
        }
        return true
    }

    func publish(_ snapshot: SharedShelf.Snapshot) {
        guard let container else { return }
        do {
            try SharedShelf.writeSnapshot(snapshot, to: container)
            scheduleReload()
        } catch {
            NSLog("barshelf: could not share \(snapshot.widgetID) with widgets: \(error)")
        }
    }

    /// Takes a widget out of the shared folder at once — for one that turned
    /// out to be sensitive.
    func withdraw(widgetID: String) {
        guard let container else { return }
        SharedShelf.removeSnapshot(widgetID: widgetID, from: container)
        scheduleReload()
    }

    private func scheduleReload(now: Date = Date()) {
        guard pendingReload == nil else { return }
        let wait = Self.reloadDelay(lastReload: lastReload, now: now)
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingReload = nil
            self.lastReload = Date()
            WidgetCenter.shared.reloadTimelines(ofKind: SharedShelf.widgetKind)
        }
        pendingReload = item
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: item)
    }

    /// How long to wait before the next reload: none if the last was long
    /// enough ago, otherwise until the window closes.
    static func reloadDelay(lastReload: Date?, now: Date) -> TimeInterval {
        guard let lastReload else { return 0 }
        return max(0, minimumReloadInterval - now.timeIntervalSince(lastReload))
    }

    /// The group container, when this copy of BarShelf is signed with the
    /// App Group entitlement; nil otherwise.
    static func entitledContainer() -> URL? {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(
                task, "com.apple.security.application-groups" as CFString, nil
              ),
              let groups = value as? [String],
              groups.contains(SharedShelf.appGroupID)
        else { return nil }
        return FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: SharedShelf.appGroupID
        )
    }
}
