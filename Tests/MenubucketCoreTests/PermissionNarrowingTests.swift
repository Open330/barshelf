import XCTest
@testable import MenubucketCore

/// An approval carries over to an update that only drops permissions, and
/// to nothing else.
final class PermissionNarrowingTests: XCTestCase {
    private typealias P = Manifest.Permissions
    private typealias Exec = Manifest.ExecPermission

    private func covered(_ new: P?, by old: P?) -> Bool {
        PermissionNarrowing.isCovered(new, by: old)
    }

    private let osascript = "/usr/bin/osascript"

    // MARK: - The rule

    func testKeepAwakeDroppingItsStatusCommandIsCovered() {
        let old = P(exec: [Exec(command: osascript, allowedArgs: [
            ["-l", "JavaScript", "./keep-awake.js", "status"],
            ["-l", "JavaScript", "./keep-awake.js", "on", "*"],
        ])], readPaths: ["~/Library/Application Support/PowerDisplayGuard"])
        let new = P(exec: [Exec(command: osascript, allowedArgs: [
            ["-l", "JavaScript", "./keep-awake.js", "on", "*"],
        ])], readPaths: ["~/Library/Application Support/PowerDisplayGuard"])
        XCTAssertTrue(covered(new, by: old))
        XCTAssertFalse(covered(old, by: new), "adding the command back asks again")
    }

    func testListsMustBeSubsets() {
        XCTAssertTrue(covered(P(network: ["a.com"]), by: P(network: ["a.com", "b.com"])))
        XCTAssertFalse(covered(P(network: ["c.com"]), by: P(network: ["a.com"])))
        XCTAssertTrue(covered(P(readPaths: []), by: P(readPaths: ["~/x"])))
        XCTAssertFalse(covered(P(readPaths: ["~/x/y"]), by: P(readPaths: ["~/x"])), "no path reasoning")
        XCTAssertFalse(covered(P(env: ["TOKEN"]), by: P()))
        XCTAssertFalse(covered(P(system: ["cpu", "disk"]), by: P(system: ["cpu"])))
    }

    func testVaultGrantsMustBeIdentical() {
        let vault = Manifest.VaultPermission(provider: "bitwarden", idleLockMinutes: 10)
        XCTAssertTrue(covered(P(vault: vault), by: P(vault: vault)))
        XCTAssertTrue(covered(P(), by: P(vault: vault)), "dropping the vault is narrower")
        XCTAssertFalse(covered(P(vault: vault), by: P()))
        XCTAssertFalse(covered(P(vault: .init(provider: "bitwarden", idleLockMinutes: 30)), by: P(vault: vault)), "longer sessions ask again")
        XCTAssertTrue(PermissionStore.requiresApproval(for: Manifest(schemaVersion: 1, id: "v", name: "v", entry: .init(kind: "workflow"), permissions: P(vault: vault))))
    }

    func testFlagsCanOnlyTurnOff() {
        XCTAssertTrue(covered(P(keychain: false), by: P(keychain: true)))
        XCTAssertTrue(covered(P(), by: P(notifications: true)))
        XCTAssertFalse(covered(P(keychain: true), by: P()))
        XCTAssertFalse(covered(P(notifications: true), by: P(notifications: false)))
        XCTAssertFalse(covered(P(quitApps: true), by: P()))
    }

    func testStorageQuota() {
        XCTAssertTrue(covered(P(storage: .init(granted: false)), by: P()))
        XCTAssertFalse(covered(P(storage: .init()), by: P()))
        XCTAssertTrue(covered(P(storage: .init(maxBytes: 100)), by: P(storage: .init(maxBytes: 200))))
        XCTAssertFalse(covered(P(storage: .init(maxBytes: 300)), by: P(storage: .init(maxBytes: 200))))
        XCTAssertFalse(covered(P(storage: .init(maxBytes: 100)), by: P(storage: .init())), "default quota is not a number")
        XCTAssertFalse(covered(P(storage: .init()), by: P(storage: .init(maxBytes: 100))))
    }

