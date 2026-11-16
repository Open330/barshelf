import AppKit
import Combine
import XCTest
import MenubucketCore
@testable import MenubucketApp

/// A stand-in for the runtime: answers what the coordinator asks about a
/// widget and records, in order, everything it sets off.
@MainActor
private final class StubHost: NativeRefreshCoordinatorHost {
    var widgets: [String: LoadedWidget] = [:]
    var disabled: Set<String> = []
    var status: PermissionStore.Status = .approved
    private(set) var events: [String] = []
    var onRefreshAgain: () -> Void = {}

    func isDisabled(_ widgetID: String) -> Bool { disabled.contains(widgetID) }
    func permissionStatus(for manifest: Manifest) -> PermissionStore.Status { status }
    func loadedWidget(_ widgetID: String) -> LoadedWidget? { widgets[widgetID] }
    func forgetRefreshStart(widgetID: String) { events.append("forgetStart:\(widgetID)") }
    func refreshStoppedLoading(widgetID: String) { events.append("stoppedLoading:\(widgetID)") }
    func rerunRefresh(_ widget: LoadedWidget) { events.append("rerun:\(widget.id)") }

    func refreshAgain(widgetID: String) {
        events.append("again:\(widgetID)")
        onRefreshAgain()
    }
}

@MainActor
final class NativeRefreshCoordinatorTests: XCTestCase {
    private var host: StubHost!
    /// What the coordinator put off to a later turn; the test runs it.
    private var deferred: [@MainActor @Sendable () -> Void] = []
    private var coordinator: NativeRefreshCoordinator!

    override func setUp() async throws {
        host = StubHost()
        host.widgets = ["w": widget("w"), "other": widget("other")]
        deferred = []
        coordinator = NativeRefreshCoordinator(runLater: { [unowned self] work in
            self.deferred.append(work)
        })
        coordinator.host = host
    }

    private func widget(_ id: String) -> LoadedWidget {
        LoadedWidget(
            manifest: Manifest(schemaVersion: 1, id: id, name: id,
                               entry: .init(kind: "workflow", main: "workflow.json")),
            directory: URL(fileURLWithPath: "/nonexistent/\(id)")
        )
    }

    private func runDeferred() {
        let work = deferred
        deferred = []
        for item in work { item() }
    }

    /// A refresh's task as the runtime keeps it: here it does nothing.
    private func idleTask() -> Task<Void, Never> { Task {} }

    // MARK: - In flight

    func testANativeRefreshIsInFlightFromItsStartToItsEnd() {
        XCTAssertFalse(coordinator.isInFlight("w"))
        let token = coordinator.begin("w")
        XCTAssertTrue(coordinator.isInFlight("w"))
        XCTAssertTrue(coordinator.isCurrent("w", token: token))
        XCTAssertFalse(coordinator.isInFlight("other"))

        XCTAssertTrue(coordinator.finish("w", token: token))
        XCTAssertFalse(coordinator.isInFlight("w"))
        XCTAssertFalse(coordinator.isCurrent("w", token: token))
        XCTAssertTrue(host.events.isEmpty)
        XCTAssertTrue(deferred.isEmpty)
    }

    func testAnIdleWidgetJoinsNothingAndQueuesNoRerun() {
        XCTAssertFalse(coordinator.joinsRunningRefresh("w", manual: true))
        XCTAssertFalse(coordinator.joinsRunningRefresh("w", manual: false))
        // Nothing waited: the refresh that runs next ends without a rerun.
        let token = coordinator.begin("w")
        XCTAssertTrue(coordinator.finish("w", token: token))
        XCTAssertTrue(deferred.isEmpty)
    }

    func testAnAutomaticRequestDuringARefreshIsDropped() {
        let token = coordinator.begin("w")
        XCTAssertTrue(coordinator.joinsRunningRefresh("w", manual: false))
        XCTAssertTrue(coordinator.finish("w", token: token))
        XCTAssertTrue(deferred.isEmpty)
        XCTAssertTrue(host.events.isEmpty)
    }

