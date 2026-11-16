import AppKit
import XCTest
import MenubucketCore
@testable import MenubucketApp

/// A stand-in for the runtime: says whether a change refreshes, and records
/// what it was asked and told.
@MainActor
private final class StubHost: WorkflowWatchRegistryHost {
    var mayRefresh = true
    private(set) var asked: [String] = []
    private(set) var refreshed: [String] = []

    func workflowWatchMayRefresh(widgetID: String) -> Bool {
        asked.append(widgetID)
        return mayRefresh
    }

    func refreshForWorkflowWatch(widgetID: String) {
        refreshed.append(widgetID)
    }
}

/// A watch that never looks at the disk: the test fires its change.
private final class FakeWatch: WorkflowWatch {
    let path: String
    let onChange: () -> Void
    private(set) var cancels = 0

    init(path: String, onChange: @escaping () -> Void) {
        self.path = path
        self.onChange = onChange
    }

    func cancel() { cancels += 1 }
}

private struct WatchUnavailable: Error {}

@MainActor
final class WorkflowWatchRegistryTests: XCTestCase {
    private var sandbox: URL!
    private var host: StubHost!
    private var made: [FakeWatch] = []
    private var failNextWatch = false
    private var registry: WorkflowWatchRegistry!

    override func setUp() async throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("workflow-watch-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        host = StubHost()
        made = []
        failNextWatch = false
        registry = WorkflowWatchRegistry(makeWatch: { [unowned self] directory, onChange in
            if self.failNextWatch {
                self.failNextWatch = false
                throw WatchUnavailable()
            }
            let watch = FakeWatch(path: directory.path, onChange: onChange)
            self.made.append(watch)
            return watch
        })
        registry.host = host
    }

    override func tearDown() async throws {
        registry = nil
        made = []
        try? FileManager.default.removeItem(at: sandbox)
    }

    private func directory(_ name: String) throws -> FileSource.AuthorizedDirectory {
        let folder = sandbox.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return try FileSource.openAuthorizedDirectory(path: folder.path, readPaths: [sandbox.path])
    }

    func testAChangeInAWatchedDirectoryRefreshesItsWidget() throws {
        registry.watch(try directory("a"), widgetID: "w")
        XCTAssertEqual(made.count, 1)
        XCTAssertTrue(host.refreshed.isEmpty, "watching alone refreshes nothing")

        made[0].onChange()
        XCTAssertEqual(host.asked, ["w"])
        XCTAssertEqual(host.refreshed, ["w"])

        made[0].onChange()
        XCTAssertEqual(host.refreshed, ["w", "w"], "every change asks again")
    }

    func testAChangeTheHostTurnsAwayRefreshesNothing() throws {
        host.mayRefresh = false
        registry.watch(try directory("a"), widgetID: "w")
        made[0].onChange()
        XCTAssertEqual(host.asked, ["w"])
        XCTAssertTrue(host.refreshed.isEmpty)

        // Asked at the time of each change, not once when the watch started.
        host.mayRefresh = true
        made[0].onChange()
        XCTAssertEqual(host.refreshed, ["w"])
    }

    func testTheWatchIsOnTheDirectoryItWasHanded() throws {
        let handed = try directory("a")
        registry.watch(handed, widgetID: "w")
        XCTAssertEqual(made.map(\.path), [handed.path])
    }

    func testWatchingAgainCancelsTheWidgetsPreviousWatch() throws {
        registry.watch(try directory("a"), widgetID: "w")
        registry.watch(try directory("b"), widgetID: "w")
        XCTAssertEqual(made.count, 2)
        XCTAssertEqual(made[0].cancels, 1)
        XCTAssertEqual(made[1].cancels, 0)

        made[1].onChange()
        XCTAssertEqual(host.refreshed, ["w"])
    }

    /// A watch used to stay open until the widget's next listing replaced
    /// it, which never came for a widget that was stopped or removed.
    func testCancellingStopsThoseWidgetsWatchesOnce() throws {
        registry.watch(try directory("a"), widgetID: "w")
        registry.watch(try directory("b"), widgetID: "other")
        registry.cancel(widgetIDs: ["w", "never-watched"])
        XCTAssertEqual(made[0].cancels, 1)
        XCTAssertEqual(made[1].cancels, 0)

        // Nothing is left to cancel a second time, and watching again works.
        registry.cancel(widgetIDs: ["w"])
        XCTAssertEqual(made[0].cancels, 1)
        registry.watch(try directory("a"), widgetID: "w")
        XCTAssertEqual(made.count, 3)
        XCTAssertEqual(made[0].cancels, 1)
    }

    func testRetainingStopsTheWatchesOfWidgetsThatAreGone() throws {
        registry.watch(try directory("a"), widgetID: "gone")
        registry.watch(try directory("b"), widgetID: "live")
        registry.retain(widgetIDs: ["live"])
        XCTAssertEqual(made[0].cancels, 1)
        XCTAssertEqual(made[1].cancels, 0)
    }

