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
        case extractionFailed(String)
        case archiveHasNoApp
        case archiveHasSeveralApps
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
            case .hostNotSigned, .signatureRejected, .gatekeeperRejected:
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

        public var message: String {
            switch self {
            case .notSigned:
                return "This is a locally built copy, so BarShelf cannot verify"
                    + " an update against it."
            case .notWritable:
                return "BarShelf cannot write to its own location."
            case .homebrewManaged:
                return "BarShelf was installed with Homebrew."
            }
        }
    }

    /// Directories Homebrew records cask installs in — the Apple Silicon and
    /// Intel prefixes.
    public static let homebrewCaskroots = [
        "/opt/homebrew/Caskroom/barshelf",
        "/usr/local/Caskroom/barshelf",
    ]

    /// Whether this install can replace itself, and why not when it cannot.
    ///
    /// `fileExists` is injected so the Homebrew probe is testable without a
    /// Homebrew installation.
    public static func blocker(
        appURL: URL,
        hostTeam: String?,
        isWritable: (String) -> Bool = { FileManager.default.isWritableFile(atPath: $0) },
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> Blocker? {
        if homebrewCaskroots.contains(where: fileExists) { return .homebrewManaged }
        guard hostTeam != nil else { return .notSigned }
        guard isWritable(appURL.deletingLastPathComponent().path),
              isWritable(appURL.path)
        else { return .notWritable }
        return nil
    }

    /// Expands `archive`, verifies the app inside it, and swaps it for `target`.
    ///
    /// - Parameter expectedTeam: the team the replacement must be signed by —
    ///   in production the running app's own, so a build signed by anyone else
    ///   (including an unsigned one) is refused.
    /// - Returns: the version string of the installed build, when its
    ///   `Info.plist` carries one.
    @discardableResult
    public static func install(
        archive: URL,
        replacing target: URL,
        expectedTeam: String,
        checkGatekeeper: Bool = true
    ) throws -> String? {
        let fileManager = FileManager.default
        guard fileManager.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
            throw Failure.destinationNotWritable(target.deletingLastPathComponent().path)
        }

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

        let status = CodeSignature.verify(app, signedBy: expectedTeam)
        guard status == errSecSuccess else {
            throw Failure.signatureRejected(CodeSignature.describe(status))
        }
        if checkGatekeeper, !CodeSignature.passesGatekeeper(app) {
            throw Failure.gatekeeperRejected
        }

        let version = installedVersion(of: app)
        do {
            _ = try fileManager.replaceItemAt(target, withItemAt: app)
        } catch {
            throw Failure.replaceFailed(error.localizedDescription)
        }
        return version
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

    static func installedVersion(of app: URL) -> String? {
        let plist = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil
              ) as? [String: Any]
        else { return nil }
        let version = info["CFBundleShortVersionString"] as? String
        return (version?.isEmpty == false) ? version : nil
    }
}
