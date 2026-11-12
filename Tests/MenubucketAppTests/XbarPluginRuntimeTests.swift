import AppKit
import XCTest
import MenubucketCore
@testable import MenubucketApp

/// A real plugin file installed, allowed and refreshed through the runtime.
@MainActor
final class XbarPluginRuntimeTests: XCTestCase {
    func testPluginRendersRunsItselfAndCannotRunUndeclaredCommands() async throws {
        guard let home = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"],
              home.contains("barshelf-quality-home-"),
              WidgetRuntime.applicationSupportDirectory.resolvingSymlinksInPath().path.hasPrefix(
                URL(fileURLWithPath: home).resolvingSymlinksInPath().path + "/") else {
            throw XCTSkip("requires a disposable barshelf-quality-home-* Foundation home")
        }
        _ = NSApplication.shared
        let root = WidgetRuntime.applicationSupportDirectory
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("xbar-src-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: source) }
        let name = "probe\(Int.random(in: 1000...9999)).1m.sh"
        let plugin = source.appendingPathComponent(name)
        try Data("""
        #!/bin/sh
        if [ "$1" = mark ]; then echo "$BARSHELF $OS_APPEARANCE" > "$(dirname "$0")/marked"; exit 0; fi
        echo "Probe 42 | sfimage=bolt.fill"
        echo "---"
        echo "Mark | bash='$0' param1=mark terminal=false"
        echo "Elsewhere | bash=/usr/bin/touch param1=/tmp/barshelf-xbar-should-not-exist"
        """.utf8).write(to: plugin)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: plugin.path)

        let session = try HeadlessInstaller.fetchSession(pluginFile: plugin)
        defer { session.cleanup() }
        let candidate = try XCTUnwrap(session.candidates.first)
        let installed = try HeadlessInstaller.install(candidate, into: root.appendingPathComponent("widgets"), hostVersion: nil)
        defer { try? FileManager.default.removeItem(at: installed) }
        let id = candidate.manifest.id

        let permissions = PermissionStore(fileURL: root.appendingPathComponent("xbar-permissions-\(id).json"))
        permissions.approve(candidate.manifest)
        let runtime = WidgetRuntime(
            appPrefs: AppPrefs(fileURL: root.appendingPathComponent("xbar-app-prefs.json")),
            permissionStore: permissions
        )
        runtime.loadWidgets()
        runtime.refresh(widgetID: id, manual: true)
        let deadline = Date().addingTimeInterval(10)
        while runtime.snapshots[id]?.statusLabel == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let snapshot = try XCTUnwrap(runtime.snapshots[id])
        XCTAssertNil(snapshot.error)
        XCTAssertEqual(snapshot.statusLabel, "Probe 42")
        XCTAssertEqual(snapshot.statusIcon, "bolt.fill")

        let buttons = (snapshot.viewTree?.children ?? []).filter { $0.type == "button" }
        let mark = try XCTUnwrap(buttons.first { $0.title == "Mark" }?.action)
        XCTAssertEqual(mark.command, ["./" + name, "mark"], "$0 is rewritten to the declared command")
        let task = try XCTUnwrap(runtime.performRun(action: mark, widgetID: id))
        await task.value
        let marked = try String(contentsOf: installed.appendingPathComponent("marked"), encoding: .utf8)
        XCTAssertTrue(marked.hasPrefix("1 "), marked)
        XCTAssertTrue(marked.contains("Light") || marked.contains("Dark"), marked)

        let elsewhere = try XCTUnwrap(buttons.first { $0.title == "Elsewhere" }?.action)
        XCTAssertNil(runtime.performRun(action: elsewhere, widgetID: id), "an undeclared command stays blocked")
        XCTAssertFalse(FileManager.default.fileExists(atPath: "/tmp/barshelf-xbar-should-not-exist"))
    }
}
