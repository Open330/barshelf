import XCTest
import MenubucketCore
@testable import MenubucketApp

/// A stand-in for the runtime: answers what an action asks and records, in
/// order, everything it is told.
@MainActor
private final class StubHost: RunActionExecutorHost {
    var widgets: [String: LoadedWidget] = [:]
    var mayStart = true
    var gatePasses = true
    var approved = true
    private(set) var events: [String] = []
    private(set) var feedback: [RuntimeFeedback] = []

    func runActionWidget(_ widgetID: String) -> LoadedWidget? { widgets[widgetID] }

    func runActionMayStart(widgetID: String) -> Bool {
        events.append("mayStart")
        return mayStart
    }

    func gateRunActionPermissions(for widget: LoadedWidget) -> Bool {
        events.append("gate")
        return gatePasses
    }

    func runActionIsApproved(_ widget: LoadedWidget) -> Bool {
        events.append("approved?")
        return approved
    }

    func reportRunActionFeedback(_ feedback: RuntimeFeedback) {
        events.append("feedback")
        self.feedback.append(feedback)
    }

    func refreshAfterRunAction(widgetID: String) { events.append("refresh:\(widgetID)") }
}

/// What the executor launched, in place of a process, and what happens
/// while the "command" runs.
@MainActor
private final class Launches {
    private(set) var commands: [[String]] = []
    private(set) var permissions: [String] = []
    var result: Result<Data, ExecService.ExecError> = .success(Data())
    /// Runs on the main actor while the command is "running".
    var whileRunning: () -> Void = {}

    func launched(_ command: [String], _ permission: Manifest.ExecPermission) -> Result<Data, ExecService.ExecError> {
        commands.append(command)
        permissions.append(permission.command)
        whileRunning()
        return result
    }
}

