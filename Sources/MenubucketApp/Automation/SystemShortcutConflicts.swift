import Carbon.HIToolbox
import Foundation

/// Automation bindings that macOS also uses for one of its own keyboard
/// shortcuts. macOS takes those keys first and still lets the app's shortcut
/// fire, so both run: a ⌘Space bound to `selectNextInputSource()` while the
/// system's "Select next source" is on switches twice and lands where it
/// started. Nothing reports that, so settings say it.
enum SystemShortcutConflicts {
    struct Conflict: Equatable, Identifiable {
        /// The binding as typed in the script, e.g. "cmd+space".
        let binding: String
        /// The `com.apple.symbolichotkeys` id.
        let systemID: Int
        var id: String { "\(binding)#\(systemID)" }

        /// The shortcut as the user sees it, e.g. "⌘Space".
        var displayBinding: String { HotkeyGrammar.displayText(binding) }

        var systemName: String {
            SystemShortcutConflicts.names[systemID]
                ?? String(localized: "a macOS keyboard shortcut",
                          comment: "Fallback name of a system shortcut BarShelf has no name for")
        }
    }

    /// Bindings that collide with an enabled system shortcut, in binding order.
    static func find(
        bindings: [HotkeyGrammar.Combination], symbolicHotKeys: [String: Any]
    ) -> [Conflict] {
        let enabled: [(id: Int, keyCode: Int, modifiers: Int)] = symbolicHotKeys.compactMap { key, value in
            guard let id = Int(key), let entry = value as? [String: Any],
                  (entry["enabled"] as? NSNumber)?.boolValue == true,
                  let parameters = (entry["value"] as? [String: Any])?["parameters"] as? [NSNumber],
                  parameters.count >= 3
            else { return nil }
            return (id, parameters[1].intValue, parameters[2].intValue & relevantCocoaModifiers)
        }
        var conflicts: [Conflict] = []
        for binding in bindings {
            let modifiers = cocoaModifiers(fromCarbon: binding.modifiers)
            for system in enabled.sorted(by: { $0.id < $1.id })
            where system.keyCode == Int(binding.keyCode) && system.modifiers == modifiers {
                conflicts.append(Conflict(binding: binding.canonicalText, systemID: system.id))
            }
        }
        return conflicts
    }

    /// The live system shortcuts.
    static func current(bindings: [HotkeyGrammar.Combination]) -> [Conflict] {
        guard !bindings.isEmpty else { return [] }
        let domain = "com.apple.symbolichotkeys" as CFString
        CFPreferencesAppSynchronize(domain)
        let table = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, domain) as? [String: Any] ?? [:]
        return find(bindings: bindings, symbolicHotKeys: table)
    }

    // ⌘ ⇧ ⌥ ⌃ as `NSEvent.ModifierFlags` raw values, which is what the system
    // shortcut table stores; Carbon hot keys use their own bits.
    static let relevantCocoaModifiers = 0x100000 | 0x20000 | 0x80000 | 0x40000

    static func cocoaModifiers(fromCarbon carbon: UInt32) -> Int {
        var flags = 0
        if carbon & UInt32(cmdKey) != 0 { flags |= 0x100000 }
        if carbon & UInt32(shiftKey) != 0 { flags |= 0x20000 }
        if carbon & UInt32(optionKey) != 0 { flags |= 0x80000 }
        if carbon & UInt32(controlKey) != 0 { flags |= 0x40000 }
        return flags
    }

    /// The system shortcuts people most often bind over.
    static let names: [Int: String] = [
        60: String(localized: "Select the previous input source"),
        61: String(localized: "Select next source in Input menu"),
        64: String(localized: "Show Spotlight search"),
        65: String(localized: "Show Finder search window"),
        32: String(localized: "Mission Control"),
        33: String(localized: "Application windows"),
        36: String(localized: "Show Desktop"),
        79: String(localized: "Move left a space"),
        81: String(localized: "Move right a space"),
        27: String(localized: "Move focus to next window"),
        28: String(localized: "Save picture of screen as a file"),
        30: String(localized: "Save picture of selected area as a file"),
        184: String(localized: "Screenshot and recording options"),
    ]
}
