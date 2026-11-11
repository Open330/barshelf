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
            if lock.withLock({ signedOutOnUnlock }) { throw VaultError.signedOut }
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
        var accountState: VaultAccount = .signedIn
        /// Sign-in requests seen, and what each one answers in turn.
        var signIns: [VaultSignIn] = []
        var signInResults: [Result<String, VaultError>] = []
        var signedOutOnUnlock = false
        func status() async -> VaultStatus {
            VaultStatus(account: lock.withLock { accountState }, lastSync: "2026-11-11T00:00:00.000Z", server: "https://vault.example")
        }
        var syncs = 0
        func sync(session: String) async throws { lock.withLock { syncs += 1 } }
        func suggestedAccount() async -> (server: String?, email: String?) { ("https://vault.example", "me@example.com") }
        func signIn(_ request: VaultSignIn) async throws -> String {
            let result: Result<String, VaultError> = lock.withLock {
                calls.append("signIn")
                signIns.append(request)
                return signInResults.isEmpty ? .success("signed-in-session-key-abcdefgh") : signInResults.removeFirst()
            }
            let key = try result.get()
            lock.withLock { accountState = .signedIn }
            return key
        }
        func lock(session: String?) async { lock.withLock { locked.append(session); calls.append("lock") } }
    }

    /// Seals by keeping the secret with its AAD; opening returns what the
    /// test scripts (Touch ID result) and checks the AAD.
    private final class FakeSealer: VaultKeySealer, @unchecked Sendable {
        let lock = NSLock()
        var state: BiometryState = .available
        var outcome: ResumeFailure?
        var openDelayNs: UInt64 = 0
        var opened = 0
        var store: [Data: (Data, Data)] = [:]
        var biometry: BiometryState { lock.withLock { state } }
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
        let fake = sealer ?? { let none = FakeSealer(); none.state = .unavailable; return none }()
        let broker = VaultBroker(provider: provider, sealer: fake, now: { [unowned self] in self.clock })
        broker.promptForPassword = { _, _, offered, _ in password.map { .init(password: $0, touchID: offered && touchID) } }
        broker.defaults = UserDefaults(suiteName: "barshelf-vault-test-\(UUID().uuidString)")!
        broker.toast = { _ in }
        broker.pasteboard = NSPasteboard(name: NSPasteboard.Name("barshelf-vault-test-\(UUID().uuidString)"))
        return broker
    }

    /// onChange also fires when unlocking starts; wait for the session itself.
    private func waitUntilUnlocked(_ broker: VaultBroker, _ description: String) -> XCTestExpectation {
        let changed = expectation(description: description)
        changed.assertForOverFulfill = false
        broker.onChange = { [permission] in if broker.isUnlocked(permission) { changed.fulfill() } }
        return changed
    }

    private func unlocked(_ broker: VaultBroker) async throws {
        let changed = waitUntilUnlocked(broker, "unlocked")
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
        relocked.assertForOverFulfill = false
        provider.beforeUnlockReturns = { [permission] in
            broker.lockAll()
            broker.onChange = { if broker.isUnlocked(permission) { relocked.fulfill() } }
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
        let changed = waitUntilUnlocked(broker, "reopened")
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

    /// The 8 hours run out while a copy or a Touch ID prompt is in flight:
    /// nothing is published, and the copy is hard-ended at once.
    func testTheEightHourDeadlineHoldsForWorkInFlight() async throws {
        let provider = FakeProvider()
        let sealer = FakeSealer()
        let broker = makeBroker(provider, sealer: sealer, touchID: true)
        let start = clock
        try await unlockedWithTouchID(broker)
        broker.setBlocked(screenLocked: true)
        broker.setBlocked()
        clock = start + VaultBroker.resumeWindow - 30
        await reopened(broker)
        let handle = try await firstHandle(broker)
        provider.valueDelayNs = 300_000_000
        broker.copy(widgetID: "w", permission: permission, handle: handle, field: .password)
        clock += 60
        try await Task.sleep(nanoseconds: 450_000_000)
        XCTAssertNil(broker.pasteboard.string(forType: .string))
        XCTAssertFalse(broker.isResumable(permission))

        provider.valueDelayNs = 0
        let again = clock
        try await unlockedWithTouchID(broker)
        broker.setBlocked(screenLocked: true)
        broker.setBlocked()
        clock = again + VaultBroker.resumeWindow - 30
        sealer.openDelayNs = 300_000_000
        broker.unlock(widgetID: "w", permission: permission, widgetName: "Bitwarden")
        clock += 60
        try await Task.sleep(nanoseconds: 450_000_000)
        XCTAssertFalse(broker.isUnlocked(permission))
        XCTAssertEqual(provider.lock.withLock { provider.locked.count }, 2, "both expiries locked bw")
    }

    /// A stricter grant that is already past its limit when it first looks
    /// still tightens what Touch ID reopens.
    func testAStricterGrantAlreadyPastItsLimitStillTightensTheCopy() async throws {
        let broker = makeBroker(FakeProvider(), sealer: FakeSealer(), touchID: true)
        try await unlockedWithTouchID(broker)
        let strict = Manifest.VaultPermission(provider: "bitwarden", idleLockMinutes: 2, maxSessionMinutes: 5)
        clock += 3 * 60
        let source = await broker.itemsSource(widgetID: "strict", permission: strict)
        XCTAssertEqual(source.objectValue?["state"], .string("locked"))
        XCTAssertTrue(broker.isResumable(permission))
        await reopened(broker)
        clock += 3 * 60
        XCTAssertFalse(broker.isUnlocked(permission), "reopened with the strict 2-minute idle")
    }

    /// Locked out (or every finger removed) before Touch ID is even asked:
    /// the copy is void and bw locked, then the password prompt opens.
    func testLockoutAtPreflightEndsHard() async throws {
        let provider = FakeProvider()
        let sealer = FakeSealer()
        var prompts = 0
        let broker = makeBroker(provider, sealer: sealer, touchID: true)
        broker.promptForPassword = { _, _, offered, _ in
            prompts += 1
            return prompts == 1 ? .init(password: "right", touchID: offered) : nil
        }
        try await unlockedWithTouchID(broker)
        broker.setBlocked(screenLocked: true)
        broker.setBlocked()
        sealer.state = .invalid
        broker.unlock(widgetID: "w", permission: permission, widgetName: "Bitwarden")
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(broker.isResumable(permission))
        XCTAssertEqual(prompts, 2, "then the password prompt (cancelled here)")
        XCTAssertEqual(sealer.lock.withLock { sealer.opened }, 0)
        XCTAssertEqual(provider.lock.withLock { provider.locked }, [nil])
    }

    // MARK: BarShelf's own Bitwarden profile

    private func signInPrompts(_ broker: VaultBroker, factors: [VaultBroker.TwoFactorAnswer] = []) -> (() -> Int, () -> [Bool]) {
        var signIns = 0
        var emailSentFlags: [Bool] = []
        var remaining = factors
        broker.promptForSignIn = { _, server, email, _, _ in
            signIns += 1
            XCTAssertEqual(server, "https://vault.example", "suggested from the terminal profile")
            XCTAssertEqual(email, "me@example.com")
            return .init(server: server ?? "", email: email ?? "", password: "right", touchID: false)
        }
        broker.promptForTwoFactor = { sent in
            emailSentFlags.append(sent)
            return remaining.isEmpty ? nil : remaining.removeFirst()
        }
        return ({ signIns }, { emailSentFlags })
    }

    /// A profile without an account says so to the widget, and Unlock signs
    /// in instead, which also unlocks.
    func testASignedOutProfileSignsInFromUnlock() async throws {
        let provider = FakeProvider()
        provider.accountState = .signedOut
        let broker = makeBroker(provider)
        let (signIns, _) = signInPrompts(broker)
        let locked = await broker.itemsSource(widgetID: "w", permission: permission)
        XCTAssertEqual(locked.objectValue?["account"], .string("signedOut"))
        try await unlocked(broker)
        XCTAssertEqual(signIns(), 1)
        XCTAssertEqual(provider.lock.withLock { provider.calls }, ["signIn"], "no password unlock against a signed-out profile")
        XCTAssertEqual(provider.lock.withLock { provider.signIns.first?.server }, "https://vault.example")
    }

    /// Unlocking decrypts the local copy; the vault is then synced once.
    func testEachUnlockSyncsOnce() async throws {
        let provider = FakeProvider()
        let broker = makeBroker(provider)
        try await unlocked(broker)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(provider.lock.withLock { provider.syncs }, 1)
    }

    /// An unlock that finds the profile signed out turns into a sign-in.
    func testAnUnlockThatFindsNoAccountSignsIn() async throws {
        let provider = FakeProvider()
        provider.signedOutOnUnlock = true
        let broker = makeBroker(provider)
        let (signIns, _) = signInPrompts(broker)
        try await unlocked(broker)
        XCTAssertEqual(signIns(), 1)
        XCTAssertEqual(provider.lock.withLock { provider.calls }, ["unlock", "signIn"])
    }

    /// Two-step: an authenticator code is asked for and passed; by email,
    /// an empty code first asks Bitwarden to send one.
    func testTwoStepCodes() async throws {
        let provider = FakeProvider()
        provider.accountState = .signedOut
        provider.signInResults = [.failure(.twoFactorRequired), .success("signed-in-session-key-abcdefgh")]
        let broker = makeBroker(provider)
        let (_, sent) = signInPrompts(broker, factors: [.init(method: 0, code: "123456")])
        _ = await broker.itemsSource(widgetID: "w", permission: permission)
        try await unlocked(broker)
        XCTAssertEqual(provider.lock.withLock { provider.signIns.map(\.code) }, [nil, "123456"])
        XCTAssertEqual(sent(), [false])

        let byEmail = FakeProvider()
        byEmail.accountState = .signedOut
        byEmail.signInResults = [.failure(.twoFactorRequired), .failure(.twoFactorRequired), .success("signed-in-session-key-abcdefgh")]
        let emailBroker = makeBroker(byEmail)
        let (_, emailSent) = signInPrompts(emailBroker, factors: [.init(method: 1, code: ""), .init(method: 1, code: "654321")])
        _ = await emailBroker.itemsSource(widgetID: "w", permission: permission)
        try await unlocked(emailBroker)
        XCTAssertEqual(byEmail.lock.withLock { byEmail.signIns.map(\.method) }, [nil, 1, 1])
        XCTAssertEqual(byEmail.lock.withLock { byEmail.signIns.map(\.code) }, [nil, nil, "654321"])
        XCTAssertEqual(emailSent(), [false, true], "the second prompt says the email went out")
    }

    /// New-device verification (no two-step on the account) is done with an
    /// API key; the key goes to the provider, the password unlocks.
    func testAPIKeySignIn() async throws {
        let provider = FakeProvider()
        provider.accountState = .signedOut
        provider.signInResults = [.failure(.twoFactorRequired), .success("signed-in-session-key-abcdefgh")]
        let broker = makeBroker(provider)
        _ = signInPrompts(broker, factors: [.init(method: 0, code: "", useAPIKey: true)])
        broker.promptForAPIKey = { ("user.abc", "s3cret") }
        _ = await broker.itemsSource(widgetID: "w", permission: permission)
        try await unlocked(broker)
        XCTAssertEqual(provider.lock.withLock { provider.signIns.map(\.clientID) }, [nil, "user.abc"])
        XCTAssertEqual(provider.lock.withLock { provider.syncs }, 0, "sign-in already synced")
    }

    /// An authenticator choice with no code says so instead of going quiet.
    func testAnEmptyCodeSaysWhy() async throws {
        let provider = FakeProvider()
        provider.accountState = .signedOut
        provider.signInResults = [.failure(.twoFactorRequired)]
        let broker = makeBroker(provider)
        var messages: [String] = []
        broker.toast = { messages.append($0) }
        _ = signInPrompts(broker, factors: [.init(method: 0, code: "")])
        _ = await broker.itemsSource(widgetID: "w", permission: permission)
        broker.unlock(widgetID: "w", permission: permission, widgetName: "Bitwarden")
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(messages, [String(localized: "Enter the code to sign in.")])
        XCTAssertFalse(broker.isUnlocked(permission))
    }

    /// A wrong code ends the attempt with a fixed message; nothing unlocks.
    func testAWrongCodeFailsCleanly() async throws {
        let provider = FakeProvider()
        provider.accountState = .signedOut
        provider.signInResults = [.failure(.twoFactorRequired), .failure(.twoFactorRequired)]
        let broker = makeBroker(provider)
        var messages: [String] = []
        broker.toast = { messages.append($0) }
        _ = signInPrompts(broker, factors: [.init(method: 0, code: "000000")])
        _ = await broker.itemsSource(widgetID: "w", permission: permission)
        broker.unlock(widgetID: "w", permission: permission, widgetName: "Bitwarden")
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(broker.isUnlocked(permission))
        XCTAssertEqual(messages, [VaultError.signInFailed.message])
    }

    /// The real runner uses BarShelf's own profile for its own calls, and the
    /// user's default one only to suggest the account; bw's messages are
    /// classified, never shown.
    func testRunnerUsesItsOwnProfileAndClassifiesBwMessages() async throws {
        let url = try helper(#"""
        case "$1" in
          status) if [ -n "$BITWARDENCLI_APPDATA_DIR" ]; then printf '{"status":"unauthenticated"}'; else printf '{"status":"locked","serverUrl":"https://vault.example","userEmail":"me@example.com"}'; fi ;;
          unlock) if [ -f "$BITWARDENCLI_APPDATA_DIR/apikey" ]; then read -r pw; printf 'YXBpLWtleS1zZXNzaW9uLWtleS0xMjM='; else echo "You are not logged in." >&2; exit 1; fi ;;
          config) [ "$2" = "server" ] && echo "$3" > "$BITWARDENCLI_APPDATA_DIR/server"; exit 0 ;;
          login)
            if [ "$2" = "--apikey" ]; then
              [ "$BW_CLIENTID" = "user.abc" ] && [ "$BW_CLIENTSECRET" = "s3cret" ] && touch "$BITWARDENCLI_APPDATA_DIR/apikey" && exit 0
              exit 1
            fi
            read -r pw
            for a in "$@"; do last="$a"; done
            if [ "$last" = "multi@example.com" ]; then echo "Login failed. No provider selected." >&2; exit 1; fi
            if [ "$7" = "--code" ] && [ "$8" = "111111" ]; then printf 'c2Vzc2lvbi1rZXktZm9yLXRlc3Rpbmc='; else echo "Code is required." >&2; exit 1; fi ;;
        esac
        """#)
        let directory = url.deletingLastPathComponent().appendingPathComponent("profile")
        var provider = BitwardenCLIProvider(executableOverride: url, timeout: 5)
        provider.dataDirectory = directory
        let status = await provider.status()
        XCTAssertEqual(status.account, .signedOut)
        let suggestion = await provider.suggestedAccount()
        XCTAssertEqual(suggestion.email, "me@example.com")
        do { _ = try await provider.unlock(password: "x"); XCTFail() } catch { XCTAssertEqual(error as? VaultError, .signedOut) }
        let request = VaultSignIn(server: "https://vault.example", email: "me@example.com", password: "right")
        do { _ = try await provider.signIn(request); XCTFail() } catch { XCTAssertEqual(error as? VaultError, .twoFactorRequired) }
        var withCode = request
        withCode.method = 0
        withCode.code = "111111"
        let key = try await provider.signIn(withCode)
        XCTAssertEqual(key, "c2Vzc2lvbi1rZXktZm9yLXRlc3Rpbmc=")
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700, "owner-only profile folder")
        var insecure = request
        insecure.server = "http://vault.example"
        do { _ = try await provider.signIn(insecure); XCTFail() } catch { XCTAssertEqual(error as? VaultError, .signInFailed) }
        // Several two-step methods without --method: still a code prompt.
        var multi = request
        multi.email = "multi@example.com"
        do { _ = try await provider.signIn(multi); XCTFail() } catch { XCTAssertEqual(error as? VaultError, .twoFactorRequired) }
        // An empty server resets the profile to bitwarden.com.
        var cloud = request
        cloud.server = nil
        _ = try? await provider.signIn(cloud)
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("server"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), "bitwarden.com")
        // API key: signs in from the child's environment, then the password unlocks.
        var apiKey = request
        apiKey.clientID = "user.abc"
        apiKey.clientSecret = "s3cret"
        let apiSession = try await provider.signIn(apiKey)
        XCTAssertEqual(apiSession, "YXBpLWtleS1zZXNzaW9uLWtleS0xMjM=")
    }

    /// The real envelope round trip needs this Mac's Secure Enclave and a
    /// finger, so it only checks that sealing never needs either.
    func testSecureEnclaveSealingNeedsNoPrompt() throws {
        let sealer = SecureEnclaveSealer()
        guard sealer.biometry == .available else { throw XCTSkip("no Touch ID available here") }
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

    /// While bw derives the key the card hears about it and shows
    /// "unlocking", then "unlocked"; vault events reach the audit log
    /// without any secret.
    func testUnlockingIsAnnouncedAndAudited() async throws {
        let provider = FakeProvider()
        provider.unlockDelayNs = 200_000_000
        let broker = makeBroker(provider)
        var events: [(String, [String: JSONValue])] = []
        broker.audit = { event, _, detail in events.append((event, detail)) }
        var states: [String] = []
        let done = expectation(description: "unlocked")
        done.assertForOverFulfill = false
        broker.onChange = { [permission] in
            Task { @MainActor in
                let source = await broker.itemsSource(widgetID: "w", permission: permission)
                states.append(source.objectValue?["state"]?.stringValue ?? "?")
                if broker.isUnlocked(permission) { done.fulfill() }
            }
        }
        broker.unlock(widgetID: "w", permission: permission, widgetName: "Bitwarden")
        await fulfillment(of: [done], timeout: 2)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(states.first, "unlocking")
        XCTAssertTrue(states.contains("unlocked"))
        XCTAssertEqual(events.map(\.0).prefix(2), ["vault.unlocked", "vault.listed"])
        XCTAssertFalse("\(events)".contains("session-key"), "no secret in the audit log")
        XCTAssertFalse("\(events)".contains("right"), "no password in the audit log")
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