    func testManualRequestsDuringARefreshRunOnceMoreOnALaterTurn() {
        let token = coordinator.begin("w")
        XCTAssertTrue(coordinator.joinsRunningRefresh("w", manual: true))
        XCTAssertTrue(coordinator.joinsRunningRefresh("w", manual: true))
        XCTAssertTrue(host.events.isEmpty, "not while the refresh runs")

        XCTAssertTrue(coordinator.finish("w", token: token))
        XCTAssertTrue(host.events.isEmpty, "not in the turn the refresh ends in")
        XCTAssertEqual(deferred.count, 1)

        runDeferred()
        XCTAssertEqual(host.events, ["again:w"])

        // The request was used up: the next end runs nothing more.
        let next = coordinator.begin("w")
        XCTAssertTrue(coordinator.finish("w", token: next))
        XCTAssertTrue(deferred.isEmpty)
    }

    func testAWaitingRequestBelongsToItsOwnWidget() {
        let token = coordinator.begin("w")
        let other = coordinator.begin("other")
        XCTAssertTrue(coordinator.joinsRunningRefresh("w", manual: true))
        XCTAssertTrue(coordinator.finish("other", token: other))
        XCTAssertTrue(deferred.isEmpty)
        XCTAssertTrue(coordinator.finish("w", token: token))
        runDeferred()
        XCTAssertEqual(host.events, ["again:w"])
    }

    func testAScriptLoadSharesTheInFlightSet() {
        coordinator.markInFlight("w")
        XCTAssertTrue(coordinator.isInFlight("w"))
        XCTAssertTrue(coordinator.joinsRunningRefresh("w", manual: true))
        coordinator.endInFlight("w")
        XCTAssertFalse(coordinator.isInFlight("w"))
        runDeferred()
        XCTAssertEqual(host.events, ["again:w"])
    }

    func testEndingARefreshThatNobodyWaitedForRunsNothing() {
        coordinator.markInFlight("w")
        coordinator.endInFlight("w")
        coordinator.endInFlight("w")
        XCTAssertTrue(deferred.isEmpty)
    }

    func testAStoppedWidgetDropsItsWaitingRequest() {
        coordinator.markInFlight("w")
        XCTAssertTrue(coordinator.joinsRunningRefresh("w", manual: true))
        coordinator.endWithoutRerun("w")
        XCTAssertFalse(coordinator.isInFlight("w"))
        XCTAssertTrue(deferred.isEmpty)

        // Nor does it come back with the widget's next refresh.
        coordinator.markInFlight("w")
        coordinator.endInFlight("w")
        XCTAssertTrue(deferred.isEmpty)
    }

    /// A rescan cancelled the script load a manual request waited for. The
    /// request used to stay behind and fire after some later refresh.
    func testAReleasedRefreshRunsItsWaitingRequestWhenTheWidgetIsStillThere() {
        coordinator.markInFlight("w")
        coordinator.markInFlight("other")
        XCTAssertTrue(coordinator.joinsRunningRefresh("w", manual: true))
        coordinator.releaseInFlight(["w"], live: ["w", "other"])
        XCTAssertFalse(coordinator.isInFlight("w"))
        XCTAssertTrue(coordinator.isInFlight("other"))
        XCTAssertEqual(deferred.count, 1, "the request runs now: what it waited for will never end")

        // And only once: nothing is left to fire after the next refresh.
        coordinator.markInFlight("w")
        coordinator.endInFlight("w")
        XCTAssertEqual(deferred.count, 1)
    }

    func testAReleasedRefreshOfAWidgetThatIsGoneDropsItsWaitingRequest() {
        coordinator.markInFlight("w")
        XCTAssertTrue(coordinator.joinsRunningRefresh("w", manual: true))
        coordinator.releaseInFlight(["w"], live: [])
        XCTAssertFalse(coordinator.isInFlight("w"))
        XCTAssertTrue(deferred.isEmpty)

        // A widget installed later under the same id does not inherit it.
        coordinator.markInFlight("w")
        coordinator.endInFlight("w")
        XCTAssertTrue(deferred.isEmpty)
    }

