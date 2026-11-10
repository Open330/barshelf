import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// A session key sealed to a Secure Enclave key that only current
/// biometrics can use. Holds no plaintext, no context and no opened key.
struct SealedSecret: Sendable, Equatable {
    /// `SecureEnclave.P256.KeyAgreement.PrivateKey.dataRepresentation`:
    /// usable only by this Mac's Secure Enclave, and only after Touch ID.
    let enclaveKey: Data
    /// The sender's one-time public key (x9.63).
    let ephemeralPublic: Data
    let salt: Data
    /// AES-GCM nonce, ciphertext and tag.
    let box: Data
}

/// Why a Touch ID resume did not produce the key.
enum ResumeFailure: Error, Equatable, Sendable {
    /// The user, the system or BarShelf cancelled; the resume stays.
    case cancelled
    /// The user chose Use Password.
    case fallback
    /// No usable sensor right now (lid closed, nothing enrolled); the resume stays.
    case unavailable
    /// Lockout, changed enrollment or a damaged envelope: the resume is void.
    case invalid
}

/// Whether Touch ID can be asked for right now.
enum BiometryState: Equatable, Sendable {
    case available
    /// Nothing usable at the moment (lid closed, sensor busy): sealed copies stay.
    case unavailable
    /// Locked out, or every finger removed: sealed copies are void.
    case invalid
}

/// Seals a secret for Touch ID resume and opens it again. Swappable in tests.
protocol VaultKeySealer: Sendable {
    var biometry: BiometryState { get }
    func seal(_ secret: Data, aad: Data) throws -> SealedSecret
    /// Asks for Touch ID, then opens with the Secure Enclave. Cancelling the
    /// calling task cancels the prompt.
    func open(_ sealed: SealedSecret, aad: Data, reason: String) async -> Result<Data, ResumeFailure>
}

/// ECIES to a Secure Enclave P-256 key: a fresh software key agrees with the
/// enclave's public key (no authentication needed to seal), HKDF-SHA256 with a
/// random salt derives an AES-GCM key, and the ephemeral private key, shared
/// secret and AES key are dropped. Opening rebuilds the enclave key with an
/// LAContext the user just authorized; the enclave enforces
/// `biometryCurrentSet` on the key agreement itself, so a new or removed
/// finger voids every sealed copy.
struct SecureEnclaveSealer: VaultKeySealer {
    static let info = Data("barshelf.vault.resume.v1".utf8)

    var biometry: BiometryState {
        guard SecureEnclave.isAvailable else { return .unavailable }
        var error: NSError?
        if LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) { return .available }
        switch (error as? LAError)?.code {
        case .biometryLockout?, .biometryNotEnrolled?: return .invalid
        default: return .unavailable
        }
    }

    func seal(_ secret: Data, aad: Data) throws -> SealedSecret {
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, [.privateKeyUsage, .biometryCurrentSet], &error
        ) else { throw ResumeFailure.unavailable }
        let enclave = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: access)
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: enclave.publicKey)
        var salt = Data(count: 32)
        let status = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        guard status == errSecSuccess else { throw ResumeFailure.unavailable }
        let key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: Self.info, outputByteCount: 32)
        let box = try AES.GCM.seal(secret, using: key, authenticating: aad)
        guard let combined = box.combined else { throw ResumeFailure.invalid }
        return SealedSecret(enclaveKey: enclave.dataRepresentation,
                            ephemeralPublic: ephemeral.publicKey.x963Representation,
                            salt: salt, box: combined)
    }

    func open(_ sealed: SealedSecret, aad: Data, reason: String) async -> Result<Data, ResumeFailure> {
        // A fresh context per attempt, never reused, invalidated at the end.
        let context = LAContext()
        context.localizedFallbackTitle = String(localized: "Use Password")
        context.touchIDAuthenticationAllowableReuseDuration = 0
        defer { context.invalidate() }
        do {
            try await withTaskCancellationHandler {
                _ = try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)
            } onCancel: {
                context.invalidate()
            }
        } catch {
            if Task.isCancelled { return .failure(.cancelled) }
            switch (error as? LAError)?.code {
            case .userFallback?: return .failure(.fallback)
            case .biometryNotAvailable?, .biometryNotEnrolled?, .passcodeNotSet?, .biometryDisconnected?:
                return .failure(.unavailable)
            case .biometryLockout?, .invalidContext?: return .failure(.invalid)
            default: return .failure(.cancelled)
            }
        }
        if Task.isCancelled { return .failure(.cancelled) }
        do {
            let enclave = try SecureEnclave.P256.KeyAgreement.PrivateKey(
                dataRepresentation: sealed.enclaveKey, authenticationContext: context)
            let sender = try P256.KeyAgreement.PublicKey(x963Representation: sealed.ephemeralPublic)
            let shared = try enclave.sharedSecretFromKeyAgreement(with: sender)
            let key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: sealed.salt,
                                                     sharedInfo: Self.info, outputByteCount: 32)
            return .success(try AES.GCM.open(AES.GCM.SealedBox(combined: sealed.box), using: key, authenticating: aad))
        } catch {
            return .failure(.invalid)
        }
    }
}
