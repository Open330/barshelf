import Foundation

/// URL-install v1 — finds every installable widget inside an extracted
/// archive: any directory containing a `widget.json` (repo root, nested
/// subdirectories, multi-widget repos).
public enum WidgetDiscovery {
    public static let manifestFileName = "widget.json"
    private static let maxDepth = 8

    public struct Candidate: Equatable {
        /// Directory that contains `widget.json`.
        public let directory: URL
        public let manifest: Manifest
        /// Optional `version` string from widget.json (not part of the
        /// decoded `Manifest`, shown in the install confirmation).
        public let displayVersion: String?
        /// Path relative to the discovery root (for messages).
        public let relativePath: String
    }

    public struct Failure: Equatable {
        public let relativePath: String
        public let reason: String
    }

    public struct Result: Equatable {
        public var candidates: [Candidate]
        public var failures: [Failure]
    }

    public enum DiscoveryError: Error, Equatable, LocalizedError {
        case subdirectoryNotFound(String)

        public var errorDescription: String? {
            switch self {
            case let .subdirectoryNotFound(subdir):
                return "subdirectory \"\(subdir)\" not found in the archive"
            }
        }
    }

    /// Scans `root` for widget directories. If `subdirectory` is given
    /// (GitHub `/tree/{branch}/{subdir}` URLs) only that subtree is searched.
    /// A single top-level wrapper directory (GitHub archives extract to
    /// `{repo}-{branch}/…`) is unwrapped automatically.
    public static func discover(
        under root: URL, subdirectory: String? = nil
    ) throws -> Result {
        let fm = FileManager.default
        var effectiveRoot = root.standardizedFileURL

        // Unwrap the single wrapper directory GitHub archives add.
        if !fm.fileExists(atPath: effectiveRoot.appendingPathComponent(manifestFileName).path),
           let children = try? childDirectoriesAndFiles(of: effectiveRoot),
           children.files.isEmpty, children.directories.count == 1 {
            effectiveRoot = children.directories[0]
        }

        if let subdirectory {
            for component in subdirectory.split(separator: "/") {
                effectiveRoot.appendPathComponent(String(component), isDirectory: true)
            }
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: effectiveRoot.path, isDirectory: &isDirectory),
                  isDirectory.boolValue
            else {
                throw DiscoveryError.subdirectoryNotFound(subdirectory)
            }
        }

        var result = Result(candidates: [], failures: [])
        walk(directory: effectiveRoot, root: effectiveRoot, depth: 0, into: &result)
        return result
    }

    /// Human-readable permission summary. Empty means the widget
    /// requests no gated permissions.
    public static func permissionSummary(for manifest: Manifest) -> [String] {
        var lines: [String] = []
        if let exec = manifest.permissions?.exec, !exec.isEmpty {
            lines.append("exec: " + exec.map(\.command).joined(separator: ", "))
        }
        if let network = manifest.permissions?.network, !network.isEmpty {
            lines.append("network: fetches from " + network.joined(separator: ", "))
        }
        if let readPaths = manifest.permissions?.readPaths, !readPaths.isEmpty {
            lines.append("files: reads " + readPaths.joined(separator: ", "))
        }
        if manifest.permissions?.keychain == true {
            lines.append("keychain: reads secrets from the macOS Keychain")
        }
        if manifest.permissions?.notifications == true {
            lines.append("notifications: may show system notifications")
        }
        if let environment = manifest.permissions?.env, !environment.isEmpty {
            lines.append("environment: reads " + environment.joined(separator: ", "))
        }
        if manifest.permissions?.storage?.granted == true {
            lines.append("storage: saves small data on this Mac")
        }
        return lines
    }

    /// Widget ids become install directory names — restrict them to a safe
    /// character set (no path separators, no leading dot).
    public static func isValidWidgetID(_ id: String) -> Bool {
        guard !id.isEmpty, id.count <= 100 else { return false }
        guard let first = id.first, first.isLetter || first.isNumber else { return false }
        return id.allSatisfy { char in
            char.isLetter || char.isNumber || char == "-" || char == "_" || char == "."
        } && !id.contains("..")
    }

    // MARK: - Internals

    /// Depth-first search. A directory containing `widget.json` is one
    /// widget package; its subdirectories are widget content (not descended).
    private static func walk(
        directory: URL, root: URL, depth: Int, into result: inout Result
    ) {
        let fm = FileManager.default
        let manifestURL = directory.appendingPathComponent(manifestFileName)
        let relative = relativePath(of: directory, under: root)

        if fm.fileExists(atPath: manifestURL.path) {
            do {
                let data = try Data(contentsOf: manifestURL)
                let manifest = try Manifest.decode(from: data)
                guard isValidWidgetID(manifest.id) else {
                    result.failures.append(Failure(
                        relativePath: relative,
                        reason: "invalid widget id \"\(manifest.id)\""
                    ))
                    return
                }
                let version = (try? JSONDecoder().decode(VersionProbe.self, from: data))?.version
                result.candidates.append(Candidate(
                    directory: directory,
                    manifest: manifest,
                    displayVersion: version,
                    relativePath: relative
                ))
            } catch {
                result.failures.append(Failure(
                    relativePath: relative,
                    reason: "invalid widget.json: \(error.localizedDescription)"
                ))
            }
            return
        }

        guard depth < maxDepth,
              let children = try? childDirectoriesAndFiles(of: directory)
        else { return }
        for child in children.directories {
            walk(directory: child, root: root, depth: depth + 1, into: &result)
        }
    }

    /// Non-hidden, non-symlink children, sorted by name for determinism.
    private static func childDirectoriesAndFiles(
        of directory: URL
    ) throws -> (directories: [URL], files: [URL]) {
        let entries = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }

        var directories: [URL] = []
        var files: [URL] = []
        for entry in entries {
            let values = try? entry.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
            if values?.isSymbolicLink == true { continue }
            if values?.isDirectory == true {
                directories.append(entry)
            } else {
                files.append(entry)
            }
        }
        return (directories, files)
    }

    private static func relativePath(of url: URL, under root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path == rootPath { return "." }
        if path.hasPrefix(rootPath + "/") {
            return String(path.dropFirst(rootPath.count + 1))
        }
        return path
    }

    private struct VersionProbe: Decodable {
        let version: String?
    }
}