    func testForgettingWidgetsThatAreGoneDropsTheirWaitingRequests() {
        coordinator.markInFlight("w")
        XCTAssertTrue(coordinator.joinsRunningRefresh("w", manual: true))
        coordinator.forgetInFlight(notIn: [])
        coordinator.markInFlight("w")
        coordinator.endInFlight("w")
        XCTAssertTrue(deferred.isEmpty, "a request for a removed widget does not outlive it")
    }

    func testForgettingWidgetsThatAreGoneKeepsTheOthersInFlight() {
        coordinator.markInFlight("w")
        coordinator.markInFlight("other")
        coordinator.forgetInFlight(notIn: ["other"])
        XCTAssertFalse(coordinator.isInFlight("w"))
        XCTAssertTrue(coordinator.isInFlight("other"))
    }

    func testARerunPutOffPastTheCoordinatorsLifeRunsNothing() {
        coordinator.markInFlight("w")
        XCTAssertTrue(coordinator.joinsRunningRefresh("w", manual: true))
        coordinator.endInFlight("w")
        coordinator = nil
        runDeferred()
        XCTAssertTrue(host.events.isEmpty)
    }

    func testTheShippedDeferralIsALaterMainQueueTurn() async {
        let shipped = NativeRefreshCoordinator()
        shipped.host = host
        let ran = expectation(description: "the waiting refresh runs")
        host.onRefreshAgain = { ran.fulfill() }
        shipped.markInFlight("w")
        XCTAssertTrue(shipped.joinsRunningRefresh("w", manual: true))
        shipped.endInFlight("w")
        XCTAssertTrue(host.events.isEmpty, "not in the same turn")
        await fulfillment(of: [ran], timeout: 10)
        XCTAssertEqual(host.events, ["again:w"])
    }

    // MARK: - Whether a result still counts

    func testAResultOfAStoppedRefreshIsDropped() {
        let token = coordinator.begin("w")
        coordinator.cancel("w")
        coordinator.endWithoutRerun("w")
        XCTAssertFalse(coordinator.isCurrent("w", token: token))
        XCTAssertFalse(coordinator.finish("w", token: token))
        XCTAssertTrue(host.events.isEmpty, "dropped without a word to the host")
        XCTAssertTrue(deferred.isEmpty)
    }

    func testAStaleResultCannotEndTheRefreshThatReplacedIt() {
        let old = coordinator.begin("w")
        let oldTask = idleTask()
        coordinator.track(oldTask, for: "w", token: old)
        coordinator.cancel("w")
        coordinator.endWithoutRerun("w")

        let replacement = coordinator.begin("w")
        let replacementTask = idleTask()
        coordinator.track(replacementTask, for: "w", token: replacement)
        XCTAssertTrue(coordinator.joinsRunningRefresh("w", manual: true))

        XCTAssertFalse(coordinator.finish("w", token: old))
        XCTAssertTrue(coordinator.isInFlight("w"), "the replacement is still running")
        XCTAssertTrue(coordinator.isCurrent("w", token: replacement))
        XCTAssertNotNil(coordinator.task(for: "w"), "the replacement's task is still tracked")
        XCTAssertFalse(replacementTask.isCancelled)
        XCTAssertTrue(deferred.isEmpty, "the waiting request waits for the replacement")
        XCTAssertTrue(host.events.isEmpty)

        XCTAssertTrue(coordinator.finish("w", token: replacement))
        XCTAssertFalse(coordinator.isInFlight("w"))
        XCTAssertNil(coordinator.task(for: "w"))
        XCTAssertEqual(deferred.count, 1)
    }

    func testAResultCountsOnlyOnce() {
        let token = coordinator.begin("w")
        XCTAssertTrue(coordinator.finish("w", token: token))
        XCTAssertFalse(coordinator.finish("w", token: token))
    }

