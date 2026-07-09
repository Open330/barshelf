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

    /// Erases every stored trace of a widget — used by `removeWidget`.
    func removeAllState(for id: String) {
        var changed = false
        if let index = pinned.firstIndex(of: id) { pinned.remove(at: index); changed = true }
        if settings.removeValue(forKey: id) != nil { changed = true }
        if bucketOverrides.removeValue(forKey: id) != nil { changed = true }
        if disabled.remove(id) != nil { changed = true }
        if appearanceOverrides.removeValue(forKey: id) != nil { changed = true }
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
    func effectiveAppearance(for manifest: Manifest) -> WidgetAppearance {
        let neutral = WidgetAppearance()
        let base = (manifest.appearance ?? neutral).merged(over: neutral)
        guard let override = appearanceOverrides[manifest.id] else { return base }
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
    func effectiveSettings(for manifest: Manifest) -> JSONValue {
        var merged = manifest.settingsDefaults().objectValue ?? [:]
        for (key, value) in settings(for: manifest.id) {
            merged[key] = value
        }
        return .object(merged)
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let persisted = try? JSONDecoder().decode(Persisted.self, from: data) else { return }
        pinned = persisted.pinned
        settings = persisted.settings
        welcomePending = persisted.welcomePending ?? false
        disabled = Set(persisted.disabled ?? [])
        bucketOverrides = persisted.bucketOverrides ?? [:]
        appearanceOverrides = persisted.appearanceOverrides ?? [:]
        groupOrder = persisted.groupOrder ?? [:]
    }

    private func save() {
        let persisted = Persisted(
            pinned: pinned, settings: settings, welcomePending: welcomePending,
            disabled: disabled.isEmpty ? nil : disabled.sorted(),
            bucketOverrides: bucketOverrides.isEmpty ? nil : bucketOverrides,
            appearanceOverrides: appearanceOverrides.isEmpty ? nil : appearanceOverrides,
            groupOrder: groupOrder.isEmpty ? nil : groupOrder
        )
        guard let data = try? JSONEncoder().encode(persisted) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
    }
}
