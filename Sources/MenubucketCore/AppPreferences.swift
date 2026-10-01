import Foundation

/// App-level preferences persisted at
/// `~/Library/Application Support/barshelf/app-prefs.json` (R08 contract C3).
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
    /// Optional audible confirmation after copying; visual feedback is always shown.
    public var copySoundEnabled: Bool
    /// When true a global hotkey toggles the popup (R11). The hotkey itself is
    /// registered app-side; this model only persists the preference.
    public var popupHotkeyEnabled: Bool
    /// Lowercase modifiers + key joined by "+" (e.g. "cmd+shift+b"). Persisted
    /// verbatim; parsing/registration happens app-side.
    public var popupHotkey: String
    /// How every menu bar item looks unless its own settings say otherwise:
    /// width, digits, alignment, text size and weight, colour. Sits
    /// between an item's own choices and the widget's defaults. Only the
    /// style fields are honoured (`MenuBarPolicy.globalStyle`); precision,
    /// ordering and per-row overrides mean something only for one widget.
    public var menuBarPresentation: MenuBarPresentation?
    /// Look for a new release shortly after launch. A manual check from the
    /// menu or Settings works either way.
    public var checkForUpdatesAutomatically: Bool
    /// A release the user chose to skip: the automatic check stays quiet
    /// about it, and speaks up again for anything newer.
    public var skippedUpdateVersion: String?

    public static let defaultMenuBarSymbol = "barshelf.logo"
    public static let defaultPopupHotkey = "cmd+shift+b"

    public init(
        menuBarSymbol: String = AppPreferences.defaultMenuBarSymbol,
        refreshMultiplier: Double = 1,
        pauseWhenClosed: Bool = false,
        launchAtLogin: Bool = false,
        popupHotkeyEnabled: Bool = false,
        popupHotkey: String = AppPreferences.defaultPopupHotkey,
        copySoundEnabled: Bool = false,
        menuBarPresentation: MenuBarPresentation? = nil,
        checkForUpdatesAutomatically: Bool = true,
        skippedUpdateVersion: String? = nil
    ) {
        self.menuBarSymbol = menuBarSymbol
        self.refreshMultiplier = refreshMultiplier
        self.pauseWhenClosed = pauseWhenClosed
        self.launchAtLogin = launchAtLogin
        self.copySoundEnabled = copySoundEnabled
        self.popupHotkeyEnabled = popupHotkeyEnabled
        self.popupHotkey = popupHotkey
        self.menuBarPresentation = menuBarPresentation
        self.checkForUpdatesAutomatically = checkForUpdatesAutomatically
        self.skippedUpdateVersion = skippedUpdateVersion
        normalize()
    }

    /// Brings every field into its allowed range: a blank symbol or hotkey
    /// falls back to the default (a blank status item would make the app
    /// unreachable), the multiplier snaps to the allowed steps, and the
    /// menu bar block keeps only its style fields. The one place these rules
    /// live, so an edit through `AppPrefs.update` cannot skip them and a new
    /// preference does not have to be threaded through a field-by-field copy.
    public mutating func normalize() {
        let symbol = menuBarSymbol.trimmingCharacters(in: .whitespacesAndNewlines)
        menuBarSymbol = symbol.isEmpty ? Self.defaultMenuBarSymbol : symbol
        refreshMultiplier = SchedulePolicy.normalizedRefreshMultiplier(refreshMultiplier)
        let hotkey = popupHotkey.trimmingCharacters(in: .whitespacesAndNewlines)
        popupHotkey = hotkey.isEmpty ? Self.defaultPopupHotkey : hotkey
        menuBarPresentation = MenuBarPolicy.globalStyle(menuBarPresentation)
        let skipped = skippedUpdateVersion?.trimmingCharacters(in: .whitespacesAndNewlines)
        skippedUpdateVersion = (skipped?.isEmpty == false) ? skipped : nil
    }

    /// Lenient decoding: absent keys fall back to defaults, the multiplier is
    /// snapped to the allowed steps, an empty symbol falls back to the
    /// default (a blank status item would make the app unreachable).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        menuBarSymbol = try container.decodeIfPresent(String.self, forKey: .menuBarSymbol)
            ?? Self.defaultMenuBarSymbol
        refreshMultiplier = try container.decodeIfPresent(
            Double.self, forKey: .refreshMultiplier
        ) ?? 1
        pauseWhenClosed = try container.decodeIfPresent(
            Bool.self, forKey: .pauseWhenClosed
        ) ?? false
        launchAtLogin = try container.decodeIfPresent(
            Bool.self, forKey: .launchAtLogin
        ) ?? false
        copySoundEnabled = try container.decodeIfPresent(
            Bool.self, forKey: .copySoundEnabled
        ) ?? false
        popupHotkeyEnabled = try container.decodeIfPresent(
            Bool.self, forKey: .popupHotkeyEnabled
        ) ?? false
        popupHotkey = try container.decodeIfPresent(String.self, forKey: .popupHotkey)
            ?? Self.defaultPopupHotkey
        // A malformed block must not cost the user every other preference.
        menuBarPresentation = (try? container.decodeIfPresent(
            MenuBarPresentation.self, forKey: .menuBarPresentation
        )) ?? nil
        checkForUpdatesAutomatically = try container.decodeIfPresent(
            Bool.self, forKey: .checkForUpdatesAutomatically
        ) ?? true
        skippedUpdateVersion = try container.decodeIfPresent(
            String.self, forKey: .skippedUpdateVersion
        )
        normalize()
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
