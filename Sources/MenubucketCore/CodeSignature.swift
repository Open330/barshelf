import Foundation
import Security

/// Code-signature inspection, used to decide whether a downloaded build is
/// allowed to replace the running one.
///
/// The trust anchor is the system's, not ours: an update must satisfy the
/// **Developer ID** requirement for a specific team — the same shape Gatekeeper
/// evaluates. Nothing here invents a signature scheme, and nothing here trusts
/// a checksum published next to the download; whoever can serve the archive can
/// serve its hash too.
public enum CodeSignature {
    /// Apple's certificate extension OIDs.
    ///
    /// Pinning only `anchor apple generic` + the team's OU would also accept an
    /// **Apple Development** or Mac App Store certificate from the same team —
    /// a developer's own debug identity could then sign a "release". These two
    /// extensions are what narrow it to Developer ID Application specifically.
    static let developerIDLeafOID = "1.2.840.113635.100.6.1.13"
    static let developerIDIntermediateOID = "1.2.840.113635.100.6.2.6"

    /// How long `spctl` is given before its verdict is treated as unavailable.
    /// The assessment performs a notarization lookup, which can hang on a
    /// captive portal.
    public static let gatekeeperTimeout: TimeInterval = 30

    /// The Developer ID requirement for `team`.
    public static func developerIDRequirement(team: String) -> String {
        "anchor apple generic"
            + " and certificate 1[field.\(developerIDIntermediateOID)] exists"
            + " and certificate leaf[field.\(developerIDLeafOID)] exists"
            + " and certificate leaf[subject.OU] = \"\(team)\""
    }

    /// Team identifier recorded in a bundle's signature.
    ///
    /// Present for Apple's own applications too, so this alone says nothing
    /// about *who* signed the code — use `isDeveloperIDSigned` for that.
    public static func teamIdentifier(of url: URL) -> String? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode
        else { return nil }
        return team(of: staticCode)
    }

    /// The running process's own team identifier.
    public static func hostTeamIdentifier() -> String? {
        guard let staticCode = hostStaticCode() else { return nil }
        return team(of: staticCode)
    }

    /// Whether the running build is itself a Developer ID release.
    ///
    /// This is the gate on offering an in-place update at all: a locally built
    /// copy — ad-hoc signed, or signed with the contributor's own Apple
    /// Development identity — has no release identity to pin an update against,
    /// and offering to "update" it would download the whole archive only to
    /// reject it.
    public static func hostDeveloperIDTeam() -> String? {
        guard let staticCode = hostStaticCode(),
              let team = team(of: staticCode),
              check(staticCode, against: developerIDRequirement(team: team)) == errSecSuccess
        else { return nil }
        return team
    }

    /// The Developer ID team of code on disk, or nil when it is not a
    /// Developer ID build.
    ///
    /// The counterpart to `hostDeveloperIDTeam()` for something other than the
    /// running process — `barshelf upgrade` needs it to anchor an app update to
    /// the *installed app's* identity rather than to the CLI's own.
    public static func developerIDTeam(of url: URL) -> String? {
        guard let team = teamIdentifier(of: url),
              verify(url, signedBy: team) == errSecSuccess
        else { return nil }
        return team
    }

    /// Whether the bundle is a Developer ID build from `team`, with an intact
    /// signature over every nested component.
    ///
    /// Returns the raw `OSStatus` so a caller can report *why* — a mismatched
    /// team (`errSecCSReqFailed`) reads very differently from a bundle that was
    /// tampered with after signing.
    public static func verify(_ url: URL, signedBy team: String) -> OSStatus {
        var staticCode: SecStaticCode?
        let created = SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode)
        guard created == errSecSuccess, let staticCode else { return created }
        return check(staticCode, against: developerIDRequirement(team: team))
    }

    public static func isSigned(_ url: URL, by team: String) -> Bool {
        verify(url, signedBy: team) == errSecSuccess
    }

    /// Gatekeeper's verdict, which additionally covers notarization (and its
    /// revocation). `SecAssessment` is not exposed to Swift, so this asks the
    /// same question through `spctl`.
    ///
    /// Checking before the swap means a build Apple has revoked is refused
    /// while the installed copy is still intact, instead of after it has been
    /// replaced by something macOS will not launch.
    ///
    /// A timeout counts as "not accepted": the assessment reaches the network,
    /// and an update must not hang on a stalled lookup.
    public static func passesGatekeeper(
        _ url: URL, timeout: TimeInterval = gatekeeperTimeout
    ) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/spctl")
        process.arguments = ["--assess", "--type", "execute", url.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }
        guard waitForExit(process, timeout: timeout) else {
            process.terminate()
            return false
        }
        return process.terminationStatus == 0
    }

    /// Human-readable form of the statuses this module produces.
    public static func describe(_ status: OSStatus) -> String {
        switch status {
        case errSecSuccess: return "valid"
        case errSecCSReqFailed: return "signed by a different developer"
        case errSecCSUnsigned: return "not signed"
        case errSecCSSignatureFailed: return "signature does not match its contents"
        case errSecCSStaticCodeNotFound: return "no code found at that path"
        default:
            return (SecCopyErrorMessageString(status, nil) as String?)
                ?? "code signing error \(status)"
        }
    }

    // MARK: - Internals

    private static func hostStaticCode() -> SecStaticCode? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess else { return nil }
        return staticCode
    }

    /// One reader for the signing dictionary. The host side is the trust
    /// anchor, so a second copy of this that drifted would be a security bug.
    private static func team(of staticCode: SecStaticCode) -> String? {
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information
        ) == errSecSuccess,
            let dictionary = information as? [String: Any]
        else { return nil }
        let team = dictionary[kSecCodeInfoTeamIdentifier as String] as? String
        return (team?.isEmpty == false) ? team : nil
    }

    /// `kSecCSStrictValidate` rejects the nonstandard bundle layouts — stray
    /// files or symlinks at the bundle root that the seal does not cover —
    /// that a plain validity check lets through. It is the hardening this
    /// verify-then-swap flow specifically needs.
    private static func check(_ staticCode: SecStaticCode, against requirement: String) -> OSStatus {
        var compiled: SecRequirement?
        let created = SecRequirementCreateWithString(requirement as CFString, [], &compiled)
        guard created == errSecSuccess else { return created }
        return SecStaticCodeCheckValidity(
            staticCode,
            SecCSFlags(
                rawValue: kSecCSCheckAllArchitectures
                    | kSecCSCheckNestedCode
                    | kSecCSStrictValidate
            ),
            compiled
        )
    }

    private static func waitForExit(_ process: Process, timeout: TimeInterval) -> Bool {
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        return finished.wait(timeout: .now() + timeout) == .success
    }
}
