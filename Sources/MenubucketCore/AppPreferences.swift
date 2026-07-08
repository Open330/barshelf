import Foundation

/// App-level preferences persisted at
/// `~/Library/Application Support/menubucket/app-prefs.json` (R08 contract C3).
///
/// Pure Codable model (UI-free, unit-testable). The app-side `AppPrefs`
/// ObservableObject wraps this for live updates; missing keys decode to their
/// defaults so files written by older builds keep loading.
public struct AppPreferences: Codable, Equatable, Sendable {
    /// SF Symbol shown in the menu bar status item.
    public var menuBarSymbol: String
    /// Global refresh multiplier (0.5 / 1 / 2 / 4) applied to every widget's
    /// `interval` and `staleAfter` judgment.
    public var refreshMultiplier: Double
    /// Battery saver: while the popup is closed *all* scheduling stops,
    /// `runInBackground` widgets included.
    public var pauseWhenClosed: Bool
    /// `SMAppService.mainApp` registration mirror.
    public var launchAtLogin: Bool

    public static let defaultMenuBarSymbol = "tray.full"

    public init(
        menuBarSymbol: String = AppPreferences.defaultMenuBarSymbol,
        refreshMultiplier: Double = 1,
        pauseWhenClosed: Bool = false,
        launchAtLogin: Bool = false
    ) {
        let symbol = menuBarSymbol.trimmingCharacters(in: .whitespacesAndNewlines)
        self.menuBarSymbol = symbol.isEmpty ? Self.defaultMenuBarSymbol : symbol
        self.refreshMultiplier = SchedulePolicy.normalizedRefreshMultiplier(refreshMultiplier)
        self.pauseWhenClosed = pauseWhenClosed
        self.launchAtLogin = launchAtLogin
    }

    /// Lenient decoding: absent keys fall back to defaults, the multiplier is
    /// snapped to the allowed steps, an empty symbol falls back to the
    /// default (a blank status item would make the app unreachable).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let symbol = try container.decodeIfPresent(
            String.self, forKey: .menuBarSymbol
        )?.trimmingCharacters(in: .whitespacesAndNewlines)
        menuBarSymbol = (symbol?.isEmpty == false)
            ? symbol! : Self.defaultMenuBarSymbol
        refreshMultiplier = SchedulePolicy.normalizedRefreshMultiplier(
            try container.decodeIfPresent(Double.self, forKey: .refreshMultiplier) ?? 1
        )
        pauseWhenClosed = try container.decodeIfPresent(
            Bool.self, forKey: .pauseWhenClosed
        ) ?? false
        launchAtLogin = try container.decodeIfPresent(
            Bool.self, forKey: .launchAtLogin
        ) ?? false
    }

    // MARK: - File persistence

    public static func load(from fileURL: URL) -> AppPreferences {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(AppPreferences.self, from: data)
        else { return AppPreferences() }
        return decoded
    }

    /// Best-effort atomic write (creates the parent directory).
    public func save(to fileURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
    }
}
