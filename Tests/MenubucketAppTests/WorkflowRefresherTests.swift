import AppKit
import XCTest
import MenubucketCore
@testable import MenubucketApp

/// A stand-in for the runtime: answers what a refresh asks and records what
/// it is handed.
@MainActor
private final class StubHost: WorkflowRefresherHost {
    /// How many more checks pass; nil is every one.
    var checksAllowed: Int?
    private(set) var checks = 0
    var readPaths: [String] = []
    private(set) var readPathRequests = 0
    private(set) var watched: [(widgetID: String, path: String)] = []
    private(set) var alerts: [(widgetID: String, alertID: String)] = []
    /// Never unlocked and never started; no test here reads a vault.
    lazy var vaultBroker = VaultBroker()

    func workflowRefreshMayContinue(_ widget: LoadedWidget, token: NativeRefreshGate.Token) -> Bool {
        checks += 1
        guard let allowed = checksAllowed else { return true }
        return checks <= allowed
    }

    func effectiveReadPaths(for widget: LoadedWidget) -> [String] {
        readPathRequests += 1
        return readPaths
    }

    func watchWorkflowDirectory(_ directory: FileSource.AuthorizedDirectory, widgetID: String) {
        watched.append((widgetID, directory.path))
    }

    func deliverWorkflowAlert(_ alert: WorkflowEngine.AlertSample, for widget: LoadedWidget) {
        alerts.append((widget.id, alert.id))
    }
}

@MainActor
final class WorkflowRefresherTests: XCTestCase {
    private var directory: URL!
    private var host: StubHost!
    private var storage: StorageService!
    private var alertStates: AlertStateStore!
    private var auditURL: URL!
    private var refresher: WorkflowRefresher!
    private let token = NativeRefreshGate.Token(generation: 0, serial: 1)

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("workflow-refresher-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        host = StubHost()
        storage = StorageService(directory: directory.appendingPathComponent("storage", isDirectory: true))
        alertStates = AlertStateStore(fileURL: directory.appendingPathComponent("alert-state.json"))
        auditURL = directory.appendingPathComponent("audit.log")
        refresher = WorkflowRefresher(
            execService: ExecService(),
            storage: storage,
            auditLog: AuditLog(fileURL: auditURL),
            alertStates: alertStates
        )
        refresher.host = host
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Fixtures

    private func widget(_ id: String = "dev.test.workflow", permissions: String = "{}") throws -> LoadedWidget {
        let json = #"{"schemaVersion":1,"id":"\#(id)","name":"Workflow","entry":{"kind":"workflow"},"permissions":\#(permissions)}"#
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(json.utf8))
        let folder = directory.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return LoadedWidget(manifest: manifest, directory: folder)
    }

    /// Writes `workflow` as the widget's `workflow.json` and refreshes it.
    private func refresh(
        _ widget: LoadedWidget, _ workflow: String, settings: JSONValue = .object([:])
    ) async throws -> WorkflowRefreshOutcome {
        let url = widget.directory.appendingPathComponent("workflow.json")
        try Data(workflow.utf8).write(to: url)
        return await refresher.refresh(
            widget: widget, workflowURL: url, settings: settings,
            widgetContext: .object(["visible": .bool(true)]), token: token
        )
    }

    private func assertText(
        _ widget: LoadedWidget, _ workflow: String, _ expected: String, line: UInt = #line
    ) async throws {
        let outcome = try await refresh(widget, workflow)
        XCTAssertEqual(try outcome.result.get().viewTree.text, expected, line: line)
    }

