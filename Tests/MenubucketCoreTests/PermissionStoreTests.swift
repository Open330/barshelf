import XCTest
@testable import MenubucketCore

final class PermissionStoreTests: XCTestCase {
    private func manifest(permissions: Manifest.Permissions? = nil) -> Manifest {
        Manifest(
            schemaVersion: 1,
            id: "dev.test.permission",
            name: "Permission",
            entry: .init(kind: "workflow"),
            permissions: permissions
        )
    }

    private func store() -> PermissionStore {
        PermissionStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("barshelf-permissions-\(UUID().uuidString).json"))
    }

    /// One record this build cannot read must not cost every other
    /// approval: they used to decode as one dictionary or not at all.
    func testOneUnreadableRecordKeepsTheOthers() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("barshelf-permissions-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let widget = manifest(permissions: .init(network: ["example.com"]))
        let first = PermissionStore(fileURL: url)
        first.approve(widget)

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        object["dev.test.broken"] = ["hash": 12]
        if var record = object[widget.id] as? [String: Any] {
            record["permissions"] = ["exec": "not a list"]
            object[widget.id] = record
        }
        try JSONSerialization.data(withJSONObject: object).write(to: url)

        let reloaded = PermissionStore(fileURL: url)
        XCTAssertEqual(reloaded.status(for: widget), .approved)
        XCTAssertNil(reloaded.record(forWidget: "dev.test.broken"))
    }

    func testPermissionFreeWidgetIsApprovedWithoutRecord() {
        let store = store()
        let widget = manifest()
        XCTAssertFalse(PermissionStore.requiresApproval(for: widget))
        XCTAssertEqual(store.status(for: widget), .approved)
        XCTAssertNil(store.record(forWidget: widget.id))
    }

    func testEmptyAndFalsePermissionsArePermissionFree() {
        let widget = manifest(permissions: .init(
            exec: [], network: [], readPaths: [], env: [],
            keychain: false, notifications: false,
            storage: .init(granted: false)
        ))
        XCTAssertFalse(PermissionStore.requiresApproval(for: widget))
        XCTAssertEqual(store().status(for: widget), .approved)
    }

    func testReadPathRequiresExplicitApproval() {
        let store = store()
        let widget = manifest(permissions: .init(readPaths: ["~/Downloads"]))
        XCTAssertTrue(PermissionStore.manifestDeclares(.readPaths, in: widget))
        XCTAssertEqual(store.status(for: widget), .pending)
        store.approve(widget)
        XCTAssertEqual(store.status(for: widget), .approved)
    }

    /// The hash is remembered between checks, but a manifest reloaded with
    /// other permissions is not taken for the approved one.
    func testChangedPermissionsAskAgainAfterTheHashWasRemembered() {
        let store = store()
        let approved = manifest(permissions: .init(readPaths: ["~/Downloads"]))
        store.approve(approved)
        XCTAssertEqual(store.status(for: approved), .approved)
        XCTAssertEqual(store.status(for: approved), .approved)
        let widened = manifest(permissions: .init(readPaths: ["~/Downloads", "~/Documents"]))
        XCTAssertEqual(store.status(for: widened), .pending)
        XCTAssertEqual(store.status(for: approved), .approved)
    }
}
