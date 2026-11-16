import Foundation
import MenubucketCore

/// The runtime's side of removing and duplicating a widget: which widgets
/// are loaded, and the running work and in-memory traces only it can reach.
@MainActor
protocol WidgetLibraryHost: AnyObject {
    /// The widgets loaded now.
    var widgets: [LoadedWidget] { get }
    /// Stops the widget and returns once everything that could still write
    /// its storage or a secret has finished: its native refresh (and the
    /// command it runs), its `run` actions, then the script and its host
    /// commands.
    func stopWidgetAndWaitForItsWork(_ widgetID: String) async
    /// Forgets what the widget's workflow alerts last saw.
    func forgetWorkflowAlerts(widgetID: String)
    /// A removal failed after the widget was stopped: start it again.
    func resumeWidget(_ widgetID: String)
    /// The widget is gone: no queued write may re-create its cached render.
    func forgetCachedSnapshot(widgetID: String)
    /// Rescans the widget directories.
    func reloadWidgets()
}

/// The installed widgets as things on disk: removes one with everything it
/// left behind, and makes a second instance of one. Owns which widgets are
/// in the middle of being removed.
///
/// Main-actor isolated, like the runtime it reports to. Without a host it
/// knows no widgets, so both operations throw `widgetNotFound`.
@MainActor
final class WidgetLibrary {
    /// The runtime. Weak: the runtime owns the library.
    weak var host: WidgetLibraryHost?

    /// The single directory `remove` is allowed to delete inside, and where
    /// `duplicate` puts its link.
    let root: URL
    private let secretStore: SecretStoring
    private let storage: StorageService
    private let prefs: WidgetPrefs
    private let permissionStore: PermissionStore
    /// Widgets `remove` is waiting to stop and purge.
    private var removingWidgetIDs: Set<String> = []

    /// - Parameters:
    ///   - root: Nil is the user widgets root (`WidgetRuntime.userWidgetsRoot`).
    ///   - secretStore: `host.secret.*` values, per widget instance.
    ///   - storage: The widgets' key-value store.
    ///   - prefs: Per-widget preferences: erased on removal, copied to a
    ///     new instance.
    ///   - permissionStore: The packages' permission decisions.
    /// What happens to a folder hidden behind the widget being removed.
    private let discardHiddenFolder: (URL) throws -> Void

    init(
        root: URL? = nil,
        secretStore: SecretStoring,
        storage: StorageService,
        prefs: WidgetPrefs,
        permissionStore: PermissionStore,
        discardHiddenFolder: ((URL) throws -> Void)? = nil
    ) {
        if let discardHiddenFolder {
            self.discardHiddenFolder = discardHiddenFolder
        } else {
            // To the Trash, not deleted: the user never saw this folder, and
            // a hand-made copy may hold edits the loaded one did not.
            self.discardHiddenFolder = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
        }
        if let root {
            self.root = root
        } else {
            self.root = WidgetRuntime.userWidgetsRoot
        }
        self.secretStore = secretStore
        self.storage = storage
        self.prefs = prefs
        self.permissionStore = permissionStore
    }

    // MARK: - Decisions

    /// True only for a proper subdirectory of `root`. Resolving `..` first
    /// refuses path-traversal ids and dev-checkout (`./widgets/`) widgets,
    /// so a removal can never delete outside that root.
    nonisolated static func isRemovable(_ directory: URL, under root: URL) -> Bool {
        let root = root.standardizedFileURL.path
        let target = directory.standardizedFileURL.path
        return target != root && target.hasPrefix(root + "/")
    }

