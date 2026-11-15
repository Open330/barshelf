import AppKit
import XCTest
import MenubucketCore
@testable import MenubucketApp

/// Stands in for the runtime: answers the bridge's questions from what a
/// test set, and records what the bridge reported.
@MainActor
private final class StubHost: ScriptRuntimeBridgeHost {
    enum Event: Equatable {
        case render(String, RenderParams)
        case loadComplete(String, rendered: Bool, error: String?)
        case stateChange(String, ScriptWidgetState)
    }

    var scriptTimerPolicy = ScriptTimerPolicy(pauseWhenClosed: true)
    var widgets: [String: LoadedWidget] = [:]
    /// Widgets that take no events: disabled, or still being stopped.
    var refusing: Set<String> = []
    /// Loaded and taking events, but not approved.
    var unapproved: Set<String> = []
    private(set) var events: [Event] = []

    func acceptsScriptEvents(for widgetID: String) -> Bool { !refusing.contains(widgetID) }

    func scriptRenderTarget(for widgetID: String) -> LoadedWidget? {
        guard acceptsScriptEvents(for: widgetID), !unapproved.contains(widgetID) else { return nil }
        return widgets[widgetID]
    }

    func scriptDidRender(_ widget: LoadedWidget, params: RenderParams) {
        events.append(.render(widget.id, params))
    }

    func scriptLoadDidComplete(widgetID: String, rendered: Bool, error: String?) {
        events.append(.loadComplete(widgetID, rendered: rendered, error: error))
    }

    func scriptStateDidChange(widgetID: String, state: ScriptWidgetState) {
        events.append(.stateChange(widgetID, state))
    }
}

/// Counts what the bridge asks its factories for, and keeps the events the
/// supervisor was created with.
@MainActor
private final class SupervisorFactory {
    private(set) var configurationsMade = 0
    private(set) var supervisorsMade = 0
    private(set) var events: RuntimeSupervisorEvents?
    private let directory: URL

    init(directory: URL) { self.directory = directory }

    /// Never launches anything.
    var configuration: RuntimeSupervisorConfiguration {
        RuntimeSupervisorConfiguration(
            makeLaunchPlan: { _ in throw CocoaError(.fileNoSuchFile) },
            storage: StorageService(directory: directory),
            secrets: InMemorySecretStore()
        )
    }

    func makeBridge(supervisor: RuntimeSupervisor? = nil) -> ScriptRuntimeBridge {
        ScriptRuntimeBridge(
            supervisor: supervisor,
            makeConfiguration: { [unowned self] in
                self.configurationsMade += 1
                return self.configuration
            },
            makeSupervisor: { [unowned self] configuration, events in
                self.supervisorsMade += 1
                self.events = events
                return RuntimeSupervisor(configuration: configuration, events: events)
            }
        )
    }
}

/// Returns once everything already on the main queue has run: the queue is
/// first in, first out, so an event's hop queued before this is over.
@MainActor
private func mainQueueDrained() async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        DispatchQueue.main.async { continuation.resume() }
    }
}

@MainActor
final class ScriptRuntimeBridgeTests: XCTestCase {
    private var directory: URL!
    private var factory: SupervisorFactory!
    private var host: StubHost!

    private let tree = UINode(type: "text", text: "rendered")

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("script-bridge-\(UUID().uuidString)", isDirectory: true)
        factory = SupervisorFactory(directory: directory)
        host = StubHost()
        host.widgets["w"] = LoadedWidget(
            manifest: Manifest(
                schemaVersion: 1, id: "w", name: "w",
                entry: .init(kind: "script", runtime: "deno-ts@1", main: "index.ts")
            ),
            directory: directory
        )
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A bridge on the stub host, and the events it hands a supervisor.
    private func makeBridge() -> (ScriptRuntimeBridge, RuntimeSupervisorEvents) {
        let bridge = factory.makeBridge()
        bridge.host = host
        return (bridge, bridge.supervisorEvents)
    }

    // MARK: - Lazy creation

