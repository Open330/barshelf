import Combine
import Foundation
import MenubucketCore

/// App-wide preferences stored under Application Support. Kept separate from
/// per-widget `WidgetPrefs` so global scheduling/status-item settings can be
/// observed by the app shell.
final class AppPrefs: ObservableObject {
    static let shared = AppPrefs()

    static var defaultFileURL: URL {
        WidgetRuntime.applicationSupportDirectory
            .appendingPathComponent("app-prefs.json")
    }

    @Published private(set) var preferences: AppPreferences {
        didSet { save() }
    }
    @Published private(set) var lastError: String?

    private let fileURL: URL

    init(fileURL: URL = AppPrefs.defaultFileURL) {
        self.fileURL = fileURL
        self.preferences = AppPreferences.load(from: fileURL)
    }

    func update(_ change: (inout AppPreferences) -> Void) {
        var copy = preferences
        change(&copy)
        copy = AppPreferences(
            menuBarSymbol: copy.menuBarSymbol,
            refreshMultiplier: copy.refreshMultiplier,
            pauseWhenClosed: copy.pauseWhenClosed,
            launchAtLogin: copy.launchAtLogin
        )
        preferences = copy
    }

    private func save() {
        do {
            var normalized = preferences
            normalized.refreshMultiplier = SchedulePolicy.normalizedRefreshMultiplier(
                normalized.refreshMultiplier
            )
            try normalized.save(to: fileURL)
            lastError = nil
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }
}
