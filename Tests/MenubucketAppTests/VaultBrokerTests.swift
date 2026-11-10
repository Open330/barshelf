import AppKit
import XCTest
import MenubucketCore
@testable import MenubucketApp

@MainActor
final class VaultBrokerTests: XCTestCase {
    private final class FakeProvider: VaultProvider, @unchecked Sendable {
        let lock = NSLock()
        var unlockDelayNs: UInt64 = 0
        var valueDelayNs: UInt64 = 0
        var itemsDelayNs: UInt64 = 0
        var locked: [String?] = []
        var calls: [String] = []
        /// Runs once on the main actor just before an unlock returns.
        var beforeUnlockReturns: (@MainActor () -> Void)?
        func unlock(password: String) async throws -> String {
            lock.withLock { calls.append("unlock") }
            if unlockDelayNs > 0 { try await Task.sleep(nanoseconds: unlockDelayNs) }
            if let hook = lock.withLock({ () -> (@MainActor () -> Void)? in
                defer { beforeUnlockReturns = nil }
                return beforeUnlockReturns
            }) {
                await MainActor.run { hook() }
            }
            guard password == "right" else { throw VaultError.unlockFailed }
            return "session-key-abcdefghijklmnop"
        }
        func items(session: String) async throws -> [VaultItem] {
            lock.withLock { calls.append("items") }
            if itemsDelayNs > 0 {
                do { try await Task.sleep(nanoseconds: itemsDelayNs) } catch {
                    lock.withLock { calls.append("items-cancelled") }
                    throw error
                }
            }
            return [VaultItem(id: "item-1", name: "GitHub", username: "june", host: "github.com", hasTOTP: true)]
        }
        func value(of field: VaultField, itemID: String, session: String) async throws -> String {
            if valueDelayNs > 0 { try await Task.sleep(nanoseconds: valueDelayNs) }
            return "\(field.rawValue)-of-\(itemID) "
        }
        func lock(session: String?) async { lock.withLock { locked.append(session); calls.append("lock") } }
    }

    /// Seals by keeping the secret with its AAD; opening returns what the
    /// test scripts (Touch ID result) and checks the AAD.
    private final class FakeSealer: VaultKeySealer, @unchecked Sendable {
        let lock = NSLock()
        var available = true
        var outcome: ResumeFailure?
        var openDelayNs: UInt64 = 0
        var opened = 0
        var store: [Data: (Data, Data)] = [:]
        var biometryAvailable: Bool { lock.withLock { available } }
        func seal(_ secret: Data, aad: Data) throws -> SealedSecret {
            let id = Data(UUID().uuidString.utf8)
            lock.withLock { store[id] = (secret, aad) }
            return SealedSecret(enclaveKey: id, ephemeralPublic: Data(), salt: Data(), box: Data())
        }
        func open(_ sealed: SealedSecret, aad: Data, reason: String) async -> Result<Data, ResumeFailure> {
            if openDelayNs > 0 {
                do { try await Task.sleep(nanoseconds: openDelayNs) } catch { return .failure(.cancelled) }
            }
            return lock.withLock {
                opened += 1
                if let outcome { return .failure(outcome) }
                guard let (secret, sealedAAD) = store[sealed.enclaveKey], sealedAAD == aad else { return .failure(.invalid) }
                return .success(secret)
            }
        }
    }

    private var clock: TimeInterval = 1_000
    private let permission = Manifest.VaultPermission(provider: "bitwarden", idleLockMinutes: 10, maxSessionMinutes: 60)

    private func makeBroker(_ provider: FakeProvider, password: String? = "right",
                            sealer: FakeSealer? = nil, touchID: Bool = false) -> VaultBroker {
        let fake = sealer ?? { let none = FakeSealer(); none.available = false; return none }()
        let broker = VaultBroker(provider: provider, sealer: fake, now: { [unowned self] in self.clock })
        broker.promptForPassword = { _, _, offered, _ in password.map { .init(password: $0, touchID: offered && touchID) } }
        broker.defaults = UserDefaults(suiteName: "barshelf-vault-test-\(UUID().uuidString)")!
        broker.toast = { _ in }
        broker.pasteboard = NSPasteboard(name: NSPasteboard.Name("barshelf-vault-test-\(UUID().uuidString)"))
        return broker
    }