    func testTheSupervisorIsCreatedOnFirstUseAndOnlyOnce() {
        let bridge = factory.makeBridge()
        bridge.host = host

        bridge.syncTimerActivity()
        _ = bridge.beginRefresh(widgetID: "w", generation: "g")
        _ = bridge.cancelRefresh(widgetID: "w")
        _ = bridge.supervisorEvents
        XCTAssertNil(bridge.existingSupervisor)
        XCTAssertEqual(factory.supervisorsMade, 0, "nothing but a use creates it")
        XCTAssertEqual(factory.configurationsMade, 0, "nor its configuration")

        let first = bridge.supervisor
        XCTAssertEqual(factory.supervisorsMade, 1)
        XCTAssertEqual(factory.configurationsMade, 1)
        XCTAssertTrue(bridge.existingSupervisor === first)
        XCTAssertTrue(bridge.supervisor === first)
        XCTAssertEqual(factory.supervisorsMade, 1, "kept, not made again")
    }

    func testAnInjectedSupervisorIsUsedAndNoneIsCreated() {
        let injected = RuntimeSupervisor(configuration: factory.configuration, events: RuntimeSupervisorEvents())
        let bridge = factory.makeBridge(supervisor: injected)
        bridge.host = host

        XCTAssertTrue(bridge.existingSupervisor === injected)
        XCTAssertTrue(bridge.supervisor === injected)
        XCTAssertEqual(factory.supervisorsMade, 0)
        XCTAssertEqual(factory.configurationsMade, 0)
    }

    func testACreatedSupervisorReportsToTheBridge() async {
        let bridge = factory.makeBridge()
        bridge.host = host
        _ = bridge.supervisor

        let events = try? XCTUnwrap(factory.events)
        events?.onRender("w", RenderParams(root: tree), 1)
        await mainQueueDrained()
        XCTAssertEqual(host.events, [.render("w", RenderParams(root: tree))])
    }

    // MARK: - Callback tokens

    func testAnEventIsDeliveredOnTheMainQueueNotInline() async {
        let (bridge, events) = makeBridge()

        events.onRender("w", RenderParams(root: tree), 1)
        XCTAssertEqual(host.events, [], "never inline")
        await mainQueueDrained()
        XCTAssertEqual(host.events, [.render("w", RenderParams(root: tree))])
        withExtendedLifetime(bridge) {}
    }

    func testAnEventQueuedBeforeItsWidgetWasInvalidatedIsDropped() async {
        let (bridge, events) = makeBridge()
        XCTAssertTrue(bridge.beginRefresh(widgetID: "w", generation: "g"))

        events.onRender("w", RenderParams(root: tree), 1)
        events.onLoadComplete("w", "g", nil)
        events.onStateChange("w", .stopped)
        bridge.callbackGate.invalidate(widgetID: "w")
        await mainQueueDrained()

        XCTAssertEqual(host.events, [], "the token was taken when each arrived")
        XCTAssertFalse(bridge.beginRefresh(widgetID: "w", generation: "next"),
                       "the stale completion did not release the load either")
    }

    func testAnEventArrivingAfterTheInvalidationIsDelivered() async {
        let (bridge, events) = makeBridge()

        bridge.callbackGate.invalidate(widgetID: "w")
        events.onStateChange("w", .running)
        await mainQueueDrained()
        XCTAssertEqual(host.events, [.stateChange("w", .running)])
    }

    func testInvalidatingOneWidgetLeavesAnothersEventsAlone() async {
        let (bridge, events) = makeBridge()

        events.onStateChange("other", .running)
        bridge.callbackGate.invalidate(widgetID: "w")
        await mainQueueDrained()
        XCTAssertEqual(host.events, [.stateChange("other", .running)])
    }

    func testEventsForAReleasedBridgeOrHostAreDropped() async {
        var bridge: ScriptRuntimeBridge? = factory.makeBridge()
        let events = bridge!.supervisorEvents

        events.onStateChange("w", .running)
        await mainQueueDrained()
        XCTAssertEqual(host.events, [], "no host yet")

        bridge?.host = host
        events.onStateChange("w", .running)
        bridge = nil
        await mainQueueDrained()
        events.onStateChange("w", .running)
        await mainQueueDrained()
        XCTAssertEqual(host.events, [], "released between arrival and delivery, and before arrival")
    }

    // MARK: - Renders

