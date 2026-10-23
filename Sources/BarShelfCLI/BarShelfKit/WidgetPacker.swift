import Darwin
import Foundation
import MenubucketCore

/// `barshelf pack` — zips a widget directory into a `.mbw` archive, adding a
/// `manifest.sha256` checksum of widget.json to the archive. Uses
/// `/usr/bin/zip` (a developer-tool invocation, not a runtime shellout).
public enum WidgetPacker {
    public struct Output: Equatable, Sendable {
        public let archiveURL: URL
        public let fileCount: Int
        /// sha256 of widget.json (also recorded in manifest.sha256).
        public let manifestSHA256: String
        /// Private configuration and development metadata left out of the archive.
        public let excludedPaths: [String]
    }

    public enum PackError: Error, LocalizedError, Equatable {
        case notADirectory(String)
        case validationFailed([String])
        case zipToolMissing(String)
        case zipFailed(status: Int32, output: String)
        case symbolicLink(String)
        case unsafeOutput(String)

        public var errorDescription: String? {
            switch self {
            case let .unsafeOutput(path):
                return "unsafe archive output: \(path); choose a regular .mbw file outside the widget directory (for example, -o ../widget.mbw)"
            case let .symbolicLink(path):
                return "cannot pack symbolic link: \(path); replace it with a regular package file"
            case let .notADirectory(path):
                return "not a widget directory: \(path)"
            case let .validationFailed(issues):
                return "widget failed validation:\n"
                    + issues.map { "  \($0)" }.joined(separator: "\n")
            case let .zipToolMissing(path):
                return "zip tool not found at \(path)"
            case let .zipFailed(status, output):
                return "zip exited with status \(status)"
                    + (output.isEmpty ? "" : ": \(output)")
            }
        }
    }

    static let zipToolPath = "/usr/bin/zip"

    /// Narrow failure-injection seam; production always zips and atomically
    /// renames a finished sibling archive over the destination.
    struct Operations {
        var zip: (URL, [String], URL) throws -> Void = WidgetPacker.runZip
        var commit: (URL, URL) throws -> Void = WidgetPacker.commitArchive
        var currentDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }

    /// Validates, stages (widget files + manifest.sha256) and zips.
    /// `output` defaults to `<directory-name>.mbw` in the current directory.
    @discardableResult
    public static func pack(directory: URL, output: URL? = nil) throws -> Output {
        try pack(directory: directory, output: output, operations: Operations())
    }

    static func pack(directory: URL, output: URL?, operations: Operations) throws -> Output {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw PackError.notADirectory(directory.path)
        }
        let requestedOutput = (output ?? operations.currentDirectory
            .appendingPathComponent(directory.lastPathComponent + ".mbw")).standardizedFileURL
        let directory = canonicalURL(directory)
        let archiveURL = try checkedOutput(requestedOutput, outside: directory)

        // Refuse to pack an invalid widget.
        let report = WidgetValidator.validate(directory: directory)
        guard report.isValid else {
            throw PackError.validationFailed(report.issues.map(\.description))
        }

        let manifestData = try Data(
            contentsOf: directory
                .appendingPathComponent(WidgetDiscovery.manifestFileName)
        )
        let sha256 = WidgetValidator.sha256Hex(of: manifestData)

        // Stage a copy so manifest.sha256 never pollutes the source tree.
        let staging = fm.temporaryDirectory
            .appendingPathComponent("barshelf-pack-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: staging) }
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)

        var excluded: [String] = []
        var relativeFiles = try copyPackageFiles(from: directory, to: staging, excluded: &excluded)
        try "\(sha256)  \(WidgetDiscovery.manifestFileName)\n".write(
            to: staging.appendingPathComponent(WidgetValidator.packSHA256FileName),
            atomically: true,
            encoding: .utf8
        )
        if !relativeFiles.contains(WidgetValidator.packSHA256FileName) {
            relativeFiles.append(WidgetValidator.packSHA256FileName)
        }
        relativeFiles.sort()

        let stagedReport = WidgetValidator.validate(directory: staging)
        guard stagedReport.isValid else {
            throw PackError.validationFailed(stagedReport.issues.map(\.description))
        }

