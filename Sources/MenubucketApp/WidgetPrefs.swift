import Foundation
import MenubucketCore

/// A user override of a widget's manifest bucket placement. Absent fields keep
/// the manifest value; both nil means "no override" (the entry is dropped).
struct BucketOverride: Codable, Equatable {
    var group: String?
    var order: Double?
    var size: String?

    init(group: String? = nil, order: Double? = nil, size: String? = nil) {
        self.group = group
        self.order = order
        self.size = size
    }

    private enum CodingKeys: String, CodingKey { case group, order, size }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        group = c.lenient(String.self, forKey: .group)
        order = c.lenient(Double.self, forKey: .order)
        size = c.lenient(String.self, forKey: .size)
    }
}

/// User-scoped widget preferences: pinned widget ids and per-widget settings
/// overrides. Persisted as one JSON file in Application Support.
final class WidgetPrefs: ObservableObject {
    @Published private(set) var pinned: [String] = []
    @Published private(set) var settings: [String: [String: JSONValue]] = [:]
    /// True between first-run starter seeding and the user dismissing the
    /// one-time welcome card (R07 onboarding).
    @Published private(set) var welcomePending: Bool = false
    /// Widget ids hidden from the popup and never scheduled/refreshed (R11).
    @Published private(set) var disabled: Set<String> = []
    /// User overrides of manifest bucket placement, keyed by widget id (R11).
    @Published private(set) var bucketOverrides: [String: BucketOverride] = [:]
    /// User theming overrides, keyed by widget id (R12).
    @Published private(set) var appearanceOverrides: [String: WidgetAppearance] = [:]
    /// Explicit panel/group display order (0-based index per group name). Empty
    /// means "no manual order" — groups fall back to member order then name.
    @Published private(set) var groupOrder: [String: Double] = [:]
    /// Pages the user made by name. A page is otherwise only the name its
    /// widgets share, so it vanishes once empty; these stay, and an empty one
    /// shows an "add a widget here" card in its place.
    @Published private(set) var keptPages: [String] = []
    /// Menu-bar promotion, keyed by widget id. A widget with no entry falls
    /// back to its manifest's `statusItem.mode`.
    @Published private(set) var menuBarPlacements: [String: MenuBarPlacement] = [:]
    /// Cadence overrides for every surface; menu bar overrides take precedence.
    @Published private(set) var refreshIntervals: [String: Double] = [:]

    private let fileURL: URL

    private struct Persisted: Codable {
        var pinned: [String]
        var settings: [String: [String: JSONValue]]
        /// Optional for backward compatibility with pre-R07 prefs files.
        var welcomePending: Bool?
        /// Optional for backward compatibility with pre-R11 prefs files.
        var disabled: [String]?
        var bucketOverrides: [String: BucketOverride]?
        /// Optional for backward compatibility with pre-R12 prefs files.
        var appearanceOverrides: [String: WidgetAppearance]?
        var groupOrder: [String: Double]?
        var keptPages: [String]?
        /// Optional for backward compatibility with pre-menu-bar prefs files.
        var menuBarPlacements: [String: MenuBarPlacement]?
        var refreshIntervals: [String: Double]?

        init(
            pinned: [String], settings: [String: [String: JSONValue]], welcomePending: Bool?,
            disabled: [String]?, bucketOverrides: [String: BucketOverride]?,
            appearanceOverrides: [String: WidgetAppearance]?, groupOrder: [String: Double]?,
            keptPages: [String]?, menuBarPlacements: [String: MenuBarPlacement]?,
            refreshIntervals: [String: Double]?
        ) {
            self.pinned = pinned
            self.settings = settings
            self.welcomePending = welcomePending
            self.disabled = disabled
            self.bucketOverrides = bucketOverrides
            self.appearanceOverrides = appearanceOverrides
            self.groupOrder = groupOrder
            self.keptPages = keptPages
            self.menuBarPlacements = menuBarPlacements
            self.refreshIntervals = refreshIntervals
        }

        private enum CodingKeys: String, CodingKey {
            case pinned, settings, welcomePending, disabled, bucketOverrides
            case appearanceOverrides, groupOrder, keptPages, menuBarPlacements, refreshIntervals
        }