@MainActor
final class RunActionExecutorTests: XCTestCase {
    private var directory: URL!
    private var auditURL: URL!
    private var host: StubHost!
    private var launches: Launches!
    private var gate: ScriptCallbackGate!
    private var executor: RunActionExecutor!
    private let id = "dev.test.run"

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("run-action-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        auditURL = directory.appendingPathComponent("audit.log")
        host = StubHost()
        launches = Launches()
        gate = ScriptCallbackGate()
        let launches = launches!
        executor = RunActionExecutor(
            execService: ExecService(),
            auditLog: AuditLog(fileURL: auditURL),
            callbackGate: gate,
            launch: { _, command, permission in
                await launches.launched(command, permission)
            }
        )
        executor.host = host
        host.widgets[id] = widget(id)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Fixtures

    private func widget(
        _ id: String,
        exec: [Manifest.ExecPermission]? = [.init(command: "/bin/tool")]
    ) -> LoadedWidget {
        let manifest = Manifest(
            schemaVersion: 1, id: id, name: "Run",
            entry: .init(kind: "workflow", main: "workflow.json"), permissions: .init(exec: exec)
        )
        return LoadedWidget(manifest: manifest, directory: directory)
    }

    private func run(
        _ command: [String]? = ["/bin/tool", "go"], thenRefresh: Bool? = nil
    ) -> NodeAction {
        NodeAction(type: "run", command: command, thenRefresh: thenRefresh)
    }

    private func audit() -> [[String: JSONValue]] {
        let text = (try? String(contentsOf: auditURL, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap { line in
            (try? JSONValue.parse(Data(line.utf8)))?.objectValue
        }
    }

    private func auditEvents() -> [String] {
        audit().compactMap { $0["event"]?.stringValue }
    }

    // MARK: - Turned away before it starts

    func testAnUnknownWidgetRunsNothing() {
        XCTAssertNil(executor.perform(action: run(), widgetID: "dev.test.gone"))
        XCTAssertEqual(host.events, [])
        XCTAssertTrue(auditEvents().isEmpty)
    }

    func testWithoutAHostNothingRuns() {
        executor.host = nil
        XCTAssertNil(executor.perform(action: run(), widgetID: id))
        XCTAssertTrue(auditEvents().isEmpty)
    }

    func testAWidgetThatMayNotActIsNotAskedForPermission() {
        host.mayStart = false
        XCTAssertNil(executor.perform(action: run(), widgetID: id))
        XCTAssertEqual(host.events, ["mayStart"], "a disabled widget raises no approval card")
        XCTAssertTrue(auditEvents().isEmpty)
    }

    func testAnUnapprovedWidgetIsGatedAndRunsNothing() {
        host.gatePasses = false
        XCTAssertNil(executor.perform(action: run(), widgetID: id))
        XCTAssertEqual(host.events, ["mayStart", "gate"])
        XCTAssertTrue(auditEvents().isEmpty)
    }

    func testAnActionWithoutACommandRunsNothingAndSaysNothing() {
        for command in [nil, [String]()] {
            XCTAssertNil(executor.perform(action: run(command), widgetID: id))
        }
        XCTAssertEqual(host.feedback, [])
        XCTAssertTrue(auditEvents().isEmpty)
    }

    func testACommandOutsideTheAllowlistIsBlockedAuditedAndExplained() async {
        XCTAssertNil(executor.perform(
            action: run(["/usr/bin/other", "x"]), widgetID: id, title: "Restart", surface: .dock
        ))
        XCTAssertEqual(auditEvents(), ["exec.blocked"])
        XCTAssertEqual(audit().first?["command"]?.stringValue, "/usr/bin/other x")
        XCTAssertEqual(audit().first?["reason"]?.stringValue, "run action not in permissions.exec allowlist")
        XCTAssertEqual(host.feedback.count, 1)
        XCTAssertEqual(host.feedback.first?.message, "Couldn’t Restart")
        XCTAssertEqual(host.feedback.first?.tone, .failure)
        XCTAssertEqual(host.feedback.first?.surface, .dock)
        XCTAssertNotNil(host.feedback.first?.detail)
        XCTAssertTrue(executor.tasks(for: id).isEmpty)
    }

    func testAWidgetWithNoExecPermissionsAuthorizesNothing() {
        host.widgets[id] = widget(id, exec: nil)
        XCTAssertNil(executor.perform(action: run(), widgetID: id))
        XCTAssertEqual(auditEvents(), ["exec.blocked"])
    }

    // MARK: - Running

    func testACoveredCommandIsAuditedLaunchedAndForgotten() async throws {
        let task = try XCTUnwrap(executor.perform(action: run(), widgetID: id))
        XCTAssertEqual(auditEvents(), ["exec.run"], "audited when accepted, before it runs")
        XCTAssertEqual(audit().first?["command"]?.stringValue, "/bin/tool go")
        XCTAssertEqual(audit().first?["trigger"]?.stringValue, "run-action")
        XCTAssertEqual(executor.tasks(for: id).count, 1)
        XCTAssertEqual(launches.commands, [], "nothing runs synchronously")

        await task.value
        XCTAssertEqual(launches.commands, [["/bin/tool", "go"]])
        XCTAssertEqual(launches.permissions, ["/bin/tool"])
        XCTAssertTrue(executor.tasks(for: id).isEmpty)
        XCTAssertEqual(host.events, ["mayStart", "gate", "mayStart", "approved?", "approved?"])
        XCTAssertEqual(host.feedback, [])
    }

    func testASensitiveCommandIsAuditedWithoutItsArguments() async throws {
        host.widgets[id] = widget(id, exec: [.init(command: "/bin/tool", sensitiveOutput: true)])
        let task = try XCTUnwrap(executor.perform(action: run(["/bin/tool", "secret"]), widgetID: id))
        await task.value
        XCTAssertEqual(audit().first?["command"]?.stringValue, "/bin/tool")
    }

    func testASuccessRefreshesOnlyWhenTheActionAsksForIt() async throws {
        try await XCTUnwrap(executor.perform(action: run(), widgetID: id)).value
        try await XCTUnwrap(executor.perform(action: run(thenRefresh: false), widgetID: id)).value
        XCTAssertFalse(host.events.contains("refresh:\(id)"))

        try await XCTUnwrap(executor.perform(action: run(thenRefresh: true), widgetID: id)).value
        XCTAssertEqual(host.events.last, "refresh:\(id)")
        XCTAssertEqual(host.feedback, [])
    }

    func testAFailureIsExplainedWhereTheButtonWasAndDoesNotRefresh() async throws {
        launches.result = .failure(.nonZeroExit(code: 3, stderr: "boom"))
        let task = try XCTUnwrap(executor.perform(
            action: run(thenRefresh: true), widgetID: id, title: " Restart ", surface: .menuBarCard
        ))
        await task.value
        XCTAssertEqual(host.feedback.count, 1)
        XCTAssertEqual(host.feedback.first?.message, "Couldn’t Restart")
        XCTAssertEqual(host.feedback.first?.tone, .failure)
        XCTAssertEqual(host.feedback.first?.surface, .menuBarCard)
        XCTAssertFalse(host.feedback.first?.detail?.isEmpty ?? true)
        XCTAssertFalse(host.events.contains("refresh:\(id)"))
        XCTAssertTrue(executor.tasks(for: id).isEmpty)
    }

    func testAFailedButtonWithoutWordsGetsThePlainTitle() async throws {
        launches.result = .failure(.nonZeroExit(code: 1, stderr: ""))
        try await XCTUnwrap(executor.perform(action: run(), widgetID: id)).value
        XCTAssertEqual(host.feedback.first?.message, "That didn’t work")
        XCTAssertEqual(host.feedback.first?.surface, .popup)
    }

    // MARK: - Stopped before or while it runs

    func testAnActionCancelledBeforeItStartsLaunchesNothing() async throws {
        let task = try XCTUnwrap(executor.perform(action: run(thenRefresh: true), widgetID: id))
        executor.cancel(widgetID: id)
        XCTAssertTrue(executor.tasks(for: id).isEmpty)
        await task.value
        XCTAssertEqual(launches.commands, [])
        XCTAssertFalse(host.events.contains("refresh:\(id)"))
    }

    func testAnActionWhoseWidgetWasStoppedSinceLaunchesNothing() async throws {
        let task = try XCTUnwrap(executor.perform(action: run(), widgetID: id))
        gate.invalidate(widgetID: id)
        await task.value
        XCTAssertEqual(launches.commands, [])
        XCTAssertTrue(executor.tasks(for: id).isEmpty, "it still leaves the table")
    }

    func testAnActionWhoseWidgetWasDisabledSinceLaunchesNothing() async throws {
        let task = try XCTUnwrap(executor.perform(action: run(), widgetID: id))
        host.mayStart = false
        await task.value
        XCTAssertEqual(launches.commands, [])
    }

    func testAnActionWhoseApprovalWasWithdrawnSinceLaunchesNothing() async throws {
        let task = try XCTUnwrap(executor.perform(action: run(), widgetID: id))
        host.approved = false
        await task.value
        XCTAssertEqual(launches.commands, [])
    }

    func testAnActionCancelledWhileRunningReportsNothing() async throws {
        launches.result = .failure(.nonZeroExit(code: 1, stderr: "killed"))
        launches.whileRunning = { [executor, id] in executor?.cancel(widgetID: id) }
        let task = try XCTUnwrap(executor.perform(action: run(thenRefresh: true), widgetID: id))
        await task.value
        XCTAssertEqual(launches.commands.count, 1)
        XCTAssertEqual(host.feedback, [])
        XCTAssertFalse(host.events.contains("refresh:\(id)"))
    }

    func testAnActionWhoseWidgetWasStoppedWhileRunningDoesNotRefresh() async throws {
        launches.whileRunning = { [gate, id] in gate?.invalidate(widgetID: id) }
        let task = try XCTUnwrap(executor.perform(action: run(thenRefresh: true), widgetID: id))
        await task.value
        XCTAssertEqual(launches.commands.count, 1)
        XCTAssertFalse(host.events.contains("refresh:\(id)"))
    }

    func testAnActionWhoseApprovalWasWithdrawnWhileRunningDoesNotRefresh() async throws {
        launches.whileRunning = { [host] in host?.approved = false }
        let task = try XCTUnwrap(executor.perform(action: run(thenRefresh: true), widgetID: id))
        await task.value
        XCTAssertEqual(launches.commands.count, 1)
        XCTAssertFalse(host.events.contains("refresh:\(id)"))
        XCTAssertEqual(host.feedback, [])
    }

    func testTheHostIsKeptForTheWholeAction() async throws {
        launches.whileRunning = { [executor] in executor?.host = nil }
        let task = try XCTUnwrap(executor.perform(action: run(thenRefresh: true), widgetID: id))
        await task.value
        XCTAssertEqual(host.events.last, "refresh:\(id)")
    }

    // MARK: - The running actions

    func testEveryRunningActionOfAWidgetIsListedAndCancelledTogether() async throws {
        let first = try XCTUnwrap(executor.perform(action: run(), widgetID: id))
        let second = try XCTUnwrap(executor.perform(action: run(), widgetID: id))
        XCTAssertEqual(executor.tasks(for: id).count, 2)
        XCTAssertTrue(executor.tasks(for: "dev.test.other").isEmpty)

        executor.cancel(widgetID: id)
        XCTAssertTrue(first.isCancelled)
        XCTAssertTrue(second.isCancelled)
        await first.value
        await second.value
        XCTAssertEqual(launches.commands, [])
    }

    func testARescanCancelsTheActionsOfGoneAndChangedWidgetsOnly() async throws {
        let kept = "dev.test.kept", changed = "dev.test.changed", gone = "dev.test.gone"
        var tasks: [String: Task<Void, Never>] = [:]
        for widgetID in [kept, changed, gone] {
            host.widgets[widgetID] = widget(widgetID)
            tasks[widgetID] = try XCTUnwrap(executor.perform(
                action: run(["/bin/tool", widgetID]), widgetID: widgetID
            ))
        }

        executor.cancel(widgetsNotIn: [kept, changed], orIn: [changed])
        XCTAssertEqual(executor.tasks(for: kept).count, 1)
        XCTAssertTrue(executor.tasks(for: changed).isEmpty)
        XCTAssertTrue(executor.tasks(for: gone).isEmpty)
        XCTAssertEqual(tasks[kept]?.isCancelled, false)
        XCTAssertEqual(tasks[changed]?.isCancelled, true)
        XCTAssertEqual(tasks[gone]?.isCancelled, true)

        for task in tasks.values { await task.value }
        XCTAssertEqual(launches.commands, [["/bin/tool", kept]])
    }

    // MARK: - Wording

    func testActionFailureTitle() {
        XCTAssertEqual(RunActionExecutor.actionFailureTitle("Restart"), "Couldn’t Restart")
        XCTAssertEqual(RunActionExecutor.actionFailureTitle("  "), "That didn’t work")
        XCTAssertEqual(RunActionExecutor.actionFailureTitle(nil), "That didn’t work")
    }
}
