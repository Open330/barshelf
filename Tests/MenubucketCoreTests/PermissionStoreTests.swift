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
}
