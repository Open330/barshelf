import AppKit
import XCTest
import MenubucketCore
@testable import MenubucketApp

/// A widget that cannot run at all — an entry kind this build does not know,
/// or a command its `permissions.exec` does not cover — fails the same way on
/// every attempt. Requires a disposable Foundation home, like
/// WidgetRemovalPurgeTests: run with CFFIXED_USER_HOME.
@MainActor
final class RefusedRefreshBackoffTests: XCTestCase {
    func testAnUncoveredCommandBacksOffAutomaticRefreshes() throws {
        try assertBacksOff(
            name: "uncovered-command",
            broken: { id in
                Manifest(schemaVersion: 1, id: id, name: "Uncovered",
                         entry: .init(kind: "exec"),
                         source: .init(command: ["/usr/bin/true"]),
                         permissions: .init(exec: [.init(command: "/usr/bin/false")]))
            },
            expectedError: "source.command is not covered by permissions.exec allowlist",
            auditsEachAttempt: true
        )
    }

    func testAnUnsupportedEntryKindBacksOffAutomaticRefreshes() throws {
        try assertBacksOff(
            name: "unsupported-kind",
            broken: { id in
                Manifest(schemaVersion: 1, id: id, name: "Unsupported",
                         entry: .init(kind: "wasm"),
                         permissions: .init(exec: [.init(command: "/usr/bin/false")]))
            },
            expectedError: "entry.kind \"wasm\" is not supported in M2 (only \"exec\", \"script\", \"workflow\")",
            auditsEachAttempt: false
        )
    }

    private func assertBacksOff(
        name: String, broken: (String) -> Manifest, expectedError: String, auditsEachAttempt: Bool,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let root = try disposableRoot()
        let id = "dev.test.refused-\(name)-\(UUID().uuidString.lowercased())"
        let folder = root.appendingPathComponent("widgets/\(id)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let manifestURL = folder.appendingPathComponent("widget.json")
        let manifest = broken(id)
        try JSONEncoder().encode(manifest).write(to: manifestURL)
        let permissionsFile = root.appendingPathComponent("permissions-\(id).json")
        let prefsFile = root.appendingPathComponent("prefs-\(id).json")
        defer {
            try? FileManager.default.removeItem(at: permissionsFile)
            try? FileManager.default.removeItem(at: prefsFile)
        }
        let permissions = PermissionStore(fileURL: permissionsFile)
        permissions.approve(manifest)
        let stats = RefreshStatsStore()
        let runtime = WidgetRuntime(appPrefs: AppPrefs(fileURL: prefsFile),
                                    refreshStatsStore: stats, permissionStore: permissions)
        runtime.loadWidgets()
        func failures() -> Int { stats.stats(for: id)?.failureCount ?? 0 }
        func blocked() -> Int {
            let text = (try? String(contentsOf: AuditLog.defaultFileURL(), encoding: .utf8)) ?? ""
            return text.split(separator: "\n").filter { $0.contains(id) && $0.contains("exec.blocked") }.count
        }
        XCTAssertTrue(runtime.scheduler.allowsAutomaticRefresh(widgetID: id), file: file, line: line)

        // What a timer tick does.
        runtime.refresh(widgetID: id, manual: false)
        XCTAssertEqual(runtime.snapshots[id]?.error, expectedError, file: file, line: line)
        XCTAssertEqual(failures(), 1, file: file, line: line)
        XCTAssertFalse(runtime.scheduler.allowsAutomaticRefresh(widgetID: id),
                       "a refresh that can never run backs off like one that failed", file: file, line: line)
        for _ in 0..<5 { runtime.refresh(widgetID: id, manual: false) }
        XCTAssertEqual(failures(), 1, "ticks inside the backoff window do not try again", file: file, line: line)
        if auditsEachAttempt {
            XCTAssertEqual(blocked(), 1, "and do not write the audit entry again", file: file, line: line)
        }

        // Asking for it by hand is never held back.
        runtime.refresh(widgetID: id, manual: true)
        XCTAssertEqual(failures(), 2, file: file, line: line)

        // A rescan that changed nothing keeps the backoff.
        runtime.loadWidgets()
        XCTAssertFalse(runtime.scheduler.allowsAutomaticRefresh(widgetID: id),
                       "a rescan that changed nothing keeps the backoff", file: file, line: line)

        // A corrected manifest starts over: its first tick is not held to
        // the broken one's backoff.
        let fixed = Manifest(schemaVersion: 1, id: id, name: "Fixed",
                             entry: .init(kind: "exec"),
                             source: .init(command: ["/usr/bin/false"]),
                             permissions: .init(exec: [.init(command: "/usr/bin/false")]))
        try JSONEncoder().encode(fixed).write(to: manifestURL)
        runtime.loadWidgets()
        XCTAssertTrue(runtime.scheduler.allowsAutomaticRefresh(widgetID: id),
                      "a changed manifest is not held to the old one's backoff", file: file, line: line)
    }

    /// A workflow widget's behaviour is its `workflow.json`; fixing only
    /// that file used to leave automatic refresh held back for up to five
    /// minutes, because the rescan compared manifests alone.
    func testAFixedEntryFileIsNotHeldToTheOldOnesBackoff() throws {
        let root = try disposableRoot()
        let id = "dev.test.entry-backoff-\(UUID().uuidString.prefix(8).lowercased())"
        let directory = root.appendingPathComponent("widgets/\(id)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifest = Manifest(schemaVersion: 1, id: id, name: "Entry", entry: .init(kind: "workflow"))
        try JSONEncoder().encode(manifest).write(to: directory.appendingPathComponent("widget.json"))
        let entry = directory.appendingPathComponent("workflow.json")
        try Data("{".utf8).write(to: entry)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)], ofItemAtPath: entry.path)

        let prefsFile = root.appendingPathComponent("prefs-\(id).json")
        defer { try? FileManager.default.removeItem(at: prefsFile) }
        let runtime = WidgetRuntime(appPrefs: AppPrefs(fileURL: prefsFile))
        runtime.loadWidgets()
        runtime.scheduler.noteRefreshFailed(widgetID: id)
        XCTAssertFalse(runtime.scheduler.allowsAutomaticRefresh(widgetID: id))

        // Another file in the folder changing is not the code changing.
        try Data("x".utf8).write(to: directory.appendingPathComponent("data.json"))
        runtime.loadWidgets()
        XCTAssertFalse(runtime.scheduler.allowsAutomaticRefresh(widgetID: id),
                       "a widget writing into its own folder keeps its backoff")

        try Data("{}".utf8).write(to: entry)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_700_000_100)], ofItemAtPath: entry.path)
        runtime.loadWidgets()
        XCTAssertTrue(runtime.scheduler.allowsAutomaticRefresh(widgetID: id),
                      "a rewritten workflow.json is not held to the old one's backoff")
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
}
