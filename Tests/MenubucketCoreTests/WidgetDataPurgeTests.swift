import Security
import XCTest
@testable import MenubucketCore

/// Removing one widget instance erases exactly its storage and secrets.
final class WidgetDataPurgeTests: XCTestCase {
    func testStorageRemoveAllErasesOnlyThatInstanceAndRefusesLateWrites() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = StorageService(directory: directory)
        for id in ["pkg", "pkg--work", "pkg--work2"] {
            try storage.set(widgetId: id, key: "value", value: .string(id))
        }
        try storage.removeAll(widgetId: "pkg--work")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("pkg--work.json").path
        ))
        XCTAssertNil(storage.get(widgetId: "pkg--work", key: "value"))
        XCTAssertEqual(storage.get(widgetId: "pkg", key: "value"), .string("pkg"))
        XCTAssertEqual(storage.get(widgetId: "pkg--work2", key: "value"), .string("pkg--work2"))

        // A process still stopping cannot write the namespace back.
        XCTAssertThrowsError(try storage.set(widgetId: "pkg--work", key: "late", value: .bool(true)))
        XCTAssertThrowsError(try storage.delete(widgetId: "pkg--work", key: "late"))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("pkg--work.json").path
        ))
        try storage.removeAll(widgetId: "never-stored")

        // Loaded again (reinstall): writable, and starts empty.
        storage.retain(widgetIDs: ["pkg", "pkg--work"])
        XCTAssertNil(storage.get(widgetId: "pkg--work", key: "value"))
        try storage.set(widgetId: "pkg--work", key: "value", value: .number(1))
        XCTAssertEqual(storage.get(widgetId: "pkg--work", key: "value"), .number(1))

        try storage.removeAll(widgetId: "pkg")
        try storage.removeAll(widgetId: "pkg--work")
        storage.retain(widgetID: "pkg") // only this removal failed
        try storage.set(widgetId: "pkg", key: "fresh", value: .bool(true))
        XCTAssertThrowsError(try storage.set(widgetId: "pkg--work", key: "fresh", value: .bool(true)))
    }

    func testInMemorySecretsRemoveAllStopsAtTheSlashBoundary() throws {
        let secrets = InMemorySecretStore()
        for id in ["pkg", "pkg--work", "pkgx"] {
            try secrets.set(widgetId: id, key: "token", value: id)
        }
        try secrets.set(widgetId: "pkg", key: "nested/key", value: "n")
        try secrets.removeAll(widgetId: "pkg")
        XCTAssertNil(try secrets.get(widgetId: "pkg", key: "token"))
        XCTAssertNil(try secrets.get(widgetId: "pkg", key: "nested/key"))
        XCTAssertEqual(try secrets.get(widgetId: "pkg--work", key: "token"), "pkg--work")
        XCTAssertEqual(try secrets.get(widgetId: "pkgx", key: "token"), "pkgx")
        XCTAssertThrowsError(try secrets.removeAll(widgetId: ""))
        XCTAssertThrowsError(try secrets.removeAll(widgetId: "pkg/token"))
        XCTAssertEqual(try secrets.get(widgetId: "pkg--work", key: "token"), "pkg--work")
    }

    /// Writes to the login Keychain under a freshly generated service, so it
    /// never sees a real BarShelf secret. Opt in with BARSHELF_KEYCHAIN_TEST=1
    /// from a logged-in session (an SSH session's Keychain is locked).
    func testKeychainRemoveAllDeletesOnlyMatchingAccountsOfItsService() throws {
        guard ProcessInfo.processInfo.environment["BARSHELF_KEYCHAIN_TEST"] == "1" else {
            throw XCTSkip("set BARSHELF_KEYCHAIN_TEST=1 to exercise the real Keychain")
        }
        let service = "dev.barshelf.test.\(UUID().uuidString)"
        let foreignService = "dev.barshelf.test.\(UUID().uuidString)"
        let store = KeychainSecretStore(service: service)
        let foreign = KeychainSecretStore(service: foreignService)
        defer {
            for id in ["pkg", "pkg--work", "pkgx"] {
                try? store.removeAll(widgetId: id)
                try? foreign.removeAll(widgetId: id)
            }
        }
        for id in ["pkg", "pkg--work", "pkgx"] {
            try store.set(widgetId: id, key: "token", value: id)
        }
        try store.set(widgetId: "pkg", key: "second", value: "2")
        try foreign.set(widgetId: "pkg", key: "token", value: "foreign")

        try store.removeAll(widgetId: "pkg")
        XCTAssertNil(try store.get(widgetId: "pkg", key: "token"))
        XCTAssertNil(try store.get(widgetId: "pkg", key: "second"))
        XCTAssertEqual(try store.get(widgetId: "pkg--work", key: "token"), "pkg--work")
        XCTAssertEqual(try store.get(widgetId: "pkgx", key: "token"), "pkgx")
        XCTAssertEqual(try foreign.get(widgetId: "pkg", key: "token"), "foreign")
        try store.removeAll(widgetId: "pkg") // nothing left: still fine

        try store.removeAll(widgetId: "pkg--work")
        try store.removeAll(widgetId: "pkgx")
        try foreign.removeAll(widgetId: "pkg")
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        var items: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &items), errSecItemNotFound)
    }
}