    func testARenderOutsideALoadNeedsNoLoadInFlight() async {
        let (bridge, events) = makeBridge()

        events.onRender("w", RenderParams(root: tree), 1)
        await mainQueueDrained()
        XCTAssertEqual(host.events.count, 1, "an action or timer render carries no generation")
        withExtendedLifetime(bridge) {}
    }

    func testARenderOfALoadIsDeliveredOnlyForTheGenerationInFlight() async {
        let (bridge, events) = makeBridge()
        let stale = RenderParams(root: tree, loadGeneration: "old")
        let current = RenderParams(root: tree, loadGeneration: "g")

        events.onRender("w", current, 1)
        await mainQueueDrained()
        XCTAssertEqual(host.events, [], "no load in flight")

        XCTAssertTrue(bridge.beginRefresh(widgetID: "w", generation: "g"))
        events.onRender("w", stale, 1)
        await mainQueueDrained()
        XCTAssertEqual(host.events, [], "another generation")

        events.onRender("w", current, 1)
        await mainQueueDrained()
        XCTAssertEqual(host.events, [.render("w", current)])
    }

    func testARenderForAWidgetThatIsNotATargetIsDroppedAndDoesNotCountAsRendered() async {
        let (bridge, events) = makeBridge()
        XCTAssertTrue(bridge.beginRefresh(widgetID: "w", generation: "g"))

        host.unapproved = ["w"]
        events.onRender("w", RenderParams(root: tree, loadGeneration: "g"), 1)
        await mainQueueDrained()
        XCTAssertEqual(host.events, [])

        host.unapproved = []
        events.onLoadComplete("w", "g", nil)
        await mainQueueDrained()
        XCTAssertEqual(host.events, [.loadComplete("w", rendered: false, error: nil)],
                       "the host is asked before the load is marked as rendered")
    }

    // MARK: - Load completion

    func testCompletionReportsWhetherTheLoadRenderedAndReleasesIt() async {
        let (bridge, events) = makeBridge()
        let render = RenderParams(root: tree, loadGeneration: "g")

        XCTAssertTrue(bridge.beginRefresh(widgetID: "w", generation: "g"))
        XCTAssertFalse(bridge.beginRefresh(widgetID: "w", generation: "overlap"), "one load at a time")
        events.onRender("w", render, 1)
        events.onLoadComplete("w", "g", nil)
        await mainQueueDrained()
        XCTAssertEqual(host.events, [.render("w", render), .loadComplete("w", rendered: true, error: nil)])

        XCTAssertTrue(bridge.beginRefresh(widgetID: "w", generation: "h"), "released")
        events.onLoadComplete("w", "h", "boom")
        await mainQueueDrained()
        XCTAssertEqual(host.events.last, .loadComplete("w", rendered: false, error: "boom"))
    }

    func testACompletionOfAnotherGenerationOrOfNoLoadIsDropped() async {
        let (bridge, events) = makeBridge()

        events.onLoadComplete("w", "g", nil)
        await mainQueueDrained()
        XCTAssertTrue(bridge.beginRefresh(widgetID: "w", generation: "g"))
        events.onLoadComplete("w", "old", nil)
        await mainQueueDrained()

        XCTAssertEqual(host.events, [])
        XCTAssertFalse(bridge.beginRefresh(widgetID: "w", generation: "next"), "still held by g")
    }

    func testACompletionTheHostRefusesLeavesTheLoadInFlight() async {
        let (bridge, events) = makeBridge()
        XCTAssertTrue(bridge.beginRefresh(widgetID: "w", generation: "g"))

        host.refusing = ["w"]
        events.onLoadComplete("w", "g", nil)
        await mainQueueDrained()

        XCTAssertEqual(host.events, [])
        XCTAssertTrue(bridge.cancelRefresh(widgetID: "w", generation: "g"),
                      "the host is asked before the load is released")
    }

