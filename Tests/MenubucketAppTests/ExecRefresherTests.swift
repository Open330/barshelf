import AppKit
import XCTest
import MenubucketCore
@testable import MenubucketApp

/// A stand-in for the runtime: answers what a refresh asks.
@MainActor
private final class StubHost: ExecRefresherHost {
    /// How many more checks pass; nil is every one.
    var checksAllowed: Int?
    private(set) var checks = 0
    var settings: [String: JSONValue] = [:]
    private(set) var settingsRequests = 0

    func execRefreshMayContinue(_ widget: LoadedWidget, token: NativeRefreshGate.Token) -> Bool {
        checks += 1
        guard let allowed = checksAllowed else { return true }
        return checks <= allowed
    }

    func adapterSettings(for widget: LoadedWidget) -> [String: JSONValue] {
        settingsRequests += 1
        return settings
    }
}

/// What the refresher launched and handed to an adapter, in place of a
/// process.
private actor Recorder {
    private(set) var launches: [[String]] = []
    private(set) var adapterInputs: [String] = []
    private(set) var adapterSettings: [[String: JSONValue]] = []

    func launched(_ command: [String]) { launches.append(command) }

    func adapted(_ data: Data, settings: [String: JSONValue]) {
        adapterInputs.append(String(decoding: data, as: UTF8.self))
        adapterSettings.append(settings)
    }
}

