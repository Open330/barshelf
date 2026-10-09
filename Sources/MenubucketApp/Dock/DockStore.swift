import AppKit
import Combine
import MenubucketCore

/// The BarShelf Dock's settings and profiles (R15), and the one place that
/// changes the Apple Dock: hiding it for `replace`, putting it back, and
/// rewriting its layout when a profile carries one.
final class DockStore: ObservableObject {
    static let shared = DockStore()

    static var defaultFileURL: URL {
        WidgetRuntime.applicationSupportDirectory.appendingPathComponent("dock.json")
    }

    static var backupDirectory: URL {
        WidgetRuntime.applicationSupportDirectory.appendingPathComponent("dock-backups", isDirectory: true)
    }

    @Published private(set) var configuration: DockConfiguration
    @Published private(set) var lastError: String?
    /// The profile just switched to, for the dock's brief name banner.
    @Published private(set) var announcedProfile: DockProfile?

    /// Runs after a profile becomes active (popup page, and so on).
    var onProfileActivated: ((DockProfile) -> Void)?

    let appleDock: AppleDock
    private let fileURL: URL
    private var announceTask: Task<Void, Never>?

    init(
        fileURL: URL = DockStore.defaultFileURL,
        appleDock: AppleDock = AppleDock(backupDirectory: DockStore.backupDirectory)
    ) {
        self.fileURL = fileURL
        self.appleDock = appleDock
        var configuration = DockConfiguration.load(from: fileURL)
        // A first dock starts at the Apple Dock's own icon size.
        if !FileManager.default.fileExists(atPath: fileURL.path), let size = appleDock.tileSize {
            configuration.tileSize = size
            configuration.normalize()
        }
        self.configuration = configuration
    }

    var activeProfile: DockProfile { configuration.activeProfile }

    // MARK: Editing

    /// Applies an edit, saves it, and carries out what a mode change means
    /// for the Apple Dock.
    func update(_ change: (inout DockConfiguration) -> Void) {
        var copy = configuration
        change(&copy)
        copy.normalize()
        let oldMode = configuration.mode
        configuration = copy
        if oldMode != .replace, copy.mode == .replace {
            hideAppleDock()
        } else if oldMode == .replace, copy.mode != .replace {
            restoreAppleDock()
        }
        save()
    }

    func updateProfile(_ id: String, _ change: (inout DockProfile) -> Void) {
        update { config in
            guard let index = config.profiles.firstIndex(where: { $0.id == id }) else { return }
            change(&config.profiles[index])
        }
    }

    /// Adds items to the active profile, before `beforeID` or at the end.
    func addItems(_ items: [DockItem], before beforeID: String? = nil, profileID: String? = nil) {
        guard !items.isEmpty else { return }
        updateProfile(profileID ?? configuration.activeProfileID) { profile in
            let index = beforeID.flatMap { id in profile.items.firstIndex { $0.id == id } } ?? profile.items.count
            profile.items.insert(contentsOf: items, at: index)
        }
    }

    func removeItem(_ itemID: String, profileID: String? = nil) {
        updateProfile(profileID ?? configuration.activeProfileID) { profile in
            profile.items.removeAll { $0.id == itemID }
        }
    }

    /// Moves an item in front of another (or to the end with nil).
    func moveItem(_ itemID: String, before targetID: String?, profileID: String? = nil) {
        guard itemID != targetID else { return }
        updateProfile(profileID ?? configuration.activeProfileID) { profile in
            guard let from = profile.items.firstIndex(where: { $0.id == itemID }) else { return }
            let item = profile.items.remove(at: from)
            let to = targetID.flatMap { id in profile.items.firstIndex { $0.id == id } } ?? profile.items.count
            profile.items.insert(item, at: to)
        }
    }

    func replaceItem(_ item: DockItem, profileID: String? = nil) {
        updateProfile(profileID ?? configuration.activeProfileID) { profile in
            guard let index = profile.items.firstIndex(where: { $0.id == item.id }) else { return }
            profile.items[index] = item
        }
    }

    @discardableResult
    func addProfile(named name: String, copying source: DockProfile? = nil) -> String {
        var profile = DockProfile(name: name)
        if let source {
            profile.symbol = source.symbol
            profile.items = source.items.map { DockItem(kind: $0.kind) }
            profile.appleDock = source.appleDock
            profile.popupPage = source.popupPage
        }
        update { $0.profiles.append(profile) }
        return profile.id
    }

    func removeProfile(_ id: String) {
        let wasActive = configuration.activeProfileID == id
        update { config in
            guard config.profiles.count > 1 else { return }
            config.profiles.removeAll { $0.id == id }
        }
        // The profile that takes over is switched to properly: its Apple
        // Dock layout and popup page, not just its items.
        if wasActive, configuration.activeProfileID != id {
            activate(profileID: configuration.activeProfileID)
        }
    }

    // MARK: Switching

