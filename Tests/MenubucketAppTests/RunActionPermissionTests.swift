import AppKit
import XCTest
import MenubucketCore
@testable import MenubucketApp

@MainActor
final class RunActionPermissionTests: XCTestCase {
    func testRevokeCancelsQueuedAndAlreadyRunningActionCommands() async throws {
        guard let home = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"],
              home.contains("barshelf-quality-home-"),
              WidgetRuntime.applicationSupportDirectory.resolvingSymlinksInPath().path.hasPrefix(
                URL(fileURLWithPath: home).resolvingSymlinksInPath().path + "/") else {
            throw XCTSkip("requires a disposable barshelf-quality-home-* Foundation home")
        }
        _ = NSApplication.shared
        let root = WidgetRuntime.applicationSupportDirectory
        for waitForStart in [false, true] {
            let id = "dev.test.action-\(UUID().uuidString)"
            let fixture = root.appendingPathComponent("widgets/\(id)")
            try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: fixture) }
            let manifest = Manifest(schemaVersion: 1, id: id, name: "Action",
                entry: .init(kind: "workflow", main: "workflow.json"), permissions: .init(exec: [.init(command: "/bin/sh")]))
            try JSONEncoder().encode(manifest).write(to: fixture.appendingPathComponent("widget.json"))
            try Data(#"{"schemaVersion":1,"sources":{},"view":{"type":"text","text":"ready"}}"#.utf8)
                .write(to: fixture.appendingPathComponent("workflow.json"))
            let permissions = PermissionStore(fileURL: root.appendingPathComponent("action-permissions-\(id).json"))
            permissions.approve(manifest)
            let runtime = WidgetRuntime(appPrefs: AppPrefs(fileURL: root.appendingPathComponent("action-app-prefs.json")), permissionStore: permissions)
            runtime.loadWidgets()
            let task = try XCTUnwrap(runtime.performRun(action: NodeAction(type: "run",
                command: ["/bin/sh", "-c", "/usr/bin/touch started; /bin/sleep 0.3; /usr/bin/touch late"], thenRefresh: true), widgetID: id))
            let started = fixture.appendingPathComponent("started")
            if waitForStart {
                let deadline = Date().addingTimeInterval(5)
                while !FileManager.default.fileExists(atPath: started.path), Date() < deadline {
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
                XCTAssertTrue(FileManager.default.fileExists(atPath: started.path))
            }
            runtime.revokePermissions(widgetID: id)
            await task.value
            if !waitForStart { XCTAssertFalse(FileManager.default.fileExists(atPath: started.path)) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.appendingPathComponent("late").path))
            XCTAssertEqual(permissions.status(for: manifest), .pending)
        }
    }
}
