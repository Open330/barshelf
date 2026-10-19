import Carbon.HIToolbox
import CoreGraphics

/// Switches to the next keyboard input source the moment a BarShelf shortcut
/// goes down, whereas the system "Select next source" shortcut commits only
/// when its modifier is released.
///
/// Preferred path: when the system shortcut (symbolic hot key 61) is set to a
/// key with no modifier, such as F18, that key is sent and macOS switches
/// itself, which commits at once and reaches the focused app reliably.
/// Otherwise the source is selected through Text Input Sources. That path
/// sometimes changes the menu bar but not the focused app's input for Korean,
/// Japanese, and Chinese input methods: the first keys come out in the old
/// language. It is the same flaw Karabiner's select_input_source has, and why
/// the common setup is a key relayed to a modifier-less system shortcut.
enum AutomationInputSource {
    /// The "Select next source in Input menu" system shortcut.
    static let nextSourceHotKeyID = "61"

    /// A system shortcut that can stand in for the switch: the key code and
    /// the flags to send it with.
    struct SystemTrigger: Equatable {
        let keyCode: CGKeyCode
        let flags: CGEventFlags
    }

    /// The trigger when hot key 61 is on and bound to a key with no modifier
    /// (F-keys carry only the function flag). A shortcut with a modifier
    /// would commit on its release again, so it does not qualify.
    static func systemTrigger(in symbolicHotKeys: [String: Any]) -> SystemTrigger? {
        guard let entry = symbolicHotKeys[nextSourceHotKeyID] as? [String: Any],
              (entry["enabled"] as? NSNumber)?.boolValue == true,
              let parameters = (entry["value"] as? [String: Any])?["parameters"] as? [NSNumber],
              parameters.count >= 3
        else { return nil }
        let keyCode = parameters[1].intValue
        let modifiers = UInt64(truncatingIfNeeded: parameters[2].intValue)
        let function = CGEventFlags.maskSecondaryFn.rawValue
        guard (0...127).contains(keyCode), modifiers & ~function == 0 else { return nil }
        return SystemTrigger(keyCode: CGKeyCode(keyCode), flags: CGEventFlags(rawValue: modifiers & function))
    }

    static func currentSystemTrigger() -> SystemTrigger? {
        let domain = "com.apple.symbolichotkeys" as CFString
        CFPreferencesAppSynchronize(domain)
        let table = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, domain) as? [String: Any] ?? [:]
        return systemTrigger(in: table)
    }

    /// Sends the trigger key. A private event source keeps the modifiers the
    /// user is still holding (⌘ of ⌘Space) out of the event, so it matches
    /// the bare system shortcut.
    static func send(_ trigger: SystemTrigger) throws {
        let source = CGEventSource(stateID: .privateState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: trigger.keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: trigger.keyCode, keyDown: false) else {
            throw AutomationFailure(String(localized: "Cannot send the input source shortcut."))
        }
        down.flags = trigger.flags
        up.flags = trigger.flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
    /// The source after `current` in `enabled`, wrapping; the first one when
    /// `current` is not in the list (e.g. a palette is selected).
    static func next(after current: String?, in enabled: [String]) -> String? {
        guard enabled.count > 1 else { return nil }
        guard let current, let index = enabled.firstIndex(of: current) else { return enabled.first }
        return enabled[(index + 1) % enabled.count]
    }

    static func selectNext() throws {
        if let trigger = currentSystemTrigger() {
            try send(trigger)
            return
        }
        let sources = enabledKeyboardSources()
        let current = id(of: TISCopyCurrentKeyboardInputSource().takeRetainedValue())
        guard let target = next(after: current, in: sources.map(\.id)),
              let source = sources.first(where: { $0.id == target })?.source else {
            throw AutomationFailure(String(localized: "Enable at least two keyboard input sources to switch between them."))
        }
        let status = TISSelectInputSource(source)
        guard status == noErr else {
            throw AutomationFailure(String(localized: "Cannot select input source \(target) (\(status))."))
        }
    }

    /// Enabled, selectable keyboard layouts and input modes — the entries the
    /// Input menu lists. Excludes the character palette and parent input methods.
    private static func enabledKeyboardSources() -> [(id: String, source: TISInputSource)] {
        let filter = [
            kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String,
            kTISPropertyInputSourceIsSelectCapable as String: true,
        ] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] else { return [] }
        return list.compactMap { source in id(of: source).map { ($0, source) } }
    }

    private static func id(of source: TISInputSource) -> String? {
        guard let value = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(value).takeUnretainedValue() as String
    }
}
