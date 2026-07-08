import Foundation
import Security

/// Widget secret storage backing `host.secret.get/set`.
///
/// Production implementation is the Keychain (service `dev.barshelf`,
/// account `<widgetId>/<key>`); tests inject `InMemorySecretStore`.
public protocol SecretStoring: Sendable {
    func get(widgetId: String, key: String) throws -> String?
    func set(widgetId: String, key: String, value: String) throws
}

/// Keychain-backed secrets: generic passwords under service `dev.barshelf`
/// with account `<widgetId>/<key>`. Requires manifest
/// `permissions.keychain: true` (enforced by the supervisor, not here).
public struct KeychainSecretStore: SecretStoring {
    public static let service = "dev.barshelf"

    private let service: String

    public init(service: String = KeychainSecretStore.service) {
        self.service = service
    }

    static func account(widgetId: String, key: String) -> String {
        "\(widgetId)/\(key)"
    }

    public func get(widgetId: String, key: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.account(widgetId: widgetId, key: key),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw JsonRpcError.internalError("keychain read failed (status \(status))")
        }
        return String(data: data, encoding: .utf8)
    }

    public func set(widgetId: String, key: String, value: String) throws {
        let account = Self.account(widgetId: widgetId, key: key)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let valueData = Data(value.utf8)
        let update: [String: Any] = [kSecValueData as String: valueData]
        var status = SecItemUpdate(base as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = valueData
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw JsonRpcError.internalError("keychain write failed (status \(status))")
        }
    }
}

/// Test double: process-local secret map.
public final class InMemorySecretStore: SecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    public init() {}

    public func get(widgetId: String, key: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values["\(widgetId)/\(key)"]
    }

    public func set(widgetId: String, key: String, value: String) throws {
        lock.lock()
        defer { lock.unlock() }
        values["\(widgetId)/\(key)"] = value
    }
}
