import Foundation
import MenubucketCore

/// Advisory validation for the settings editor. Runtime filesystem access
/// still authorizes an open descriptor against the manifest's read roots.
enum DirectorySettingPolicy {
    /// Constrain only settings wired directly to the host directory source.
    /// A directory used by an approved external command can have different
    /// semantics and must not inherit an unrelated readPaths restriction.
    static func constrainedKeys(in workflow: WorkflowDefinition) -> Set<String> {
        Set(workflow.sources.values.compactMap { source in
            guard source.use == "fs.directory", let path = source.with?.objectValue?["path"]?.stringValue,
                  path.hasPrefix("${settings."), path.hasSuffix("}") else { return nil }
            let key = String(path.dropFirst("${settings.".count).dropLast())
            guard !key.isEmpty, !key.contains("${"), !key.contains("}") else { return nil }
            return key
        })
    }

    static func allows(_ path: String, roots: [String]) -> Bool {
        guard !roots.isEmpty else { return true }
        guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let directory = canonical(path)
        return roots.contains { root in
            let allowed = canonical(root)
            return directory == allowed || directory.hasPrefix(allowed == "/" ? "/" : allowed + "/")
        }
    }

    static func saving(_ proposed: [String: JSONValue], over previous: [String: JSONValue],
                       settings: [Manifest.Setting], roots: [String]) -> [String: JSONValue] {
        var values = proposed
        for setting in settings where setting.type == "directory" {
            guard let key = setting.key,
                  !allows(values[key]?.stringValue ?? "", roots: roots) else { continue }
            // Keep the user's draft visible with its explanation. Other
            // settings can still save without committing an unusable folder.
            values[key] = previous[key]
        }
        return values
    }

    private static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            .standardizedFileURL.resolvingSymlinksInPath().path
    }
}
