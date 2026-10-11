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

    static func decode(_ values: [[String: Any]]) throws -> [Self] {
        guard !values.isEmpty, values.count <= 128 else {
            throw AutomationFailure("Register between 1 and 128 key remaps.")
        }
        return try values.map { value in
            guard Set(value.keys).isSubset(of: ["from", "to", "mandatory", "optional"]),
                  let source = value["from"] as? String, let from = keys[source],
                  let destination = value["to"] as? String, let to = keys[destination] else {
                throw AutomationFailure("Key remaps require supported from/to key names.")
            }
            func flags(_ name: String) throws -> (UInt64, Bool) {
                guard let names = (value[name] ?? [String]()) as? [String],
                      Set(names).count == names.count else {
                    throw AutomationFailure("Key-remap modifiers must be unique strings.")
                }
                if names == ["any"], name == "optional" { return (0, true) }
                var flags: UInt64 = 0
                for name in names {
                    guard let flag = modifierFlags[name] else {
                        throw AutomationFailure("Unsupported key-remap modifier: \(name).")
                    }
                    flags |= flag.rawValue
                }
                return (flags, false)
            }
            let mandatory = try flags("mandatory")
            let optional = try flags("optional")
            guard mandatory.0 & optional.0 == 0 else {
                throw AutomationFailure("Mandatory and optional modifiers must not overlap.")
            }
            return Self(from: from, to: to, mandatory: mandatory.0,
                        optional: optional.0, anyOptional: optional.1)
        }
    }

    func matches(code: Int64, flags: UInt64) -> Bool {
        let modifiers = flags & Self.modifierMask
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
