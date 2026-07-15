import Foundation
import CryptoKit
import MenubucketCore

/// `barshelf validate` — decodes widget.json (and workflow.json when present)
/// with the MenubucketCore decoders and reports problems per file / field.
public enum WidgetValidator {
    public struct Issue: Equatable, CustomStringConvertible, Sendable {
        /// Path relative to the validated root, e.g. "widget.json" or
        /// "my-widget/workflow.json".
        public let file: String
        /// Dotted field path inside the file ("entry.kind"), empty when the
        /// problem is file-level (missing file, invalid JSON).
        public let field: String
        public let message: String

        public init(file: String, field: String = "", message: String) {
            self.file = file
            self.field = field
            self.message = message
        }

        public var description: String {
            field.isEmpty ? "\(file): \(message)" : "\(file): \(field): \(message)"
        }
    }

    public struct Report: Equatable, Sendable {
        /// Widget directories that were checked (relative paths).
        public var validatedWidgets: [String]
        public var issues: [Issue]

        public var isValid: Bool {
            issues.isEmpty && !validatedWidgets.isEmpty
        }
    }

    public enum ValidationError: Error, LocalizedError, Equatable {
        case pathNotFound(String)

        public var errorDescription: String? {
            switch self {
            case let .pathNotFound(path):
                return "no such file or directory: \(path)"
            }
        }
    }

    /// Validates a widget directory, or a packed `.mbw`/`.zip` archive
    /// (extracted with SafeZipExtractor first).
    public static func validate(path: URL) throws -> Report {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: path.path, isDirectory: &isDirectory) else {
            throw ValidationError.pathNotFound(path.path)
        }

