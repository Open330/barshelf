import Carbon.HIToolbox
import Combine
import Foundation

/// The supported, portable spelling of a popup shortcut. Keeping parsing out
/// of the status-item controller lets the settings UI reject a draft before it
/// changes the registered shortcut.
enum HotkeyGrammar {
    struct Combination: Equatable {
        let keyCode: UInt32
        let modifiers: UInt32
        let canonicalText: String

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.keyCode == rhs.keyCode && lhs.modifiers == rhs.modifiers
        }
    }

    enum Error: LocalizedError, Equatable {
        case empty
        case missingModifier
        case missingKey
        case duplicateModifier(String)
        case multipleKeys
        case unsupportedKey(String)

        var errorDescription: String? {
            switch self {
            case .empty: return String(localized: "Enter a shortcut, for example cmd+shift+b.")
            case .missingModifier: return String(localized: "Include at least one modifier: cmd, shift, opt, or ctrl.")
            case .missingKey: return String(localized: "Include one key after the modifiers.")
            case .duplicateModifier(let modifier): return String(localized: "\(modifier) is included more than once.")
            case .multipleKeys: return String(localized: "Use exactly one key with the modifiers.")
            case .unsupportedKey(let key): return String(localized: "\"\(key)\" is not a supported shortcut key.")
            }
        }
    }

    static func parse(_ text: String) -> Result<Combination, Error> {
        let parts = text.lowercased().split(separator: "+", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !parts.isEmpty, !parts.allSatisfy(\.isEmpty) else { return .failure(.empty) }
        guard !parts.contains(where: \.isEmpty) else { return .failure(.missingKey) }

        var modifiers: UInt32 = 0
        var modifierNames: Set<String> = []
        var key: String?
        for part in parts {
            let modifier: (name: String, flag: UInt32)?
            switch part {
            case "cmd", "command", "⌘": modifier = ("cmd", UInt32(cmdKey))
            case "shift", "⇧": modifier = ("shift", UInt32(shiftKey))
            case "opt", "option", "alt", "⌥": modifier = ("opt", UInt32(optionKey))
            case "ctrl", "control", "^": modifier = ("ctrl", UInt32(controlKey))
            default: modifier = nil
            }
            if let modifier {
                guard modifierNames.insert(modifier.name).inserted else {
                    return .failure(.duplicateModifier(modifier.name))
                }
                modifiers |= modifier.flag
            } else if key == nil {
                key = part
            } else {
                return .failure(.multipleKeys)
            }
        }
        guard modifiers != 0 else { return .failure(.missingModifier) }
        guard let key else { return .failure(.missingKey) }
        guard let keyCode = keyCodes[key] else { return .failure(.unsupportedKey(key)) }
        return .success(Combination(
            keyCode: keyCode, modifiers: modifiers,
            canonicalText: canonicalModifiers(for: modifiers).appending("+\(key)")
        ))
    }

    private static func canonicalModifiers(for modifiers: UInt32) -> String {
        [
            ("cmd", UInt32(cmdKey)),
            ("shift", UInt32(shiftKey)),
            ("opt", UInt32(optionKey)),
            ("ctrl", UInt32(controlKey)),
        ]
        .compactMap { modifiers & $0.1 == 0 ? nil : $0.0 }
        .joined(separator: "+")
    }

    /// The grammar's name for a key code, or nil when the key cannot be
    /// part of a shortcut. Lets a recorder turn a key press into text the
    /// parser accepts.
    static func keyName(for keyCode: UInt32) -> String? {
        keyCodes.first { $0.value == keyCode }?.key
    }

    /// "cmd+shift+b" as the menu bar would print it: ⌘⇧B.
    static func displayText(_ text: String) -> String {
        guard case .success(let combination) = parse(text) else { return text }
        let parts = combination.canonicalText.split(separator: "+").map(String.init)
        var symbols = ""
        for part in parts.dropLast() {
            switch part {
            case "ctrl": symbols += "⌃"
            case "opt": symbols += "⌥"
            case "shift": symbols += "⇧"
            case "cmd": symbols += "⌘"
            default: break
            }
        }
        // AppKit's order is ⌃⌥⇧⌘; canonical text is cmd, shift, opt, ctrl.
        let ordered = String("⌃⌥⇧⌘".filter { symbols.contains($0) })
        let key = parts.last ?? ""
        let keyLabel: String
        switch key {
        case "space": keyLabel = String(localized: "Space", comment: "The space bar, as a shortcut key.")
        case "return": keyLabel = "↩"
        case "tab": keyLabel = "⇥"
        default: keyLabel = key.uppercased()
        }
        return ordered + keyLabel
    }

    private static let keyCodes: [String: UInt32] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
        "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16,
        "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
        "9": 25, "7": 26, "8": 28, "0": 29, "o": 31, "u": 32, "i": 34,
        "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
        "space": 49, "return": 36, "tab": 48,
    ]
}

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
