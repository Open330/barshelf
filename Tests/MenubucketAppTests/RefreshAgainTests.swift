import AppKit
import XCTest
import MenubucketCore
@testable import MenubucketApp

/// Requires a disposable Foundation home, like WidgetRemovalPurgeTests:
/// run with CFFIXED_USER_HOME set to a barshelf-quality-home-* directory.
@MainActor
final class RefreshAgainTests: XCTestCase {
    /// A manual refresh asked for while one is running is not dropped: it
    /// runs once more afterwards (a vault unlock landing mid-refresh used to
    /// show only on the next timer).
    func testAManualRefreshDuringAnotherRunsOnceMore() async throws {
        guard let home = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"],
              home.contains("barshelf-quality-home-"),
              WidgetRuntime.applicationSupportDirectory.resolvingSymlinksInPath().path.hasPrefix(
                URL(fileURLWithPath: home).resolvingSymlinksInPath().path + "/") else {
            throw XCTSkip("run with CFFIXED_USER_HOME set to a disposable barshelf-quality-home-* directory")
        }
        _ = NSApplication.shared
        let root = WidgetRuntime.applicationSupportDirectory
        let counter = FileManager.default.temporaryDirectory.appendingPathComponent("refresh-again-\(UUID().uuidString)")
        let starts = counter.appendingPathExtension("starts")
        defer {
            try? FileManager.default.removeItem(at: counter)
            try? FileManager.default.removeItem(at: starts)
        }
        // Marks its start and its end, so the test waits on what happened
        // instead of on how long it usually takes.
        let script = "echo s >> \"$1\"; sleep 0.4; echo x >> \"$0\"; echo 1"
        let manifest = Manifest(schemaVersion: 1, id: "dev.test.refresh-again", name: "Refresh again",
                                entry: .init(kind: "workflow"),
                                permissions: .init(exec: [.init(command: "/bin/sh", allowedArgs: [["-c", script, counter.path, starts.path]])]))
        let folder = WidgetRuntime.userWidgetsRoot.appendingPathComponent(manifest.id)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try JSONEncoder().encode(manifest).write(to: folder.appendingPathComponent("widget.json"))
        let workflow: [String: Any] = [
            "schemaVersion": 1,
            "sources": ["n": ["use": "exec", "with": ["command": ["/bin/sh", "-c", script, counter.path, starts.path]]]],
            "view": ["type": "text", "text": "x"],
        ]
        try JSONSerialization.data(withJSONObject: workflow).write(to: folder.appendingPathComponent("workflow.json"))

        let runtime = WidgetRuntime(appPrefs: AppPrefs(fileURL: root.appendingPathComponent("refresh-again-prefs.json")))
        runtime.loadWidgets()
        func lines(_ url: URL) -> Int {
            (try? String(contentsOf: url, encoding: .utf8))?.split(separator: "\n").count ?? 0
        }
        func idle() -> Bool { runtime.snapshots[manifest.id]?.isLoading != true }
        /// Polls until `condition` holds; the bound only costs time on failure.
        func wait(_ what: String, _ condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(15)
            while !condition() {
                guard Date() < deadline else { return XCTFail("timed out waiting for \(what)") }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        }

        runtime.approvePermissions(widgetID: manifest.id)  // also starts one refresh
        try await wait("the first refresh to finish") { lines(counter) == 1 && idle() }
        let before = lines(counter)

        runtime.refresh(widgetID: manifest.id, manual: true)
        try await wait("the second refresh to start") { lines(starts) == 2 }
        runtime.refresh(widgetID: manifest.id, manual: true)  // arrives mid-run
        runtime.refresh(widgetID: manifest.id, manual: true)  // coalesces with the one above
        try await wait("the extra refresh to finish") { lines(counter) == before + 2 && idle() }
        // A wrong third run would start right after the second ended.
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(lines(starts), 3, "the running refresh, then exactly one more")
        XCTAssertEqual(lines(counter) - before, 2, "the running refresh, then exactly one more")
    }
}