    /// Makes a profile active: the BarShelf Dock shows its items, the Apple
    /// Dock takes its saved layout (when that is turned on), and the popup
    /// moves to its page.
    func activate(profileID: String) {
        guard let profile = configuration.profiles.first(where: { $0.id == profileID }) else { return }
        if configuration.activeProfileID != profileID {
            update { $0.activeProfileID = profileID }
        }
        if configuration.appleDockLayouts, let layout = profile.appleDock {
            appleDock.apply(layout)
        }
        onProfileActivated?(profile)
        announce(profile)
    }

    /// For URLs, the CLI, and Shortcuts: an id, a name, or a 1-based number.
    @discardableResult
    func activate(matching query: String) -> Bool {
        guard let profile = configuration.profile(matching: query) else { return false }
        activate(profileID: profile.id)
        return true
    }

    func activate(offset: Int) {
        guard configuration.profiles.count > 1 else { return }
        activate(profileID: configuration.profile(offsetFromActive: offset).id)
    }

    private func announce(_ profile: DockProfile) {
        announcedProfile = profile
        announceTask?.cancel()
        announceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            guard !Task.isCancelled else { return }
            self?.announcedProfile = nil
        }
    }

    // MARK: Apple Dock layouts

    /// Saves what the Apple Dock shows now into a profile. False when its
    /// layout could not be read; an empty save would unpin everything later.
    @discardableResult
    func captureAppleDock(into profileID: String) -> Bool {
        let layout = appleDock.currentLayout()
        guard !layout.isEmpty else {
            lastError = String(localized: "Couldn't read the Apple Dock's layout, so nothing was saved.")
            return false
        }
        updateProfile(profileID) { $0.appleDock = layout }
        return true
    }

    /// `barshelf dock restore-apple-dock` while BarShelf runs: the app owns
    /// dock.json then, so the CLI asks it instead of editing the file.
    func restoreAppleDockOnRequest() {
        if configuration.mode == .replace {
            update { $0.mode = .alongside }
        } else if configuration.appleDockBackup != nil {
            restoreAppleDock()
            save()
        } else {
            appleDock.unhideWithoutBackup()
        }
    }

    /// Puts a profile's saved layout into the Apple Dock now.
    func applyAppleDockLayout(of profileID: String) {
        guard let layout = configuration.profiles.first(where: { $0.id == profileID })?.appleDock else { return }
        appleDock.apply(layout)
    }

    /// The Apple Dock's apps, folders, and files as BarShelf Dock items.
    func appleDockItems() -> [DockItem] {
        let layout = appleDock.currentLayout()
        func items(_ tiles: [Any]) -> [DockItem] {
            tiles.compactMap { tile in
                if AppleDockTiles.isSpacer(tile) { return DockItem(kind: .spacer) }
                guard let url = AppleDockTiles.fileURL(of: tile) else { return nil }
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return nil }
                return DockItem.forFile(at: url, isDirectory: isDirectory.boolValue)
            }
        }
        let apps = items(layout.appTiles)
        let others = items(layout.otherTiles)
        return others.isEmpty ? apps : apps + [DockItem(kind: .separator)] + others
    }

    /// Follows the Apple Dock's icon size when that is turned on. Its size
    /// changes in System Settings without telling anyone, so this is called
    /// at launch and whenever apps or Spaces change.
    func syncSizeWithAppleDock() {
        guard configuration.matchAppleDockSize, let size = appleDock.tileSize,
              abs(size - configuration.tileSize) >= 0.5 else { return }
        update { $0.tileSize = size }
    }

    // MARK: Hiding the Apple Dock (`replace`)

    private func hideAppleDock() {
        guard let before = appleDock.hide() else { return }
        // Only the first backup counts: it holds the user's own settings.
        if configuration.appleDockBackup == nil {
            configuration.appleDockBackup = before
        }
    }

    private func restoreAppleDock() {
        guard let backup = configuration.appleDockBackup else { return }
        appleDock.restore(backup)
        configuration.appleDockBackup = nil
    }

    /// At launch: `replace` hides the Apple Dock again (it was shown at quit,
    /// or something put it back); anything else restores a backup left
    /// behind by a crash.
    func reconcileAppleDockAtLaunch() {
        let before = configuration
        if configuration.mode == .replace {
            hideAppleDock()
        } else {
            restoreAppleDock()
        }
        // Someone who never opened the Dock page gets no dock.json.
        if configuration != before { save() }
    }

    /// At quit the Apple Dock comes back, so the Mac is never left without a
    /// dock while BarShelf is not running. Launch hides it again.
    func restoreAppleDockForTermination() {
        guard configuration.mode == .replace, configuration.appleDockBackup != nil else { return }
        restoreAppleDock()
        save()
    }

    // MARK: Persistence

    private func save() {
        do {
            try configuration.save(to: fileURL)
            lastError = nil
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
