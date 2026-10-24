import Foundation

/// Convert only behavior the native event tap can preserve. Reject the whole
/// candidate on unsupported actions instead of silently dropping rules.
enum KarabinerImporter {
    struct Result {
        let script: String
        let summary: String
    }

    static func convert(_ source: String, excludingFunctionKeys: Bool = false) throws -> Result {
        guard let data = source.data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AutomationFailure(String(localized: "Choose a Karabiner JSON configuration or rules file."))
        }
        var remaps: [[String: Any]] = []
        var profileName: String?
        var omittedFunctionKeys = false
        let container: [String: Any]
        if root["profiles"] != nil {
            // `global` and `machine_specific` hold app-wide preferences (menu
            // bar icon, notifications), not key behavior.
            try allowed(root, ["profiles", "global", "machine_specific"], at: "configuration")
            guard let profiles = root["profiles"] as? [[String: Any]], !profiles.isEmpty else {
                throw AutomationFailure(String(localized: "Karabiner configuration needs at least one profile."))
            }
            let selected = profiles.filter { ($0["selected"] as? Bool) == true }
            guard selected.count == 1 || (selected.isEmpty && profiles.count == 1) else {
                throw AutomationFailure(String(localized: "Select exactly one Karabiner profile before importing."))
            }
            container = selected.first ?? profiles[0]
            profileName = container["name"] as? String
            try allowed(container, ["name", "selected", "simple_modifications", "complex_modifications",
                "fn_function_keys", "devices", "virtual_hid_keyboard", "parameters"], at: "profile")
            // What Karabiner writes into every configuration on its own is
            // accepted; only settings that change keys are refused.
            // Media outputs are behavior too. Even a familiar F-key table
            // cannot be assumed to match this keyboard's native macOS layout.
            // Refuse partial migration; users can export supported rules alone.
            if excludingFunctionKeys, let value = container["fn_function_keys"] {
                omittedFunctionKeys = (value as? [Any])?.isEmpty != true
            } else {
                try empty(container["fn_function_keys"], at: "profile.fn_function_keys")
            }
            if let parameters = container["parameters"] {
                guard let parameters = parameters as? [String: Any] else { throw unsupported("profile.parameters") }
                try allowed(parameters, ["delay_milliseconds_before_open_device"], at: "profile.parameters")
            }
            if let devices = container["devices"] {
                guard let devices = devices as? [[String: Any]] else { throw unsupported("profile.devices") }
                for (index, device) in devices.enumerated() {
                    let path = "profile.devices[\(index)]"
                    // Per-keyboard remaps, or ignoring a keyboard, change which
                    // keys do what; the rest is how Karabiner talks to it.
                    try empty(device["simple_modifications"], at: path + ".simple_modifications")
                    try empty(device["fn_function_keys"], at: path + ".fn_function_keys")
                    if device["ignore"] as? Bool == true { throw unsupported(path + ".ignore") }
                    if device["disable_built_in_keyboard_if_exists"] as? Bool == true {
                        throw unsupported(path + ".disable_built_in_keyboard_if_exists")
                    }
                }
            }
            if let virtual = container["virtual_hid_keyboard"] as? [String: Any] {
                try allowed(virtual, ["keyboard_type", "keyboard_type_v2", "country_code",
                    "mouse_key_xy_scale", "indicate_sticky_modifier_keys_state"], at: "virtual_hid_keyboard")
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
                // `parameters` are the basic.* timeouts the GUI writes; they
                // tune to_if_alone and held keys, which are not imported.
                try allowed(complex, ["rules", "parameters"], at: "complex_modifications")
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
            try allowed(rule, ["description", "manipulators", "enabled"], at: path)
            // A rule switched off in Karabiner stays off.
            if rule["enabled"] as? Bool == false { continue }
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
        // deliberately applies one rule per physical event. A rule's output
        // (a bare key) chains only into a rule that needs no modifier for it.
        let unmodifiedSources = Set(remaps.compactMap { remap -> String? in
            guard ((remap["mandatory"] as? [String]) ?? []).isEmpty else { return nil }
            return remap["from"] as? String
        })
        guard !remaps.contains(where: { remap in
            let target = remap["to"] as? String ?? ""
            return unmodifiedSources.contains(target) || target == remap["from"] as? String
        }) else {
            throw unsupported("chained or self-referencing key remaps")
        }
        _ = try AutomationKeyRemap.decode(remaps)
        let json = String(decoding: try JSONSerialization.data(withJSONObject: remaps,
            options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
        let omission = omittedFunctionKeys
            ? "// Function/media customizations omitted at your request. Verify native key behavior before quitting Karabiner.\n" : ""
        let script = "// Imported from Karabiner-Elements. Original settings are unchanged.\n" + omission + "barshelf.remapKeys(\(json));"
        _ = try AutomationScript(source: script)
        let profile = profileName.map { " (\($0))" } ?? ""
        var summary = String(localized: "Imported \(remaps.count) key remaps from Karabiner-Elements\(profile). Rules apply to all keyboards. Disable the original Karabiner rules before enabling this extension.")
        if omittedFunctionKeys {
            summary += " " + String(localized: "Function and media key customizations were not imported. After quitting Karabiner, those keys use native macOS behavior, which may differ.")
        }
        return Result(script: script, summary: summary)
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
        if path == "profile.fn_function_keys" {
            return AutomationFailure(String(localized: "Function and media key settings (profile.fn_function_keys) cannot be preserved. Nothing was imported. Choose Import Settings › Karabiner Key Mappings Only… to review the supported mappings separately."))
        }
        return AutomationFailure(String(localized: "Unsupported Karabiner behavior at \(path). Nothing was imported. Supported: global key-to-key mappings with command/control/option/shift/fn/caps_lock modifiers. Device/app conditions, modifier keys, macros and shell actions need manual migration."))
    }
}
