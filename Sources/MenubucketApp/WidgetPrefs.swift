import Foundation
import MenubucketCore

/// User-scoped widget preferences: pinned widget ids and per-widget settings
/// overrides. Persisted as one JSON file in Application Support.
final class WidgetPrefs: ObservableObject {
    @Published private(set) var pinned: [String] = []
    @Published private(set) var settings: [String: [String: JSONValue]] = [:]
    /// True between first-run starter seeding and the user dismissing the
    /// one-time welcome card (R07 onboarding).
    @Published private(set) var welcomePending: Bool = false

    private let fileURL: URL

    private struct Persisted: Codable {
        var pinned: [String]
        var settings: [String: [String: JSONValue]]
        /// Optional for backward compatibility with pre-R07 prefs files.
        var welcomePending: Bool?
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
    }

    private func save() {
        let persisted = Persisted(
            pinned: pinned, settings: settings, welcomePending: welcomePending
        )
        guard let data = try? JSONEncoder().encode(persisted) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
    }
}