    func testAFinishedRefreshForgetsItsTask() {
        let token = coordinator.begin("w")
        let task = idleTask()
        coordinator.track(task, for: "w", token: token)
        XCTAssertNotNil(coordinator.task(for: "w"))
        XCTAssertTrue(coordinator.finish("w", token: token))
        XCTAssertNil(coordinator.task(for: "w"))
        XCTAssertFalse(task.isCancelled)
    }

    // MARK: - A configuration that changed under a refresh

    func testAResultUnderAnOldConfigurationIsDroppedAndTheRefreshRunAgain() {
        let token = coordinator.begin("w")
        let task = idleTask()
        coordinator.track(task, for: "w", token: token)
        coordinator.reload(keeping: ["w", "other"], changed: ["w"])
        XCTAssertTrue(task.isCancelled)
        XCTAssertNil(coordinator.task(for: "w"))
        XCTAssertFalse(coordinator.isCurrent("w", token: token))
        XCTAssertTrue(coordinator.isInFlight("w"), "until the cancelled refresh ends")

        XCTAssertFalse(coordinator.finish("w", token: token))
        XCTAssertFalse(coordinator.isInFlight("w"))
        XCTAssertEqual(host.events, ["forgetStart:w", "stoppedLoading:w", "rerun:w"])
        XCTAssertTrue(deferred.isEmpty)
    }

    func testTheRerunIsOfTheWidgetAsItIsLoadedNow() {
        let token = coordinator.begin("w")
        coordinator.reload(keeping: ["w"], changed: ["w"])
        host.widgets["w"] = nil
        XCTAssertFalse(coordinator.finish("w", token: token))
        XCTAssertEqual(host.events, ["forgetStart:w"], "a widget that is gone is not run again")
        XCTAssertFalse(coordinator.isInFlight("w"))
    }

    func testADisabledWidgetIsNotRunAgain() {
        let token = coordinator.begin("w")
        coordinator.reload(keeping: ["w"], changed: ["w"])
        host.disabled = ["w"]
        XCTAssertFalse(coordinator.finish("w", token: token))
        XCTAssertEqual(host.events, ["forgetStart:w"])
    }

    func testARequestThatWaitedForAnOutdatedRefreshStillRuns() {
        let token = coordinator.begin("w")
        XCTAssertTrue(coordinator.joinsRunningRefresh("w", manual: true))
        coordinator.reload(keeping: ["w"], changed: ["w"])
        XCTAssertFalse(coordinator.finish("w", token: token))
        XCTAssertEqual(host.events, ["forgetStart:w", "stoppedLoading:w", "rerun:w"])
        runDeferred()
        XCTAssertEqual(host.events.last, "again:w")
    }

    func testARescanLeavesAnUnchangedWidgetsRefreshAlone() {
        let token = coordinator.begin("w")
        let task = idleTask()
        coordinator.track(task, for: "w", token: token)
        coordinator.reload(keeping: ["w", "other"], changed: ["other"])
        XCTAssertFalse(task.isCancelled)
        XCTAssertNotNil(coordinator.task(for: "w"))
        XCTAssertTrue(coordinator.isCurrent("w", token: token))
        XCTAssertTrue(coordinator.finish("w", token: token))
        XCTAssertTrue(host.events.isEmpty)
    }

    func testARescanCancelsARemovedWidgetsRefreshAndDropsItsResult() {
        let token = coordinator.begin("w")
        let task = idleTask()
        coordinator.track(task, for: "w", token: token)
        coordinator.reload(keeping: ["other"], changed: [])
        XCTAssertTrue(task.isCancelled)
        XCTAssertNil(coordinator.task(for: "w"))
        XCTAssertFalse(coordinator.finish("w", token: token))
        XCTAssertTrue(host.events.isEmpty, "nothing is run again for a widget that is gone")
    }

    // MARK: - Stopping

