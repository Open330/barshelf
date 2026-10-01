import MenubucketCore

// The words the app shows for its own concepts, in one place (R13 §3.1).
// Code keeps its internal names — `bucket`, `group`, `exec`, the XS/S/M/L
// size codes — because they are in manifests and preference files. Users see
// what the thing does instead.

enum LayoutSizeName {
    /// What a manifest size code does on the shelf. S is the only size that
    /// shares a row: two in a row sit side by side.
    static func name(_ code: String) -> String {
        switch code.uppercased() {
        case "XS": return String(localized: "Strip", comment: "Widget size name")
        case "S": return String(localized: "Half Width", comment: "Widget size name")
        case "L": return String(localized: "Tall (size)", defaultValue: "Tall", comment: "Widget size name; distinct from the Tall height preset")
        default: return String(localized: "Full Width", comment: "Widget size name")
        }
    }

    static func description(_ code: String) -> String {
        switch code.uppercased() {
        case "XS": return String(localized: "A single compact line.")
        case "S": return String(localized: "Half the width; two in a row share it.")
        case "L": return String(localized: "Full width, with room for a list or grid.")
        default: return String(localized: "Full width, standard height.")
        }
    }
}

enum WidgetTypeName {
    /// `exec` / `workflow` / `script` from the registry, as a person would say it.
    static func name(_ kind: String) -> String {
        switch kind {
        case "exec": return String(localized: "Command", comment: "Widget type")
        case "workflow": return String(localized: "Workflow", comment: "Widget type")
        case "script": return String(localized: "Script", comment: "Widget type")
        default: return kind.capitalized
        }
    }
}
