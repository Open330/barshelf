import BarShelfAutomation
import Carbon.HIToolbox
import Combine
import Foundation

/// Pure preference transition used after a registration attempt. A failed
/// attempt preserves the last working enabled/value pair.
enum HotkeyPreferencePolicy {
    static func committed(
        current: (enabled: Bool, shortcut: String),
        candidate: HotkeyGrammar.Combination,
        registrationSucceeded: Bool
    ) -> (enabled: Bool, shortcut: String) {
        registrationSucceeded ? (true, candidate.canonicalText) : current
    }
}

/// Bridge between Settings and the Carbon-owning status item. Settings only
/// changes persisted state after this bridge confirms registration, so a
/// checked toggle always represents an active shortcut.
final class HotkeyRegistrationCoordinator: ObservableObject {
    static let shared = HotkeyRegistrationCoordinator()

    @Published private(set) var message: String?
    /// The setting's enabled state is persisted only after this becomes true.
    /// It also lets a controller reconcile a stale enabled preference loaded
    /// at launch after Carbon rejects it.
    @Published private(set) var isRegistered = false
    var register: ((HotkeyGrammar.Combination) -> Bool)?

    func validate(_ draft: String) -> String? {
        if case .failure(let error) = HotkeyGrammar.parse(draft) {
            return error.localizedDescription
        }
        return nil
    }

    func report(_ message: String?) {
        self.message = message
    }

    func registrationDidChange(isRegistered: Bool) {
        self.isRegistered = isRegistered
    }

    func enable(draft: String, appPrefs: AppPrefs) {
        switch HotkeyGrammar.parse(draft) {
        case .failure(let error):
            message = error.localizedDescription
        case .success(let combination):
            guard register?(combination) == true else {
                // `StatusItemController` registers a candidate before it
                // releases the current Carbon shortcut. A conflict therefore
                // leaves an already-working shortcut live.
                message = String(localized: "BarShelf could not register \(combination.canonicalText). It may already be used by another app.")
                return
            }
            let next = HotkeyPreferencePolicy.committed(
                current: (appPrefs.preferences.popupHotkeyEnabled, appPrefs.preferences.popupHotkey),
                candidate: combination,
                registrationSucceeded: true
            )
            appPrefs.update {
                $0.popupHotkeyEnabled = next.enabled
                $0.popupHotkey = next.shortcut
            }
            isRegistered = true
            message = nil
        }
    }

    func disable(appPrefs: AppPrefs) {
        isRegistered = false
        appPrefs.update { $0.popupHotkeyEnabled = false }
        message = nil
    }
}
