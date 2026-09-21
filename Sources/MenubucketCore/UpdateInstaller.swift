import Foundation

/// Replaces the installed app with a downloaded build, or refuses to.
///
/// The security-critical part is what it will *not* do: nothing is swapped in
/// until the downloaded bundle proves it was signed by the same developer as
/// the build asking to be replaced (see `CodeSignature`). Every failure leaves
/// the installed copy untouched, and the caller falls back to opening the
/// release page — the behavior BarShelf had before it could update itself.
public enum UpdateInstaller {
    /// Why an install cannot proceed. Each case says what the user can do.
    public enum Failure: Error, LocalizedError, Equatable {
        /// The running build carries no team identifier (ad-hoc or unsigned),
        /// so there is no anchor an update could be pinned to.
        case hostNotSigned
        case destinationNotWritable(String)
        case archiveRejected(String)
        case extractionFailed(String)
        case archiveHasNoApp
        case archiveHasSeveralApps
        case identityMismatch(expected: String, found: String)
        case signatureRejected(String)
        case gatekeeperRejected
        case replaceFailed(String)

        public var errorDescription: String? {
            switch self {
            case .hostNotSigned:
                return "This copy of BarShelf is not Developer ID signed, so an"
                    + " update cannot be verified against it."
            case let .destinationNotWritable(path):
                return "\(path) is not writable by this user."
            case let .archiveRejected(detail):
                return "The downloaded archive is not usable: \(detail)"
            case let .identityMismatch(expected, found):
                return "The downloaded build is \(found), not \(expected)."
            case let .extractionFailed(detail):
                return "The downloaded archive could not be expanded: \(detail)"
            case .archiveHasNoApp:
                return "The downloaded archive contains no application."
            case .archiveHasSeveralApps:
                return "The downloaded archive contains more than one application."
            case let .signatureRejected(detail):
                return "The downloaded build was rejected: \(detail)."
            case .gatekeeperRejected:
                return "macOS refused the downloaded build (it may have been"
                    + " revoked or is not notarized)."
            case let .replaceFailed(detail):
                return "The update could not be moved into place: \(detail)"
            }
        }

        public var recoverySuggestion: String? {
            switch self {
            case .hostNotSigned, .signatureRejected, .gatekeeperRejected, .identityMismatch:
                return "Download the release manually and verify its checksum."
            case .archiveRejected:
                return "Download the release manually and verify its checksum."
            case .destinationNotWritable, .replaceFailed:
                return "Move BarShelf to /Applications, or update with"
                    + " `brew upgrade --cask barshelf`."
            case .extractionFailed, .archiveHasNoApp, .archiveHasSeveralApps:
                return "Try again, or download the release manually."
            }
        }
    }

    /// Something that stops BarShelf offering to update itself at all.
    public enum Blocker: Equatable {
        case notSigned
        case notWritable
        /// Installed by Homebrew — self-updating would desync `brew`'s records,
        /// so the user is pointed at `brew upgrade --cask barshelf` instead.
        case homebrewManaged
        /// A sandboxed (Mac App Store) build. It cannot spawn `ditto`/`spctl`,
        /// and the Store owns its updates anyway.
        case sandboxed

        public var message: String {
            switch self {
            case .notSigned:
                return "This is a locally built copy, so BarShelf cannot verify"
                    + " an update against it."
            case .notWritable:
                return "BarShelf cannot write to its own location."
            case .homebrewManaged:
                return "BarShelf was installed with Homebrew."
            case .sandboxed:
                return "This copy came from the App Store, which handles its"
                    + " own updates."
            }
        }
    }

    /// Directories Homebrew records cask installs in — the Apple Silicon and
    /// Intel prefixes.
    public static let homebrewCaskroots = [
        "/opt/homebrew/Caskroom/barshelf",
        "/usr/local/Caskroom/barshelf",
    ]

    /// Where a `brew install --cask barshelf` puts the app (`app "BarShelf.app"`).
    public static let homebrewAppPath = "/Applications/BarShelf.app"

    /// The command that upgrades a Homebrew-managed copy. Named once so the
    /// menu item and `barshelf upgrade` cannot print different instructions for
    /// the same situation.
    public static let homebrewUpgradeCommand = "brew upgrade --cask barshelf"

    /// The same, for a CLI installed from the `barshelf-cli` formula.
    public static let homebrewCLIUpgradeCommand = "brew upgrade barshelf-cli"

    /// Homebrew's Cellar on the Apple Silicon and Intel prefixes. A formula's
    /// files live here, with a symlink in `<prefix>/bin` pointing at them.
    public static let homebrewCellars = [
        "/opt/homebrew/Cellar/",
        "/usr/local/Cellar/",
    ]

