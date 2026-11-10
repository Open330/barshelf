import AppKit
import XCTest
import MenubucketCore
@testable import MenubucketApp

@MainActor
final class VaultBrokerTests: XCTestCase {
    private final class FakeProvider: VaultProvider, @unchecked Sendable {
        let lock = NSLock()
        var unlockDelayNs: UInt64 = 0
        var locked: [String] = []
        var unlockPasswords: [String] = []
        func unlock(password: String) async throws -> String {
            lock.withLock { unlockPasswords.append(password) }
            if unlockDelayNs > 0 { try? await Task.sleep(nanoseconds: unlockDelayNs) }
            guard password == "right" else { throw VaultError.unlockFailed }
            return "session-key-abcdefghijklmnop"
        }
        func items(session: String) async throws -> [VaultItem] {
            [VaultItem(id: "item-1", name: "GitHub", username: "june", host: "github.com", hasTOTP: true)]
        }
        func value(of field: VaultField, itemID: String, session: String) async throws -> String {
            "\(field.rawValue)-of-\(itemID)"
        }
        func lock(session: String) async { lock.withLock { locked.append(session) } }
    }

    private var clock = Date(timeIntervalSince1970: 1_000_000)
    private let permission = Manifest.VaultPermission(provider: "bitwarden", idleLockMinutes: 10, maxSessionMinutes: 60)

    private func makeBroker(_ provider: FakeProvider, password: String? = "right") -> VaultBroker {
        let broker = VaultBroker(provider: provider, now: { [unowned self] in self.clock })
        broker.promptForPassword = { _, _ in password }
        broker.toast = { _ in }
        broker.pasteboard = NSPasteboard(name: NSPasteboard.Name("barshelf-vault-test-\(UUID().uuidString)"))
        return broker
    }

    private func unlocked(_ broker: VaultBroker) async throws {
        let changed = expectation(description: "unlocked")
        broker.onChange = { _ in changed.fulfill() }
        broker.unlock(widgetID: "w", permission: permission, widgetName: "Bitwarden")
        await fulfillment(of: [changed], timeout: 2)
        broker.onChange = nil
    }

    private func handle(_ source: JSONValue) -> String? {
        source.objectValue?["items"]?.arrayValue?.first?.objectValue?["handle"]?.stringValue
    }

    func testUnlockListsMetadataAndCopiesByHandle() async throws {
        let provider = FakeProvider()
        let broker = makeBroker(provider)
        try await unlocked(broker)
        XCTAssertTrue(broker.isUnlocked("w"))
        let source = await broker.itemsSource(widgetID: "w")
        XCTAssertEqual(source.objectValue?["state"], .string("unlocked"))
        let row = try XCTUnwrap(source.objectValue?["items"]?.arrayValue?.first?.objectValue)
        XCTAssertEqual(row["name"], .string("GitHub"))
        XCTAssertNil(row["id"], "the provider's item id stays in the host")
        XCTAssertFalse("\(source)".contains("session-key"), "no session in what the widget gets")
        broker.copy(widgetID: "w", handle: try XCTUnwrap(handle(source)), field: .password)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(broker.pasteboard.string(forType: .string), "password-of-item-1")
        XCTAssertNotNil(broker.pasteboard.data(forType: VaultBroker.concealedType), "marked concealed")
        broker.copy(widgetID: "w", handle: "made-up", field: .password)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(broker.pasteboard.string(forType: .string), "password-of-item-1", "an unknown handle copies nothing")
    }

    /// Background listing is not use: only the user's own vault actions keep
    /// a session alive, and nothing outlives the cap.
    func testIdleAndMaximumLifetimes() async throws {
        let provider = FakeProvider()
        let broker = makeBroker(provider)
        try await unlocked(broker)
        clock += 9 * 60
        _ = await broker.itemsSource(widgetID: "w")
        clock += 2 * 60
        XCTAssertFalse(broker.isUnlocked("w"), "listing did not reset the idle clock")
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(provider.lock.withLock { provider.locked.count }, 1, "the provider is asked to lock")

        try await unlocked(broker)
        let source = await broker.itemsSource(widgetID: "w")
        let item = try XCTUnwrap(handle(source))
        for _ in 0..<7 {
            clock += 9 * 60
            broker.copy(widgetID: "w", handle: item, field: .username) // a user action each time
        }
        XCTAssertFalse(broker.isUnlocked("w"), "63 minutes in: past the 60-minute cap")
    }

    /// Locking while the master password is being checked: the late session
    /// is discarded and handed back to the provider to lock.
    func testALateUnlockAfterLockIsDiscarded() async throws {
        let provider = FakeProvider()
        provider.unlockDelayNs = 300_000_000
        let broker = makeBroker(provider)
        broker.unlock(widgetID: "w", permission: permission, widgetName: "Bitwarden")
        broker.end("w", runProviderLock: true)
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertFalse(broker.isUnlocked("w"))
        XCTAssertEqual(provider.lock.withLock { provider.locked }, ["session-key-abcdefghijklmnop"])
    }

    func testHandlesDieWithTheirSession() async throws {
        let provider = FakeProvider()
        let broker = makeBroker(provider)
        try await unlocked(broker)
        let first = await broker.itemsSource(widgetID: "w")
        let old = try XCTUnwrap(handle(first))
        broker.lockAll()
        try await unlocked(broker)
        broker.copy(widgetID: "w", handle: old, field: .password)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNil(broker.pasteboard.string(forType: .string))
    }

    func testCancelledOrWrongPasswordStaysLocked() async throws {
        let cancelled = makeBroker(FakeProvider(), password: nil)
        cancelled.unlock(widgetID: "w", permission: permission, widgetName: "Bitwarden")
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(cancelled.isUnlocked("w"))
        let wrong = makeBroker(FakeProvider(), password: "wrong")
        var messages: [String] = []
        wrong.toast = { messages.append($0) }
        wrong.unlock(widgetID: "w", permission: permission, widgetName: "Bitwarden")
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(wrong.isUnlocked("w"))
        XCTAssertEqual(messages, [VaultError.unlockFailed.message])
    }

    /// The projection keeps names, usernames, hosts and a TOTP flag; a
    /// password, notes or a TOTP seed has nowhere to go.
    func testProjectionKeepsOnlyMetadata() throws {
        let json = #"[{"id":"a","name":"Bank","notes":"secret notes","login":{"username":"me","password":"hunter2","totp":"otpauth://seed","uris":[{"uri":"https://bank.example/login"}]}},{"id":"b","name":"Wi-Fi","type":2}]"#
        let items = try BitwardenCLIProvider.project(Data(json.utf8))
        XCTAssertEqual(items.map(\.name), ["Bank", "Wi-Fi"])
        XCTAssertEqual(items[0], VaultItem(id: "a", name: "Bank", username: "me", host: "bank.example", hasTOTP: true))
        XCTAssertFalse("\(items)".contains("hunter2"))
        XCTAssertFalse("\(items)".contains("otpauth"))
        XCTAssertThrowsError(try BitwardenCLIProvider.project(Data("not json".utf8)))
    }
}