    func testCancellingStopsTheTaskAndOutdatesItsToken() {
        let token = coordinator.begin("w")
        let task = idleTask()
        coordinator.track(task, for: "w", token: token)
        let other = coordinator.begin("other")
        let otherTask = idleTask()
        coordinator.track(otherTask, for: "other", token: other)

        coordinator.cancel("w")
        XCTAssertTrue(task.isCancelled)
        XCTAssertNil(coordinator.task(for: "w"))
        XCTAssertFalse(coordinator.isCurrent("w", token: token))
        XCTAssertTrue(coordinator.isInFlight("w"), "ending it is a separate step")
        XCTAssertFalse(otherTask.isCancelled)
        XCTAssertTrue(coordinator.isCurrent("other", token: other))
    }

    func testCancellingAWidgetWithNoRefreshDoesNothing() {
        coordinator.cancel("w")
        XCTAssertNil(coordinator.task(for: "w"))
        XCTAssertTrue(host.events.isEmpty)
    }

    // MARK: - Whether a refresh may go on

    func testACurrentRefreshOfAnEnabledApprovedWidgetMayContinue() {
        let token = coordinator.begin("w")
        XCTAssertTrue(coordinator.mayContinue(widget("w"), token: token))
    }

    func testARefreshMayNotContinueOnceItsWidgetIsDisabledOrUnapproved() {
        let token = coordinator.begin("w")
        host.disabled = ["w"]
        XCTAssertFalse(coordinator.mayContinue(widget("w"), token: token))
        host.disabled = []
        host.status = .pending
        XCTAssertFalse(coordinator.mayContinue(widget("w"), token: token))
        host.status = .denied
        XCTAssertFalse(coordinator.mayContinue(widget("w"), token: token))
        host.status = .approved
        XCTAssertTrue(coordinator.mayContinue(widget("w"), token: token))
    }

    func testARefreshMayNotContinueOnceItsTokenIsOutdated() {
        let stopped = coordinator.begin("w")
        coordinator.cancel("w")
        XCTAssertFalse(coordinator.mayContinue(widget("w"), token: stopped))

        let reloaded = coordinator.begin("w")
        coordinator.reload(keeping: ["w"], changed: ["w"])
        XCTAssertFalse(coordinator.mayContinue(widget("w"), token: reloaded))

        let replaced = coordinator.begin("w")
        let replacement = coordinator.begin("w")
        XCTAssertFalse(coordinator.mayContinue(widget("w"), token: replaced))
        XCTAssertTrue(coordinator.mayContinue(widget("w"), token: replacement))
    }

    func testACancelledTaskMayNotContinue() async {
        let token = coordinator.begin("w")
        let coordinator = coordinator!
        let widget = widget("w")
        let answers = await Task { @MainActor () -> [Bool] in
            let before = coordinator.mayContinue(widget, token: token)
            withUnsafeCurrentTask { $0?.cancel() }
            return [before, coordinator.mayContinue(widget, token: token)]
        }.value
        XCTAssertEqual(answers, [true, false])
    }

    func testWithoutAHostNoRefreshMayContinueAndNothingRunsAgain() {
        coordinator.host = nil
        let token = coordinator.begin("w")
        XCTAssertFalse(coordinator.mayContinue(widget("w"), token: token))
        XCTAssertTrue(coordinator.joinsRunningRefresh("w", manual: true))
        coordinator.reload(keeping: ["w"], changed: ["w"])
        XCTAssertFalse(coordinator.finish("w", token: token))
        XCTAssertFalse(coordinator.isInFlight("w"))
        runDeferred()
        XCTAssertTrue(host.events.isEmpty)
    }
}

/// The runtime wired to its coordinator. Requires a disposable Foundation
/// home, like RefreshAgainTests: run with CFFIXED_USER_HOME set to a
/// barshelf-quality-home-* directory.
@MainActor
final class NativeRefreshCoordinatorRuntimeTests: XCTestCase {
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

