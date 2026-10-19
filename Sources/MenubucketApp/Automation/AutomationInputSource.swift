import Carbon.HIToolbox

/// Switches keyboard input sources directly through Text Input Sources. A
/// BarShelf shortcut fires on key-down, whereas the system "Select next source"
/// shortcut commits only when its modifier is released.
enum AutomationInputSource {
    /// The source after `current` in `enabled`, wrapping; the first one when
    /// `current` is not in the list (e.g. a palette is selected).
    static func next(after current: String?, in enabled: [String]) -> String? {
        guard enabled.count > 1 else { return nil }
        guard let current, let index = enabled.firstIndex(of: current) else { return enabled.first }
        return enabled[(index + 1) % enabled.count]
    }

    static func selectNext() throws {
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
