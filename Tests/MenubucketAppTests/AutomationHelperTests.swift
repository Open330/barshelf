import XCTest
@testable import BarShelfAutomation

/// The app/helper channel, with both ends in this process: a real request
/// file, status file and Darwin notifications under names of their own.
final class AutomationHelperTests: XCTestCase {
    private final class StubEngine: AutomationRunning {
        var report: ((String) -> Void)?
        var permissionLost: (() -> Void)?
        var runtimeFailed: ((String) -> Void)?
        var inputSourceStatusChanged: ((AutomationInputSource.Status) -> Void)?
        var startError: Error?
        private(set) var started = 0
        private(set) var stopped = 0
        func start() throws {
            if let startError { throw startError }
            started += 1
        }
        func stop() { stopped += 1 }
    }

    private var directory: URL!
    private var channel: AutomationHelperChannel!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("barshelf-helper-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        channel = AutomationHelperChannel(directory: directory, prefix: "dev.barshelf.test.\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeServer(engine: StubEngine = StubEngine(), owner: Int32 = 4242)
        -> (AutomationHelperServer, AutomationController) {
        let controller = AutomationController(
            fileURL: directory.appendingPathComponent("automation.json"),
            makeEngine: { _ in engine }, isTrusted: { true }, hammerspoonRunning: { false })
        return (AutomationHelperServer(controller: controller, channel: channel, ownerPID: owner, build: "test"), controller)
    }

    private func readStatus() throws -> AutomationHelperStatus {
        try XCTUnwrap(channel.read(AutomationHelperStatus.self, from: channel.statusURL))
    }

    func testApplyStartsTheExtensionAndReportsItsShortcuts() throws {
        let engine = StubEngine()
        let (server, controller) = makeServer(engine: engine)
        server.start()
        XCTAssertFalse(try readStatus().isRunning)

        let request = AutomationHelperRequest(kind: .apply, appPID: 4242, source: AutomationScript.example)
        server.handle(request)

        let status = try readStatus()
        XCTAssertEqual(status.reply, .init(id: request.id, ok: true))
        XCTAssertTrue(status.isRunning)
        XCTAssertTrue(status.enabled)
        XCTAssertEqual(status.source, AutomationScript.example)
        XCTAssertEqual(status.bindings.count, try AutomationScript(source: AutomationScript.example).bindings.count)
        XCTAssertEqual(engine.started, 1)
        XCTAssertTrue(controller.isRunning)
    }

    func testAFailedApplyAnswersNoAndCarriesTheReason() throws {
        let engine = StubEngine()
        engine.startError = AutomationFailure("no tap")
        let (server, _) = makeServer(engine: engine)
        server.start()
        let request = AutomationHelperRequest(kind: .apply, appPID: 4242, source: AutomationScript.example)
        server.handle(request)
        let status = try readStatus()
        XCTAssertEqual(status.reply, .init(id: request.id, ok: false))
        XCTAssertFalse(status.isRunning)
        XCTAssertEqual(status.message, "no tap")
    }

    func testStopIsObeyedOnlyFromTheOwner() throws {
        let engine = StubEngine()
        let (server, _) = makeServer(engine: engine)
        var stopped = 0
        server.stopped = { stopped += 1 }
        server.start()
        server.handle(.init(kind: .apply, appPID: 4242, source: AutomationScript.example))

        // An app that is quitting after its successor (7777) took over.
        server.handle(.init(kind: .adopt, appPID: 7777))
        server.handle(.init(kind: .stop, appPID: 4242))
        XCTAssertEqual(stopped, 0)
        XCTAssertTrue(try readStatus().isRunning)

        server.handle(.init(kind: .stop, appPID: 7777))
        XCTAssertEqual(stopped, 1)
        XCTAssertFalse(try readStatus().isRunning)
        XCTAssertEqual(engine.stopped, 1)
    }

    func testAdoptionTellsTheProcessWhomToWatch() {
        let (server, _) = makeServer()
        var watched: [Int32] = []
        server.ownerChanged = { watched.append($0) }
        server.start()
        server.handle(.init(kind: .adopt, appPID: 4242))
        server.handle(.init(kind: .adopt, appPID: 9001))
        XCTAssertEqual(watched, [9001])
        XCTAssertEqual(server.ownerPID, 9001)
    }

    func testARequestLeftInTheFileFromBeforeIsIgnored() throws {
        let engine = StubEngine()
        let stale = AutomationHelperRequest(kind: .apply, appPID: 1, source: AutomationScript.example,
                                            sentAt: Date().addingTimeInterval(-3600))
        try channel.write(stale, to: channel.requestURL)
        let (server, _) = makeServer(engine: engine)
        server.start()
        XCTAssertEqual(engine.started, 0)
        XCTAssertEqual(server.ownerPID, 4242)
        XCTAssertNil(try readStatus().reply)
    }

    func testTheSameRequestIsHandledOnce() throws {
        let engine = StubEngine()
        let (server, _) = makeServer(engine: engine)
        server.start()
        try channel.write(AutomationHelperRequest(kind: .apply, appPID: 4242, source: AutomationScript.example),
                          to: channel.requestURL)
        server.handlePendingRequest()
        server.handlePendingRequest()
        XCTAssertEqual(engine.started, 1)
    }

    /// The client adopts a live helper of its build and applies through the
    /// real files and notifications.
    func testClientAdoptsALiveHelperAndAppliesThroughTheChannel() throws {
        let engine = StubEngine()
        let (server, _) = makeServer(engine: engine, owner: 1)
        server.start()

        let client = AutomationHelperClient(executable: URL(fileURLWithPath: "/usr/bin/false"),
                                            channel: channel, build: "test", appPID: 31337)
        var seen: [AutomationHelperStatus] = []
        client.onStatus = { seen.append($0) }

        XCTAssertTrue(client.ensureRunning())
        XCTAssertEqual(server.ownerPID, 31337, "the helper now answers to this app")

        let status = try XCTUnwrap(client.apply(source: AutomationScript.example))
        XCTAssertEqual(status.reply?.ok, true)
        XCTAssertTrue(status.isRunning)
        XCTAssertEqual(engine.started, 1)
        XCTAssertEqual(seen.last, status)
    }

    /// What the Automation page is bound to, when the extension runs in the
    /// helper: the app's controller mirrors it and stops it on Disable.
    func testAppControllerMirrorsTheHelperAndStopsItOnDisable() throws {
        let engine = StubEngine()
        let (server, _) = makeServer(engine: engine, owner: 1)
        var helperStopped = 0
        server.stopped = { helperStopped += 1 }
        server.start()

        var forced: [Int32] = []
        let client = AutomationHelperClient(executable: URL(fileURLWithPath: "/usr/bin/false"),
                                            channel: channel, build: "test", appPID: 31337,
                                            exitTimeout: 0.2, forceQuit: { forced.append($0) })
        let appDirectory = directory.appendingPathComponent("app", isDirectory: true)
        let app = AutomationController(
            fileURL: appDirectory.appendingPathComponent("automation.json"),
            makeEngine: { _ in XCTFail("the app must not run the engine itself"); return StubEngine() },
            isTrusted: { true }, hammerspoonRunning: { false })
        app.useHelper(client)

        XCTAssertTrue(app.apply(source: AutomationScript.example, enabled: true))
        XCTAssertTrue(app.isRunning)
        XCTAssertEqual(app.source, AutomationScript.example)
        XCTAssertEqual(app.activeBindings.count, try AutomationScript(source: AutomationScript.example).bindings.count)
        XCTAssertFalse(InAppHotkeys.shared.automation.isEmpty, "the dock's keys give way to the extension's")

        app.disable()
        XCTAssertEqual(helperStopped, 1)
        XCTAssertFalse(app.isRunning)
        XCTAssertFalse(app.isEnabledAtLaunch)
        XCTAssertTrue(InAppHotkeys.shared.automation.isEmpty)
        // In this test the "helper" is the test process, which does not
        // exit; the client then falls back to forcing it, through the hook.
        XCTAssertEqual(forced, [getpid()])
    }

    func testStatusRoundTripsTheInputSourceState() {
        for state in [AutomationInputSource.Status.idle, .checking, .changed, .needsAttention("F18 is off")] {
            let (name, message) = AutomationHelperStatus.encode(state)
            let status = AutomationHelperStatus(pid: 1, ownerPID: 2, build: "b", isRunning: true, enabled: true,
                source: "", message: nil, bindings: [], inputSource: name, inputSourceMessage: message, reply: nil)
            XCTAssertEqual(status.inputSourceStatus, state)
        }
    }
}