        /// Field by field and entry by entry: a value this build cannot read
        /// (one written by a newer build, say) costs that value, never the
        /// user's pins, pages and settings with it.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            pinned = c.lenientArray(String.self, forKey: .pinned) ?? []
            settings = (c.lenientDictionary(JSONValue.self, forKey: .settings) ?? [:])
                .compactMapValues(\.objectValue)
            welcomePending = c.lenient(Bool.self, forKey: .welcomePending)
            disabled = c.lenientArray(String.self, forKey: .disabled)
            bucketOverrides = c.lenientDictionary(BucketOverride.self, forKey: .bucketOverrides)
            appearanceOverrides = c.lenientDictionary(WidgetAppearance.self, forKey: .appearanceOverrides)
            groupOrder = c.lenientDictionary(Double.self, forKey: .groupOrder)
            keptPages = c.lenientArray(String.self, forKey: .keptPages)
            menuBarPlacements = c.lenientDictionary(MenuBarPlacement.self, forKey: .menuBarPlacements)
            refreshIntervals = c.lenientDictionary(Double.self, forKey: .refreshIntervals)
        }
    }

    func setRefreshInterval(_ interval: Double?, for id: String) {
        let normalized = interval.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        guard refreshIntervals[id] != normalized else { return }
        refreshIntervals[id] = normalized
        save()
    }

    // MARK: - Group order

    func groupSortKey(_ group: String) -> Double? { groupOrder[group] }

    /// Assigns 0-based ordering indices to the given groups (top → bottom).
    func setGroupsOrder(_ orderedGroups: [String]) {
        var map: [String: Double] = [:]
        for (index, group) in orderedGroups.enumerated() { map[group] = Double(index) }
        guard map != groupOrder else { return }
        groupOrder = map
        save()
    }

    /// Default pages bundled widgets used to start on, and what they are
    /// called now. A renamed page keeps the place the user gave the old one.
    static let renamedPages = ["Demo": "Everyday"]

    /// Moves a renamed page's place (and its "kept" mark) to its new name
    /// once no widget is on the old one, unless the new name has its own.
    /// Returns true when something changed.
    @discardableResult
    func migrateRenamedPages(inUse groups: Set<String>) -> Bool {
        var order = groupOrder
        var kept = keptPages
        for (old, new) in Self.renamedPages where !groups.contains(old) {
            if let key = order.removeValue(forKey: old), order[new] == nil { order[new] = key }
            if let index = kept.firstIndex(of: old) {
                kept.remove(at: index)
                if !kept.contains(new) { kept.append(new) }
            }
        }
        guard order != groupOrder || kept != keptPages else { return false }
        groupOrder = order
        keptPages = kept
        save()
        return true
    }

    // MARK: - Kept pages

    func isKeptPage(_ name: String) -> Bool { keptPages.contains(name) }

    func setKeptPages(_ names: [String]) {
        var seen: Set<String> = []
        let unique = names.filter { !$0.isEmpty && seen.insert($0).inserted }
        guard unique != keptPages else { return }
        keptPages = unique
        save()
    }

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("barshelf/prefs.json")
        load()
    }

    // MARK: - Pins

    func isPinned(_ widgetID: String) -> Bool {
        pinned.contains(widgetID)
    }

    func togglePin(_ widgetID: String) {
        if let index = pinned.firstIndex(of: widgetID) {
            pinned.remove(at: index)
        } else {
            pinned.append(widgetID)
        }
        save()
    }

    // MARK: - Welcome card (first-run onboarding)

    /// Armed by the runtime right after starter widgets were seeded.
    func markWelcomePending() {
        guard !welcomePending else { return }
        welcomePending = true
        save()
    }

    /// The card's close button — the card never comes back.
    func dismissWelcome() {
        guard welcomePending else { return }
        welcomePending = false
        save()
    }

    // MARK: - Disabled widgets (R11)

    func isDisabled(_ id: String) -> Bool {
        disabled.contains(id)
    }

    func setDisabled(_ id: String, _ flag: Bool) {
        let changed = flag ? disabled.insert(id).inserted : (disabled.remove(id) != nil)
        guard changed else { return }
        save()
    }

    // MARK: - Bucket overrides (R11)

    func override(for id: String) -> BucketOverride? {
        bucketOverrides[id]
    }

    /// Stores a placement override; passing both fields nil clears the entry.
    func setOverride(group: String?, order: Double?, size: String? = nil, for id: String) {
        if group == nil, order == nil, size == nil {
            guard bucketOverrides.removeValue(forKey: id) != nil else { return }
        } else {
            let override = BucketOverride(group: group, order: order, size: size)
            guard bucketOverrides[id] != override else { return }
            bucketOverrides[id] = override
        }
        save()
    }

    /// Where every widget sits: its page, order, size, and whether it is on.
    /// Captured before a layout change so the change can be undone whole.
    struct LayoutState: Equatable {
        var overrides: [String: BucketOverride]
        var groupOrder: [String: Double]
        var disabled: Set<String>
        var keptPages: [String] = []
    }

    var layoutState: LayoutState {
        LayoutState(overrides: bucketOverrides, groupOrder: groupOrder, disabled: disabled, keptPages: keptPages)
    }

    func restoreLayout(_ state: LayoutState) {
        guard state != layoutState else { return }
        bucketOverrides = state.overrides
        groupOrder = state.groupOrder
        disabled = state.disabled
        keptPages = state.keptPages
        save()
    }

    /// Runs `change` as one undo step: ⌘Z puts every widget back where it
    /// was and ⇧⌘Z does it again. `restored` runs after either, so whoever
    /// shows the layout can redraw it.
    func changeLayout(
        _ name: String, undoManager: UndoManager?, _ change: () -> Void,
        restored: @escaping () -> Void = {}
    ) {
        let before = layoutState
        change()
        registerLayoutUndo(name, back: before, undoManager: undoManager, restored: restored)
    }

    private func registerLayoutUndo(
        _ name: String, back target: LayoutState, undoManager: UndoManager?,
        restored: @escaping () -> Void
    ) {
        guard let undoManager, layoutState != target else { return }
        undoManager.registerUndo(withTarget: self) { prefs in
            let now = prefs.layoutState
            prefs.restoreLayout(target)
            restored()
            // Registered while undoing, so it becomes the redo (and back).
            prefs.registerLayoutUndo(name, back: now, undoManager: undoManager, restored: restored)
        }
        undoManager.setActionName(name)
    }

    /// Erases every stored trace of a widget — used by `removeWidget`.
    func removeAllState(for id: String) {
        var changed = false
        if let index = pinned.firstIndex(of: id) { pinned.remove(at: index); changed = true }
        if settings.removeValue(forKey: id) != nil { changed = true }
        if bucketOverrides.removeValue(forKey: id) != nil { changed = true }
        if disabled.remove(id) != nil { changed = true }
        if appearanceOverrides.removeValue(forKey: id) != nil { changed = true }
        if menuBarPlacements.removeValue(forKey: id) != nil { changed = true }
        if refreshIntervals.removeValue(forKey: id) != nil { changed = true }
        if changed { save() }
    }

    // MARK: - Menu bar promotion

    /// Effective placement: the user's stored choice, else the author's
    /// `statusItem.mode`.
    func menuBarPlacement(
        for manifest: Manifest,
        widgetID: String? = nil
    ) -> MenuBarPlacement {
        MenuBarPolicy.resolvedPlacement(
            stored: menuBarPlacements[widgetID ?? manifest.id],
            statusItem: manifest.statusItem
        )
    }

    /// Stores an explicit placement. Passing `nil` clears the override so the
    /// widget follows its manifest again.
    func setMenuBarPlacement(_ placement: MenuBarPlacement?, for id: String) {
        if let placement {
            guard menuBarPlacements[id] != placement else { return }
            menuBarPlacements[id] = placement
        } else {
            guard menuBarPlacements.removeValue(forKey: id) != nil else { return }
        }
        save()
    }

    /// Several placements in one write; nil clears one, as above.
    func setMenuBarPlacements(_ changes: [String: MenuBarPlacement?]) {
        var changed = false
        for (id, placement) in changes {
            if let placement {
                guard menuBarPlacements[id] != placement else { continue }
                menuBarPlacements[id] = placement
            } else {
                guard menuBarPlacements.removeValue(forKey: id) != nil else { continue }
            }
            changed = true
        }
        if changed { save() }
    }

    // MARK: - Appearance overrides (R12)

    /// The user's stored theming override for a widget, if any.
    func appearanceOverride(for id: String) -> WidgetAppearance? {
        appearanceOverrides[id]
    }

    /// Stores a theming override; passing `nil` or an all-nil (neutral)
    /// appearance clears the entry so the widget reverts to its author default.
    func setAppearanceOverride(_ appearance: WidgetAppearance?, for id: String) {
        if let appearance, appearance != WidgetAppearance() {
            guard appearanceOverrides[id] != appearance else { return }
            appearanceOverrides[id] = appearance
        } else {
            guard appearanceOverrides.removeValue(forKey: id) != nil else { return }
        }
        save()
    }

    /// Effective theming = user override merged over the manifest's author
    /// default merged over the neutral baseline.
    static let builderWidgetPrefix = "dev.barshelf.user."

    /// The widget's look before any user override: its manifest over neutral.
    ///
    /// Builder widgets made before the card header was on by default draw
    /// their own name/icon row and say nothing about the header. Showing the
    /// card header too would print the name twice. The builder now writes
    /// `showHeader` either way, so only those older ones match.
    static func baseAppearance(for manifest: Manifest) -> WidgetAppearance {
        let neutral = WidgetAppearance()
        var base = (manifest.appearance ?? neutral).merged(over: neutral)
        if base.showHeader == nil, manifest.id.hasPrefix(builderWidgetPrefix) {
            base.showHeader = false
        }
        return base
    }

    func effectiveAppearance(
        for manifest: Manifest,
        widgetID: String? = nil
    ) -> WidgetAppearance {
        let base = Self.baseAppearance(for: manifest)
        guard let override = appearanceOverrides[widgetID ?? manifest.id] else { return base }
        return override.merged(over: base)
    }

    // MARK: - Settings overrides

    func settings(for widgetID: String) -> [String: JSONValue] {
        settings[widgetID] ?? [:]
    }

    func setSetting(widgetID: String, key: String, value: JSONValue?) {
        var overrides = settings[widgetID] ?? [:]
        overrides[key] = value
        if value == nil { overrides.removeValue(forKey: key) }
        settings[widgetID] = overrides.isEmpty ? nil : overrides
        save()
    }

    /// Manifest defaults overlaid with the user's stored values.
    func effectiveSettings(
        for manifest: Manifest,
        widgetID: String? = nil
    ) -> JSONValue {
        var merged = manifest.settingsDefaults().objectValue ?? [:]
        for (key, value) in settings(for: widgetID ?? manifest.id) {
            merged[key] = value
        }
        return .object(merged)
    }

    // MARK: - Persistence

    private func load() {
        // A file that cannot be read at all is moved aside before the
        // defaults below are ever saved over it.
        guard let persisted = JSONFile.load(Persisted.self, from: fileURL) else { return }
        pinned = persisted.pinned
        settings = persisted.settings
        welcomePending = persisted.welcomePending ?? false
        disabled = Set(persisted.disabled ?? [])
        bucketOverrides = persisted.bucketOverrides ?? [:]
        appearanceOverrides = persisted.appearanceOverrides ?? [:]
        groupOrder = persisted.groupOrder ?? [:]
        keptPages = persisted.keptPages ?? []
        menuBarPlacements = persisted.menuBarPlacements ?? [:]
        refreshIntervals = (persisted.refreshIntervals ?? [:]).filter { $0.value.isFinite && $0.value > 0 }
    }

    private func save() {
        let persisted = Persisted(
            pinned: pinned, settings: settings, welcomePending: welcomePending,
            disabled: disabled.isEmpty ? nil : disabled.sorted(),
            bucketOverrides: bucketOverrides.isEmpty ? nil : bucketOverrides,
            appearanceOverrides: appearanceOverrides.isEmpty ? nil : appearanceOverrides,
            groupOrder: groupOrder.isEmpty ? nil : groupOrder,
            keptPages: keptPages.isEmpty ? nil : keptPages,
            menuBarPlacements: menuBarPlacements.isEmpty ? nil : menuBarPlacements,
            refreshIntervals: refreshIntervals.isEmpty ? nil : refreshIntervals
        )
        JSONFile.save(persisted, to: fileURL)
    }
}