    /// Every folder directly under `root` that discovery would load as
    /// `instanceID`: discovery loads the first and hides the rest (a
    /// hand-copied package folder, say). A `<package id>--<label>` copy is
    /// its own instance and never matches another id; a folder whose
    /// `widget.json` cannot be read matches nothing.
    nonisolated static func folders(holding instanceID: String, in root: URL) -> [URL] {
        let children = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        return children.filter { child in
            guard let data = try? Data(contentsOf: child.appendingPathComponent(WidgetDiscovery.manifestFileName)),
                  let manifest = try? Manifest.decode(from: data) else { return false }
            return WidgetRuntime.instanceID(
                manifestID: manifest.id, directoryName: child.lastPathComponent
            ) == instanceID
        }
    }

    /// The part of an instance id after `<package id>--`: lowercased, runs of
    /// anything but letters, digits, `.`, `_` and `-` collapsed to one `-`,
    /// and no separator at either end. Empty when nothing usable is left.
    nonisolated static func normalizedInstanceLabel(_ label: String) -> String {
        let lowered = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var result = ""
        var previousWasSeparator = false
        for scalar in lowered.unicodeScalars {
            let allowed = CharacterSet.alphanumerics.contains(scalar)
                || scalar == "." || scalar == "_" || scalar == "-"
            if allowed {
                result.unicodeScalars.append(scalar)
                previousWasSeparator = false
            } else if !previousWasSeparator, !result.isEmpty {
                result.append("-")
                previousWasSeparator = true
            }
        }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: "-._"))
    }

    /// Whether `remove` is still stopping or purging the widget. Refresh,
    /// restart, actions and duplicate stay off it until it is gone or the
    /// removal failed.
    func isRemoving(_ widgetID: String) -> Bool {
        removingWidgetIDs.contains(widgetID)
    }

    // MARK: - Remove

    /// Stops the widget, waits for its running work, then deletes its storage,
    /// secrets and directory — with any other folder under the root holding
    /// the same widget, so it cannot reappear — and scrubs every per-widget trace (cached
    /// snapshot, permissions, prefs), then rescans — which drops the
    /// in-memory snapshot, card model, refresh stats, and scheduler timers.
    /// Throws (deleting nothing) for unknown ids or directories outside the
    /// root; throws with the widget still installed when its data cannot be
    /// erased.
    func remove(id: String) async throws {
        guard let host, let widget = host.widgets.first(where: { $0.id == id }) else {
            throw WidgetRuntime.RuntimeError.widgetNotFound(id)
        }
        guard Self.isRemovable(widget.directory, under: root) else {
            throw WidgetRuntime.RuntimeError.notRemovable(
                String(localized: "This widget came with BarShelf or was added from another folder, so it can’t be removed here. Turn it off instead.")
            )
        }
        if id == widget.manifest.id {
            let aliasPrefix = widget.manifest.id + "--"
            let hasInstances = (try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ))?.contains { $0.lastPathComponent.hasPrefix(aliasPrefix) } ?? false
            if hasInstances {
                throw WidgetRuntime.RuntimeError.notRemovable(
                    String(localized: "Remove the copies of “\(widget.manifest.name)” first, then remove the original.")
                )
            }
        }
        // Refresh, restart and duplicate stay off this widget until it is
        // gone or the removal failed.
        guard removingWidgetIDs.insert(id).inserted else {
            throw WidgetRuntime.RuntimeError.notRemovable(
                String(localized: "\"\(widget.manifest.name)\" is already being removed.")
            )
        }
        do {
            // Only once nothing can write the widget's storage or a secret
            // any more is the purge final.
            await host.stopWidgetAndWaitForItsWork(id)
            // Purging before the files go means a failure leaves the widget
            // installed, not reported as removed with its data still on disk.
            try purgeInstanceData(id, host: host)
            // A folder hidden behind the loaded one would take this id over
            // on the rescan, with the settings and decision just erased.
            for hidden in Self.folders(holding: id, in: root)
            where hidden.lastPathComponent != widget.directory.lastPathComponent {
                try discardHiddenFolder(hidden)
            }
            try FileManager.default.removeItem(at: widget.directory)
        } catch {
            removingWidgetIDs.remove(id)
            storage.retain(widgetID: id)
            host.resumeWidget(id) // resume what the stop halted
            throw error
        }
        removingWidgetIDs.remove(id)
        host.forgetCachedSnapshot(widgetID: id)
        // Decisions belong to the package, which other loaded copies still use.
        if !host.widgets.contains(where: { $0.id != id && $0.manifest.id == widget.manifest.id }) {
            permissionStore.reset(widgetId: widget.manifest.id)
        }
        prefs.removeAllState(for: id)
        host.reloadWidgets()
    }

    /// Storage and secrets of exactly this instance; another instance of the
    /// same package keeps its own.
    /// Secrets first: the Keychain is what can refuse (locked, or no user
    /// interaction allowed), and failing there must leave the widget's
    /// storage intact, as the removal error promises.
    private func purgeInstanceData(_ id: String, host: WidgetLibraryHost) throws {
        try secretStore.removeAll(widgetId: id)
        try storage.removeAll(widgetId: id)
        host.forgetWorkflowAlerts(widgetID: id)
    }

    // MARK: - Duplicate

    /// Creates a second independently configurable instance of an installed
    /// widget. A symlink keeps aliases on the canonical package so registry
    /// updates automatically update every instance instead of copying stale
    /// script and manifest files.
    @discardableResult
    func duplicate(id: String, label: String) throws -> String {
        guard let host, let widget = host.widgets.first(where: { $0.id == id }) else {
            throw WidgetRuntime.RuntimeError.widgetNotFound(id)
        }
        guard !removingWidgetIDs.contains(id), !removingWidgetIDs.contains(widget.manifest.id) else {
            throw WidgetRuntime.RuntimeError.notRemovable(
                String(localized: "\"\(widget.manifest.name)\" is being removed.")
            )
        }
        guard WidgetDiscovery.isValidWidgetID(widget.manifest.id) else {
            throw WidgetRuntime.RuntimeError.invalidInstanceName(
                String(localized: "This widget can’t be duplicated because its widget ID isn’t valid. The widget’s author needs to fix it.")
            )
        }
        let normalized = Self.normalizedInstanceLabel(label)
        guard !normalized.isEmpty else {
            throw WidgetRuntime.RuntimeError.invalidInstanceName(
                String(localized: "Give the copy a name with at least one letter or number.")
            )
        }

        guard Self.isRemovable(widget.directory, under: root),
              let installed = HeadlessInstaller.installedPackages(in: root)[widget.manifest.id] else {
            throw WidgetRuntime.RuntimeError.notRemovable(
                String(localized: "Install “\(widget.manifest.name)” before making a copy of it.")
            )
        }
        let canonical = installed.directory

        let instanceID = widget.manifest.id + "--" + normalized
        let destination = root.appendingPathComponent(instanceID)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw WidgetRuntime.RuntimeError.invalidInstanceName(
                String(localized: "There’s already a copy named “\(normalized)”. Choose another name.")
            )
        }
        do {
            try FileManager.default.createSymbolicLink(
                at: destination, withDestinationURL: canonical
            )
        } catch {
            throw WidgetRuntime.RuntimeError.invalidInstanceName(
                String(localized: "Couldn’t make the copy “\(normalized)”. \(error.localizedDescription)")
            )
        }

        for (key, value) in prefs.settings(for: id) {
            prefs.setSetting(widgetID: instanceID, key: key, value: value)
        }
        if let appearance = prefs.appearanceOverride(for: id) {
            prefs.setAppearanceOverride(appearance, for: instanceID)
        }
        prefs.setRefreshInterval(prefs.refreshIntervals[id], for: instanceID)
        if let placement = prefs.override(for: id) {
            prefs.setOverride(
                group: placement.group,
                order: placement.order,
                size: placement.size,
                for: instanceID
            )
        }
        if prefs.isPinned(id) {
            prefs.togglePin(instanceID)
        }
        host.reloadWidgets()
        return instanceID
    }
}