    private func unlocked(_ broker: VaultBroker) async throws {
        let changed = expectation(description: "unlocked")
        broker.onChange = { changed.fulfill() }
        broker.unlock(widgetID: "w", permission: permission, widgetName: "Bitwarden")
        await fulfillment(of: [changed], timeout: 2)
        broker.onChange = nil
    }

    private func firstHandle(_ broker: VaultBroker, widget: String = "w") async throws -> String {
        let source = await broker.itemsSource(widgetID: widget, permission: permission)
        return try XCTUnwrap(source.objectValue?["items"]?.arrayValue?.first?.objectValue?["handle"]?.stringValue)
    }

    func testUnlockListsMetadataAndCopiesExactBytesByHandle() async throws {
        let broker = makeBroker(FakeProvider())
        try await unlocked(broker)
        XCTAssertTrue(broker.isUnlocked(permission))
        let source = await broker.itemsSource(widgetID: "w", permission: permission)
        let row = try XCTUnwrap(source.objectValue?["items"]?.arrayValue?.first?.objectValue)
        XCTAssertEqual(row["name"], .string("GitHub"))
        XCTAssertNil(row["id"], "the provider's item id stays in the host")
        XCTAssertFalse("\(source)".contains("session-key"), "no session in what the widget gets")
        broker.copy(widgetID: "w", permission: permission, handle: try XCTUnwrap(row["handle"]?.stringValue), field: .password)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(broker.pasteboard.string(forType: .string), "password-of-item-1 ", "trailing space kept")
        XCTAssertNotNil(broker.pasteboard.data(forType: VaultBroker.concealedType), "marked concealed")
        broker.copy(widgetID: "other", permission: permission, handle: try XCTUnwrap(row["handle"]?.stringValue), field: .username)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(broker.pasteboard.string(forType: .string), "password-of-item-1 ", "a handle belongs to the widget it was given to")
    }

    /// Background listing is not use; nothing outlives the cap.
    func testIdleAndMaximumLifetimes() async throws {
        let provider = FakeProvider()
        let broker = makeBroker(provider)
        try await unlocked(broker)
        clock += 9 * 60
        _ = await broker.itemsSource(widgetID: "w", permission: permission)
        clock += 2 * 60
        XCTAssertFalse(broker.isUnlocked(permission), "listing did not reset the idle clock")
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(provider.lock.withLock { provider.locked.count }, 1, "the provider is asked to lock")

        try await unlocked(broker)
        let item = try await firstHandle(broker)
        for _ in 0..<7 {
            clock += 9 * 60
            broker.copy(widgetID: "w", permission: permission, handle: item, field: .username)
        }
        XCTAssertFalse(broker.isUnlocked(permission), "63 minutes in: past the 60-minute cap")
    }

    /// Screen lock while the master password is being checked: the late
    /// session is discarded, locked again, and new work is refused.
    func testScreenLockDuringUnlockDiscardsTheLateSession() async throws {
        let provider = FakeProvider()
        provider.unlockDelayNs = 300_000_000
        let broker = makeBroker(provider)
        broker.unlock(widgetID: "w", permission: permission, widgetName: "Bitwarden")
        broker.setBlocked(screenLocked: true)
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertFalse(broker.isUnlocked(permission))
        broker.unlock(widgetID: "w", permission: permission, widgetName: "Bitwarden")
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(broker.isUnlocked(permission), "no unlock while the screen is locked")
        broker.setBlocked()
        try await unlocked(broker)
        XCTAssertTrue(broker.isUnlocked(permission))
    }

