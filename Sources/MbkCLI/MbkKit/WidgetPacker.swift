import Foundation
import MenubucketCore

/// `mbk pack` — zips a widget directory into a `.mbw` archive, adding a
/// `manifest.sha256` checksum of widget.json to the archive. Uses
/// `/usr/bin/zip` (a developer-tool invocation, not a runtime shellout).
public enum WidgetPacker {
    public struct Output: Equatable, Sendable {
        public let archiveURL: URL
        public let fileCount: Int
        /// sha256 of widget.json (also recorded in manifest.sha256).
        public let manifestSHA256: String
    }

    public enum PackError: Error, LocalizedError, Equatable {
        case notADirectory(String)
        case validationFailed([String])
        case zipToolMissing(String)
        case zipFailed(status: Int32, output: String)

        public var errorDescription: String? {
            switch self {
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

    /// Validates, stages (widget files + manifest.sha256) and zips.
    /// `output` defaults to `<directory-name>.mbw` in the current directory.
    @discardableResult
    public static func pack(directory: URL, output: URL? = nil) throws -> Output {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw PackError.notADirectory(directory.path)
        }

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
            .appendingPathComponent("mbk-pack-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: staging) }
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)

        var relativeFiles = try copyPackageFiles(from: directory, to: staging)
        try "\(sha256)  \(WidgetDiscovery.manifestFileName)\n".write(
            to: staging.appendingPathComponent(WidgetValidator.packSHA256FileName),
            atomically: true,
            encoding: .utf8
        )
        relativeFiles.append(WidgetValidator.packSHA256FileName)
        relativeFiles.sort()

        let archiveURL = (
            output
                ?? URL(fileURLWithPath: fm.currentDirectoryPath)
                    .appendingPathComponent(directory.lastPathComponent + ".mbw")
        ).standardizedFileURL
        if fm.fileExists(atPath: archiveURL.path) {
            try fm.removeItem(at: archiveURL) // zip(1) would append otherwise
        }
        try fm.createDirectory(
            at: archiveURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        try runZip(archive: archiveURL, files: relativeFiles, workingDirectory: staging)
        return Output(
            archiveURL: archiveURL,
            fileCount: relativeFiles.count,
            manifestSHA256: sha256
        )
    }

    /// Copies the package's regular files (skipping hidden files such as
    /// .git/.DS_Store and symlinks — mirroring what SafeZipExtractor accepts).
    /// Returns the relative file paths.
    private static func copyPackageFiles(
        from source: URL, to destination: URL
    ) throws -> [String] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: source,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw PackError.notADirectory(source.path)
        }

        let rootPath = source.standardizedFileURL.path
        var relativeFiles: [String] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
            if values?.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(rootPath + "/") else { continue }
            let relative = String(path.dropFirst(rootPath.count + 1))

            let target = destination.appendingPathComponent(relative)
            if values?.isDirectory == true {
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
        process.arguments = ["-X", "-q", archive.path] + files
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
