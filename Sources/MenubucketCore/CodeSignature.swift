import Foundation
import Security

/// Code-signature inspection, used to decide whether a downloaded build is
/// allowed to replace the running one.
///
/// The trust anchor is the system's, not ours: an update must satisfy
/// `anchor apple generic and certificate leaf[subject.OU] = "<team>"`, which is
/// the same Developer ID requirement Gatekeeper evaluates. Nothing here invents
/// a signature scheme, and nothing here trusts a checksum published next to the
/// download — an attacker able to serve the archive can serve its hash too.
public enum CodeSignature {
    /// Team identifier recorded in a bundle's signature.
    ///
    /// `nil` for an unsigned or ad-hoc-signed bundle, which is the signal that
    /// there is no anchor to pin an update against.
    public static func teamIdentifier(of url: URL) -> String? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode
        else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information
        ) == errSecSuccess,
            let dictionary = information as? [String: Any]
        else { return nil }
        let team = dictionary[kSecCodeInfoTeamIdentifier as String] as? String
        return (team?.isEmpty == false) ? team : nil
    }

    /// The running process's own team identifier.
    public static func hostTeamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode
        else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information
        ) == errSecSuccess,
            let dictionary = information as? [String: Any]
        else { return nil }
        let team = dictionary[kSecCodeInfoTeamIdentifier as String] as? String
        return (team?.isEmpty == false) ? team : nil
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

        var requirement: SecRequirement?
        let text = "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
        let compiled = SecRequirementCreateWithString(text as CFString, [], &requirement)
        guard compiled == errSecSuccess else { return compiled }

        return SecStaticCodeCheckValidity(
            staticCode,
            SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode),
            requirement
        )
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
    public static func passesGatekeeper(_ url: URL) -> Bool {
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
        process.waitUntilExit()
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
}
