import AppKit
import XCTest
import MenubucketCore
@testable import MenubucketApp

/// Requires a disposable Foundation home: never starts a live runtime against
/// the user's installed widgets. Run separately with CFFIXED_USER_HOME.
@MainActor
final class PermissionWithdrawalTests: XCTestCase {
    func testWithdrawalClearsCachedReadingFromCardsDockAndMenuBar() throws {
        let root = try disposableRoot()
        for deny in [false, true] {
            let id = "dev.test.withdraw-display-\(UUID().uuidString)"
            let fixture = root.appendingPathComponent("widgets/\(id)")
            try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: fixture) }
            let manifest = Manifest(schemaVersion: 1, id: id, name: "Private reading",
                entry: .init(kind: "workflow", main: "workflow.json"),
                statusItem: .init(mode: "dynamic"), permissions: .init(storage: .init()))
            try JSONEncoder().encode(manifest).write(to: fixture.appendingPathComponent("widget.json"))
            try Data(#"{"schemaVersion":1,"sources":{},"view":{"type":"text","text":"new reading"}}"#.utf8)
                .write(to: fixture.appendingPathComponent("workflow.json"))
            let cache = root.appendingPathComponent("cache/\(id).json")
            try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
            try WidgetSnapshot(widgetID: id, viewTree: UINode(type: "text", text: "private cached value"),
                updatedAt: Date(), statusLabel: "private cached value").serialized().write(to: cache)
            defer { try? FileManager.default.removeItem(at: cache) }
            let permissions = PermissionStore(fileURL: root.appendingPathComponent("permissions-\(id).json"))
            permissions.approve(manifest)
            let runtime = WidgetRuntime(appPrefs: AppPrefs(fileURL: root.appendingPathComponent("test-app-prefs.json")),
                permissionStore: permissions)
            runtime.loadWidgets()
            runtime.setMenuBarPlacement(.init(enabled: true), for: id)
            let model = runtime.cardModel(for: id)
            XCTAssertEqual(model.snapshot.viewTree?.text, "private cached value")
            XCTAssertTrue(runtime.ownedMenuBarEntries.contains {
                $0.widgetID == id && $0.label == MenuBarPolicy.normalizedLabel("private cached value")
            })
            if deny { runtime.denyPermissions(widgetID: id) }
            else { runtime.revokePermissions(widgetID: id) }
            XCTAssertNil(model.snapshot.viewTree, "Dock glances observe the same card model")
            XCTAssertNil(runtime.snapshots[id]?.statusLabel)
            XCTAssertFalse(runtime.menuBarWidgetIDs.contains(id))
            runtime.loadWidgets()
            XCTAssertNil(runtime.snapshots[id]?.viewTree, "rescan must not restore revoked cached data")
            XCTAssertFalse(runtime.menuBarWidgetIDs.contains(id))
            runtime.approvePermissions(widgetID: id)
            XCTAssertTrue(runtime.menuBarWidgetIDs.contains(id), "Allow must restore promotion in the same turn")
            XCTAssertNil(model.overlay)
        }
    }

    func testRevokeAndDenyStopTheResidentScript() async throws {
        guard let home = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"],
              home.contains("barshelf-quality-home-"),
              WidgetRuntime.applicationSupportDirectory.resolvingSymlinksInPath().path.hasPrefix(
                URL(fileURLWithPath: home).resolvingSymlinksInPath().path + "/") else {
            throw XCTSkip("run with CFFIXED_USER_HOME set to a disposable barshelf-quality-home-* directory")
        }
        _ = NSApplication.shared
        let root = WidgetRuntime.applicationSupportDirectory
        let fixture = root.appendingPathComponent("widgets/permission-withdrawal")
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let manifest = Manifest(schemaVersion: 1, id: "dev.test.permission-withdrawal", name: "Withdrawal",
                                entry: .init(kind: "script", runtime: "deno-ts@1", main: "index.ts"),
                                permissions: .init(keychain: true))
        try JSONEncoder().encode(manifest).write(to: fixture.appendingPathComponent("widget.json"))
        try Data().write(to: fixture.appendingPathComponent("index.ts"))
        let stub = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/rpc-stub.sh")
        let permissions = PermissionStore(fileURL: root.appendingPathComponent("test-permissions.json"))
        let supervisor = RuntimeSupervisor(configuration: RuntimeSupervisorConfiguration(
            makeLaunchPlan: { _ in ScriptLaunchPlan(executable: URL(fileURLWithPath: "/bin/bash"), arguments: [stub.path, "render"]) },
            storage: StorageService(directory: root.appendingPathComponent("test-storage")),
            secrets: InMemorySecretStore(),
            isApproved: { permissions.status(for: $0) == .approved }
        ), events: RuntimeSupervisorEvents())
        let runtime = WidgetRuntime(appPrefs: AppPrefs(fileURL: root.appendingPathComponent("test-app-prefs.json")),
                                    permissionStore: permissions, scriptSupervisor: supervisor)
        runtime.loadWidgets()
        XCTAssertTrue(runtime.widgets.contains { $0.id == manifest.id })
        let descriptor = ScriptWidgetDescriptor(manifest: manifest, directory: fixture)
        for deny in [false, true] {
            permissions.approve(manifest)
            try await supervisor.load(descriptor, reason: "manual")
            let running = await supervisor.isRunning(widgetId: manifest.id)
            XCTAssertTrue(running)
            if deny { runtime.denyPermissions(widgetID: manifest.id) }
            else { runtime.revokePermissions(widgetID: manifest.id) }
            let deadline = Date().addingTimeInterval(5)
            while await supervisor.isRunning(widgetId: manifest.id), Date() < deadline {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            let stopped = await supervisor.isRunning(widgetId: manifest.id)
            XCTAssertFalse(stopped)
            XCTAssertEqual(permissions.status(for: manifest), deny ? .denied : .pending)
        }
        await supervisor.stopAll()
    }

    /// Refresh and Revoke in one main-actor turn: the queued exec must never
    /// launch, for a direct exec widget and for a workflow exec source.
    func testRevokeInTheSameTurnLaunchesNoNativeCommand() async throws {
        let root = try disposableRoot()
        for kind in ["exec", "workflow"] {
            let (runtime, permissions, manifest, witness) = try makeNativeFixture(
                root: root, name: "same-turn-\(kind)", kind: kind,
                script: "/usr/bin/touch \"$W/started.a\"; echo '{}'"
            )
            defer { try? FileManager.default.removeItem(at: witness.deletingLastPathComponent()) }
            permissions.approve(manifest)
            let widget = try XCTUnwrap(runtime.widgets.first { $0.id == manifest.id })
            runtime.refresh(widget, manual: true)
            runtime.revokePermissions(widgetID: manifest.id)
            try await Task.sleep(nanoseconds: 600_000_000)
            XCTAssertEqual(try startedMarkers(witness), [], kind)
            XCTAssertEqual(permissions.status(for: manifest), .pending, kind)
            XCTAssertNil(runtime.snapshots[manifest.id]?.viewTree, kind)
        }
    }

    /// Revoke while a workflow's first exec source is running: no later source
    /// starts, and the result in flight is never published.
    func testRevokeDuringWorkflowStopsLaterSources() async throws {
        let root = try disposableRoot()
        for action in ["revoke", "deny", "disable"] {
            let (runtime, permissions, manifest, witness) = try makeNativeFixture(
                root: root, name: "mid-workflow-\(action)", kind: "workflow",
                script: "/usr/bin/touch \"$W/started.$1\"; /bin/sleep 0.6; echo '{}'",
                sources: ["a", "b"]
            )
            defer { try? FileManager.default.removeItem(at: witness.deletingLastPathComponent()) }
            permissions.approve(manifest)
            let widget = try XCTUnwrap(runtime.widgets.first { $0.id == manifest.id })
            runtime.refresh(widget, manual: true)
            let deadline = Date().addingTimeInterval(5)
            while try startedMarkers(witness).isEmpty, Date() < deadline {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertEqual(try startedMarkers(witness).count, 1, action)
            switch action {
            case "revoke": runtime.revokePermissions(widgetID: manifest.id)
            case "deny": runtime.denyPermissions(widgetID: manifest.id)
            default: runtime.setWidgetDisabled(manifest.id, true)
            }
            try await Task.sleep(nanoseconds: 1_500_000_000)
            XCTAssertEqual(try startedMarkers(witness).count, 1, action)
            XCTAssertNil(runtime.snapshots[manifest.id]?.viewTree, action)
            XCTAssertNil(runtime.snapshots[manifest.id]?.error, action)
            XCTAssertEqual(runtime.snapshots[manifest.id]?.isLoading, false, action)
            if action == "disable" { runtime.prefs.setDisabled(manifest.id, false) }
        }
    }

    private func disposableRoot() throws -> URL {
        guard let home = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"],
              home.contains("barshelf-quality-home-"),
              WidgetRuntime.applicationSupportDirectory.resolvingSymlinksInPath().path.hasPrefix(
                URL(fileURLWithPath: home).resolvingSymlinksInPath().path + "/") else {
            throw XCTSkip("run with CFFIXED_USER_HOME set to a disposable barshelf-quality-home-* directory")
        }
        _ = NSApplication.shared
        return WidgetRuntime.applicationSupportDirectory
    }

    /// A widget whose every command is `/bin/sh -c script <source>` with `$W`
    /// set to a fresh witness directory; each launch leaves a `started.*` file.
    private func makeNativeFixture(
        root: URL, name: String, kind: String, script: String, sources: [String] = ["a"]
    ) throws -> (WidgetRuntime, PermissionStore, Manifest, URL) {
        let fixture = root.appendingPathComponent("widgets/\(name)")
        let witness = root.appendingPathComponent("witness-\(name)-\(UUID().uuidString)/w")
        try? FileManager.default.removeItem(at: fixture)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: witness, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture) }
        let body = "W='\(witness.path)'; \(script)"
        let id = "dev.test.\(name)"
        let manifest: Manifest
        if kind == "exec" {
            manifest = Manifest(schemaVersion: 1, id: id, name: name,
                                entry: .init(kind: "exec"),
                                source: .init(command: ["/bin/sh", "-c", body, "sh", "a"]),
                                permissions: .init(exec: [.init(command: "/bin/sh")]))
        } else {
            manifest = Manifest(schemaVersion: 1, id: id, name: name,
                                entry: .init(kind: "workflow", main: "workflow.json"),
                                permissions: .init(exec: [.init(command: "/bin/sh")]))
            let workflow = WorkflowDefinition(
                sources: Dictionary(uniqueKeysWithValues: sources.map { source in
                    (source, WorkflowDefinition.SourceDef(use: "exec", with: .object([
                        "command": .array(["/bin/sh", "-c", body, "sh", source].map(JSONValue.string)),
                    ])))
                }),
                view: .object(["type": .string("text"), "text": .string("done")])
            )
            try JSONEncoder().encode(workflow).write(to: fixture.appendingPathComponent("workflow.json"))
        }
        try JSONEncoder().encode(manifest).write(to: fixture.appendingPathComponent("widget.json"))
        let permissions = PermissionStore(fileURL: root.appendingPathComponent("test-permissions-\(name).json"))
        let runtime = WidgetRuntime(appPrefs: AppPrefs(fileURL: root.appendingPathComponent("test-app-prefs.json")),
                                    permissionStore: permissions)
        runtime.loadWidgets()
        return (runtime, permissions, manifest, witness)
    }

    private func startedMarkers(_ witness: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: witness.path)
            .filter { $0.hasPrefix("started.") }.sorted()
    }
}
