import XCTest
@testable import MenubucketApp
import MenubucketCore

final class RuntimePermissionGateTests: XCTestCase {
    private func manifest(
        exec: [Manifest.ExecPermission]? = nil,
        readPaths: [String]? = nil
    ) -> Manifest {
        Manifest(
            schemaVersion: 1,
            id: "dev.test.runtime-permission",
            name: "Runtime Permission",
            entry: .init(kind: "workflow"),
            permissions: .init(exec: exec, readPaths: readPaths)
        )
    }

    func testExecIsFailClosedWhenPermissionMissingOrEmpty() {
        XCTAssertFalse(WidgetRuntime.execCommandAllowed(["/bin/date"], manifest: manifest()))
        XCTAssertFalse(WidgetRuntime.execCommandAllowed(
            ["/bin/date"], manifest: manifest(exec: [])
        ))
    }

    func testExecRequiresMatchingAllowlistEntry() {
        let widget = manifest(exec: [.init(command: "/bin/date", allowedArgs: [[]])])
        XCTAssertTrue(WidgetRuntime.execCommandAllowed(["/bin/date"], manifest: widget))
        XCTAssertFalse(WidgetRuntime.execCommandAllowed(["/bin/sh"], manifest: widget))
    }

    func testFilePathAllowsChildrenButNotPrefixSiblings() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("barshelf-read-root-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let widget = manifest(readPaths: [root.path])
        XCTAssertTrue(WidgetRuntime.filePathAllowed(
            root.appendingPathComponent("child/file.txt").path, manifest: widget
        ))
        XCTAssertFalse(WidgetRuntime.filePathAllowed(root.path + "-private/file.txt", manifest: widget))
    }

    func testFilePathRejectsSymlinkEscape() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("barshelf-read-link-\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent("allowed", isDirectory: true)
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("escape"), withDestinationURL: outside
        )
        let widget = manifest(readPaths: [root.path])
        XCTAssertFalse(WidgetRuntime.filePathAllowed(
            root.appendingPathComponent("escape/secret.txt").path, manifest: widget
        ))
    }
}