@MainActor
final class ExecRefresherTests: XCTestCase {
    private var directory: URL!
    private var host: StubHost!
    private var auditURL: URL!
    private var recorder: Recorder!
    private let token = NativeRefreshGate.Token(generation: 0, serial: 1)

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("exec-refresher-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        host = StubHost()
        auditURL = directory.appendingPathComponent("audit.log")
        recorder = Recorder()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Fixtures

    /// A refresher whose command "prints" `output` (or fails with it) without
    /// a process, and whose only adapter is `fake`.
    private func refresher(
        prints output: Result<String, ExecService.ExecError> = .success(#"{"type":"text","text":"hi"}"#)
    ) -> ExecRefresher {
        let recorder = recorder!
        let refresher = ExecRefresher(
            execService: ExecService(),
            auditLog: AuditLog(fileURL: auditURL),
            adapters: ["fake": { data, context in
                await recorder.adapted(data, settings: context.settings)
                return AdapterResult(
                    viewTree: UINode(type: "text", text: "adapted"),
                    nextRefreshAtMs: 1234, statusText: "status"
                )
            }],
            launch: { _, _, command, _ in
                await recorder.launched(command)
                return output.map { Data($0.utf8) }
            }
        )
        refresher.host = host
        return refresher
    }

    private func widget(
        source: Manifest.Source? = .init(command: ["/bin/tool", "now"]),
        exec: [Manifest.ExecPermission]? = [.init(command: "/bin/tool", allowedArgs: [["now"]])]
    ) -> LoadedWidget {
        let manifest = Manifest(
            schemaVersion: 1, id: "dev.test.exec", name: "Exec",
            entry: .init(kind: "exec"), source: source, permissions: .init(exec: exec)
        )
        return LoadedWidget(manifest: manifest, directory: directory)
    }

    private func refresh(_ refresher: ExecRefresher, _ widget: LoadedWidget) async throws -> Result<ExecRender, Error> {
        let plan = try refresher.plan(for: widget).get()
        return await refresher.refresh(widget: widget, plan: plan, token: token)
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

    private func failureMessage(_ result: Result<ExecRender, Error>) -> String? {
        guard case let .failure(error) = result else { return nil }
        return (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }

    private func isCancelled(_ result: Result<ExecRender, Error>) -> Bool {
        guard case let .failure(error) = result else { return false }
        return error is CancellationError
    }

    // MARK: - Plan

    func testACoveredCommandIsPlannedWithItsPermission() throws {
        let plan = try refresher().plan(for: widget()).get()
        XCTAssertEqual(plan.command, ["/bin/tool", "now"])
        XCTAssertEqual(plan.permission.command, "/bin/tool")
        XCTAssertTrue(auditEvents().isEmpty)
    }

    func testAWidgetWithoutACommandIsRefusedWithoutAnAuditEntry() {
        let refresher = refresher()
        for source in [nil, Manifest.Source(command: nil), Manifest.Source(command: [])] {
            XCTAssertEqual(
                refresher.plan(for: widget(source: source)),
                .failure(.init(message: "manifest has no source.command"))
            )
        }
        XCTAssertTrue(auditEvents().isEmpty)
    }

    func testACommandOutsideTheAllowlistIsRefusedAndAudited() {
        let refresher = refresher()
        let refusal = ExecRefresher.Refusal(message: "source.command is not covered by permissions.exec allowlist")
        XCTAssertEqual(refresher.plan(for: widget(exec: nil)), .failure(refusal))
        XCTAssertEqual(
            refresher.plan(for: widget(exec: [.init(command: "/bin/tool", allowedArgs: [["later"]])])),
            .failure(refusal)
        )
        XCTAssertEqual(auditEvents(), ["exec.blocked", "exec.blocked"])
    }

    // MARK: - Refresh

    func testAUITreeOnStdoutIsTheRender() async throws {
        let render = try await refresh(refresher(), widget()).get()
        XCTAssertEqual(render.viewTree.text, "hi")
        XCTAssertNil(render.statusLabel)
        XCTAssertNil(render.nextRefreshAtMs)
        let launches = await recorder.launches
        XCTAssertEqual(launches, [["/bin/tool", "now"]])
        XCTAssertEqual(host.checks, 2, "once before the launch, once after it")
        XCTAssertEqual(host.settingsRequests, 0)
    }

    func testTheRunIsAuditedAndASensitiveCommandKeepsItsArgumentsOut() async throws {
        _ = try await refresh(refresher(), widget())
        _ = try await refresh(refresher(), widget(
            exec: [.init(command: "/bin/tool", allowedArgs: [["now"]], sensitiveOutput: true)]
        ))
        let runs = audit().filter { $0["event"]?.stringValue == "exec.run" }
        XCTAssertEqual(runs.compactMap { $0["command"]?.stringValue }, ["/bin/tool now", "/bin/tool"])
        XCTAssertEqual(runs.compactMap { $0["trigger"]?.stringValue }, ["refresh", "refresh"])
    }

    func testOutputThatIsNotAUITreeFailsTheRefresh() async throws {
        let result = try await refresh(refresher(prints: .success("not json")), widget())
        XCTAssertNotNil(failureMessage(result))
        XCTAssertFalse(isCancelled(result))
    }

    func testACommandThatFailsFailsTheRefreshWithItsError() async throws {
        let result = try await refresh(
            refresher(prints: .failure(.nonZeroExit(code: 3, stderr: "boom"))), widget()
        )
        XCTAssertEqual(failureMessage(result), "exited with code 3: boom")
        XCTAssertEqual(host.checks, 1, "nothing is asked after a failed launch")
    }

    func testAPluginsLinesBecomeTheViewAndTheStatus() async throws {
        let result = try await refresh(
            refresher(prints: .success("Probe 42 | sfimage=bolt.fill\n---\nRow\n")),
            widget(source: .init(command: ["/bin/tool", "now"], output: "xbar"))
        )
        let render = try result.get()
        XCTAssertEqual(render.statusLabel, "Probe 42")
        XCTAssertEqual(render.statusIcon, "bolt.fill")
    }

    // MARK: - Adapters

    func testAnAdapterGetsTheOutputAndTheHostsSettings() async throws {
        host.settings = ["account": .string("work")]
        let result = try await refresh(
            refresher(prints: .success("raw")),
            widget(source: .init(command: ["/bin/tool", "now"], output: "data", adapter: "fake"))
        )
        let render = try result.get()
        XCTAssertEqual(render.viewTree.text, "adapted")
        XCTAssertEqual(render.nextRefreshAtMs, 1234)
        XCTAssertEqual(render.statusLabel, "status")
        let inputs = await recorder.adapterInputs
        let settings = await recorder.adapterSettings
        XCTAssertEqual(inputs, ["raw"])
        XCTAssertEqual(settings, [["account": .string("work")]])
        XCTAssertEqual(host.settingsRequests, 1)
    }

    func testDataOutputWithoutAKnownAdapterFails() async throws {
        let unnamed = try await refresh(
            refresher(), widget(source: .init(command: ["/bin/tool", "now"], output: "data"))
        )
        XCTAssertEqual(failureMessage(unnamed), "source.output is \"data\" but no adapter is set")
        let unknown = try await refresh(
            refresher(), widget(source: .init(command: ["/bin/tool", "now"], output: "data", adapter: "nope"))
        )
        XCTAssertEqual(failureMessage(unknown), "unknown adapter \"nope\"")
        XCTAssertEqual(host.settingsRequests, 0)
    }

    func testTheShippedRegistryHasTheBuiltinAdapters() {
        XCTAssertEqual(
            Set(ExecRefresher.builtinAdapters.keys), [AasUsageAdapter.name, OtpeekAdapter.name]
        )
    }

    // MARK: - Cancellation

    func testWithoutAHostNothingIsLaunched() async throws {
        let refresher = refresher()
        refresher.host = nil
        let result = try await refresh(refresher, widget())
        XCTAssertTrue(isCancelled(result))
        let launches = await recorder.launches
        XCTAssertTrue(launches.isEmpty)
        XCTAssertFalse(auditEvents().contains("exec.run"))
    }

    func testARefusedCheckBeforeTheLaunchStopsIt() async throws {
        host.checksAllowed = 0
        let result = try await refresh(refresher(), widget())
        XCTAssertTrue(isCancelled(result))
        let launches = await recorder.launches
        XCTAssertTrue(launches.isEmpty)
        XCTAssertFalse(auditEvents().contains("exec.run"))
    }

    func testARefusedCheckAfterTheLaunchKeepsTheAdapterFromRunning() async throws {
        host.checksAllowed = 1
        let result = try await refresh(
            refresher(prints: .success("raw")),
            widget(source: .init(command: ["/bin/tool", "now"], output: "data", adapter: "fake"))
        )
        XCTAssertTrue(isCancelled(result))
        let launches = await recorder.launches
        let inputs = await recorder.adapterInputs
        XCTAssertEqual(launches.count, 1)
        XCTAssertTrue(inputs.isEmpty)
        XCTAssertEqual(host.settingsRequests, 0)
    }

    // MARK: - Environment

    func testOnlyAPluginGetsTheAppearanceMarkersAndItsOwnValuesWin() {
        let plain = widget().manifest
        XCTAssertNil(ExecRefresher.pluginEnvironment(for: plain, nil))
        XCTAssertEqual(ExecRefresher.pluginEnvironment(for: plain, ["A": "1"]), ["A": "1"])

        let plugin = widget(source: .init(command: ["/bin/tool", "now"], output: "xbar")).manifest
        let environment = ExecRefresher.pluginEnvironment(for: plugin, ["A": "1", "BARSHELF": "mine"])
        XCTAssertEqual(environment?["A"], "1")
        XCTAssertEqual(environment?["BARSHELF"], "mine")
        XCTAssertNotNil(environment?["OS_APPEARANCE"])
    }

    func testDeclaredEnvironmentVariablesAreListedOnceInOrder() {
        let manifest = Manifest(
            schemaVersion: 1, id: "dev.test.exec", name: "Exec", entry: .init(kind: "exec"),
            permissions: .init(
                exec: [
                    .init(command: "/bin/a", env: ["B", "A"]),
                    .init(command: "/bin/b", env: ["C", "B"]),
                ],
                env: ["A"]
            )
        )
        XCTAssertEqual(ExecRefresher.declaredEnvironmentVariables(for: manifest), ["A", "B", "C"])
    }

    func testAPluginCallingItselfIsReadAgainstItsOwnFile() {
        let relative = widget(source: .init(command: ["./plugin.sh"], output: "xbar"))
        let context = ExecRefresher.xbarContext(widget: relative, source: relative.manifest.source!)
        XCTAssertEqual(context.selfCommand, "./plugin.sh")
        XCTAssertEqual(context.pluginFile, directory.appendingPathComponent("./plugin.sh"))

        let absolute = widget(source: .init(command: ["/opt/plugin.sh"], output: "xbar"))
        XCTAssertEqual(
            ExecRefresher.xbarContext(widget: absolute, source: absolute.manifest.source!).pluginFile,
            URL(fileURLWithPath: "/opt/plugin.sh")
        )
    }
}

/// The runtime end of the wiring: an exec widget refreshed through
/// `WidgetRuntime` gets its view only if the runtime made itself the
/// refresher's host and hands the refresh to it.
///
/// Requires a disposable Foundation home, like WidgetRemovalPurgeTests:
/// run with CFFIXED_USER_HOME set to a barshelf-quality-home-* directory.
@MainActor
final class ExecRefreshWiringTests: XCTestCase {
    private func install(_ manifest: Manifest) throws -> URL {
        let folder = WidgetRuntime.userWidgetsRoot.appendingPathComponent(manifest.id)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(manifest).write(to: folder.appendingPathComponent("widget.json"))
        return folder
    }

    /// The widget's snapshot once its refresh is over. Polls on what
    /// happened; the bound only costs time on failure.
    private func finishedSnapshot(_ runtime: WidgetRuntime, _ id: String) async throws -> WidgetSnapshot {
        let deadline = Date().addingTimeInterval(15)
        func finished() -> Bool {
            guard let snapshot = runtime.snapshots[id], !snapshot.isLoading else { return false }
            return snapshot.updatedAt != nil || snapshot.error != nil
        }
        while !finished() {
            guard Date() < deadline else {
                XCTFail("timed out waiting for the refresh to finish")
                throw CancellationError()
            }
            await Task.yield()
        }
        return try XCTUnwrap(runtime.snapshots[id])
    }

    private func requireDisposableHome() throws {
        guard let home = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"],
              home.contains("barshelf-quality-home-"),
              WidgetRuntime.applicationSupportDirectory.resolvingSymlinksInPath().path.hasPrefix(
                URL(fileURLWithPath: home).resolvingSymlinksInPath().path + "/") else {
            throw XCTSkip("run with CFFIXED_USER_HOME set to a disposable barshelf-quality-home-* directory")
        }
        _ = NSApplication.shared
    }

    func testAnExecWidgetRendersThroughTheRuntime() async throws {
        try requireDisposableHome()
        let root = WidgetRuntime.applicationSupportDirectory
        let tree = #"{"type":"text","text":"wired"}"#
        let manifest = Manifest(
            schemaVersion: 1, id: "dev.test.exec-wiring", name: "Exec wiring",
            entry: .init(kind: "exec"),
            source: .init(command: ["/bin/echo", tree]),
            permissions: .init(exec: [.init(command: "/bin/echo", allowedArgs: [[tree]])])
        )
        let folder = try install(manifest)
        defer { try? FileManager.default.removeItem(at: folder) }

        let runtime = WidgetRuntime(appPrefs: AppPrefs(fileURL: root.appendingPathComponent("exec-wiring-prefs.json")))
        runtime.loadWidgets()
        runtime.approvePermissions(widgetID: manifest.id)  // also starts one refresh

        let snapshot = try await finishedSnapshot(runtime, manifest.id)
        XCTAssertNil(snapshot.error)
        XCTAssertEqual(snapshot.viewTree?.text, "wired")
    }

    func testAnUncoveredCommandShowsWhyOnTheCardAndRunsNothing() async throws {
        try requireDisposableHome()
        let root = WidgetRuntime.applicationSupportDirectory
        let manifest = Manifest(
            schemaVersion: 1, id: "dev.test.exec-wiring-blocked", name: "Exec wiring blocked",
            entry: .init(kind: "exec"),
            source: .init(command: ["/bin/echo", "other"]),
            permissions: .init(exec: [.init(command: "/bin/echo", allowedArgs: [["this"]])])
        )
        let folder = try install(manifest)
        defer { try? FileManager.default.removeItem(at: folder) }

        let runtime = WidgetRuntime(appPrefs: AppPrefs(fileURL: root.appendingPathComponent("exec-wiring-blocked-prefs.json")))
        runtime.loadWidgets()
        runtime.approvePermissions(widgetID: manifest.id)

        let snapshot = try XCTUnwrap(runtime.snapshots[manifest.id])
        XCTAssertEqual(snapshot.error, "source.command is not covered by permissions.exec allowlist")
        XCTAssertFalse(snapshot.isLoading)
        XCTAssertNil(snapshot.viewTree)
    }
}