    /// Polls until `condition` holds; the bound only costs time on failure.
    private func wait(_ what: String, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(15)
        while !condition() {
            guard Date() < deadline else { return XCTFail("timed out waiting for \(what)") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func lines(_ url: URL) -> Int {
        (try? String(contentsOf: url, encoding: .utf8))?.split(separator: "\n").count ?? 0
    }

    /// A workflow widget whose one source marks its start in `starts` and
    /// its end in `ends`, and whose card reads `text`.
    private func install(
        id: String, name: String, text: String, hold: String, starts: URL, ends: URL
    ) throws -> (Manifest, URL) {
        let script = "echo s >> \"$1\"; sleep \(hold); echo x >> \"$0\"; echo 1"
        let command = ["/bin/sh", "-c", script, ends.path, starts.path]
        let manifest = Manifest(schemaVersion: 1, id: id, name: name,
                                entry: .init(kind: "workflow"),
                                permissions: .init(exec: [.init(command: "/bin/sh", allowedArgs: [Array(command.dropFirst())])]))
        let folder = WidgetRuntime.userWidgetsRoot.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(manifest).write(to: folder.appendingPathComponent("widget.json"))
        let workflow: [String: Any] = [
            "schemaVersion": 1,
            "sources": ["n": ["use": "exec", "with": ["command": command]]],
            "view": ["type": "text", "text": text],
        ]
        try JSONSerialization.data(withJSONObject: workflow).write(to: folder.appendingPathComponent("workflow.json"))
        return (manifest, folder)
    }

    /// A widget reloaded with a new configuration while it refreshes: the
    /// result under the old one is never shown, and the refresh runs again
    /// under the new one without anyone asking.
    func testAResultUnderAReloadedConfigurationIsDroppedAndTheRefreshRunAgain() async throws {
        let root = try disposableRoot()
        let id = "dev.test.refresh-stale-configuration"
        let marks = FileManager.default.temporaryDirectory.appendingPathComponent("refresh-stale-\(UUID().uuidString)")
        let starts = marks.appendingPathExtension("starts")
        let ends = marks.appendingPathExtension("ends")
        let folder = WidgetRuntime.userWidgetsRoot.appendingPathComponent(id)
        try? FileManager.default.removeItem(at: folder)
        let permissionsURL = root.appendingPathComponent("refresh-stale-permissions.json")
        defer {
            try? FileManager.default.removeItem(at: starts)
            try? FileManager.default.removeItem(at: ends)
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: permissionsURL)
        }
        let (old, _) = try install(id: id, name: "Old", text: "old", hold: "0.4", starts: starts, ends: ends)
        let permissions = PermissionStore(fileURL: permissionsURL)
        permissions.approve(old)
        let runtime = WidgetRuntime(
            appPrefs: AppPrefs(fileURL: root.appendingPathComponent("refresh-stale-prefs.json")),
            permissionStore: permissions
        )
        runtime.loadWidgets()

        runtime.refresh(widgetID: id, manual: true)
        try await wait("the refresh to start") { self.lines(starts) == 1 }
        XCTAssertEqual(runtime.snapshots[id]?.isLoading, true)

        // Same command, so the approval carries; a new name and a new card.
        let (new, _) = try install(id: id, name: "New", text: "new", hold: "0", starts: starts, ends: ends)
        permissions.approve(new)
        runtime.loadWidgets()
        // What the card shows from here on, change by change.
        var shown: [String] = []
        let watching = runtime.cardModel(for: id).$snapshot.dropFirst().sink { snapshot in
            shown.append("\(snapshot.isLoading ? "loading" : "idle"):\(snapshot.viewTree?.text ?? "-")")
        }
        defer { watching.cancel() }

        try await wait("the refresh to run again under the new configuration") {
            runtime.snapshots[id]?.viewTree?.text == "new" && runtime.snapshots[id]?.isLoading == false
        }
        XCTAssertEqual(lines(starts), 2, "the outdated refresh, then one under the new configuration")
        XCTAssertNil(runtime.snapshots[id]?.error)
        // The outdated refresh ends, the new one starts and renders. The
        // dropped result must not touch the card in between.
        XCTAssertEqual(shown, ["idle:-", "loading:-", "idle:new"])
    }

    /// An automatic trigger that lands while the widget refreshes joins the
    /// refresh that is running: no second command starts.
    func testAnAutomaticRefreshDuringAnotherStartsNoSecondCommand() async throws {
        let root = try disposableRoot()
        let id = "dev.test.refresh-coalesced"
        let marks = FileManager.default.temporaryDirectory.appendingPathComponent("refresh-coalesced-\(UUID().uuidString)")
        let starts = marks.appendingPathExtension("starts")
        let ends = marks.appendingPathExtension("ends")
        let folder = WidgetRuntime.userWidgetsRoot.appendingPathComponent(id)
        try? FileManager.default.removeItem(at: folder)
        let permissionsURL = root.appendingPathComponent("refresh-coalesced-permissions.json")
        defer {
            try? FileManager.default.removeItem(at: starts)
            try? FileManager.default.removeItem(at: ends)
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: permissionsURL)
        }
        let (manifest, _) = try install(id: id, name: "Coalesced", text: "x", hold: "0.4", starts: starts, ends: ends)
        let permissions = PermissionStore(fileURL: permissionsURL)
        permissions.approve(manifest)
        let runtime = WidgetRuntime(
            appPrefs: AppPrefs(fileURL: root.appendingPathComponent("refresh-coalesced-prefs.json")),
            permissionStore: permissions
        )
        runtime.loadWidgets()

        runtime.refresh(widgetID: id, manual: true)
        try await wait("the refresh to start") { self.lines(starts) == 1 }
        runtime.refresh(widgetID: id, manual: false)
        try await wait("the refresh to finish") {
            self.lines(ends) == 1 && runtime.snapshots[id]?.isLoading == false
        }
        XCTAssertEqual(runtime.snapshots[id]?.viewTree?.text, "x", "the running refresh's result is the one shown")
        // A second command would have started while the first still ran.
        XCTAssertEqual(lines(starts), 1)
    }

    /// Removing a widget while it refreshes cancels the refresh and waits
    /// for it, instead of for the command to run its course.
    func testRemovingAWidgetStopsItsRefreshInFlight() async throws {
        let root = try disposableRoot()
        let id = "dev.test.refresh-removed-in-flight"
        let marks = FileManager.default.temporaryDirectory.appendingPathComponent("refresh-removed-\(UUID().uuidString)")
        let starts = marks.appendingPathExtension("starts")
        let ends = marks.appendingPathExtension("ends")
        let folder = WidgetRuntime.userWidgetsRoot.appendingPathComponent(id)
        try? FileManager.default.removeItem(at: folder)
        let permissionsURL = root.appendingPathComponent("refresh-removed-permissions.json")
        defer {
            try? FileManager.default.removeItem(at: starts)
            try? FileManager.default.removeItem(at: ends)
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: permissionsURL)
        }
        // Longer than the wait below: only a cancelled command ends in time.
        let (manifest, _) = try install(id: id, name: "Removed", text: "x", hold: "20", starts: starts, ends: ends)
        let permissions = PermissionStore(fileURL: permissionsURL)
        permissions.approve(manifest)
        let runtime = WidgetRuntime(
            appPrefs: AppPrefs(fileURL: root.appendingPathComponent("refresh-removed-prefs.json")),
            permissionStore: permissions
        )
        runtime.loadWidgets()

        runtime.refresh(widgetID: id, manual: true)
        try await wait("the refresh to start") { self.lines(starts) == 1 }

        let began = Date()
        try await runtime.removeWidget(id: id)
        XCTAssertLessThan(Date().timeIntervalSince(began), 10, "removal waited out the command instead of cancelling it")
        XCTAssertEqual(lines(ends), 0, "the command was cut short")
        XCTAssertFalse(runtime.widgets.contains { $0.id == id })
        XCTAssertNil(runtime.snapshots[id])
    }
}