        try fm.createDirectory(
            at: archiveURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // A sibling keeps the commit on one filesystem. Neither zip failure
        // nor rename failure removes the existing output; zip never appends
        // to an earlier release. The unique directory owns all temporary files.
        let temporary = archiveURL.deletingLastPathComponent()
            .appendingPathComponent(".barshelf-pack-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: temporary, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: temporary) }
        let temporaryArchive = temporary.appendingPathComponent("archive.mbw")
        try operations.zip(temporaryArchive, relativeFiles, staging)
        // Recheck after the long-running zip, including symlinked parents.
        guard try checkedOutput(requestedOutput, outside: directory) == archiveURL else {
            throw PackError.unsafeOutput(requestedOutput.path)
        }
        try operations.commit(temporaryArchive, archiveURL)
        return Output(
            archiveURL: requestedOutput,
            fileCount: relativeFiles.count,
            manifestSHA256: sha256,
            excludedPaths: excluded.sorted()
        )
    }

    /// Resolve existing ancestors even when several output directories do
    /// not exist yet. A symlinked parent must not bypass the package boundary.
    private static func canonicalURL(_ url: URL) -> URL {
        var ancestor = url.standardizedFileURL
        var suffix: [String] = []
        while !FileManager.default.fileExists(atPath: ancestor.path), ancestor.path != "/" {
            suffix.append(ancestor.lastPathComponent)
            ancestor.deleteLastPathComponent()
        }
        return suffix.reversed().reduce(ancestor.resolvingSymlinksInPath()) { $0.appendingPathComponent($1) }
            .standardizedFileURL
    }

    private static func checkedOutput(_ output: URL, outside directory: URL) throws -> URL {
        guard output.isFileURL else { throw PackError.unsafeOutput(output.absoluteString) }
        if let attributes = try? FileManager.default.attributesOfItem(atPath: output.path),
           attributes[.type] as? FileAttributeType != .typeRegular {
            throw PackError.unsafeOutput(output.path)
        }
        let resolved = canonicalURL(output)
        let root = directory.path
        guard resolved.path != root, !resolved.path.hasPrefix(root + "/") else {
            throw PackError.unsafeOutput(output.path)
        }
        return resolved
    }

    private static func commitArchive(_ temporary: URL, to destination: URL) throws {
        guard Darwin.rename(temporary.path, destination.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    /// Hidden files may be entry points or dependencies. Exclude only known
    /// metadata; reject symlinks rather than silently omitting package content.
    /// Returns the relative file paths.
    private static func copyPackageFiles(
        from source: URL, to destination: URL, excluded: inout [String]
    ) throws -> [String] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: source,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ) else {
            throw PackError.notADirectory(source.path)
        }

        let rootPath = source.standardizedFileURL.path
        var relativeFiles: [String] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(rootPath + "/") else { continue }
            let relative = String(path.dropFirst(rootPath.count + 1))
            if isPrivateOrMetadata(url.lastPathComponent) {
                excluded.append(relative)
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            if values.isSymbolicLink == true {
                throw PackError.symbolicLink(relative)
            }

            let target = destination.appendingPathComponent(relative)
            if values.isDirectory == true {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
            } else {
                try fm.createDirectory(
                    at: target.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try fm.copyItem(at: url, to: target)
                relativeFiles.append(relative)
            }
        }
        return relativeFiles
    }

    /// Hidden source modules are valid package assets; local credentials and
    /// editor/agent configuration are not distributable widget dependencies.
    private static func isPrivateOrMetadata(_ name: String) -> Bool {
        let name = name.lowercased()
        let excluded: Set<String> = [
            ".git", ".gitconfig", ".git-credentials", ".hg", ".hgrc", ".svn", ".ds_store", "__macosx",
            ".npmrc", ".netrc", ".pypirc", ".envrc", ".yarnrc", ".yarnrc.yml", ".pnpmrc",
            ".ssh", ".aws", ".azure", ".gnupg", ".docker", ".kube", ".config", ".pgpass",
            ".terraform", ".terraformrc", "terraform.rc", "terraform.tfstate", "terraform.tfstate.backup",
            ".s3cfg", ".boto", ".dev.vars", ".vault-token",
            ".vscode", ".idea", ".claude", ".codex", ".cursor", ".gemini", ".mcp.json",
            ".bash_history", ".zsh_history", ".sh_history", ".ash_history", ".history",
            ".python_history", ".node_repl_history", ".irb_history", ".pry_history", ".rediscli_history",
            ".mysql_history", ".psql_history", ".sqlite_history", ".fish_history", "fish_history",
            ".bash_sessions", ".zsh_sessions", ".lesshst", ".viminfo",
            "id_rsa", "id_ed25519", "id_ecdsa", "id_dsa", "id_xmss", "id_ecdsa_sk", "id_ed25519_sk",
        ]
        let excludedExtensions: Set<String> = [
            "mbw", "pem", "key", "p12", "pfx", "p8", "jks", "keystore", "ppk", "pkcs12", "pkcs8",
            "swp", "swo", "swn",
        ]
        let localConfiguration = [".env", ".envrc", ".dev.vars", ".mcp.json"]
            .contains { name == $0 || name.hasPrefix($0 + ".") }
        // Editor recovery/lock files can retain text removed from the live
        // source. Unknown hidden source modules otherwise remain distributable.
        let editorTemporary = name.hasSuffix("~") || name.hasPrefix(".#")
            || (name.hasPrefix("#") && name.hasSuffix("#"))
        return excluded.contains(name) || localConfiguration || editorTemporary
            || excludedExtensions.contains((name as NSString).pathExtension)
    }

    private static func runZip(
        archive: URL, files: [String], workingDirectory: URL
    ) throws {
        guard FileManager.default.isExecutableFile(atPath: zipToolPath) else {
            throw PackError.zipToolMissing(zipToolPath)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: zipToolPath)
        // -X: no extra file attributes; -q: quiet. Explicit file list keeps
        // entry names clean (no "./" prefixes) for SafeZipExtractor.
        process.arguments = ["-X", "-q", archive.path, "--"] + files
        process.currentDirectoryURL = workingDirectory

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            throw PackError.zipFailed(
                status: process.terminationStatus,
                output: String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            )
        }
    }
}
