import AppKit
import XCTest
import MenubucketCore
@testable import MenubucketApp

@MainActor
final class ScriptLifecycleTests: XCTestCase {
    func testDisableOrReloadBeforeQueuedScriptLoadCannotLaunchOldWork() async throws {
        guard let home = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"],
              home.contains("barshelf-quality-home-"),
              WidgetRuntime.applicationSupportDirectory.resolvingSymlinksInPath().path.hasPrefix(
                URL(fileURLWithPath: home).resolvingSymlinksInPath().path + "/") else {
            throw XCTSkip("requires a disposable barshelf-quality-home-* Foundation home")
        }
        _ = NSApplication.shared
        let root = WidgetRuntime.applicationSupportDirectory
        for action in ["disable", "reload"] {
            let fixture = root.appendingPathComponent("widgets/lifetime-\(action)")
            try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: fixture) }
            let witness = fixture.appendingPathComponent("must-not-start")
            let script = fixture.appendingPathComponent("resident.sh")
            try """
            /usr/bin/touch must-not-start
            while IFS= read -r line; do :; done
            """.write(to: script, atomically: true, encoding: .utf8)
            let manifest = Manifest(schemaVersion: 1, id: "dev.test.lifetime-\(action)", name: "Lifetime",
                entry: .init(kind: "script", runtime: "deno-ts@1", main: "index.ts"), permissions: .init(keychain: true))
            try JSONEncoder().encode(manifest).write(to: fixture.appendingPathComponent("widget.json"))
            try Data().write(to: fixture.appendingPathComponent("index.ts"))
            let store = PermissionStore(fileURL: root.appendingPathComponent("lifetime-permissions-\(action).json"))
            let supervisor = RuntimeSupervisor(configuration: RuntimeSupervisorConfiguration(
                makeLaunchPlan: { _ in ScriptLaunchPlan(executable: URL(fileURLWithPath: "/bin/bash"), arguments: [script.path], currentDirectory: fixture) },
                storage: StorageService(directory: root.appendingPathComponent("lifetime-storage")), secrets: InMemorySecretStore(),
                isApproved: { store.status(for: $0) == .approved }
            ), events: RuntimeSupervisorEvents())
            let runtime = WidgetRuntime(appPrefs: AppPrefs(fileURL: root.appendingPathComponent("lifetime-app-prefs.json")),
                permissionStore: store, scriptSupervisor: supervisor)
            runtime.loadWidgets()
            store.approve(manifest)
            let widget = try XCTUnwrap(runtime.widgets.first { $0.id == manifest.id })
            runtime.refresh(widget, manual: true)
            if action == "disable" { runtime.setWidgetDisabled(widget.id, true) }
            else { runtime.loadWidgets() }
            try await Task.sleep(nanoseconds: 200_000_000)
            XCTAssertFalse(FileManager.default.fileExists(atPath: witness.path), action)
            let running = await supervisor.isRunning(widgetId: widget.id)
            XCTAssertFalse(running, action)
            await supervisor.stopAll()
            runtime.prefs.setDisabled(widget.id, false)
        }
    }
}
