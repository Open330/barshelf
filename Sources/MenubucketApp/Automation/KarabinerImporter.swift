import Foundation

/// Convert only behavior the native event tap can preserve. Reject the whole
/// candidate on unsupported actions instead of silently dropping rules.
enum KarabinerImporter {
    struct Result {
        let script: String
        let summary: String
    }

    static func convert(_ source: String) throws -> Result {
        guard let data = source.data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AutomationFailure("Choose a Karabiner JSON configuration or rules file.")
        }
        var remaps: [[String: Any]] = []
        var profileName: String?
        let container: [String: Any]
        if root["profiles"] != nil {
            try allowed(root, ["profiles", "global"], at: "configuration")
            guard let profiles = root["profiles"] as? [[String: Any]], !profiles.isEmpty else {
                throw AutomationFailure("Karabiner configuration needs at least one profile.")
            }
            let selected = profiles.filter { ($0["selected"] as? Bool) == true }
            guard selected.count == 1 || (selected.isEmpty && profiles.count == 1) else {
                throw AutomationFailure("Select exactly one Karabiner profile before importing.")
            }
            container = selected.first ?? profiles[0]
            profileName = container["name"] as? String
            try allowed(container, ["name", "selected", "simple_modifications", "complex_modifications",
                "fn_function_keys", "devices", "virtual_hid_keyboard", "parameters"], at: "profile")
            // These affect keyboard behavior and cannot be discarded during migration.
            for key in ["fn_function_keys", "devices", "parameters"] {
                try empty(container[key], at: "profile.\(key)")
            }
            if let virtual = container["virtual_hid_keyboard"] as? [String: Any] {
                try allowed(virtual, ["keyboard_type", "country_code"], at: "virtual_hid_keyboard")
            } else if container["virtual_hid_keyboard"] != nil {
                throw unsupported("virtual_hid_keyboard")
            }
            if let simple = container["simple_modifications"] {
                guard let pairs = simple as? [[String: Any]] else { throw unsupported("simple_modifications") }
                for (index, pair) in pairs.enumerated() {
                    let path = "simple_modifications[\(index)]"
                    try allowed(pair, ["from", "to"], at: path)
                    guard let from = pair["from"] as? [String: Any],
                          let to = pair["to"] as? [[String: Any]], to.count == 1 else { throw unsupported(path) }
                    try allowed(from, ["key_code"], at: path + ".from")
                    try allowed(to[0], ["key_code"], at: path + ".to")
                    guard let key = from["key_code"] as? String, let target = to[0]["key_code"] as? String else {
                        throw unsupported(path)
                    }
                    remaps.append(["from": key, "to": target, "optional": ["any"]])
                }
            }
        } else { container = root }

        let rules: [[String: Any]]
        if root["profiles"] != nil {
            if let value = container["complex_modifications"] {
                guard let complex = value as? [String: Any] else { throw unsupported("complex_modifications") }
                try allowed(complex, ["rules", "parameters"], at: "complex_modifications")
                try empty(complex["parameters"], at: "complex_modifications.parameters")
                guard let items = (complex["rules"] ?? [[String: Any]]()) as? [[String: Any]] else {
                    throw unsupported("complex_modifications.rules")
                }
                rules = items
            } else { rules = [] }
        } else if root["manipulators"] != nil {
            rules = [root]
        } else {
            try allowed(root, ["title", "rules"], at: "rules file")
            guard let items = root["rules"] as? [[String: Any]] else { throw unsupported("rules") }
            rules = items
        }

        for (ruleIndex, rule) in rules.enumerated() {
            let path = "rules[\(ruleIndex)]"
            try allowed(rule, ["description", "manipulators"], at: path)
            guard let manipulators = rule["manipulators"] as? [[String: Any]], !manipulators.isEmpty else {
                throw unsupported(path + ".manipulators")
            }
            for (index, item) in manipulators.enumerated() {
                let path = path + ".manipulators[\(index)]"
                try allowed(item, ["type", "description", "from", "to"], at: path)
                guard item["type"] as? String == "basic",
                      let from = item["from"] as? [String: Any],
                      let to = item["to"] as? [[String: Any]], to.count == 1 else { throw unsupported(path) }
                try allowed(from, ["key_code", "modifiers"], at: path + ".from")
                try allowed(to[0], ["key_code"], at: path + ".to")
                guard let key = from["key_code"] as? String, let target = to[0]["key_code"] as? String else {
                    throw unsupported(path)
                }
                var remap: [String: Any] = ["from": key, "to": target]
                if let value = from["modifiers"] {
                    guard let modifiers = value as? [String: Any] else { throw unsupported(path + ".modifiers") }
                    try allowed(modifiers, ["mandatory", "optional"], at: path + ".modifiers")
                    for (name, value) in modifiers { remap[name] = value }
                }
                remaps.append(remap)
            }
        }
        // Simple and complex remaps can form a pipeline in Karabiner; the host
        // deliberately applies one rule per physical event.
        let sources = Set(remaps.compactMap { $0["from"] as? String })
        guard !remaps.contains(where: { sources.contains($0["to"] as? String ?? "") }) else {
            throw unsupported("chained or self-referencing key remaps")
        }
        _ = try AutomationKeyRemap.decode(remaps)
        let json = String(decoding: try JSONSerialization.data(withJSONObject: remaps,
            options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
        let script = "// Imported from Karabiner-Elements. Original settings are unchanged.\nbarshelf.remapKeys(\(json));"
        _ = try AutomationScript(source: script)
        let profile = profileName.map { " (\($0))" } ?? ""
        return Result(script: script, summary: "Imported \(remaps.count) key remaps from Karabiner-Elements\(profile). Rules apply to all keyboards. Disable the original Karabiner rules before enabling this extension.")
    }

    private static func allowed(_ object: [String: Any], _ keys: Set<String>, at path: String) throws {
        if let key = Set(object.keys).subtracting(keys).sorted().first { throw unsupported(path + "." + key) }
    }

    private static func empty(_ value: Any?, at path: String) throws {
        guard let value else { return }
        if let array = value as? [Any], array.isEmpty { return }
        if let object = value as? [String: Any], object.isEmpty { return }
        throw unsupported(path)
    }

    private static func unsupported(_ path: String) -> AutomationFailure {
        AutomationFailure("Unsupported Karabiner behavior at \(path). Nothing was imported. Supported: global key-to-key mappings with command/control/option/shift/fn/caps_lock modifiers. Device/app conditions, modifier keys, macros and shell actions need manual migration.")
    }
}