    /// A copy whose answer arrives after the session ended publishes nothing.
    func testACopyFinishingAfterExpiryPublishesNothing() async throws {
        let provider = FakeProvider()
        provider.valueDelayNs = 300_000_000
        let broker = makeBroker(provider)
        try await unlocked(broker)
        let item = try await firstHandle(broker)
        broker.copy(widgetID: "w", permission: permission, handle: item, field: .password)
        clock += 11 * 60
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertNil(broker.pasteboard.string(forType: .string))
    }

    /// Locking clears a password BarShelf put on the clipboard, and only that.
    func testLockClearsOnlyOurClipboardCopy() async throws {
        let broker = makeBroker(FakeProvider())
        try await unlocked(broker)
        let item = try await firstHandle(broker)
        broker.copy(widgetID: "w", permission: permission, handle: item, field: .password)
        try await Task.sleep(nanoseconds: 200_000_000)
        broker.lockAll()
        XCTAssertNil(broker.pasteboard.string(forType: .string))

        try await unlocked(broker)
        let again = try await firstHandle(broker)
        broker.copy(widgetID: "w", permission: permission, handle: again, field: .password)
        try await Task.sleep(nanoseconds: 200_000_000)
        broker.pasteboard.clearContents()
        broker.pasteboard.setString("something the user copied", forType: .string)
        broker.lockAll()
        XCTAssertEqual(broker.pasteboard.string(forType: .string), "something the user copied")
    }

    /// One session per provider: every copy of the widget shares it, and a
    /// lock queued behind an unlock cannot overtake it.
    func testProviderCallsAreSerial() async throws {
        let provider = FakeProvider()
        provider.unlockDelayNs = 200_000_000
        let broker = makeBroker(provider)
        try await unlocked(broker)
        XCTAssertTrue(broker.isUnlocked(permission))
        broker.lock(permission)
        try await unlocked(broker)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(provider.lock.withLock { provider.calls }, ["unlock", "lock", "unlock"])
        XCTAssertTrue(broker.isUnlocked(permission), "the old lock did not end the new session")
    }

    /// Screen lock while a listing runs cancels the provider call itself,
    /// and the provider lock runs only after it stopped.
    func testScreenLockCancelsARunningListing() async throws {
        let provider = FakeProvider()
        let broker = makeBroker(provider)
        try await unlocked(broker)
        provider.itemsDelayNs = 5_000_000_000
        let listing = Task { await broker.itemsSource(widgetID: "w", permission: permission) }
        try await Task.sleep(nanoseconds: 100_000_000)
        broker.setBlocked(screenLocked: true)
        let result = await listing.value
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(result.objectValue?["state"], .string("locked"))
        XCTAssertEqual(provider.lock.withLock { provider.calls }, ["unlock", "items", "items-cancelled", "lock"])
    }

    /// A listing queued behind a running copy never starts once the session ended.
    func testAQueuedListingNeverRunsAfterLock() async throws {
        let provider = FakeProvider()
        let broker = makeBroker(provider)
        try await unlocked(broker)
        let item = try await firstHandle(broker)
        provider.valueDelayNs = 300_000_000
        broker.copy(widgetID: "w", permission: permission, handle: item, field: .password)
        let listing = Task { await broker.itemsSource(widgetID: "w", permission: permission) }
        try await Task.sleep(nanoseconds: 50_000_000)
        broker.lock(permission)
        _ = await listing.value
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(provider.lock.withLock { provider.calls }, ["unlock", "items", "lock"])
        XCTAssertNil(broker.pasteboard.string(forType: .string))
    }

