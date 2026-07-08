import Foundation
import Security

/// Read-only Keychain access for widget secret injection.
///
/// Convention: secrets live under service `dev.barshelf` with the account
/// name derived from the env var (`OTPEEK_VAULT_PASSWORD` →
/// `otpeek-vault-password`). Users create them with:
/// `security add-generic-password -s dev.barshelf -a <account> -w`
enum KeychainStore {
    static let service = "dev.barshelf"

    /// Generic password lookup; nil when missing or unreadable.
    static func readPassword(service: String = KeychainStore.service, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Keychain account name for an env var: lowercased, `_` → `-`.
    static func account(forEnvironmentVariable name: String) -> String {
        name.lowercased().replacingOccurrences(of: "_", with: "-")
    }
}
