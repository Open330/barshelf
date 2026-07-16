import XCTest
@testable import MenubucketApp
import MenubucketCore

final class RuntimePermissionGateTests: XCTestCase {
    private func manifest(
        exec: [Manifest.ExecPermission]? = nil,
        readPaths: [String]? = nil,
        settings: [Manifest.Setting]? = nil
    ) -> Manifest {
        Manifest(
            schemaVersion: 1,
            id: "dev.test.runtime-permission",
            name: "Runtime Permission",
            entry: .init(kind: "workflow"),
            permissions: .init(exec: exec, readPaths: readPaths),
            settings: settings
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

    // MARK: - User-picked directory settings

    private func directorySetting(
        key: String = "folder",
        default defaultPath: String? = nil
    ) -> Manifest.Setting {
        Manifest.Setting(
            key: key,
            type: "directory",
            defaultValue: defaultPath.map { JSONValue.string($0) }
        )
    }

    func testUserPickedDirectoryGrantsReadAccessOutsideDeclaredPaths() {
        let widget = manifest(readPaths: ["~/Downloads"], settings: [directorySetting()])
        let granted = WidgetRuntime.userGrantedReadPaths(
            manifest: widget, storedSettings: ["folder": .string("~/Pictures/screenshots")]
        )
        XCTAssertEqual(granted, ["~/Pictures/screenshots"])
        XCTAssertTrue(WidgetRuntime.filePathAllowed(
            "~/Pictures/screenshots/shot.png",
            allowlist: (widget.permissions?.readPaths ?? []) + granted
        ))
    }

    /// The security boundary: `default` is author-controlled, so it must never
    /// self-grant. Only a folder the user actually picked counts.
    func testManifestDefaultDirectoryDoesNotGrantReadAccess() {
        let widget = manifest(
            readPaths: ["~/Downloads"],
            settings: [directorySetting(default: "~/.ssh")]
        )
        XCTAssertTrue(WidgetRuntime.userGrantedReadPaths(
            manifest: widget, storedSettings: [:]
        ).isEmpty)
        XCTAssertFalse(WidgetRuntime.filePathAllowed("~/.ssh/id_rsa", manifest: widget))
    }

    func testNonDirectorySettingDoesNotGrantReadAccess() {
        let widget = manifest(
            readPaths: ["~/Downloads"],
            settings: [Manifest.Setting(key: "folder", type: "string")]
        )
        XCTAssertTrue(WidgetRuntime.userGrantedReadPaths(
            manifest: widget, storedSettings: ["folder": .string("~/.ssh")]
        ).isEmpty)
    }

    func testEmptyOrMissingPickedDirectoryIsIgnored() {
        let widget = manifest(readPaths: [], settings: [directorySetting()])
        XCTAssertTrue(WidgetRuntime.userGrantedReadPaths(
            manifest: widget, storedSettings: ["folder": .string("")]
        ).isEmpty)
        XCTAssertTrue(WidgetRuntime.userGrantedReadPaths(
            manifest: widget, storedSettings: ["other": .string("~/.ssh")]
        ).isEmpty)
    }

    /// A picked folder is still symlink-canonicalized, so it cannot be used to
    /// reach outside itself.
    func testPickedDirectoryStillRejectsSymlinkEscape() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("barshelf-picked-link-\(UUID().uuidString)", isDirectory: true)
        let picked = base.appendingPathComponent("picked", isDirectory: true)
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: picked, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: picked.appendingPathComponent("escape"), withDestinationURL: outside
        )
        let widget = manifest(readPaths: [], settings: [directorySetting()])
        let granted = WidgetRuntime.userGrantedReadPaths(
            manifest: widget, storedSettings: ["folder": .string(picked.path)]
        )
        XCTAssertTrue(WidgetRuntime.filePathAllowed(
            picked.appendingPathComponent("shot.png").path, allowlist: granted
        ))
        XCTAssertFalse(WidgetRuntime.filePathAllowed(
            picked.appendingPathComponent("escape/secret.txt").path, allowlist: granted
        ))
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