    /// An unlock cancelled before its key was accepted still locks the
    /// provider: bw may already have unlocked.
    func testCancelledPendingUnlockStillLocksTheProvider() async throws {
        let provider = FakeProvider()
        provider.unlockDelayNs = 300_000_000
        let broker = makeBroker(provider)
        broker.unlock(widgetID: "w", permission: permission, widgetName: "Bitwarden")
        try await Task.sleep(nanoseconds: 50_000_000)
        broker.lockAll()
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertFalse(broker.isUnlocked(permission))
        XCTAssertEqual(provider.lock.withLock { provider.calls }, ["unlock", "lock"])
        XCTAssertEqual(provider.lock.withLock { provider.locked }, [nil])
    }

    /// The provider unlocked, but the session ended before the broker
    /// accepted the key, and the user unlocked again at once: the old
    /// unlock's cleanup must not lock the new session.
    func testALateUnlockDoesNotLockTheNextSession() async throws {
        let provider = FakeProvider()
        let broker = makeBroker(provider)
        let relocked = expectation(description: "second unlock accepted")
        provider.beforeUnlockReturns = { [permission] in
            broker.lockAll()
            broker.onChange = { relocked.fulfill() }
            broker.unlock(widgetID: "w", permission: permission, widgetName: "Bitwarden")
        }
        broker.unlock(widgetID: "w", permission: permission, widgetName: "Bitwarden")
        await fulfillment(of: [relocked], timeout: 2)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(provider.lock.withLock { provider.calls }, ["unlock", "lock", "unlock"])
        XCTAssertTrue(broker.isUnlocked(permission))
    }

    /// A widget granted a shorter session cannot use a longer one another
    /// widget unlocked; its limit tightens the shared session.
    func testAStricterGrantBoundsTheSharedSession() async throws {
        let broker = makeBroker(FakeProvider())
        try await unlocked(broker)
        let strict = Manifest.VaultPermission(provider: "bitwarden", idleLockMinutes: 2, maxSessionMinutes: 5)
        clock += 3 * 60
        let source = await broker.itemsSource(widgetID: "strict", permission: strict)
        XCTAssertEqual(source.objectValue?["state"], .string("locked"), "3 minutes idle is past the 2-minute grant")
        XCTAssertFalse(broker.isUnlocked(permission))

        try await unlocked(broker)
        _ = await broker.itemsSource(widgetID: "strict", permission: strict)
        clock += 90
        let handle = try await firstHandle(broker)
        for _ in 0..<3 {
            clock += 90
            broker.copy(widgetID: "w", permission: permission, handle: handle, field: .username)
        }
        XCTAssertFalse(broker.isUnlocked(permission), "6 minutes in: past the 5-minute cap the strict widget added")
    }

    // MARK: The real runner, against synthetic helpers

    private func helper(_ script: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vault-helper-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("bw")
        try ("#!/bin/sh\n" + script).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return url
    }