    func testCancellingReleasesALoadAndItsLateEventsAreDropped() async {
        let (bridge, events) = makeBridge()
        XCTAssertTrue(bridge.beginRefresh(widgetID: "w", generation: "g"))
        XCTAssertTrue(bridge.beginRefresh(widgetID: "x", generation: "g"))

        XCTAssertFalse(bridge.cancelRefresh(widgetID: "w", generation: "other"))
        XCTAssertTrue(bridge.cancelRefresh(widgetID: "w", generation: "g"))
        XCTAssertFalse(bridge.cancelRefresh(widgetID: "w"), "nothing left")
        events.onRender("w", RenderParams(root: tree, loadGeneration: "g"), 1)
        events.onLoadComplete("w", "g", nil)
        await mainQueueDrained()
        XCTAssertEqual(host.events, [])

        XCTAssertEqual(bridge.cancelAllRefreshes(), ["x"])
        XCTAssertEqual(bridge.cancelAllRefreshes(), [])
    }

    // MARK: - State changes

    func testAStateChangeIsReportedAsItIsAndLeavesTheLoadToTheHost() async {
        let (bridge, events) = makeBridge()
        XCTAssertTrue(bridge.beginRefresh(widgetID: "w", generation: "g"))

        events.onStateChange("w", .running)
        events.onStateChange("w", .stopped)
        events.onStateChange("w", .disabled(reason: "crash loop"))
        await mainQueueDrained()

        XCTAssertEqual(host.events, [
            .stateChange("w", .running), .stateChange("w", .stopped),
            .stateChange("w", .disabled(reason: "crash loop")),
        ])
        XCTAssertTrue(bridge.cancelRefresh(widgetID: "w"), "the bridge did not cancel it itself")
    }

    func testAStateChangeTheHostRefusesIsDropped() async {
        let (bridge, events) = makeBridge()
        host.refusing = ["w"]

        events.onStateChange("w", .stopped)
        await mainQueueDrained()
        XCTAssertEqual(host.events, [])
        withExtendedLifetime(bridge) {}
    }

    // MARK: - Timer policy

    func testWithoutPauseWhenClosedTimersAreUnrestricted() {
        let policy = ScriptTimerPolicy(
            pauseWhenClosed: false, menuBarWidgetIDs: ["bar"], dockWidgetIDs: ["dock"],
            shelfIsOpen: true, visibleWidgetIDs: ["page"], menuBarPopoverWidgetID: "popover",
            disabledWidgetIDs: ["bar"]
        )
        XCTAssertNil(policy.allowedWidgetIDs)
    }

    func testMenuBarAndDockWidgetsKeepTheirTimersWhileTheShelfIsClosed() {
        let policy = ScriptTimerPolicy(
            pauseWhenClosed: true, menuBarWidgetIDs: ["bar"], dockWidgetIDs: ["dock"],
            shelfIsOpen: false, visibleWidgetIDs: ["page"]
        )
        XCTAssertEqual(policy.allowedWidgetIDs, ["bar", "dock"], "a page nobody is looking at does not count")
    }

    func testVisibleWidgetsCountOnlyWhileTheShelfIsOpen() {
        var policy = ScriptTimerPolicy(pauseWhenClosed: true, menuBarWidgetIDs: ["bar"], visibleWidgetIDs: ["page"])
        XCTAssertEqual(policy.allowedWidgetIDs, ["bar"])
        policy.shelfIsOpen = true
        XCTAssertEqual(policy.allowedWidgetIDs, ["bar", "page"])
    }

    func testTheWidgetInItsOwnPopoverCountsWithTheShelfClosed() {
        let policy = ScriptTimerPolicy(
            pauseWhenClosed: true, shelfIsOpen: false, visibleWidgetIDs: ["page"], menuBarPopoverWidgetID: "popover"
        )
        XCTAssertEqual(policy.allowedWidgetIDs, ["popover"])
    }

    func testADisabledWidgetIsNeverAllowedWhereverItShows() {
        let policy = ScriptTimerPolicy(
            pauseWhenClosed: true, menuBarWidgetIDs: ["bar", "off"], dockWidgetIDs: ["off"],
            shelfIsOpen: true, visibleWidgetIDs: ["off"], menuBarPopoverWidgetID: "off",
            disabledWidgetIDs: ["off"]
        )
        XCTAssertEqual(policy.allowedWidgetIDs, ["bar"])
    }

