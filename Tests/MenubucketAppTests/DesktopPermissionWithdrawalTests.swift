import AppKit
import XCTest
import MenubucketCore
@testable import MenubucketApp

@MainActor
final class DesktopPermissionWithdrawalTests: XCTestCase {
    func testDesktopRefreshPublishesSourceFailureWithAndWithoutCachedContent() async throws {
        guard let home = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"],
              home.contains("barshelf-quality-home-"),
              WidgetRuntime.applicationSupportDirectory.resolvingSymlinksInPath().path.hasPrefix(
                URL(fileURLWithPath: home).resolvingSymlinksInPath().path + "/") else {
            throw XCTSkip("requires a disposable barshelf-quality-home-* Foundation home")
        }
        _ = NSApplication.shared
        let root = WidgetRuntime.applicationSupportDirectory
        for retainContent in [false, true] {
            let id = "dev.test.desktop-error-\(UUID().uuidString)"
            let fixture = root.appendingPathComponent("widgets/\(id)")
            try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: fixture) }
            let command = #"if [ -f fail ]; then printf failure >&2; exit 2; fi; printf '%s\n' '{"type":"text","text":"cached reading"}'"#
            let manifest = Manifest(schemaVersion: 1, id: id, name: "Desktop error",
                entry: .init(kind: "exec"), source: .init(command: ["/bin/sh", "-c", command], output: "viewtree"),
                permissions: .init(exec: [.init(command: "/bin/sh")]))
            try JSONEncoder().encode(manifest).write(to: fixture.appendingPathComponent("widget.json"))
            let permissions = PermissionStore(fileURL: root.appendingPathComponent("permissions-\(id).json"))
            permissions.approve(manifest)
            let container = root.appendingPathComponent("shared-\(id)")
            let publisher = SharedShelfPublisher(container: container, reload: {})
            let runtime = WidgetRuntime(appPrefs: AppPrefs(fileURL: root.appendingPathComponent("desktop-app-prefs.json")),
                permissionStore: permissions, sharedShelf: publisher)
            runtime.loadWidgets()
            if retainContent {
                try SharedShelf.requestRefresh(widgetID: id, in: container)
                publisher.takeRefreshRequests()
                let deadline = Date().addingTimeInterval(5)
                while SharedShelf.readSnapshot(widgetID: id, from: container) == nil, Date() < deadline {
                    try await Task.sleep(nanoseconds: 20_000_000)
                }
                XCTAssertEqual(SharedShelf.readSnapshot(widgetID: id, from: container)?.viewTree?.text, "cached reading")
            }
            try Data().write(to: fixture.appendingPathComponent("fail"))
            try SharedShelf.requestRefresh(widgetID: id, in: container)
            publisher.takeRefreshRequests()
            let deadline = Date().addingTimeInterval(5)
            while SharedShelf.readSnapshot(widgetID: id, from: container)?.error == nil, Date() < deadline {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            let shared = try XCTUnwrap(SharedShelf.readSnapshot(widgetID: id, from: container))
            XCTAssertNotNil(shared.error)
            XCTAssertEqual(shared.viewTree?.text, retainContent ? "cached reading" : nil)
            XCTAssertFalse(publisher.isAnswering(id))
            XCTAssertNil(SharedShelf.pendingRefreshRequests(in: container)[id])
        }
    }

    func testRevokeAndDenyWithdrawDesktopCopiesBeforeAnotherRefresh() throws {
        guard let home = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"],
              home.contains("barshelf-quality-home-"),
              WidgetRuntime.applicationSupportDirectory.resolvingSymlinksInPath().path.hasPrefix(
                URL(fileURLWithPath: home).resolvingSymlinksInPath().path + "/") else {
            throw XCTSkip("requires a disposable barshelf-quality-home-* Foundation home")
        }
        _ = NSApplication.shared
        let root = WidgetRuntime.applicationSupportDirectory
        for deny in [false, true] {
            let id = "dev.test.desktop-withdraw-\(deny)"
            let fixture = root.appendingPathComponent("widgets/\(id)")
            try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: fixture) }
            let manifest = Manifest(schemaVersion: 1, id: id, name: "Desktop withdrawal",
                entry: .init(kind: "workflow", main: "workflow.json"), permissions: .init(storage: .init()))
            try JSONEncoder().encode(manifest).write(to: fixture.appendingPathComponent("widget.json"))
            try Data(#"{"schemaVersion":1,"sources":{},"view":{"type":"text","text":"reading"}}"#.utf8)
                .write(to: fixture.appendingPathComponent("workflow.json"))
            let permissions = PermissionStore(fileURL: root.appendingPathComponent("desktop-permissions-\(deny).json"))
            permissions.approve(manifest)
            let container = root.appendingPathComponent("test-shared-\(deny)")
            var reloads = 0
            let publisher = SharedShelfPublisher(container: container, reload: { reloads += 1 })
            let runtime = WidgetRuntime(appPrefs: AppPrefs(fileURL: root.appendingPathComponent("desktop-app-prefs.json")),
                permissionStore: permissions, sharedShelf: publisher)
            runtime.loadWidgets()
            XCTAssertTrue(SharedShelf.readIndex(from: container)?.entries.contains { $0.id == id } == true)
            publisher.publish(.init(widgetID: id, name: "Private", viewTree: UINode(type: "text", text: "old reading")))
            XCTAssertNotNil(SharedShelf.readSnapshot(widgetID: id, from: container))
            try SharedShelf.requestRefresh(widgetID: id, in: container)
            let images = try XCTUnwrap(SharedShelf.imagesDirectory(for: id, in: container))
            try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
            try Data("cached thumbnail".utf8).write(to: images.appendingPathComponent("old.png"))
            if deny { runtime.denyPermissions(widgetID: id) }
            else { runtime.revokePermissions(widgetID: id) }
            XCTAssertFalse(SharedShelf.readIndex(from: container)?.entries.contains { $0.id == id } == true)
            XCTAssertNil(SharedShelf.readSnapshot(widgetID: id, from: container))
            XCTAssertFalse(FileManager.default.fileExists(atPath: images.path))
            XCTAssertNil(SharedShelf.pendingRefreshRequests(in: container)[id])
            XCTAssertGreaterThan(reloads, 0)
        }
    }
}
