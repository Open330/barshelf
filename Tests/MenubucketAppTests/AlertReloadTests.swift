import AppKit
import XCTest
import MenubucketCore
@testable import MenubucketApp

/// Requires a disposable Foundation home, like WidgetRemovalPurgeTests:
/// run with CFFIXED_USER_HOME set to a barshelf-quality-home-* directory.
@MainActor
final class AlertReloadTests: XCTestCase {
    /// Editing only workflow.json must end alerts raised under the old one.
    func testARescanEndsPendingAlertsOfWorkflowWidgets() throws {
        guard let home = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"],
              home.contains("barshelf-quality-home-"),
              WidgetRuntime.applicationSupportDirectory.resolvingSymlinksInPath().path.hasPrefix(
                URL(fileURLWithPath: home).resolvingSymlinksInPath().path + "/") else {
            throw XCTSkip("run with CFFIXED_USER_HOME set to a disposable barshelf-quality-home-* directory")
        }
        _ = NSApplication.shared
        let root = WidgetRuntime.applicationSupportDirectory
        let manifest = Manifest(schemaVersion: 1, id: "dev.test.alert-reload", name: "Alert reload",
                                entry: .init(kind: "workflow"), permissions: .init(notifications: true))
        let folder = WidgetRuntime.userWidgetsRoot.appendingPathComponent(manifest.id)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try JSONEncoder().encode(manifest).write(to: folder.appendingPathComponent("widget.json"))
        let workflow = folder.appendingPathComponent("workflow.json")
        try Data(#"{"schemaVersion":1,"sources":{},"view":{"type":"text","text":"x"},"alerts":{"a":{"when":"${true}","title":"A"}}}"#.utf8).write(to: workflow)

        let runtime = WidgetRuntime(appPrefs: AppPrefs(fileURL: root.appendingPathComponent("alert-reload-prefs.json")))
        runtime.loadWidgets()
        let permit = runtime.alertGate.permit(manifest.id)
        try Data(#"{"schemaVersion":1,"sources":{},"view":{"type":"text","text":"x"}}"#.utf8).write(to: workflow)
        runtime.loadWidgets()
        XCTAssertFalse(runtime.alertGate.isCurrent(manifest.id, permit), "widget.json unchanged, workflow.json changed")
    }
}