    /// Whether a command-line tool is one Homebrew manages.
    ///
    /// The cask check has an app-shaped counterpart in `blocker`; this is the
    /// formula-shaped one, and it matters more than it looks: `<prefix>/bin`
    /// comes before `~/.local/bin` on a default PATH, so a `brew install
    /// barshelf-cli` copy is the one that runs. Writing over it would leave
    /// `brew` convinced it still has the version it installed, and the next
    /// `brew upgrade` or `brew reinstall` would silently revert the update.
    ///
    /// Matched on the resolved path, since what is on PATH is the symlink.
    public static func isHomebrewManaged(
        tool: URL, cellars: [String] = homebrewCellars
    ) -> Bool {
        let path = tool.resolvingSymlinksInPath().standardizedFileURL.path
        return cellars.contains { path.hasPrefix($0) }
    }

    /// Whether this install can replace itself, and why not when it cannot.
    ///
    /// - Parameter hostTeam: the running build's **Developer ID** team, or nil
    ///   when it has none. Merely carrying a team identifier is not enough —
    ///   a contributor's Apple Development identity supplies one, and an update
    ///   signed for release would then be downloaded only to be rejected.
    ///
    /// The closures are injected so the environment probes are testable on a
    /// machine that has neither Homebrew nor a sandbox.
    public static func blocker(
        appURL: URL,
        hostTeam: String?,
        isSandboxed: Bool = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil,
        isWritable: (String) -> Bool = { FileManager.default.isWritableFile(atPath: $0) },
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> Blocker? {
        if isSandboxed { return .sandboxed }
        // Only *this* copy being the Homebrew one matters. Testing for the
        // Caskroom alone would strand someone who has the cask installed and
        // also runs a build from elsewhere: they would be told to
        // `brew upgrade`, which upgrades a different copy.
        if homebrewCaskroots.contains(where: fileExists),
           appURL.standardizedFileURL.path == homebrewAppPath {
            return .homebrewManaged
        }
        guard hostTeam != nil else { return .notSigned }
        // Only the parent matters: `replaceItemAt` renames the new bundle into
        // place and unlinks the old one, and both are directory-entry changes
        // in the parent. An app installed by a package as root is mode 755
        // root:wheel inside while /Applications stays writable by admins —
        // checking the bundle itself would refuse an update that works.
        guard isWritable(appURL.deletingLastPathComponent().path) else { return .notWritable }
        return nil
    }

    /// An update that is in place but not yet trusted to work.
    ///
    /// The previous bundle is kept alongside it until a caller says which way
    /// it went. Verifying *before* the swap cannot stand in for this: the
    /// failure that made it necessary was refused by the kernel for the
    /// destination path specifically, so the same bundle launched from a
    /// staging directory came up perfectly.
    public struct Installed {
        public let app: URL
        public let version: String?
        /// The previous bundle, parked next to `app`. Nil when there was
        /// nothing to replace.
        public let previous: URL?

        /// Discard the previous bundle. Call once the replacement has proved
        /// it runs.
        public func confirm() {
            guard let previous else { return }
            try? FileManager.default.removeItem(at: previous)
        }

        /// Put the previous bundle back, because the replacement does not run.
        ///
        /// Returns false when there is nothing to restore or the restore
        /// itself failed — the caller is then holding a broken install and has
        /// to say so rather than imply it recovered.
        @discardableResult
        public func rollBack() -> Bool {
            guard let previous,
                  FileManager.default.fileExists(atPath: previous.path)
            else { return false }
            do {
                _ = try FileManager.default.replaceItemAt(app, withItemAt: previous)
                return true
            } catch {
                return false
            }
        }
    }

    /// What the superseded bundle is called while it waits to be confirmed or
    /// restored. Hidden, so Launch Services does not briefly offer two copies
    /// of the same application.
    static func backupName(for target: URL) -> String {
        ".\(target.lastPathComponent).barshelf-previous"
    }

    /// Expands `archive`, verifies the app inside it, and swaps it for `target`.
    ///
    /// - Parameter expectedTeam: the Developer ID team the replacement must be
    ///   signed by — in production the running app's own, so a build signed by
    ///   anyone else (including an unsigned one) is refused.
    /// - Parameter expectedBundleID: the bundle identifier the replacement must
    ///   carry. A correctly signed build of a *different* product from the same
    ///   developer is not an update to this one.
    /// - Returns: the installed build, with the bundle it displaced kept until
    ///   the caller confirms or rolls back.
    @discardableResult
    public static func install(
        archive: URL,
        replacing target: URL,
        expectedTeam: String,
        expectedBundleID: String?,
        checkGatekeeper: Bool = true
    ) throws -> Installed {
        let fileManager = FileManager.default
        guard fileManager.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
            throw Failure.destinationNotWritable(target.deletingLastPathComponent().path)
        }

        // The archive is attacker-controlled bytes until the signature check
        // below passes, and `ditto` has to see it first — nothing can verify a
        // bundle that has not been expanded. Bound it before it is handed over.
        try validateArchive(archive)

        // Staging has to share a volume with the target for the swap to be
        // atomic; that is exactly what an item-replacement directory is for.
        let staging = try fileManager.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: target,
            create: true
        )
        defer { try? fileManager.removeItem(at: staging) }

