import Foundation

/// Replaces the installed `barshelf` / `bsf` binaries with the ones from a
/// release tarball, or refuses to.
///
/// This is `UpdateInstaller`'s counterpart for the standalone CLI, and it
/// differs in one way worth stating plainly rather than papering over: a bare
/// Mach-O cannot carry a stapled notarization ticket, and `spctl --assess`
/// answers *"the code is valid but does not seem to be an app"* for one. So the
/// gate here is the **Developer ID requirement** — the same one the app update
/// applies — without Gatekeeper's additional notarization/revocation verdict.
/// Everything else is identical: verify first, swap only afterwards, and leave
/// the installed binaries untouched on any failure.
public enum CommandLineToolInstaller {
    public enum Failure: Error, LocalizedError, Equatable {
        case archiveRejected(String)
        case extractionFailed(String)
        case archiveMissingTool(String)
        case notARegularFile(String)
        case destinationNotWritable(String)
        case signatureRejected(tool: String, detail: String)
        case replaceFailed(tool: String, detail: String)

        public var errorDescription: String? {
            switch self {
            case let .archiveRejected(detail):
                return "The downloaded archive is not usable: \(detail)"
            case let .extractionFailed(detail):
                return "The downloaded archive could not be expanded: \(detail)"
            case let .archiveMissingTool(name):
                return "The downloaded archive contains no \(name)."
            case let .notARegularFile(name):
                return "\(name) in the downloaded archive is not a plain file."
            case let .destinationNotWritable(path):
                return "\(path) is not writable by this user."
            case let .signatureRejected(tool, detail):
                return "The downloaded \(tool) was rejected: \(detail)."
            case let .replaceFailed(tool, detail):
                return "\(tool) could not be moved into place: \(detail)"
            }
        }

        public var recoverySuggestion: String? {
            switch self {
            case .destinationNotWritable, .replaceFailed:
                return "Re-run with sudo, or install the CLI somewhere you own"
                    + " (for example ~/.local/bin)."
            default:
                return "Download the release manually and verify its checksum."
            }
        }
    }

    /// Largest CLI tarball that will be opened at all. The real one is a few
    /// megabytes; this only has to be small enough that a hostile response
    /// cannot fill the disk before the signature check ever runs.
    public static let maximumArchiveBytes = 64 * 1024 * 1024
    /// Largest single extracted binary.
    public static let maximumToolBytes = 64 * 1024 * 1024

    /// The binaries a BarShelf CLI tarball ships, in the order `release.sh`
    /// packs them.
    public static let toolNames = ["barshelf", "bsf"]

    /// Verifies every tool in `archive` and then swaps each one in.
    ///
    /// - Parameter targets: absolute paths of the installed binaries to
    ///   replace. Each one's file name selects the member extracted from the
    ///   archive, so nothing outside that set is ever unpacked.
    /// - Parameter expectedTeam: the Developer ID team the replacements must be
    ///   signed by — the team that signed the binary asking to be replaced.
    ///
    /// Verification happens for *all* tools before any of them is swapped, so a
    /// bad archive cannot leave half the CLI updated.
    public static func install(
        archive: URL,
        replacing targets: [URL],
        expectedTeam: String
    ) throws {
        guard !targets.isEmpty else { return }
        let fileManager = FileManager.default
        for target in targets {
            let directory = target.deletingLastPathComponent().path
            guard fileManager.isWritableFile(atPath: directory) else {
                throw Failure.destinationNotWritable(directory)
            }
        }

        try validateArchive(archive)

        let work = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: work) }
        let names = targets.map(\.lastPathComponent)
        let present = try members(of: archive)
        for name in names where !present.contains(name) {
            throw Failure.archiveMissingTool(name)
        }
        try extract(names, from: archive, into: work)

        // Verify every tool before the first swap.
        for name in names {
            let extracted = work.appendingPathComponent(name)
            try checkExtracted(extracted, named: name, signedBy: expectedTeam)
        }

        for target in targets {
            let name = target.lastPathComponent
            // `replaceItemAt` renames the replacement over the target, so the
            // replacement has to sit on the target's volume — which is what an
            // item-replacement directory is for. Copying there is a byte copy
            // and a Mach-O signature is embedded in those bytes, so it travels
            // with the file; the check above still describes what lands.
            let staging = try fileManager.url(
                for: .itemReplacementDirectory,
                in: .userDomainMask,
                appropriateFor: target,
                create: true
            )
            defer { try? fileManager.removeItem(at: staging) }
            let staged = staging.appendingPathComponent(name)
            do {
                try fileManager.copyItem(at: work.appendingPathComponent(name), to: staged)
            } catch {
                throw Failure.replaceFailed(tool: name, detail: error.localizedDescription)
            }
            do {
                // Renaming over a running executable is allowed (writing into
                // one is not), so the binary doing this can replace itself.
                _ = try fileManager.replaceItemAt(target, withItemAt: staged)
            } catch {
                throw Failure.replaceFailed(tool: name, detail: error.localizedDescription)
            }
        }
    }

    // MARK: - Internals

    static func validateArchive(_ archive: URL) throws {
        let size = (try? FileManager.default.attributesOfItem(atPath: archive.path))?[.size] as? Int
        guard let size, size > 0 else {
            throw Failure.archiveRejected("it is empty or unreadable")
        }
        guard size <= maximumArchiveBytes else {
            throw Failure.archiveRejected(
                "it is larger than \(maximumArchiveBytes / 1_048_576) MB"
            )
        }
    }

    /// The archive's member names, so a missing tool is reported as such rather
    /// than as whatever `tar` prints when asked for something that is not there.
    static func members(of archive: URL) throws -> [String] {
        let (status, output, errors) = tar(["-tzf", archive.path])
        guard status == 0 else { throw Failure.extractionFailed(detail(errors, status: status)) }
        return output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Unpacks exactly the named members. Naming them is the containment: a
    /// member called `../../something` cannot match `barshelf`, so nothing an
    /// archive invents gets written.
    static func extract(_ names: [String], from archive: URL, into directory: URL) throws {
        let (status, _, errors) = tar(
            ["-xzf", archive.path, "-C", directory.path, "--"] + names
        )
        guard status == 0 else { throw Failure.extractionFailed(detail(errors, status: status)) }
    }

    private static func tar(_ arguments: [String]) -> (Int32, String, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = arguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        guard (try? process.run()) != nil else { return (-1, "", "tar could not be started") }
        let out = output.fileHandleForReading.readDataToEndOfFile()
        let err = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(data: out, encoding: .utf8) ?? "",
            String(data: err, encoding: .utf8) ?? ""
        )
    }

    private static func detail(_ errors: String, status: Int32) -> String {
        let trimmed = errors.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "tar exited \(status)" : trimmed
    }

    static func checkExtracted(_ url: URL, named name: String, signedBy team: String) throws {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard let attributes else { throw Failure.archiveMissingTool(name) }
        // A symlink member would otherwise have the checks below follow it out
        // of the staging directory and the swap install a dangling link.
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw Failure.notARegularFile(name)
        }
        guard let size = attributes[.size] as? Int, size > 0, size <= maximumToolBytes else {
            throw Failure.archiveRejected("\(name) is empty or implausibly large")
        }
        let status = CodeSignature.verify(url, signedBy: team)
        guard status == errSecSuccess else {
            throw Failure.signatureRejected(tool: name, detail: CodeSignature.describe(status))
        }
    }

    private static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("barshelf-cli-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