    func testNothingShownAllowsNothingRatherThanEverything() {
        XCTAssertEqual(ScriptTimerPolicy(pauseWhenClosed: true).allowedWidgetIDs, [])
    }

    func testThePolicyIsReadFromTheHostAsItIsNow() {
        let (bridge, _) = makeBridge()
        host.scriptTimerPolicy = ScriptTimerPolicy(pauseWhenClosed: true, dockWidgetIDs: ["dock"])
        XCTAssertEqual(bridge.allowedTimerWidgetIDs, ["dock"])
        host.scriptTimerPolicy.menuBarPopoverWidgetID = "popover"
        XCTAssertEqual(bridge.allowedTimerWidgetIDs, ["dock", "popover"])
    }

    func testThePolicyRevisionMovesOnlyWhenTheAllowedSetChanges() {
        let (bridge, _) = makeBridge()
        XCTAssertEqual(bridge.timerPolicyRevision, 0)

        bridge.syncTimerActivity()
        XCTAssertEqual(bridge.timerPolicyRevision, 1, "the first sync always counts")
        bridge.syncTimerActivity()
        XCTAssertEqual(bridge.timerPolicyRevision, 1, "unchanged")

        // A fact that changes without changing who is allowed.
        host.scriptTimerPolicy.visibleWidgetIDs = ["page"]
        bridge.syncTimerActivity()
        XCTAssertEqual(bridge.timerPolicyRevision, 1)

        host.scriptTimerPolicy.shelfIsOpen = true
        bridge.syncTimerActivity()
        XCTAssertEqual(bridge.timerPolicyRevision, 2)

        host.scriptTimerPolicy.pauseWhenClosed = false
        bridge.syncTimerActivity()
        XCTAssertEqual(bridge.timerPolicyRevision, 3, "unrestricted is a change from a set")

        bridge.syncTimerActivity(force: true)
        XCTAssertEqual(bridge.timerPolicyRevision, 4, "forced")
    }

    func testCreatingTheSupervisorSendsThePolicyUnderANewRevision() {
        let (bridge, _) = makeBridge()
        bridge.syncTimerActivity()
        XCTAssertEqual(bridge.timerPolicyRevision, 1)

        _ = bridge.supervisor
        XCTAssertEqual(bridge.timerPolicyRevision, 2, "though nothing changed: the new supervisor has not heard it")
        _ = bridge.supervisor
        XCTAssertEqual(bridge.timerPolicyRevision, 2)
    }

    func testWithoutAHostThePolicyIsLeftAlone() {
        let bridge = factory.makeBridge()
        bridge.syncTimerActivity(force: true)
        XCTAssertEqual(bridge.timerPolicyRevision, 0)
        XCTAssertNil(bridge.allowedTimerWidgetIDs)

        bridge.host = host
        bridge.syncTimerActivity()
        XCTAssertEqual(bridge.timerPolicyRevision, 1, "and the first sync with one still counts")
    }
}

/// The runtime's end of the bridge: an event the supervisor reports becomes
/// the widget's snapshot, and the runtime's own invalidations drop it.
///
/// Requires a disposable Foundation home: never starts a live runtime against
/// the user's installed widgets. Run with CFFIXED_USER_HOME.
@MainActor
final class ScriptRuntimeBridgeRuntimeTests: XCTestCase {
    private struct Fixture {
        let runtime: WidgetRuntime
        let supervisor: RuntimeSupervisor
        let id: String
        let files: [URL]

        @MainActor
        func cleanUp() async {
            await supervisor.stopAll()
            for file in files { try? FileManager.default.removeItem(at: file) }
        }
    }

