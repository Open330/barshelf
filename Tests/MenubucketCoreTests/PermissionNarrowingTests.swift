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

    func testApprovalMovesToANarrowerSetAndIsAudited() {
        let url = fileURL()
        let store = PermissionStore(fileURL: url)
        let carried = Carried()
        store.onApprovalCarried = { id, _ in carried.add(id) }
        let wide = manifest(P(network: ["a.com", "b.com"]))
        let narrow = manifest(P(network: ["a.com"]))
        store.approve(wide)
        XCTAssertEqual(store.status(for: narrow), .approved)
        XCTAssertEqual(carried.events, ["dev.test.narrow"])
        XCTAssertEqual(store.status(for: narrow), .approved)
        XCTAssertEqual(carried.events.count, 1, "carried once, then the hash matches")
        // The approval is now for the narrower set, on disk too.
        let reloaded = PermissionStore(fileURL: url)
        XCTAssertEqual(reloaded.status(for: narrow), .approved)
        XCTAssertEqual(reloaded.record(forWidget: narrow.id)?.permissions, narrow.permissions)
        XCTAssertEqual(reloaded.status(for: wide), .pending, "widening back asks again")
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
        XCTAssertEqual(PermissionStore(fileURL: url).status(for: narrow), .pending)

        let store = PermissionStore(fileURL: url)
        XCTAssertEqual(store.status(for: wide), .approved)
        XCTAssertEqual(store.record(forWidget: wide.id)?.permissions, wide.permissions)
        XCTAssertEqual(PermissionStore(fileURL: url).status(for: narrow), .approved)
    }
}