    func testEachWidgetHasItsOwnWatch() throws {
        registry.watch(try directory("a"), widgetID: "one")
        registry.watch(try directory("b"), widgetID: "two")
        XCTAssertEqual(made.map(\.cancels), [0, 0], "another widget's watch is left alone")

        made[1].onChange()
        made[0].onChange()
        XCTAssertEqual(host.refreshed, ["two", "one"])
    }

    func testAWatchThatCannotStartLeavesTheOldOneCancelled() throws {
        registry.watch(try directory("a"), widgetID: "w")
        failNextWatch = true
        registry.watch(try directory("b"), widgetID: "w")
        XCTAssertEqual(made.count, 1)
        XCTAssertEqual(made[0].cancels, 1)

        // The next listing arms a watch again.
        registry.watch(try directory("b"), widgetID: "w")
        XCTAssertEqual(made.count, 2)
        made[1].onChange()
        XCTAssertEqual(host.refreshed, ["w"])
    }

    func testWithoutAHostAChangeRefreshesNothing() throws {
        registry.host = nil
        registry.watch(try directory("a"), widgetID: "w")
        made[0].onChange()
        XCTAssertTrue(host.asked.isEmpty)
        XCTAssertTrue(host.refreshed.isEmpty)
    }

    func testAChangeAfterTheRegistryIsGoneRefreshesNothing() throws {
        registry.watch(try directory("a"), widgetID: "w")
        let watch = made[0]
        registry = nil
        watch.onChange()
        XCTAssertTrue(host.asked.isEmpty)
        XCTAssertTrue(host.refreshed.isEmpty)
    }

    func testTheShippedWatchIsADirectoryWatcherOnTheDirectory() throws {
        let shipped = WorkflowWatchRegistry()
        shipped.host = host
        // Starts a real watch; nothing changes in the directory, so the
        // host hears nothing.
        shipped.watch(try directory("a"), widgetID: "w")
        XCTAssertTrue(host.refreshed.isEmpty)
    }
}

/// The runtime wired to its registry. Requires a disposable Foundation
/// home, like RefreshAgainTests: run with CFFIXED_USER_HOME set to a
/// barshelf-quality-home-* directory.
@MainActor
final class WorkflowWatchRuntimeTests: XCTestCase {
    /// A workflow that lists a watched folder is refreshed when the folder
    /// changes while its card is on the open shelf.
    func testAChangeInAWatchedFolderRefreshesTheVisibleWidget() async throws {
        guard let home = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"],
              home.contains("barshelf-quality-home-"),
              WidgetRuntime.applicationSupportDirectory.resolvingSymlinksInPath().path.hasPrefix(
                URL(fileURLWithPath: home).resolvingSymlinksInPath().path + "/") else {
            throw XCTSkip("run with CFFIXED_USER_HOME set to a disposable barshelf-quality-home-* directory")
        }
        _ = NSApplication.shared
        let root = WidgetRuntime.applicationSupportDirectory
        let watched = FileManager.default.temporaryDirectory
            .appendingPathComponent("workflow-watch-runtime-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: watched, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: watched) }

        let manifest = Manifest(schemaVersion: 1, id: "dev.test.workflow-watch", name: "Watched folder",
                                entry: .init(kind: "workflow", main: "workflow.json"),
                                permissions: .init(readPaths: [watched.path]))
        let folder = WidgetRuntime.userWidgetsRoot.appendingPathComponent(manifest.id)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try JSONEncoder().encode(manifest).write(to: folder.appendingPathComponent("widget.json"))
        let workflow: [String: Any] = [
            "schemaVersion": 1,
            "sources": ["d": ["use": "fs.directory", "with": ["path": watched.path, "watch": true]]],
            "view": ["type": "text", "text": "x"],
        ]
        try JSONSerialization.data(withJSONObject: workflow).write(to: folder.appendingPathComponent("workflow.json"))

        let permissionsURL = root.appendingPathComponent("workflow-watch-permissions.json")
        defer { try? FileManager.default.removeItem(at: permissionsURL) }
        let runtime = WidgetRuntime(
            appPrefs: AppPrefs(fileURL: root.appendingPathComponent("workflow-watch-prefs.json")),
            permissionStore: PermissionStore(fileURL: permissionsURL)
        )
        runtime.loadWidgets()
        /// Polls until `condition` holds; the bound only costs time on failure.
        func wait(_ what: String, _ condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(15)
            while !condition() {
                guard Date() < deadline else { return XCTFail("timed out waiting for \(what)") }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        func rendered() -> Date? {
            let snapshot = runtime.snapshots[manifest.id]
            return snapshot?.isLoading == true ? nil : snapshot?.updatedAt
        }

        runtime.popupOpened()
        runtime.setVisibleWidgetIDs([manifest.id])
        runtime.approvePermissions(widgetID: manifest.id)  // starts the refresh that arms the watch
        try await wait("the first refresh to finish") { rendered() != nil }
        let first = try XCTUnwrap(rendered())
        XCTAssertNil(runtime.snapshots[manifest.id]?.error)

        try Data("x".utf8).write(to: watched.appendingPathComponent("new-file"))
        try await wait("the watch to refresh the widget") { rendered().map { $0 > first } ?? false }
    }
}
