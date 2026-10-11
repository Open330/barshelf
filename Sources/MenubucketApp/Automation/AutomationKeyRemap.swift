import CoreGraphics
import Foundation

/// Native, bounded key-to-key rules. No JavaScript runs on the event tap.
struct AutomationKeyRemap: Equatable {
    let from: Int64
    let to: Int64
    let mandatory: UInt64
    let optional: UInt64
    let anyOptional: Bool

    static let modifierFlags: [String: CGEventFlags] = [
        "command": .maskCommand, "control": .maskControl, "option": .maskAlternate,
        "shift": .maskShift, "fn": .maskSecondaryFn, "caps_lock": .maskAlphaShift
    ]
    static let modifierMask = modifierFlags.values.reduce(UInt64(0)) { $0 | $1.rawValue }
    static let keys: [String: Int64] = AutomationScript.physicalKeys.merging([
        "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22,
        "7": 26, "8": 28, "9": 25, "0": 29,
        "return_or_enter": 36, "tab": 48, "spacebar": 49,
        "delete_or_backspace": 51, "escape": 53, "delete_forward": 117,
        "home": 115, "end": 119, "page_up": 116, "page_down": 121,
        "left_arrow": 123, "right_arrow": 124, "down_arrow": 125, "up_arrow": 126
    ]) { first, _ in first }

    /// Keys macOS always reports with the fn flag: arrows, Home/End,
    /// Page Up/Down, Forward Delete, Help and the function keys. On these fn
    /// says nothing about whether fn was held, so it is left out of matching;
    /// otherwise `control+left_arrow` never matched (the event carries
    /// control|fn) and a rule requiring fn fired on every plain arrow.
    static let fnImpliedKeys: Set<Int64> = [
        123, 124, 125, 126, 115, 119, 116, 121, 117, 114,
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113,
    ]

    static func decode(_ values: [[String: Any]]) throws -> [Self] {
        guard !values.isEmpty, values.count <= 128 else {
            throw AutomationFailure(String(localized: "Register between 1 and 128 key remaps."))
        }
        return try values.map { value in
            guard Set(value.keys).isSubset(of: ["from", "to", "mandatory", "optional"]),
                  let source = value["from"] as? String, let from = keys[source],
                  let destination = value["to"] as? String, let to = keys[destination] else {
                throw AutomationFailure(String(localized: "Key remaps require supported from/to key names."))
            }
            func flags(_ name: String) throws -> (UInt64, Bool) {
                guard let names = (value[name] ?? [String]()) as? [String],
                      Set(names).count == names.count else {
                    throw AutomationFailure(String(localized: "Key-remap modifiers must be unique strings."))
                }
                if names == ["any"], name == "optional" { return (0, true) }
                var flags: UInt64 = 0
                for name in names {
                    guard let flag = modifierFlags[name] else {
                        throw AutomationFailure(String(localized: "Unsupported key-remap modifier: \(name)."))
                    }
                    flags |= flag.rawValue
                }
                return (flags, false)
            }
            let mandatory = try flags("mandatory")
            let optional = try flags("optional")
            guard mandatory.0 & optional.0 == 0 else {
                throw AutomationFailure(String(localized: "Mandatory and optional modifiers must not overlap."))
            }
            if fnImpliedKeys.contains(from), mandatory.0 & CGEventFlags.maskSecondaryFn.rawValue != 0 {
                throw AutomationFailure(String(localized: "fn cannot be required on \(source): macOS reports that key with fn either way."))
            }
            return Self(from: from, to: to, mandatory: mandatory.0,
                        optional: optional.0, anyOptional: optional.1)
        }
    }

    func matches(code: Int64, flags: UInt64) -> Bool {
        var modifiers = flags & Self.modifierMask
        if Self.fnImpliedKeys.contains(code) { modifiers &= ~CGEventFlags.maskSecondaryFn.rawValue }
        return code == from && modifiers & mandatory == mandatory &&
            (anyOptional || modifiers & ~(mandatory | optional) == 0)
    }
}

struct AutomationKeyRemapState {
    var held: [AutomationRemapState.Key: AutomationKeyRemap] = [:]

    mutating func target(code: Int64, keyboard: Int64, down: Bool, flags: UInt64,
                         rules: [AutomationKeyRemap]) -> AutomationKeyRemap? {
        let key = AutomationRemapState.Key(code: code, keyboard: keyboard)
        if !down { return held.removeValue(forKey: key) }
        if let rule = held[key] { return rule }
        guard let rule = rules.first(where: { $0.matches(code: code, flags: flags) }) else { return nil }
        held[key] = rule
        return rule
    }
}
