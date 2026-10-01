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
        case "XS": return "Strip"
        case "S": return "Half Width"
        case "L": return "Tall"
        default: return "Full Width"
        }
    }

    static func description(_ code: String) -> String {
        switch code.uppercased() {
        case "XS": return "A single compact line."
        case "S": return "Half the width; two in a row share it."
        case "L": return "Full width, with room for a list or grid."
        default: return "Full width, standard height."
        }
    }
}

enum WidgetTypeName {
    /// `exec` / `workflow` / `script` from the registry, as a person would say it.
    static func name(_ kind: String) -> String {
        switch kind {
        case "exec": return "Command"
        case "workflow": return "Workflow"
        case "script": return "Script"
        default: return kind.capitalized
        }
    }
}