    /// A runtime with one approved script widget, and a supervisor that
    /// cannot launch anything.
    private func makeFixture() throws -> Fixture {
        guard let home = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"],
              home.contains("barshelf-quality-home-"),
              WidgetRuntime.applicationSupportDirectory.resolvingSymlinksInPath().path.hasPrefix(
                URL(fileURLWithPath: home).resolvingSymlinksInPath().path + "/") else {
            throw XCTSkip("run with CFFIXED_USER_HOME set to a disposable barshelf-quality-home-* directory")
        }
        _ = NSApplication.shared
        let root = WidgetRuntime.applicationSupportDirectory
        let tag = UUID().uuidString.lowercased()
        let id = "dev.test.scriptbridge.\(tag)"
        let widgetDirectory = root.appendingPathComponent("widgets/scriptbridge-\(tag)")
        let permissionsFile = root.appendingPathComponent("scriptbridge-permissions-\(tag).json")
        let appPrefsFile = root.appendingPathComponent("scriptbridge-app-prefs-\(tag).json")
        let storageDirectory = root.appendingPathComponent("scriptbridge-storage-\(tag)")

        let manifest = Manifest(schemaVersion: 1, id: id, name: "Bridge",
                                entry: .init(kind: "script", runtime: "deno-ts@1", main: "index.ts"),
                                permissions: .init(storage: .init()))
        try FileManager.default.createDirectory(at: widgetDirectory, withIntermediateDirectories: true)
        try JSONEncoder().encode(manifest).write(to: widgetDirectory.appendingPathComponent("widget.json"))
        try Data().write(to: widgetDirectory.appendingPathComponent("index.ts"))

        let permissions = PermissionStore(fileURL: permissionsFile)
        permissions.approve(manifest)
        let supervisor = RuntimeSupervisor(configuration: RuntimeSupervisorConfiguration(
            makeLaunchPlan: { _ in throw CocoaError(.fileNoSuchFile) },
            storage: StorageService(directory: storageDirectory),
            secrets: InMemorySecretStore(),
            isApproved: { permissions.status(for: $0) == .approved }
        ), events: RuntimeSupervisorEvents())
        let runtime = WidgetRuntime(appPrefs: AppPrefs(fileURL: appPrefsFile),
                                    permissionStore: permissions, scriptSupervisor: supervisor)
        XCTAssertTrue(runtime.widgets.contains { $0.id == id })
        return Fixture(
            runtime: runtime, supervisor: supervisor, id: id,
            files: [widgetDirectory, permissionsFile, appPrefsFile, storageDirectory,
                    root.appendingPathComponent("cache/\(id).json")]
        )
    }

    func testAReportedRenderBecomesTheWidgetsSnapshot() async throws {
        let fixture = try makeFixture()
        let tree = UINode(type: "text", text: "from the script")
        XCTAssertNil(fixture.runtime.snapshots[fixture.id]?.viewTree)

        fixture.runtime.scriptSupervisorEvents.onRender(
            fixture.id, RenderParams(root: tree, status: RenderStatus(label: "42")), 1
        )
        XCTAssertNil(fixture.runtime.snapshots[fixture.id]?.viewTree, "not inline")
        await mainQueueDrained()

        let snapshot = try XCTUnwrap(fixture.runtime.snapshots[fixture.id])
        XCTAssertEqual(snapshot.viewTree, tree)
        XCTAssertEqual(snapshot.statusLabel, "42")
        XCTAssertNil(snapshot.error)
        XCTAssertNotNil(snapshot.updatedAt)
        await fixture.cleanUp()
    }

    func testARenderQueuedBeforeARescanIsNotApplied() async throws {
        let fixture = try makeFixture()

        fixture.runtime.scriptSupervisorEvents.onRender(
            fixture.id, RenderParams(root: UINode(type: "text", text: "from the old process")), 1
        )
        // A rescan replaces every script process: what the old one queued
        // must not land on the widget that kept its id.
        fixture.runtime.loadWidgets()
        await mainQueueDrained()

        XCTAssertTrue(fixture.runtime.widgets.contains { $0.id == fixture.id })
        XCTAssertNil(fixture.runtime.snapshots[fixture.id]?.viewTree)
        await fixture.cleanUp()
    }

    func testAReportedCrashLoopDisableShowsOnTheCard() async throws {
        let fixture = try makeFixture()

        fixture.runtime.scriptSupervisorEvents.onStateChange(fixture.id, .disabled(reason: "crashed 3 times"))
        await mainQueueDrained()

        XCTAssertEqual(fixture.runtime.snapshots[fixture.id]?.error, "Widget disabled: crashed 3 times")
        XCTAssertEqual(fixture.runtime.overlayCards[fixture.id], .disabled(reason: "crashed 3 times"))
        await fixture.cleanUp()
    }
}