    private func auditEvents() -> [String] {
        let text = (try? String(contentsOf: auditURL, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap { line in
            (try? JSONValue.parse(Data(line.utf8)))?.objectValue?["event"]?.stringValue
        }
    }

    private func failureMessage(_ outcome: WorkflowRefreshOutcome) -> String? {
        guard case let .failure(error) = outcome.result else { return nil }
        return (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }

    private func isCancelled(_ outcome: WorkflowRefreshOutcome) -> Bool {
        guard case let .failure(error) = outcome.result else { return false }
        return error is CancellationError
    }

    // MARK: - Evaluation

    func testAValueSourceAndTheSettingsReachTheViewAndTheStatus() async throws {
        let outcome = try await refresh(try widget(), """
        {"schemaVersion":1,
         "sources":{"v":{"use":"value","with":{"n":"hi"}}},
         "view":{"type":"text","text":"${sources.v.n}${settings.mark}"},
         "status":{"label":"${sources.v.n}","tooltip":"long ${sources.v.n}"}}
        """, settings: .object(["mark": .string("!")]))
        let render = try outcome.result.get()
        XCTAssertEqual(render.viewTree.text, "hi!")
        XCTAssertEqual(render.statusLabel, "hi")
        XCTAssertEqual(render.statusTooltip, "long hi")
        XCTAssertEqual(outcome.readsWidgetVisibility, false)
        XCTAssertEqual(outcome.hasAlerts, false)
    }

    func testAWorkflowThatReadsVisibilityAndDeclaresAlertsSaysSo() async throws {
        let outcome = try await refresh(try widget(), """
        {"schemaVersion":1,"sources":{},
         "view":{"type":"text","text":"${if(widget.visible, 'shown', 'hidden')}"},
         "alerts":{"a":{"when":"${false}","title":"A"}}}
        """)
        XCTAssertEqual(try outcome.result.get().viewTree.text, "shown")
        XCTAssertEqual(outcome.readsWidgetVisibility, true)
        XCTAssertEqual(outcome.hasAlerts, true)
    }

    func testAFileThatDoesNotDecodeFailsBeforeAnythingIsAsked() async throws {
        let outcome = try await refresh(try widget(), "not json")
        XCTAssertNotNil(failureMessage(outcome))
        XCTAssertNil(outcome.readsWidgetVisibility)
        XCTAssertNil(outcome.hasAlerts)
        XCTAssertEqual(host.checks, 0)
    }

    func testAnUnknownSourceFailsTheRefresh() async throws {
        let outcome = try await refresh(try widget(), """
        {"schemaVersion":1,"sources":{"s":{"use":"telepathy"}},"view":{"type":"text","text":"x"}}
        """)
        XCTAssertEqual(failureMessage(outcome)?.contains("unknown source use \"telepathy\""), true)
    }

    // MARK: - Cancellation

    func testWithoutAHostTheRefreshIsCancelled() async throws {
        refresher.host = nil
        let outcome = try await refresh(try widget(), """
        {"schemaVersion":1,"sources":{"v":{"use":"value","with":{}}},"view":{"type":"text","text":"x"}}
        """)
        XCTAssertTrue(isCancelled(outcome))
        XCTAssertEqual(outcome.hasAlerts, false, "the definition was still decoded")
    }

    func testARefusedCheckBeforeASourceStopsItFromRunning() async throws {
        host.checksAllowed = 0
        let folder = directory.appendingPathComponent("listed", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        host.readPaths = [folder.path]
        let outcome = try await refresh(try widget(), """
        {"schemaVersion":1,
         "sources":{"d":{"use":"fs.directory","with":{"path":"\(folder.path)","watch":true}}},
         "view":{"type":"text","text":"x"}}
        """)
        XCTAssertTrue(isCancelled(outcome))
        XCTAssertEqual(host.readPathRequests, 0)
        XCTAssertTrue(host.watched.isEmpty)
    }

    func testARefusedCheckAfterTheSourcesCommitsNothing() async throws {
        // One check before the source; the one before the evaluation fails.
        host.checksAllowed = 1
        let widget = try widget(permissions: #"{"storage":true,"notifications":true}"#)
        let outcome = try await refresh(widget, """
        {"schemaVersion":1,"sources":{"v":{"use":"value","with":{}}},
         "view":{"type":"text","text":"x"},
         "store":{"seen":{"value":"${1}"}},
         "alerts":{"a":{"when":"${true}","title":"A"}}}
        """)
        XCTAssertTrue(isCancelled(outcome))
        XCTAssertEqual(host.checks, 2)
        XCTAssertNil(storage.get(widgetId: widget.id, key: "seen"))
        XCTAssertNil(alertStates.state(widgetID: widget.id, alertID: "a"))
        XCTAssertTrue(host.alerts.isEmpty)
    }

    // MARK: - File sources

    func testAWatchedDirectoryInsideTheReadPathsIsHandedToTheHost() async throws {
        let folder = directory.appendingPathComponent("listed", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        host.readPaths = [folder.path]
        let widget = try widget()
        let outcome = try await refresh(widget, """
        {"schemaVersion":1,
         "sources":{"d":{"use":"fs.directory","with":{"path":"\(folder.path)","watch":true}}},
         "view":{"type":"text","text":"x"}}
        """)
        XCTAssertNoThrow(try outcome.result.get())
        XCTAssertEqual(host.readPathRequests, 1)
        XCTAssertEqual(host.watched.map(\.widgetID), [widget.id])
        XCTAssertEqual(host.watched.first.map { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path }, folder.path)
    }

    func testADirectoryThatIsNotWatchedIsNotHandedOver() async throws {
        let folder = directory.appendingPathComponent("listed", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        host.readPaths = [folder.path]
        let outcome = try await refresh(try widget(), """
        {"schemaVersion":1,
         "sources":{"d":{"use":"fs.directory","with":{"path":"\(folder.path)"}}},
         "view":{"type":"text","text":"x"}}
        """)
        XCTAssertNoThrow(try outcome.result.get())
        XCTAssertTrue(host.watched.isEmpty)
    }

    func testADirectoryOutsideTheHostsReadPathsIsBlockedAndAudited() async throws {
        let folder = directory.appendingPathComponent("private", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // The manifest's own list is not what counts: the host's answer is.
        let widget = try widget(permissions: #"{"readPaths":["\#(folder.path)"]}"#)
        let outcome = try await refresh(widget, """
        {"schemaVersion":1,
         "sources":{"d":{"use":"fs.directory","with":{"path":"\(folder.path)","watch":true}}},
         "view":{"type":"text","text":"x"}}
        """)
        XCTAssertEqual(failureMessage(outcome), "file source path is not covered by permissions.readPaths")
        XCTAssertEqual(auditEvents(), ["file.blocked"])
        XCTAssertTrue(host.watched.isEmpty)
    }

    func testAJSONFileOutsideTheReadPathsIsBlockedAndAudited() async throws {
        let file = directory.appendingPathComponent("secret.json")
        try Data(#"{"n":1}"#.utf8).write(to: file)
        let blocked = try await refresh(try widget(), """
        {"schemaVersion":1,"sources":{"f":{"use":"fs.json","with":{"path":"\(file.path)"}}},
         "view":{"type":"text","text":"x"}}
        """)
        XCTAssertNotNil(failureMessage(blocked))
        XCTAssertEqual(auditEvents(), ["file.blocked"])

        host.readPaths = [directory.path]
        let allowed = try await refresh(try widget(), """
        {"schemaVersion":1,"sources":{"f":{"use":"fs.json","with":{"path":"\(file.path)"}}},
         "view":{"type":"text","text":"x"}}
        """)
        XCTAssertNoThrow(try allowed.result.get())
        XCTAssertEqual(auditEvents(), ["file.blocked"], "an allowed read is not audited")
    }

    // MARK: - Permission-gated sources (refused before anything runs)

    func testAnExecSourceOutsideTheAllowlistIsBlockedAndAudited() async throws {
        let outcome = try await refresh(try widget(), """
        {"schemaVersion":1,"sources":{"e":{"use":"exec","with":{"command":["/usr/bin/true"]}}},
         "view":{"type":"text","text":"x"}}
        """)
        XCTAssertEqual(failureMessage(outcome), "exec source is not covered by permissions.exec allowlist")
        XCTAssertEqual(auditEvents(), ["exec.blocked"])
    }

    func testAnHTTPSourceWithoutTheNetworkPermissionOrOffTheAllowlistIsBlocked() async throws {
        let workflow = """
        {"schemaVersion":1,"sources":{"h":{"use":"http","with":{"url":"https://example.invalid/x"}}},
         "view":{"type":"text","text":"x"}}
        """
        let undeclared = try await refresh(try widget(), workflow)
        XCTAssertEqual(failureMessage(undeclared), "http source requires the \"network\" permission in the manifest")
        let elsewhere = try await refresh(try widget(permissions: #"{"network":["api.example.com"]}"#), workflow)
        XCTAssertEqual(failureMessage(elsewhere), "http source host is not covered by the permissions.network allowlist")
        XCTAssertEqual(auditEvents(), ["network.blocked", "network.blocked"])
    }

    func testASystemSourceReadingAnUndeclaredGroupIsBlocked() async throws {
        let outcome = try await refresh(try widget(permissions: #"{"system":["cpu"]}"#), """
        {"schemaVersion":1,"sources":{"s":{"use":"system","with":{"metrics":["cpu","memory"]}}},
         "view":{"type":"text","text":"x"}}
        """)
        XCTAssertEqual(failureMessage(outcome), "system source metrics memory are not covered by permissions.system")
        XCTAssertEqual(auditEvents(), ["system.blocked"])
    }

    func testAVaultSourceWithoutTheVaultPermissionFails() async throws {
        let outcome = try await refresh(try widget(), """
        {"schemaVersion":1,"sources":{"v":{"use":"vault.items"}},"view":{"type":"text","text":"x"}}
        """)
        XCTAssertEqual(failureMessage(outcome), "vault.items needs permissions.vault")
    }

    // MARK: - Storage

    func testTheStoreBlockIsCommittedOnlyForAWidgetGrantedStorage() async throws {
        let workflow = """
        {"schemaVersion":1,"sources":{},
         "view":{"type":"text","text":"${string(coalesce(storage.count, 0))}"},
         "store":{"count":{"value":"${add(coalesce(storage.count, 0), 1)}"}}}
        """
        let granted = try widget("dev.test.granted", permissions: #"{"storage":true}"#)
        try await assertText(granted, workflow, "0")
        try await assertText(granted, workflow, "1")
        XCTAssertEqual(storage.get(widgetId: granted.id, key: "count"), .number(2))

        let plain = try widget("dev.test.plain")
        try await assertText(plain, workflow, "0")
        try await assertText(plain, workflow, "0")
        XCTAssertNil(storage.get(widgetId: plain.id, key: "count"))
    }

    // MARK: - Alerts

    private let alertWorkflow = """
    {"schemaVersion":1,"sources":{},"view":{"type":"text","text":"x"},
     "alerts":{"hot":{"when":"${settings.hot}","title":"Hot"}}}
    """

    func testAnAlertThatTurnsActiveIsHandedToTheHostOnce() async throws {
        let widget = try widget(permissions: #"{"notifications":true}"#)
        _ = try await refresh(widget, alertWorkflow, settings: .object(["hot": .bool(false)]))
        XCTAssertTrue(host.alerts.isEmpty)
        _ = try await refresh(widget, alertWorkflow, settings: .object(["hot": .bool(true)]))
        XCTAssertEqual(host.alerts.map(\.alertID), ["hot"])
        XCTAssertEqual(host.alerts.map(\.widgetID), [widget.id])
        _ = try await refresh(widget, alertWorkflow, settings: .object(["hot": .bool(true)]))
        XCTAssertEqual(host.alerts.count, 1, "still active: not a new edge")
    }

    func testAWidgetWithoutNotificationsRecordsAndDeliversNothing() async throws {
        let widget = try widget()
        _ = try await refresh(widget, alertWorkflow, settings: .object(["hot": .bool(false)]))
        let outcome = try await refresh(widget, alertWorkflow, settings: .object(["hot": .bool(true)]))
        XCTAssertEqual(outcome.hasAlerts, true)
        XCTAssertTrue(host.alerts.isEmpty)
        XCTAssertNil(alertStates.state(widgetID: widget.id, alertID: "hot"))
    }

    func testForgettingAndRetainingDropWhatAlertsLastSaw() async throws {
        let kept = try widget("dev.test.kept", permissions: #"{"notifications":true}"#)
        let gone = try widget("dev.test.gone", permissions: #"{"notifications":true}"#)
        for widget in [kept, gone] {
            _ = try await refresh(widget, alertWorkflow, settings: .object(["hot": .bool(false)]))
            XCTAssertNotNil(alertStates.state(widgetID: widget.id, alertID: "hot"))
        }
        refresher.retainAlerts(widgetIDs: [kept.id])
        XCTAssertNotNil(alertStates.state(widgetID: kept.id, alertID: "hot"))
        XCTAssertNil(alertStates.state(widgetID: gone.id, alertID: "hot"))
        refresher.forgetAlerts(widgetID: kept.id)
        XCTAssertNil(alertStates.state(widgetID: kept.id, alertID: "hot"))
    }

    // MARK: - Definitions

    func testAChangedFileIsDecodedAgain() async throws {
        let widget = try widget()
        let first = try await refresh(widget, #"{"schemaVersion":1,"sources":{},"view":{"type":"text","text":"one"}}"#)
        XCTAssertEqual(try first.result.get().viewTree.text, "one")
        let second = try await refresh(
            widget, #"{"schemaVersion":1,"sources":{},"view":{"type":"text","text":"second, and longer"}}"#
        )
        XCTAssertEqual(try second.result.get().viewTree.text, "second, and longer")
    }
}

/// The runtime end of the wiring: a workflow widget refreshed through
/// `WidgetRuntime` gets its view only if the runtime made itself the
/// refresher's host and forwards the refresh to it.
///
/// Requires a disposable Foundation home, like WidgetRemovalPurgeTests:
/// run with CFFIXED_USER_HOME set to a barshelf-quality-home-* directory.
@MainActor
final class WorkflowRefreshWiringTests: XCTestCase {
    func testAWorkflowWidgetRendersThroughTheRuntime() async throws {
        guard let home = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"],
              home.contains("barshelf-quality-home-"),
              WidgetRuntime.applicationSupportDirectory.resolvingSymlinksInPath().path.hasPrefix(
                URL(fileURLWithPath: home).resolvingSymlinksInPath().path + "/") else {
            throw XCTSkip("run with CFFIXED_USER_HOME set to a disposable barshelf-quality-home-* directory")
        }
        _ = NSApplication.shared
        let root = WidgetRuntime.applicationSupportDirectory
        let listed = root.appendingPathComponent("workflow-wiring-listed", isDirectory: true)
        try FileManager.default.createDirectory(at: listed, withIntermediateDirectories: true)
        try Data("a".utf8).write(to: listed.appendingPathComponent("one.txt"))
        defer { try? FileManager.default.removeItem(at: listed) }
        let manifest = Manifest(schemaVersion: 1, id: "dev.test.workflow-wiring", name: "Workflow wiring",
                                entry: .init(kind: "workflow"),
                                permissions: .init(readPaths: [listed.path], storage: .init(granted: true)))
        let folder = WidgetRuntime.userWidgetsRoot.appendingPathComponent(manifest.id)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try JSONEncoder().encode(manifest).write(to: folder.appendingPathComponent("widget.json"))
        // The directory source needs the host's read paths; the value source
        // and the view need nothing but a refresh that is allowed to go on.
        let workflow = """
        {"schemaVersion":1,
         "sources":{"d":{"use":"fs.directory","with":{"path":"\(listed.path)"}},
                    "v":{"use":"value","with":{"n":"wired"}}},
         "view":{"type":"text","text":"${sources.v.n} ${string(count(sources.d.items))}"},
         "status":{"label":"${sources.v.n}"}}
        """
        try Data(workflow.utf8).write(to: folder.appendingPathComponent("workflow.json"))

        let runtime = WidgetRuntime(appPrefs: AppPrefs(fileURL: root.appendingPathComponent("workflow-wiring-prefs.json")))
        runtime.loadWidgets()
        runtime.approvePermissions(widgetID: manifest.id)  // also starts one refresh

        // Polls on what happened; the bound only costs time on failure.
        let deadline = Date().addingTimeInterval(15)
        func finished() -> Bool {
            guard let snapshot = runtime.snapshots[manifest.id], !snapshot.isLoading else { return false }
            return snapshot.updatedAt != nil || snapshot.error != nil
        }
        while !finished() {
            guard Date() < deadline else { return XCTFail("timed out waiting for the refresh to finish") }
            await Task.yield()
        }
        let snapshot = try XCTUnwrap(runtime.snapshots[manifest.id])
        XCTAssertNil(snapshot.error)
        XCTAssertEqual(snapshot.viewTree?.text, "wired 1")
        XCTAssertEqual(snapshot.statusLabel, "wired")
    }
}