    func testExecArguments() {
        let any = Exec(command: "/bin/date")
        let bare = Exec(command: "/bin/date", allowedArgs: [])
        let iso = Exec(command: "/bin/date", allowedArgs: [["-u"]])
        let wildcard = Exec(command: "/bin/date", allowedArgs: [["*"]])
        XCTAssertTrue(covered(P(exec: [iso]), by: P(exec: [any])), "any arguments covers some")
        XCTAssertFalse(covered(P(exec: [any]), by: P(exec: [iso])))
        XCTAssertTrue(covered(P(exec: [bare]), by: P(exec: [Exec(command: "/bin/date", allowedArgs: [[], ["-u"]])])))
        XCTAssertFalse(covered(P(exec: [bare]), by: P(exec: [iso])))
        XCTAssertFalse(covered(P(exec: [iso]), by: P(exec: [wildcard])), "no wildcard reasoning")
        XCTAssertFalse(covered(P(exec: [Exec(command: "date", allowedArgs: [["-u"]])]), by: P(exec: [iso])))
    }

    /// The first matching entry decides what a run gets. Dropping an entry
    /// hands its runs to the next one for the same command, which must not
    /// give them more.
    func testDroppingAnEntryCannotHandItsRunsToARicherOne() {
        let plain = Exec(command: "/usr/bin/env", allowedArgs: [])
        let withToken = Exec(command: "/usr/bin/env", allowedArgs: [], env: ["TOKEN"])
        XCTAssertFalse(covered(P(exec: [withToken]), by: P(exec: [plain, withToken])))
        XCTAssertFalse(covered(P(exec: [withToken, plain]), by: P(exec: [plain, withToken])), "reordering")
        let bigger = Exec(command: "/usr/bin/env", allowedArgs: [], maxOutputBytes: 1_000_000)
        let smaller = Exec(command: "/usr/bin/env", allowedArgs: [], maxOutputBytes: 10)
        XCTAssertFalse(covered(P(exec: [bigger]), by: P(exec: [smaller, bigger])))
        // Shrinking an entry's patterns hands the dropped ones on too.
        let both = Exec(command: "/usr/bin/env", allowedArgs: [[], ["-i"]])
        let bare = Exec(command: "/usr/bin/env", allowedArgs: [])
        let anyWithToken = Exec(command: "/usr/bin/env", env: ["TOKEN"])
        XCTAssertFalse(covered(P(exec: [Exec(command: "/usr/bin/env", allowedArgs: [["-i"]]), anyWithToken]),
                               by: P(exec: [both, anyWithToken])))
        // Dropping an entry is fine when the next one gives no more.
        XCTAssertTrue(covered(P(exec: [bare]), by: P(exec: [withToken, bare])))
        // Or when the next one is for another command.
        XCTAssertTrue(covered(P(exec: [Exec(command: "/bin/date", env: ["TOKEN"])]),
                              by: P(exec: [plain, Exec(command: "/bin/date", env: ["TOKEN"])])))
    }

    /// Marking any command sensitive covers the whole widget, so dropping the
    /// one marked command would unmark the others.
    func testDroppingTheOnlySensitiveCommandAsksAgain() {
        let secret = Exec(command: "/usr/bin/security", allowedArgs: [], sensitiveOutput: true)
        let date = Exec(command: "/bin/date", allowedArgs: [])
        XCTAssertFalse(covered(P(exec: [date]), by: P(exec: [secret, date])))
        XCTAssertTrue(covered(P(exec: [secret]), by: P(exec: [secret, date])))
    }

    func testExecEnvOutputAndSensitivity() {
        func exec(env: [String]? = nil, max: Int? = nil, sensitive: Bool? = nil) -> P {
            P(exec: [Exec(command: "/bin/x", allowedArgs: [], env: env, maxOutputBytes: max, sensitiveOutput: sensitive)])
        }
        XCTAssertTrue(covered(exec(env: ["A"]), by: exec(env: ["A", "B"])))
        XCTAssertFalse(covered(exec(env: ["C"]), by: exec(env: ["A"])))
        XCTAssertTrue(covered(exec(max: 10), by: exec(max: 20)))
        XCTAssertFalse(covered(exec(max: 30), by: exec(max: 20)))
        XCTAssertFalse(covered(exec(max: 10), by: exec()))
        XCTAssertTrue(covered(exec(sensitive: true), by: exec()), "hiding more output is narrower")
        XCTAssertFalse(covered(exec(), by: exec(sensitive: true)))
    }

