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

    func testExecEnvironmentIncludesOnlyManifestAndMatchedCommandDeclarations() throws {
        let direct = Manifest.ExecPermission(
            command: "/bin/date", allowedArgs: [[]], env: ["DIRECT_VALUE", "DIRECT_SECRET"]
        )
        let other = Manifest.ExecPermission(
            command: "/usr/bin/env", allowedArgs: [[]], env: ["OTHER_VALUE", "OTHER_SECRET"]
        )
        let widget = Manifest(
            schemaVersion: 1,
            id: "dev.test.runtime-permission",
            name: "Runtime Permission",
            entry: .init(kind: "exec"),
            permissions: .init(
                exec: [direct, other], env: ["SHARED_VALUE", "SHARED_SECRET"], keychain: true
            )
        )
        let permission = try XCTUnwrap(ExecAllowlist.match(
            command: ["/bin/date"], permissions: widget.permissions?.exec
        ))
        let values = WidgetRuntime.secretEnvironment(
            for: widget,
            permission: permission,
            hostEnvironment: [
                "SHARED_VALUE": "shared-host",
                "DIRECT_VALUE": "direct-host",
                "OTHER_VALUE": "other-host",
            ],
            readSecret: { account in
                [
                    "shared-secret": "shared-keychain",
                    "direct-secret": "direct-keychain",
                    "other-secret": "other-keychain",
                ][account]
            }
        )

        XCTAssertEqual(values, [
            "SHARED_VALUE": "shared-host",
            "SHARED_SECRET": "shared-keychain",
            "DIRECT_VALUE": "direct-host",
            "DIRECT_SECRET": "direct-keychain",
        ])
        XCTAssertNil(values?["OTHER_VALUE"])
        XCTAssertNil(values?["OTHER_SECRET"])
    }

    private func dispatchFixture() throws -> (
        widget: LoadedWidget,
        source: Manifest.Source,
        permission: Manifest.ExecPermission,
        allowedName: String,
        forbiddenName: String
    ) {
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let allowedName = "BARSHELF_RPF004_ALLOWED_\(suffix)"
        let forbiddenName = "BARSHELF_RPF004_OTHER_\(suffix)"
        let source = Manifest.Source(command: ["/usr/bin/env"], timeoutMs: 2_000)
        let manifest = Manifest(
            schemaVersion: 1,
            id: "dev.test.runtime-permission",
            name: "Runtime Permission",
            entry: .init(kind: "exec"),
            source: source,
            permissions: .init(exec: [
                .init(command: "/usr/bin/env", allowedArgs: [[]], env: [allowedName]),
                .init(command: "/bin/date", allowedArgs: [[]], env: [forbiddenName]),
            ])
        )
        let permission = try XCTUnwrap(ExecAllowlist.match(
            command: source.command ?? [], permissions: manifest.permissions?.exec
        ))
        return (
            LoadedWidget(manifest: manifest, directory: FileManager.default.temporaryDirectory),
            source,
            permission,
            allowedName,
            forbiddenName
        )
    }

    private func assertScopedDispatchOutput(
        _ result: Result<Data, ExecService.ExecError>,
        allowedName: String,
        forbiddenName: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let output = String(decoding: try result.get(), as: UTF8.self)
        XCTAssertTrue(output.contains("\(allowedName)=allowed-visible"), file: file, line: line)
        XCTAssertFalse(output.contains(forbiddenName), file: file, line: line)
        XCTAssertFalse(output.contains("other-must-not-leak"), file: file, line: line)
    }

    func testDirectExecDispatchDoesNotReceiveAnotherCommandsEnvironment() async throws {
        let fixture = try dispatchFixture()
        setenv(fixture.allowedName, "allowed-visible", 1)
        setenv(fixture.forbiddenName, "other-must-not-leak", 1)
        defer {
            unsetenv(fixture.allowedName)
            unsetenv(fixture.forbiddenName)
        }

        let result = await WidgetRuntime.dispatchDirectExec(
            execService: ExecService(),
            widget: fixture.widget,
            source: fixture.source,
            command: ["/usr/bin/env"],
            permission: fixture.permission
        )
        try assertScopedDispatchOutput(
            result, allowedName: fixture.allowedName, forbiddenName: fixture.forbiddenName
        )
    }

    func testWorkflowExecDispatchDoesNotReceiveAnotherCommandsEnvironment() async throws {
        let fixture = try dispatchFixture()
        setenv(fixture.allowedName, "allowed-visible", 1)
        setenv(fixture.forbiddenName, "other-must-not-leak", 1)
        defer {
            unsetenv(fixture.allowedName)
            unsetenv(fixture.forbiddenName)
        }

        let result = await WidgetRuntime.dispatchWorkflowExec(
            execService: ExecService(),
            widget: fixture.widget,
            command: ["/usr/bin/env"],
            discover: nil,
            timeoutMs: 2_000,
            permission: fixture.permission
        )
        try assertScopedDispatchOutput(
            result, allowedName: fixture.allowedName, forbiddenName: fixture.forbiddenName
        )
    }

    func testRunActionDispatchDoesNotReceiveAnotherCommandsEnvironment() async throws {
        let fixture = try dispatchFixture()
        setenv(fixture.allowedName, "allowed-visible", 1)
        setenv(fixture.forbiddenName, "other-must-not-leak", 1)
        defer {
            unsetenv(fixture.allowedName)
            unsetenv(fixture.forbiddenName)
        }

        let result = await WidgetRuntime.dispatchRunActionExec(
            execService: ExecService(),
            widget: fixture.widget,
            command: ["/usr/bin/env"],
            permission: fixture.permission
        )
        try assertScopedDispatchOutput(
            result, allowedName: fixture.allowedName, forbiddenName: fixture.forbiddenName
        )
    }

    func testAdapterExecResolvesEnvironmentForItsOwnMatchedCommand() async throws {
        let sourceOnly = "BARSHELF_RPF004_SOURCE_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let adapterOnly = "BARSHELF_RPF004_ADAPTER_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let shared = "BARSHELF_RPF004_SHARED_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        setenv(sourceOnly, "source-must-not-leak", 1)
        setenv(adapterOnly, "adapter-visible", 1)
        setenv(shared, "shared-visible", 1)
        defer {
            unsetenv(sourceOnly)
            unsetenv(adapterOnly)
            unsetenv(shared)
        }

        let widget = Manifest(
            schemaVersion: 1,
            id: "dev.test.runtime-permission",
            name: "Runtime Permission",
            entry: .init(kind: "exec"),
            source: .init(command: ["/bin/date"]),
            permissions: .init(
                exec: [
                    .init(command: "/bin/date", allowedArgs: [[]], env: [sourceOnly]),
                    .init(command: "/usr/bin/env", allowedArgs: [[]], env: [adapterOnly]),
                ],
                env: [shared]
            )
        )
        let context = HostAdapterContext(
            widget: LoadedWidget(
                manifest: widget, directory: FileManager.default.temporaryDirectory
            ),
            execService: ExecService(),
            defaultTimeoutMs: 2_000,
            settings: [:]
        )

        let output = String(decoding: try await context.runAllowed(command: ["/usr/bin/env"]), as: UTF8.self)
        XCTAssertTrue(output.contains("\(adapterOnly)=adapter-visible"))
        XCTAssertTrue(output.contains("\(shared)=shared-visible"))
        XCTAssertFalse(output.contains(sourceOnly))
        XCTAssertFalse(output.contains("source-must-not-leak"))
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
