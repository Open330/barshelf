import Foundation

/// One entry point for third-party formats; every converter produces a draft
/// and must validate it before the controller changes any saved state.
enum AutomationImporter {
    struct Result {
        let script: String
        let summary: String
    }

    static func convert(_ source: String, fileExtension: String) throws -> Result {
        switch fileExtension.lowercased() {
        case "lua":
            let result = try HammerspoonImporter.convert(source)
            return Result(script: result.script, summary: result.summary)
        case "json":
            let result = try KarabinerImporter.convert(source)
            return Result(script: result.script, summary: result.summary)
        case "js":
            _ = try AutomationScript(source: source)
            return Result(script: source, summary: String(localized: "JavaScript loaded into the editor. Save to apply it."))
        default:
            throw AutomationFailure(String(localized: "Choose Hammerspoon Lua, Karabiner JSON, or a JavaScript extension."))
        }
    }
}