    /// The password arrives on stdin, never argv; failures carry no stderr.
    func testRunnerPassesThePasswordOnStdin() async throws {
        let url = try helper(#"""
        [ "$1 $2 $3 $4" = "unlock --passwordfile /dev/stdin --raw" ] || exit 2
        read -r line
        [ "$line" = "right" ] || { echo "wrong: $line" >&2; exit 1; }
        printf 'c2Vzc2lvbi1rZXktZm9yLXRlc3Rpbmc='
        """#)
        let provider = BitwardenCLIProvider(executableOverride: url, timeout: 5)
        let key = try await provider.unlock(password: "right")
        XCTAssertEqual(key, "c2Vzc2lvbi1rZXktZm9yLXRlc3Rpbmc=")
        do {
            _ = try await provider.unlock(password: "nope")
            XCTFail("a wrong password unlocks nothing")
        } catch {
            XCTAssertEqual(error as? VaultError, .unlockFailed)
        }
    }

    /// A descendant holding the output pipe cannot keep a run alive past
    /// its timeout, and cancelling the caller stops the run quickly.
    func testRunnerTimeoutAndCancelReachDescendants() async throws {
        let url = try helper("/bin/sleep 30 &\n/bin/sleep 30\n")
        let provider = BitwardenCLIProvider(executableOverride: url, timeout: 1)
        let started = Date()
        do {
            _ = try await provider.items(session: "s")
            XCTFail("expected a timeout")
        } catch {
            XCTAssertEqual(error as? VaultError, .timedOut)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)

        let slow = BitwardenCLIProvider(executableOverride: url, timeout: 30)
        let run = Task { try await slow.items(session: "s") }
        try await Task.sleep(nanoseconds: 200_000_000)
        let cancelledAt = Date()
        run.cancel()
        do {
            _ = try await run.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertLessThan(Date().timeIntervalSince(cancelledAt), 5)
    }

    // MARK: Touch ID resume

    private func unlockedWithTouchID(_ broker: VaultBroker) async throws {
        try await unlocked(broker)
        XCTAssertTrue(broker.isResumable(permission))
    }

    private func reopened(_ broker: VaultBroker) async {
        let changed = expectation(description: "reopened")
        broker.onChange = { changed.fulfill() }
        broker.unlock(widgetID: "w", permission: permission, widgetName: "Bitwarden")
        await fulfillment(of: [changed], timeout: 2)
        broker.onChange = nil
    }

    /// Screen lock and idle end softly: no bw lock, and Touch ID reopens
    /// without the master password or another provider unlock.
    func testSoftLocksReopenWithTouchID() async throws {
        let provider = FakeProvider()
        let sealer = FakeSealer()
        let broker = makeBroker(provider, sealer: sealer, touchID: true)
        try await unlockedWithTouchID(broker)
        broker.setBlocked(screenLocked: true)
        XCTAssertFalse(broker.isUnlocked(permission))
        broker.setBlocked()
        await reopened(broker)
        XCTAssertTrue(broker.isUnlocked(permission))
        let handle = try await firstHandle(broker)
        clock += 11 * 60
        XCTAssertFalse(broker.isUnlocked(permission), "idle ends it")
        await reopened(broker)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(provider.lock.withLock { provider.calls }, ["unlock", "items"], "no bw lock, one password unlock")
        XCTAssertEqual(sealer.lock.withLock { sealer.opened }, 2)
    }

    /// Lock, the 8-hour window and quit end hard, also with only a sealed
    /// copy left: the copy goes and bw is locked without a key.
    func testHardLocksDiscardTheSealedCopyAndLockBw() async throws {
        let provider = FakeProvider()
        let broker = makeBroker(provider, sealer: FakeSealer(), touchID: true)
        try await unlockedWithTouchID(broker)
        broker.setBlocked(screenLocked: true)
        broker.setBlocked()
        broker.lock(permission)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(broker.isResumable(permission))
        XCTAssertEqual(provider.lock.withLock { provider.locked }, [nil], "locked with only the sealed copy left")

        try await unlockedWithTouchID(broker)
        broker.setBlocked(sleeping: true)
        clock += 8 * 3600
        broker.setBlocked()
        XCTAssertFalse(broker.isResumable(permission), "8 hours after the password, asleep or not")
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(provider.lock.withLock { provider.locked.count }, 2)
    }

    /// Without the box ticked nothing is sealed, and every lock is hard.
    func testWithoutTouchIDEveryLockIsHard() async throws {
        let provider = FakeProvider()
        let broker = makeBroker(provider, sealer: FakeSealer(), touchID: false)
        try await unlocked(broker)
        XCTAssertFalse(broker.isResumable(permission))
        broker.setBlocked(screenLocked: true)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(provider.lock.withLock { provider.calls }, ["unlock", "lock"])
    }

    /// Cancel keeps the copy and asks nothing; a changed enrollment voids it;
    /// Use Password goes to the password prompt.
    func testTouchIDOutcomes() async throws {
        let provider = FakeProvider()
        let sealer = FakeSealer()
        var prompts = 0
        let broker = makeBroker(provider, sealer: sealer, touchID: true)
        broker.promptForPassword = { _, _, offered, _ in prompts += 1; return .init(password: "right", touchID: offered) }
        try await unlockedWithTouchID(broker)
        XCTAssertEqual(prompts, 1)
        broker.setBlocked(screenLocked: true)
        broker.setBlocked()

        sealer.outcome = .cancelled
        broker.unlock(widgetID: "w", permission: permission, widgetName: "Bitwarden")
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(broker.isUnlocked(permission))
        XCTAssertTrue(broker.isResumable(permission))
        XCTAssertEqual(prompts, 1, "cancel opens no password prompt")

        sealer.outcome = .fallback
        broker.unlock(widgetID: "w", permission: permission, widgetName: "Bitwarden")
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(prompts, 2, "Use Password asks for it")
        XCTAssertTrue(broker.isUnlocked(permission))
        XCTAssertTrue(broker.isResumable(permission), "a new copy for the new session key")

        broker.setBlocked(screenLocked: true)
        broker.setBlocked()
        sealer.outcome = .invalid
        broker.unlock(widgetID: "w", permission: permission, widgetName: "Bitwarden")
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(broker.isResumable(permission), "enrollment changed: hard lock")
        XCTAssertEqual(provider.lock.withLock { provider.locked }, [nil])
    }

    /// The screen locks while Touch ID is up: the prompt is cancelled and
    /// nothing is installed; the copy survives.
    func testScreenLockDuringTouchIDInstallsNothing() async throws {
        let sealer = FakeSealer()
        let broker = makeBroker(FakeProvider(), sealer: sealer, touchID: true)
        try await unlockedWithTouchID(broker)
        broker.setBlocked(screenLocked: true)
        broker.setBlocked()
        sealer.openDelayNs = 300_000_000
        broker.unlock(widgetID: "w", permission: permission, widgetName: "Bitwarden")
        broker.setBlocked(screenLocked: true)
        try await Task.sleep(nanoseconds: 400_000_000)
        broker.setBlocked()
        XCTAssertFalse(broker.isUnlocked(permission))
        XCTAssertTrue(broker.isResumable(permission))
    }

    /// A reopened session keeps the tightest limits it ever had.
    func testReopenKeepsTheTightestLimits() async throws {
        let broker = makeBroker(FakeProvider(), sealer: FakeSealer(), touchID: true)
        try await unlockedWithTouchID(broker)
        let strict = Manifest.VaultPermission(provider: "bitwarden", idleLockMinutes: 2, maxSessionMinutes: 5)
        _ = await broker.itemsSource(widgetID: "strict", permission: strict)
        clock += 3 * 60
        XCTAssertFalse(broker.isUnlocked(permission), "past the strict 2-minute idle")
        await reopened(broker)
        clock += 3 * 60
        XCTAssertFalse(broker.isUnlocked(permission), "the reopened session kept the 2-minute idle")
    }

    /// The real envelope round trip needs this Mac's Secure Enclave and a
    /// finger, so it only checks that sealing never needs either.
    func testSecureEnclaveSealingNeedsNoPrompt() throws {
        let sealer = SecureEnclaveSealer()
        guard sealer.biometryAvailable else { throw XCTSkip("no Touch ID available here") }
        let sealed = try sealer.seal(Data("session".utf8), aad: Data("aad".utf8))
        XCTAssertFalse(sealed.box.isEmpty)
        XCTAssertFalse(sealed.box.contains(Data("session".utf8)))
    }

    func testCancelledOrWrongPasswordStaysLocked() async throws {
        let cancelled = makeBroker(FakeProvider(), password: nil)
        cancelled.unlock(widgetID: "w", permission: permission, widgetName: "Bitwarden")
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(cancelled.isUnlocked(permission))
        let wrong = makeBroker(FakeProvider(), password: "wrong")
        var messages: [String] = []
        wrong.toast = { messages.append($0) }
        wrong.unlock(widgetID: "w", permission: permission, widgetName: "Bitwarden")
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(wrong.isUnlocked(permission))
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