        if isDirectory.boolValue {
            return validate(directory: path, prefix: "")
        }
        return try validate(archive: path)
    }

    /// Validates one widget package directory.
    public static func validate(directory: URL, prefix: String = "") -> Report {
        var report = Report(validatedWidgets: [], issues: [])
        validate(directory: directory, prefix: prefix, into: &report)
        return report
    }

    /// Extracts a packed archive to a temporary directory and validates every
    /// widget package inside (root widget or nested directories).
    public static func validate(archive: URL) throws -> Report {
        let data = try Data(contentsOf: archive)
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "barshelf-validate-\(UUID().uuidString)", isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: staging) }
        try SafeZipExtractor.extract(zipData: data, to: staging)

        // Locate widget package directories (same walk the installer uses).
        let discovery = try WidgetDiscovery.discover(under: staging)
        var report = Report(validatedWidgets: [], issues: [])
        for failure in discovery.failures {
            report.issues.append(Issue(
                file: joinPath(failure.relativePath, WidgetDiscovery.manifestFileName),
                message: failure.reason
            ))
        }
        for candidate in discovery.candidates {
            let prefix = candidate.relativePath == "." ? "" : candidate.relativePath
            validate(directory: candidate.directory, prefix: prefix, into: &report)
        }
        if discovery.candidates.isEmpty && discovery.failures.isEmpty {
            report.issues.append(Issue(
                file: WidgetDiscovery.manifestFileName,
                message: "no widget.json found in the archive"
            ))
        }
        return report
    }

    // MARK: - Directory validation

    private static let knownEntryKinds: Set<String> = ["exec", "workflow", "script"]

    private static func validate(
        directory: URL, prefix: String, into report: inout Report
    ) {
        let manifestFile = joinPath(prefix, WidgetDiscovery.manifestFileName)
        let manifestURL = directory
            .appendingPathComponent(WidgetDiscovery.manifestFileName)

        guard let data = try? Data(contentsOf: manifestURL) else {
            report.issues.append(Issue(
                file: manifestFile, message: "file not found"
            ))
            return
        }

        let manifest: Manifest
        do {
            manifest = try Manifest.decode(from: data)
        } catch {
            report.issues.append(decodingIssue(error, file: manifestFile))
            return
        }
        report.validatedWidgets.append(prefix.isEmpty ? "." : prefix)

        if !WidgetDiscovery.isValidWidgetID(manifest.id) {
            report.issues.append(Issue(
                file: manifestFile,
                field: "id",
                message: "invalid widget id \"\(manifest.id)\" — letters/digits"
                    + " plus '-', '_', '.' (must start with a letter or digit)"
            ))
        }

        if !knownEntryKinds.contains(manifest.entry.kind) {
            report.issues.append(Issue(
                file: manifestFile,
                field: "entry.kind",
                message: "unknown kind \"\(manifest.entry.kind)\""
                    + " (expected exec | workflow | script)"
            ))
        }

        // entry.main (workflow default: workflow.json) must exist and decode.
        var workflowFileName: String?
        if manifest.entry.kind == "workflow" {
            workflowFileName = manifest.entry.main ?? "workflow.json"
        } else if FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("workflow.json").path
        ) {
            // Stray workflow.json next to a non-workflow entry still gets checked.
            workflowFileName = "workflow.json"
        }

        if manifest.entry.kind == "workflow" || manifest.entry.kind == "script" {
            do {
                let entryURL = try WidgetEntryResolver.resolve(
                    directory: directory,
                    main: manifest.entry.main,
                    defaultName: manifest.entry.kind == "script" ? "index.ts" : "workflow.json"
                )
                if !FileManager.default.fileExists(atPath: entryURL.path) {
                    report.issues.append(Issue(
                        file: manifestFile,
                        field: "entry.main",
                        message: "entry file not found: \(entryURL.lastPathComponent)"
                    ))
                }
            } catch {
                report.issues.append(Issue(
                    file: manifestFile,
                    field: "entry.main",
                    message: error.localizedDescription
                ))
                workflowFileName = nil
            }
        }

        if manifest.entry.kind == "exec",
           let command = manifest.source?.command,
           !command.isEmpty,
           ExecAllowlist.match(command: command, permissions: manifest.permissions?.exec) == nil {
            report.issues.append(Issue(
                file: manifestFile,
                field: "permissions.exec",
                message: "source.command is not covered by an exact exec allowlist entry"
            ))
        }

        if let workflowFileName {
            validateWorkflow(
                at: directory.appendingPathComponent(workflowFileName),
                file: joinPath(prefix, workflowFileName),
                into: &report
            )
        }

        if manifest.entry.kind == "exec",
           manifest.source?.command?.isEmpty != false,
           manifest.source?.discover?.isEmpty != false {
            report.issues.append(Issue(
                file: manifestFile,
                field: "source.command",
                message: "exec widgets need a source.command (or source.discover)"
            ))
        }

        // A manifest.sha256 written by `barshelf pack` must match widget.json.
        let sha256URL = directory.appendingPathComponent(packSHA256FileName)
        if let recorded = try? String(contentsOf: sha256URL, encoding: .utf8) {
            let expected = recorded
                .split(separator: "\n").first?
                .split(separator: " ").first
                .map(String.init) ?? ""
            let actual = sha256Hex(of: data)
            if expected.lowercased() != actual {
                report.issues.append(Issue(
                    file: joinPath(prefix, packSHA256FileName),
                    message: "checksum mismatch — widget.json was modified"
                        + " after packing (expected \(expected), got \(actual))"
                ))
            }
        }
    }

    private static func validateWorkflow(
        at url: URL, file: String, into report: inout Report
    ) {
        guard let data = try? Data(contentsOf: url) else {
            report.issues.append(Issue(file: file, message: "file not found"))
            return
        }
        do {
            _ = try JSONDecoder().decode(WorkflowDefinition.self, from: data)
        } catch {
            report.issues.append(decodingIssue(error, file: file))
        }
    }

    // MARK: - Helpers

    public static let packSHA256FileName = "manifest.sha256"

    public static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func joinPath(_ prefix: String, _ name: String) -> String {
        prefix.isEmpty || prefix == "." ? name : "\(prefix)/\(name)"
    }

    /// Maps a DecodingError onto "file: field.path: message".
    static func decodingIssue(_ error: Error, file: String) -> Issue {
        guard let decodingError = error as? DecodingError else {
            return Issue(file: file, message: error.localizedDescription)
        }
        switch decodingError {
        case let .keyNotFound(key, context):
            let path = fieldPath(context.codingPath + [key])
            return Issue(file: file, field: path, message: "missing required field")
        case let .typeMismatch(type, context):
            return Issue(
                file: file,
                field: fieldPath(context.codingPath),
                message: "wrong type — expected \(type)"
            )
        case let .valueNotFound(type, context):
            return Issue(
                file: file,
                field: fieldPath(context.codingPath),
                message: "null value — expected \(type)"
            )
        case let .dataCorrupted(context):
            let path = fieldPath(context.codingPath)
            return Issue(
                file: file,
                field: path,
                message: path.isEmpty
                    ? "invalid JSON: \(context.debugDescription)"
                    : context.debugDescription
            )
        @unknown default:
            return Issue(file: file, message: decodingError.localizedDescription)
        }
    }

    private static func fieldPath(_ codingPath: [CodingKey]) -> String {
        codingPath.map { key in
            if let index = key.intValue { return "[\(index)]" }
            return key.stringValue
        }
        .joined(separator: ".")
        .replacingOccurrences(of: ".[", with: "[")
    }
}