        try expand(archive: archive, into: staging)
        let app = try locateApp(in: staging)

        if let expectedBundleID {
            let found = bundleIdentifier(of: app)
            guard found == expectedBundleID else {
                throw Failure.identityMismatch(
                    expected: expectedBundleID, found: found ?? "an unidentified application"
                )
            }
        }

        let status = CodeSignature.verify(app, signedBy: expectedTeam)
        guard status == errSecSuccess else {
            throw Failure.signatureRejected(CodeSignature.describe(status))
        }
        if checkGatekeeper, !CodeSignature.passesGatekeeper(app) {
            throw Failure.gatekeeperRejected
        }

        let version = installedVersion(of: app)
        // A backup from a run that died before confirming would otherwise be
        // restored later as if it were this update's predecessor.
        let backup = target.deletingLastPathComponent()
            .appendingPathComponent(backupName(for: target))
        try? fileManager.removeItem(at: backup)

        let hadPrevious = fileManager.fileExists(atPath: target.path)
        do {
            _ = try fileManager.replaceItemAt(
                target,
                withItemAt: app,
                backupItemName: hadPrevious ? backupName(for: target) : nil,
                options: hadPrevious ? [.withoutDeletingBackupItem] : []
            )
        } catch {
            throw Failure.replaceFailed(error.localizedDescription)
        }
        let kept = hadPrevious && fileManager.fileExists(atPath: backup.path)
        return Installed(app: target, version: version, previous: kept ? backup : nil)
    }

    /// Largest update archive that will be opened at all.
    public static let maximumArchiveBytes = 512 * 1024 * 1024

    /// Bounds an untrusted archive before `ditto` touches it: reads the central
    /// directory, rejects entries that would escape the destination, and caps
    /// the uncompressed total.
    static func validateArchive(_ archive: URL) throws {
        let size = (try? FileManager.default.attributesOfItem(atPath: archive.path))?[.size] as? Int
        guard let size, size > 0 else {
            throw Failure.archiveRejected("it is empty or unreadable")
        }
        guard size <= maximumArchiveBytes else {
            throw Failure.archiveRejected("it is larger than \(maximumArchiveBytes / 1_048_576) MB")
        }
        do {
            let data = try Data(contentsOf: archive, options: [.mappedIfSafe])
            _ = try SafeZipExtractor.inspect(zipData: data)
        } catch let error as ZipExtractionError {
            throw Failure.archiveRejected(error.errorDescription ?? "\(error)")
        } catch {
            throw Failure.archiveRejected(error.localizedDescription)
        }
    }

    public static func bundleIdentifier(of app: URL) -> String? {
        infoDictionary(of: app)?["CFBundleIdentifier"] as? String
    }

    /// `ditto` rather than a zip library: it is the tool that preserves the
    /// extended attributes and symlinks an app bundle's signature is computed
    /// over. Expanding with anything else can invalidate a valid signature.
    static func expand(archive: URL, into directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, directory.path]
        let errors = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        do {
            try process.run()
        } catch {
            throw Failure.extractionFailed(error.localizedDescription)
        }
        let data = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure.extractionFailed(
                detail?.isEmpty == false ? detail! : "ditto exited \(process.terminationStatus)"
            )
        }
    }

    /// The single `.app` an update archive is expected to contain. More than
    /// one is refused rather than guessed at.
    static func locateApp(in directory: URL) throws -> URL {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        let apps = entries.filter { $0.pathExtension == "app" }
        switch apps.count {
        case 0: throw Failure.archiveHasNoApp
        case 1: return apps[0]
        default: throw Failure.archiveHasSeveralApps
        }
    }

    public static func installedVersion(of app: URL) -> String? {
        let version = infoDictionary(of: app)?["CFBundleShortVersionString"] as? String
        return (version?.isEmpty == false) ? version : nil
    }

    static func infoDictionary(of app: URL) -> [String: Any]? {
        let plist = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist) else { return nil }
        return (try? PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        )) as? [String: Any]
    }
}