    // MARK: - The store

    private func manifest(_ permissions: P?) -> Manifest {
        Manifest(schemaVersion: 1, id: "dev.test.narrow", name: "Narrow", entry: .init(kind: "workflow"), permissions: permissions)
    }

    private func fileURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("barshelf-narrow-\(UUID().uuidString).json")
    }

    private final class Carried: @unchecked Sendable {
        let lock = NSLock()
        var events: [String] = []
        func add(_ id: String) { lock.lock(); events.append(id); lock.unlock() }
    }

    func testApprovalCoversANarrowerSetAndIsAuditedOnce() {
        let url = fileURL()
        let store = PermissionStore(fileURL: url)
        let carried = Carried()
        store.onApprovalCarried = { id, _ in carried.add(id) }
        let wide = manifest(P(network: ["a.com", "b.com"]))
        let narrow = manifest(P(network: ["a.com"]))
        store.approve(wide)
        XCTAssertEqual(store.status(for: narrow), .approved)
        XCTAssertEqual(store.status(for: narrow), .approved)
        XCTAssertEqual(carried.events, ["dev.test.narrow"], "audited once, not on every check")
        // Survives a relaunch: the record still holds the approved set.
        let reloaded = PermissionStore(fileURL: url)
        XCTAssertEqual(reloaded.status(for: narrow), .approved)
        XCTAssertEqual(reloaded.record(forWidget: narrow.id)?.permissions, wide.permissions)
    }

    /// Copies of a widget (`<id>`, `<id>--<label>`) share one record and may
    /// declare different sets: checking the narrower copy must not take the
    /// approval from the wider one.
    func testCheckingANarrowerCopyLeavesTheWiderCopyApproved() {
        let store = PermissionStore(fileURL: fileURL())
        let wide = manifest(P(network: ["a.com", "b.com"]))
        let narrow = manifest(P(network: ["a.com"]))
        store.approve(wide)
        XCTAssertEqual(store.status(for: narrow), .approved)
        XCTAssertEqual(store.status(for: wide), .approved)
        XCTAssertEqual(store.status(for: narrow), .approved)
    }

    func testWiderOrDeniedOrUnknownSetsAskAgain() {
        let store = store(approving: P(network: ["a.com"]))
        XCTAssertEqual(store.status(for: manifest(P(network: ["a.com", "b.com"]))), .pending)

        let denied = PermissionStore(fileURL: fileURL())
        denied.deny(manifest(P(network: ["a.com", "b.com"])))
        XCTAssertEqual(denied.status(for: manifest(P(network: ["a.com"]))), .pending)
    }

    private func store(approving permissions: P) -> PermissionStore {
        let store = PermissionStore(fileURL: fileURL())
        store.approve(manifest(permissions))
        return store
    }

    /// Records written before the permissions were kept have only a hash.
    /// A narrower set cannot be judged against a hash, so it asks once;
    /// a matching hash fills the record in so the next update can be judged.
    func testOldRecordsAreFilledInWhenTheHashStillMatches() throws {
        let url = fileURL()
        let wide = manifest(P(network: ["a.com", "b.com"]))
        let legacy: [String: [String: String]] = [wide.id: [
            "hash": PermissionStore.permissionsHash(of: wide),
            "decision": "approved",
            "decidedAt": "2026-10-26T02:26:44Z",
        ]]
        try JSONEncoder().encode(legacy).write(to: url)

        let narrow = manifest(P(network: ["a.com"]))
        XCTAssertEqual(PermissionStore(fileURL: url).status(for: narrow), .pending, "a hash alone cannot be judged")

        let store = PermissionStore(fileURL: url)
        XCTAssertEqual(store.status(for: wide), .approved)
        XCTAssertEqual(store.record(forWidget: wide.id)?.permissions, wide.permissions)
        XCTAssertEqual(PermissionStore(fileURL: url).status(for: narrow), .approved)
    }
}
