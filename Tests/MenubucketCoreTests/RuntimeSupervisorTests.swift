import Darwin
import XCTest
@testable import MenubucketCore

/// M2-a: host side of the script runtime protocol, driven end-to-end by the
/// bash stub in `Tests/fixtures/rpc-stub.sh` standing in for deno.
final class RuntimeSupervisorTests: XCTestCase {
    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var stubURL: URL {
        packageRoot.appendingPathComponent("Tests/fixtures/rpc-stub.sh")
    }

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("barshelf-supervisor-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Helpers

    func testLoadSendsAnIntlCompatibleLocaleToTheScript() async throws {
        for (index, pair) in [("ko_KR", "ko-KR"), ("en_US@calendar=gregorian", "en-US"), ("", "en")].enumerated() {
            let request = tempDir.appendingPathComponent("load-\(index).json")
            let input = pair.0
            let supervisor = RuntimeSupervisor(configuration: RuntimeSupervisorConfiguration(
                makeLaunchPlan: { _ in
                    ScriptLaunchPlan(executable: URL(fileURLWithPath: "/bin/sh"), arguments: [
                        "-c", #"IFS= read -r line; printf '%s\n' "$line" > "$1"; while IFS= read -r line; do :; done"#,
                        "sh", request.path,
                    ])
                },
                storage: StorageService(directory: tempDir.appendingPathComponent("locale-storage")),
                secrets: InMemorySecretStore(), locale: { input }), events: RuntimeSupervisorEvents())
            try await supervisor.load(ScriptWidgetDescriptor(manifest: makeManifest(), directory: tempDir), reason: "manual")
            var received: JSONValue?
            let deadline = Date().addingTimeInterval(5)
            while received == nil, Date() < deadline {
                if let data = try? Data(contentsOf: request) { received = try? JSONDecoder().decode(JSONValue.self, from: data) }
                if received == nil { try await Task.sleep(nanoseconds: 10_000_000) }
            }
            XCTAssertEqual(received?.objectValue?["params"]?.objectValue?["locale"]?.stringValue, pair.1)
            await supervisor.stopAll()
        }
    }

    /// Thread-safe capture of render texts, fulfilling `expectation` per render.
    private final class RenderCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var texts: [String] = []
        private var loadGenerations: [String?] = []
        let expectation: XCTestExpectation?

        init(_ expectation: XCTestExpectation? = nil) {
            self.expectation = expectation
        }

        func record(_ params: RenderParams) {
            lock.lock()
            texts.append(params.root.text ?? "<no text>")
            loadGenerations.append(params.loadGeneration)
            lock.unlock()
            expectation?.fulfill()
        }

        var captured: [String] {
            lock.lock(); defer { lock.unlock() }
            return texts
        }

        var capturedLoadGenerations: [String?] {
            lock.lock(); defer { lock.unlock() }
            return loadGenerations
        }

        /// Polls until `count` renders arrived (the stub serializes its stdin
        /// reads, so tests must not write the next message too early).
        func waitForCount(_ count: Int, timeout: TimeInterval = 15) async -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if captured.count >= count { return true }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            return captured.count >= count
        }
    }

    private func makeManifest(permissionsJSON: String = "{}") throws -> Manifest {
        let json = """
        {
          "schemaVersion": 1,
          "id": "test.stub-widget",
          "name": "Stub Widget",
          "entry": { "kind": "script", "runtime": "deno-ts@1", "main": "index.ts" },
          "permissions": \(permissionsJSON)
        }
        """
        return try Manifest.decode(from: Data(json.utf8))
    }

    private func makeSupervisor(
        scenario: String,
        manifest: Manifest,
        capture: RenderCapture,
        onLoadComplete: (@Sendable (String, String, String?) -> Void)? = nil,
        onStateChange: (@Sendable (String, ScriptWidgetState) -> Void)? = nil
    ) -> (RuntimeSupervisor, ScriptWidgetDescriptor) {
        let stub = stubURL
        let configuration = RuntimeSupervisorConfiguration(
            makeLaunchPlan: { _ in
                ScriptLaunchPlan(executable: URL(fileURLWithPath: "/bin/bash"), arguments: [stub.path, scenario])
            },
            storage: StorageService(directory: tempDir.appendingPathComponent("storage")),
            secrets: InMemorySecretStore()
        )
        let events = RuntimeSupervisorEvents(
            onRender: { _, params, _ in capture.record(params) },
            onLoadComplete: onLoadComplete ?? { _, _, _ in },
            onStateChange: onStateChange ?? { _, _ in }
        )
        let supervisor = RuntimeSupervisor(configuration: configuration, events: events)
        let descriptor = ScriptWidgetDescriptor(manifest: manifest, directory: tempDir)
        return (supervisor, descriptor)
    }

    // MARK: - Scenarios

    private actor RequestLatch {
        private var continuation: CheckedContinuation<Void, Never>?
        private(set) var entered = false
        func hold() async {
            entered = true
            await withCheckedContinuation { continuation = $0 }
        }
        func release() {
            continuation?.resume()
            continuation = nil
        }
    }

    func testRequestHeldBeforeRoutingCannotUseReapprovedReplacementPermissions() async throws {
        let manifest = try makeManifest(permissionsJSON: #"{"storage":true}"#)
        let store = PermissionStore(fileURL: tempDir.appendingPathComponent("race-permissions.json"))
        store.approve(manifest)
        let storage = StorageService(directory: tempDir.appendingPathComponent("race-storage"))
        let oldScript = tempDir.appendingPathComponent("old-request.sh")
        try #"""
        IFS= read -r load
        printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"host.storage.set","params":{"key":"old-request","value":"must-not-write"}}'
        while IFS= read -r line; do :; done
        """#.write(to: oldScript, atomically: true, encoding: .utf8)
        let stub = stubURL
        let latch = RequestLatch()
        let capture = RenderCapture()
        var configuration = RuntimeSupervisorConfiguration(
            makeLaunchPlan: { widget in
                ScriptLaunchPlan(executable: URL(fileURLWithPath: "/bin/bash"),
                    arguments: widget.revision == "replacement" ? [stub.path, "render"] : [oldScript.path])
            }, storage: storage, secrets: InMemorySecretStore(),
            isApproved: { store.status(for: $0) == .approved }
        )
        configuration.beforeRequest = { method in
            if method == ScriptMethod.hostStorageSet { await latch.hold() }
        }
        let supervisor = RuntimeSupervisor(configuration: configuration, events: RuntimeSupervisorEvents(
            onRender: { _, params, _ in capture.record(params) }
        ))
        let original = ScriptWidgetDescriptor(manifest: manifest, directory: tempDir, revision: "original")
        try await supervisor.load(original, reason: "manual")
        let deadline = Date().addingTimeInterval(5)
        while !(await latch.entered), Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let entered = await latch.entered
        XCTAssertTrue(entered, "old request must reach the controlled scheduler boundary")
        store.reset(widgetId: manifest.id)
        await supervisor.stop(widgetId: original.id)
        var replacement = manifest
        replacement.permissions?.keychain = true
        store.approve(replacement)
        try await supervisor.load(ScriptWidgetDescriptor(manifest: replacement, directory: tempDir, revision: "replacement"), reason: "manual")
        let rendered = await capture.waitForCount(1)
        XCTAssertTrue(rendered, "the replacement must be live and approved before releasing the old request")
        await latch.release()
        // An old request is explicitly released into a live replacement. Give
        // its cancelled reader time to finish; no storage write may escape.
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertNil(storage.get(widgetId: original.id, key: "old-request"))
        XCTAssertEqual(capture.captured, ["hello from stub"])
        await supervisor.stopAll()
    }

    func testApprovalWithdrawalBlocksResidentCapabilityRequestsAndRelaunch() async throws {
        let manifest = try makeManifest(permissionsJSON: #"{"exec":[{"command":"/usr/bin/touch","allowedArgs":null}],"keychain":true,"storage":{"granted":true}}"#)
        let store = PermissionStore(fileURL: tempDir.appendingPathComponent("permissions.json"))
        store.approve(manifest)
        let trigger = tempDir.appendingPathComponent("continue")
        let responses = tempDir.appendingPathComponent("responses")
        let witness = tempDir.appendingPathComponent("must-not-exist")
        let script = tempDir.appendingPathComponent("approval-stub.sh")
        try #"""
        IFS= read -r load
        printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"host.render","params":{"root":{"type":"text","text":"ready"}}}'
        IFS= read -r reply
        while [ ! -f "$1" ]; do /bin/sleep 0.02; done
        printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"host.exec.run\",\"params\":{\"command\":\"/usr/bin/touch\",\"args\":[\"$3\"]}}"
        IFS= read -r reply
        printf '%s\n' "$reply" >> "$2"
        for method in host.secret.get host.storage.set host.timer.after host.notify.show host.render; do
          printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"$method\",\"params\":{}}"
          IFS= read -r reply
          printf '%s\n' "$reply" >> "$2"
        done
        while IFS= read -r line; do :; done
        """#.write(to: script, atomically: true, encoding: .utf8)
        let capture = RenderCapture()
        let configuration = RuntimeSupervisorConfiguration(
            makeLaunchPlan: { _ in ScriptLaunchPlan(executable: URL(fileURLWithPath: "/bin/bash"), arguments: [script.path, trigger.path, responses.path, witness.path]) },
            storage: StorageService(directory: tempDir.appendingPathComponent("storage")),
            secrets: InMemorySecretStore(),
            isApproved: { store.status(for: $0) == .approved }
        )
        let supervisor = RuntimeSupervisor(configuration: configuration, events: RuntimeSupervisorEvents(
            onRender: { _, params, _ in capture.record(params) }
        ))
        let descriptor = ScriptWidgetDescriptor(manifest: manifest, directory: tempDir)
        try await supervisor.load(descriptor, reason: "manual")
        let rendered = await capture.waitForCount(1)
        XCTAssertTrue(rendered)
        store.reset(widgetId: manifest.id)
        try Data().write(to: trigger)
        var lines: [String] = []
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            lines = (try? String(contentsOf: responses, encoding: .utf8))?.split(separator: "\n").map(String.init) ?? []
            if lines.count == 6 { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(lines.count, 6)
        for line in lines {
            let message = try JSONDecoder().decode(JsonRpcResponse.self, from: Data(line.utf8))
            XCTAssertEqual(message.error?.code, JsonRpcError.permissionDeniedCode)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: witness.path))
        XCTAssertEqual(capture.captured, ["ready"])
        do {
            try await supervisor.sendAction(widgetId: descriptor.id, actionId: "retry")
            XCTFail("actions cannot restart or reach an unapproved widget")
        } catch let error as JsonRpcError { XCTAssertEqual(error.code, JsonRpcError.permissionDeniedCode) }
        await supervisor.stop(widgetId: descriptor.id)
        do {
            try await supervisor.load(descriptor, reason: "manual")
            XCTFail("unapproved widget must not launch")
        } catch let error as JsonRpcError { XCTAssertEqual(error.code, JsonRpcError.permissionDeniedCode) }
        let running = await supervisor.isRunning(widgetId: descriptor.id)
        XCTAssertFalse(running)
    }

    func testStoppingScriptCancelsItsAlreadyRunningHostCommand() async throws {
        let manifest = try makeManifest(permissionsJSON: #"{"exec":[{"command":"/bin/sh"}]}"#)
        let store = PermissionStore(fileURL: tempDir.appendingPathComponent("command-permissions.json"))
        store.approve(manifest)
        let started = tempDir.appendingPathComponent("command-started")
        let witness = tempDir.appendingPathComponent("command-must-not-finish")
        let command = "printf started > \(started.path); /bin/sleep 1; printf escaped > \(witness.path)"
        let request = JsonRpcRequest(id: .number(1), method: ScriptMethod.hostExecRun, params: .object([
            "command": .string("/bin/sh"), "args": .array([.string("-c"), .string(command)])
        ]))
        let encoded = String(decoding: try JsonRpcCodec.encode(.request(request)), as: UTF8.self)
        let requestFile = tempDir.appendingPathComponent("command-request.json")
        try (encoded + "\n").write(to: requestFile, atomically: true, encoding: .utf8)
        let script = tempDir.appendingPathComponent("running-command.sh")
        try """
        IFS= read -r load
        /bin/cat command-request.json
        while IFS= read -r line; do :; done
        """.write(to: script, atomically: true, encoding: .utf8)
        let supervisor = RuntimeSupervisor(configuration: RuntimeSupervisorConfiguration(
            makeLaunchPlan: { _ in ScriptLaunchPlan(executable: URL(fileURLWithPath: "/bin/bash"), arguments: [script.path]) },
            storage: StorageService(directory: tempDir.appendingPathComponent("command-storage")),
            secrets: InMemorySecretStore(), isApproved: { store.status(for: $0) == .approved }
        ), events: RuntimeSupervisorEvents())
        let widget = ScriptWidgetDescriptor(manifest: manifest, directory: tempDir)
        try await supervisor.load(widget, reason: "manual")
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: started.path), Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: started.path))
        store.reset(widgetId: manifest.id)
        await supervisor.stop(widgetId: widget.id)
        try await Task.sleep(nanoseconds: 1_300_000_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: witness.path), "revocation must stop commands already started by a resident script")
        let running = await supervisor.isRunning(widgetId: widget.id)
        XCTAssertFalse(running)

        // A prior stop already removed the instance from the live registry.
        // Removal must still wait for its TERM-ignoring host child to exit.
        try FileManager.default.removeItem(at: started)
        let stubborn = "trap '' TERM; printf '%s' $$ > \(started.path); exec /bin/sleep 20"
        let stubbornRequest = JsonRpcRequest(id: .number(1), method: ScriptMethod.hostExecRun, params: .object([
            "command": .string("/bin/sh"), "args": .array([.string("-c"), .string(stubborn)])
        ]))
        let stubbornEncoded = String(decoding: try JsonRpcCodec.encode(.request(stubbornRequest)), as: UTF8.self)
        try (stubbornEncoded + "\n").write(to: requestFile, atomically: true, encoding: .utf8)
        store.approve(manifest)
        try await supervisor.load(widget, reason: "manual")
        let secondDeadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: started.path), Date() < secondDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let child = try XCTUnwrap(Int32(String(contentsOf: started, encoding: .utf8)))
        await supervisor.stop(widgetId: widget.id)
        await supervisor.stopAndWait(widgetId: widget.id)
        XCTAssertNotEqual(kill(child, 0), 0, "stopAndWait must include children cancelled by an earlier stop")
    }

    func testStoppedInstanceCannotNotifyAfterAuthorizationWaitAndReapproval() async throws {
        let manifest = try makeManifest(permissionsJSON: #"{"notifications":true}"#)
        let store = PermissionStore(fileURL: tempDir.appendingPathComponent("notify-permissions.json"))
        store.approve(manifest)
        let witness = tempDir.appendingPathComponent("must-not-notify")
        let script = tempDir.appendingPathComponent("notify-wait.sh")
        try #"""
        IFS= read -r load
        printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"host.notify.show","params":{"title":"Old instance"}}'
        while IFS= read -r line; do :; done
        """#.write(to: script, atomically: true, encoding: .utf8)
        let latch = RequestLatch()
        let finished = expectation(description: "held notification sink returned")
        let stub = stubURL
        let supervisor = RuntimeSupervisor(configuration: RuntimeSupervisorConfiguration(
            makeLaunchPlan: { widget in ScriptLaunchPlan(executable: URL(fileURLWithPath: "/bin/bash"),
                arguments: widget.revision == "new" ? [stub.path, "render"] : [script.path]) },
            storage: StorageService(directory: tempDir.appendingPathComponent("notify-storage")),
            secrets: InMemorySecretStore(), isApproved: { store.status(for: $0) == .approved },
            notifyAuthorized: { _, _, permit in
                await latch.hold()
                defer { finished.fulfill() }
                guard permit.isValid else { throw CancellationError() }
                try Data().write(to: witness)
            }
        ), events: RuntimeSupervisorEvents())
        try await supervisor.load(ScriptWidgetDescriptor(manifest: manifest, directory: tempDir, revision: "old"), reason: "manual")
        let deadline = Date().addingTimeInterval(5)
        while !(await latch.entered), Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        let entered = await latch.entered
        XCTAssertTrue(entered)
        store.reset(widgetId: manifest.id)
        await supervisor.stop(widgetId: manifest.id)
        store.approve(manifest)
        try await supervisor.load(ScriptWidgetDescriptor(manifest: manifest, directory: tempDir, revision: "new"), reason: "manual")
        await latch.release()
        await fulfillment(of: [finished], timeout: 5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: witness.path))
        await supervisor.stopAll()
    }

    func testRepeatedLaunchFailuresDoNotRetainPipeHandles() async throws {
        let missing = tempDir.appendingPathComponent("missing-runtime")
        let configuration = RuntimeSupervisorConfiguration(
            makeLaunchPlan: { _ in ScriptLaunchPlan(executable: missing, arguments: []) },
            storage: StorageService(directory: tempDir.appendingPathComponent("storage")),
            secrets: InMemorySecretStore()
        )
        let supervisor = RuntimeSupervisor(configuration: configuration, events: RuntimeSupervisorEvents())
        let descriptor = ScriptWidgetDescriptor(manifest: try makeManifest(), directory: tempDir)
        let initialHandles = try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
        for _ in 0..<64 {
            do {
                try await supervisor.load(descriptor, reason: "manual")
                XCTFail("missing executable must fail to launch")
            } catch {}
        }
        let finalHandles = try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
        XCTAssertLessThanOrEqual(finalHandles, initialHandles + 4,
                                 "failed launches must release their process and pipe handles")
        await supervisor.stopAll()
    }

    func testRepeatedPackageReloadKillsReplacedProcessesThatIgnoreTermination() async throws {
        let capture = RenderCapture()
        let (supervisor, original) = try makeSupervisor(
            scenario: "stubborn", manifest: makeManifest(), capture: capture
        )
        defer {
            for text in capture.captured {
                if let pid = Int32(text), kill(pid, 0) == 0 { kill(pid, SIGKILL) }
            }
        }
        for revision in 0..<4 {
            var widget = original
            widget.revision = String(revision)
            try await supervisor.load(widget, reason: "manual")
            let rendered = await capture.waitForCount(revision + 1, timeout: 3)
            XCTAssertTrue(rendered)
        }
        let pids = capture.captured.compactMap(Int32.init)
        XCTAssertEqual(Set(pids).count, 4, "each package revision must launch a fresh process")
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, pids.dropLast().contains(where: { kill($0, 0) == 0 }) {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(pids.dropLast().allSatisfy { kill($0, 0) != 0 }, "obsolete processes must not survive reload")
        let running = await supervisor.isRunning(widgetId: original.id)
        XCTAssertTrue(running, "late termination must preserve the newest instance")
        await supervisor.stopAll()
        let stopDeadline = Date().addingTimeInterval(5)
        while Date() < stopDeadline, pids.contains(where: { kill($0, 0) == 0 }) {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(pids.allSatisfy { kill($0, 0) != 0 }, "stop must also terminate scripts ignoring SIGTERM")
    }

    func testTimerRegistrationsAreBoundedPerWidget() async throws {
        try await checkTimerQuota(allowing: nil)
    }

    func testPausedTimerRegistrationsStillEnforceQuotaAndReleaseClearedSlots() async throws {
        try await checkTimerQuota(allowing: [])
    }

    private func checkTimerQuota(allowing widgetIDs: Set<String>?) async throws {
        let rendered = expectation(description: "timer quota reported through RPC")
        let capture = RenderCapture(rendered)
        let stub = stubURL
        var configuration = RuntimeSupervisorConfiguration(
            makeLaunchPlan: { _ in ScriptLaunchPlan(executable: URL(fileURLWithPath: "/bin/bash"),
                                                  arguments: [stub.path, "timer-quota"]) },
            storage: StorageService(directory: tempDir.appendingPathComponent("storage")),
            secrets: InMemorySecretStore()
        )
        configuration.maxTimersPerWidget = 1
        let supervisor = RuntimeSupervisor(configuration: configuration,
            events: RuntimeSupervisorEvents(onRender: { _, params, _ in capture.record(params) }))
        let descriptor = ScriptWidgetDescriptor(manifest: try makeManifest(), directory: tempDir)
        await supervisor.setTimerActivity(allowing: widgetIDs)
        try await supervisor.load(descriptor, reason: "manual")
        await fulfillment(of: [rendered], timeout: 3)
        XCTAssertEqual(capture.captured, ["timer-quota"])
        await supervisor.stopAll()
    }

    func testStdoutBurstReportsBackpressureRatherThanSilentlyDroppingMessages() async throws {
        let reported = expectation(description: "bounded stdout queue reports overflow")
        reported.assertForOverFulfill = false
        let stub = stubURL
        var configuration = RuntimeSupervisorConfiguration(
            makeLaunchPlan: { _ in ScriptLaunchPlan(executable: URL(fileURLWithPath: "/bin/bash"),
                                                  arguments: [stub.path, "stdout-burst"]) },
            storage: StorageService(directory: tempDir.appendingPathComponent("storage")),
            secrets: InMemorySecretStore()
        )
        // Four ~85-byte messages in one write against a 100-byte queue.
        configuration.maxBufferedStdoutBytes = 100
        let events = RuntimeSupervisorEvents(onWidgetLog: { _, level, message in
            if level == "error", message.contains("stdout messages waiting for the host exceeded") { reported.fulfill() }
        })
        let supervisor = RuntimeSupervisor(configuration: configuration, events: events)
        let descriptor = ScriptWidgetDescriptor(manifest: try makeManifest(), directory: tempDir)
        try await supervisor.load(descriptor, reason: "manual")
        await fulfillment(of: [reported], timeout: 3)
        await supervisor.stopAll()
    }

    func testDescriptorUsesExplicitInstanceID() throws {
        let manifest = try makeManifest()
        let descriptor = ScriptWidgetDescriptor(
            manifest: manifest,
            directory: tempDir,
            instanceID: "test.stub-widget--remote"
        )

        XCTAssertEqual(descriptor.id, "test.stub-widget--remote")
        XCTAssertEqual(descriptor.manifest.id, "test.stub-widget")
    }

    func testLoadRendersStubTree() async throws {
        let capture = RenderCapture(expectation(description: "render"))
        let (supervisor, widget) = try makeSupervisor(
            scenario: "render", manifest: makeManifest(), capture: capture
        )
        try await supervisor.load(widget, reason: "open")
        await fulfillment(of: [capture.expectation!], timeout: 15)
        XCTAssertEqual(capture.captured, ["hello from stub"])
        await supervisor.stopAll()
    }

    /// A burst of small messages is not runaway output: a count limit used
    /// to kill the script over 200 log lines in one write.
    func testABurstOfSmallMessagesDoesNotStopTheScript() async throws {
        let capture = RenderCapture(expectation(description: "render after burst"))
        let (supervisor, widget) = try makeSupervisor(
            scenario: "log-burst", manifest: makeManifest(), capture: capture
        )
        try await supervisor.load(widget, reason: "open")
        await fulfillment(of: [capture.expectation!], timeout: 15)
        XCTAssertEqual(capture.captured, ["after burst"])
        await supervisor.stopAll()
    }

    func testLoadGenerationIsEchoedByRenderAndCompletion() async throws {
        let rendered = expectation(description: "generation render")
        let completed = expectation(description: "generation completion")
        let capture = RenderCapture(rendered)
        let generation = "refresh-generation-1"
        let (supervisor, widget) = try makeSupervisor(
            scenario: "render",
            manifest: makeManifest(),
            capture: capture,
            onLoadComplete: { _, received, error in
                if received == generation, error == nil { completed.fulfill() }
            }
        )

        try await supervisor.load(
            widget, reason: "open", loadGeneration: generation
        )
        await fulfillment(of: [rendered, completed], timeout: 15)
        XCTAssertEqual(capture.capturedLoadGenerations, [generation])
        await supervisor.stopAll()
    }

    func testLoadCompletionForwardsHandlerError() async throws {
        let completed = expectation(description: "failed generation completion")
        let capture = RenderCapture()
        let generation = "refresh-generation-error"
        let (supervisor, widget) = try makeSupervisor(
            scenario: "load-error",
            manifest: makeManifest(),
            capture: capture,
            onLoadComplete: { _, received, error in
                if received == generation,
                   error == "Error: simulated load failure" {
                    completed.fulfill()
                }
            }
        )

        try await supervisor.load(
            widget, reason: "open", loadGeneration: generation
        )
        await fulfillment(of: [completed], timeout: 15)
        XCTAssertTrue(capture.captured.isEmpty)
        await supervisor.stopAll()
    }

    func testExecOutsideAllowlistIsDenied() async throws {
        let capture = RenderCapture(expectation(description: "denied render"))
        // No exec permissions at all — `rm -rf /` from the stub must bounce.
        let (supervisor, widget) = try makeSupervisor(
            scenario: "exec-denied", manifest: makeManifest(), capture: capture
        )
        try await supervisor.load(widget, reason: "open")
        await fulfillment(of: [capture.expectation!], timeout: 15)
        XCTAssertEqual(capture.captured, ["denied -32001"])
        await supervisor.stopAll()
    }

    func testExecWithinAllowlistRuns() async throws {
        let capture = RenderCapture(expectation(description: "exec render"))
        let manifest = try makeManifest(permissionsJSON: """
        { "exec": [{ "command": "echo", "allowedArgs": [["hi"]] }] }
        """)
        let (supervisor, widget) = makeSupervisor(
            scenario: "exec-ok", manifest: manifest, capture: capture
        )
        try await supervisor.load(widget, reason: "open")
        await fulfillment(of: [capture.expectation!], timeout: 15)
        XCTAssertEqual(capture.captured, ["exec-ok hi"])
        await supervisor.stopAll()
    }

    func testStorageRoundtrip() async throws {
        let capture = RenderCapture(expectation(description: "storage render"))
        let (supervisor, widget) = try makeSupervisor(
            scenario: "storage", manifest: makeManifest(), capture: capture
        )
        try await supervisor.load(widget, reason: "open")
        await fulfillment(of: [capture.expectation!], timeout: 15)
        XCTAssertEqual(capture.captured, ["storage-ok"])
        await supervisor.stopAll()
    }

    func testSecretRoundtripRequiresKeychainPermission() async throws {
        let allowed = RenderCapture(expectation(description: "secret ok"))
        let manifest = try makeManifest(permissionsJSON: #"{ "keychain": true }"#)
        let (supervisor, widget) = makeSupervisor(
            scenario: "secret", manifest: manifest, capture: allowed
        )
        try await supervisor.load(widget, reason: "open")
        await fulfillment(of: [allowed.expectation!], timeout: 15)
        XCTAssertEqual(allowed.captured, ["secret-ok"])
        await supervisor.stopAll()

        let denied = RenderCapture(expectation(description: "secret denied"))
        let (supervisor2, widget2) = try makeSupervisor(
            scenario: "secret", manifest: makeManifest(), capture: denied
        )
        try await supervisor2.load(widget2, reason: "open")
        await fulfillment(of: [denied.expectation!], timeout: 15)
        XCTAssertEqual(denied.captured, ["secret-denied -32001"])
        await supervisor2.stopAll()
    }

    func testHostTimerFiresWidgetTimer() async throws {
        let exp = expectation(description: "two renders")
        exp.expectedFulfillmentCount = 2
        let capture = RenderCapture(exp)
        let (supervisor, widget) = try makeSupervisor(
            scenario: "timer", manifest: makeManifest(), capture: capture
        )
        try await supervisor.load(widget, reason: "open")
        await fulfillment(of: [exp], timeout: 15)
        XCTAssertEqual(capture.captured, ["timer-armed", "timer-fired"])
        await supervisor.stopAll()
    }

    private func makeActivityTimerSupervisor(exitAfterArming: Bool = false) throws -> (RuntimeSupervisor, ScriptWidgetDescriptor) {
        let script = tempDir.appendingPathComponent("activity-timers.sh")
        let atMs = Date().timeIntervalSince1970 * 1000 + 100
        try #"""
        printf '%s\n' "$$" >> launches
        request() {
          printf '%s\n' "$1"
          IFS= read -r response
          case "$response" in *'"error"'*) printf '%s\n' "$response" >> errors; exit 1 ;; esac
        }
        if [ ! -f initialized ]; then
          IFS= read -r load
          request '{"jsonrpc":"2.0","id":1,"method":"host.timer.after","params":{"id":"cleared","delayMs":100}}'
          request '{"jsonrpc":"2.0","id":2,"method":"host.timer.clear","params":{"id":"cleared"}}'
          request '{"jsonrpc":"2.0","id":3,"method":"host.timer.after","params":{"id":"once","delayMs":60000}}'
          request '{"jsonrpc":"2.0","id":4,"method":"host.timer.after","params":{"id":"once","delayMs":100}}'
          request '{"jsonrpc":"2.0","id":5,"method":"host.timer.once","params":{"id":"at","atMs":\#(atMs)}}'
          request '{"jsonrpc":"2.0","id":6,"method":"host.timer.every","params":{"id":"repeat","intervalMs":400}}'
          printf ready > initialized
          \#(exitAfterArming ? "exit 0" : ":")
        fi
        while IFS= read -r line; do
          case "$line" in *'"method":"widget.timer"'*) printf '%s\n' "$line" >> ticks ;; esac
        done
        """#.write(to: script, atomically: true, encoding: .utf8)
        var configuration = RuntimeSupervisorConfiguration(
            makeLaunchPlan: { _ in ScriptLaunchPlan(executable: URL(fileURLWithPath: "/bin/bash"), arguments: [script.path]) },
            storage: StorageService(directory: tempDir.appendingPathComponent("activity-storage")),
            secrets: InMemorySecretStore()
        )
        configuration.minTimerIntervalMs = 50
        configuration.maxTimersPerWidget = 3
        let stopped = tempDir.appendingPathComponent("stopped")
        let events = RuntimeSupervisorEvents(onStateChange: { _, state in
            if state == .stopped { try? Data("stopped".utf8).write(to: stopped) }
        })
        return (RuntimeSupervisor(configuration: configuration, events: events),
                ScriptWidgetDescriptor(manifest: try makeManifest(), directory: tempDir))
    }

    private func activityTimerLines(_ name: String) -> [String] {
        (try? String(contentsOf: tempDir.appendingPathComponent(name), encoding: .utf8))?
            .split(separator: "\n").map(String.init) ?? []
    }

    private func waitForActivityTimerFile(_ name: String, count: Int) async throws -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if activityTimerLines(name).count >= count { return true }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        return activityTimerLines(name).count >= count
    }

    func testInactiveScriptTimersRegisterWithoutFiringAndResumeWithoutReplayBurst() async throws {
        let (supervisor, widget) = try makeActivityTimerSupervisor()
        await supervisor.setTimerActivity(allowing: [])
        try await supervisor.load(widget, reason: "open")
        let initialized = try await waitForActivityTimerFile("initialized", count: 1)
        XCTAssertTrue(initialized)
        XCTAssertEqual(activityTimerLines("errors"), [])
        try await Task.sleep(nanoseconds: 1_300_000_000)
        XCTAssertEqual(activityTimerLines("ticks"), [])
        XCTAssertEqual(activityTimerLines("launches").count, 1)

        await supervisor.setTimerActivity(allowing: [widget.id])
        let resumed = try await waitForActivityTimerFile("ticks", count: 3)
        XCTAssertTrue(resumed)
        try await Task.sleep(nanoseconds: 100_000_000)
        let firstTicks = activityTimerLines("ticks")
        XCTAssertEqual(firstTicks.count, 3, "missed repeating ticks must coalesce, not replay")
        for id in ["once", "at", "repeat"] {
            XCTAssertEqual(firstTicks.filter { $0.contains("\"id\":\"\(id)\"") }.count, 1)
        }
        XCTAssertFalse(firstTicks.contains { $0.contains("cleared") })
        let repeated = try await waitForActivityTimerFile("ticks", count: 4)
        XCTAssertTrue(repeated, "repeating timers must continue after resuming")
        XCTAssertTrue(activityTimerLines("ticks").last?.contains("\"id\":\"repeat\"") == true)

        await supervisor.setTimerActivity(allowing: [])
        // A timer already delivered to the child's pipe can finish before
        // the script observes the pause; only later deliveries are forbidden.
        try await Task.sleep(nanoseconds: 50_000_000)
        let pausedCount = activityTimerLines("ticks").count
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(activityTimerLines("ticks").count, pausedCount)
        await supervisor.stopAll()
    }

    func testInactiveTimerDoesNotRespawnExitedScriptUntilResumed() async throws {
        let (supervisor, widget) = try makeActivityTimerSupervisor(exitAfterArming: true)
        await supervisor.setTimerActivity(allowing: [])
        try await supervisor.load(widget, reason: "open")
        let initialized = try await waitForActivityTimerFile("initialized", count: 1)
        XCTAssertTrue(initialized)
        try await Task.sleep(nanoseconds: 1_300_000_000)
        let runningWhilePaused = await supervisor.isRunning(widgetId: widget.id)
        XCTAssertFalse(runningWhilePaused)
        XCTAssertEqual(activityTimerLines("launches").count, 1)
        XCTAssertEqual(activityTimerLines("ticks"), [])

        await supervisor.setTimerActivity(allowing: nil)
        let resumed = try await waitForActivityTimerFile("ticks", count: 3)
        XCTAssertTrue(resumed)
        XCTAssertEqual(activityTimerLines("launches").count, 2)
        let pids = activityTimerLines("launches")
        XCTAssertEqual(Set(pids).count, 2, "resuming may respawn the exited script exactly once")
        await supervisor.stopAll()
    }

    func testStoppingPausedExitedScriptDiscardsTimersBeforeResume() async throws {
        let (supervisor, widget) = try makeActivityTimerSupervisor(exitAfterArming: true)
        await supervisor.setTimerActivity(allowing: [])
        try await supervisor.load(widget, reason: "open")
        let initialized = try await waitForActivityTimerFile("initialized", count: 1)
        XCTAssertTrue(initialized)
        // Exercise stopAll when there is no live instance left to enumerate.
        let terminated = try await waitForActivityTimerFile("stopped", count: 1)
        XCTAssertTrue(terminated, "termination callback must remove the instance before stopAll")
        await supervisor.stopAll()
        await supervisor.setTimerActivity(allowing: nil)
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(activityTimerLines("launches").count, 1)
        XCTAssertEqual(activityTimerLines("ticks"), [])
        let running = await supervisor.isRunning(widgetId: widget.id)
        XCTAssertFalse(running)
    }

    func testStopCancelsHostTimersAndAllowsAFreshLoad() async throws {
        let capture = RenderCapture()
        let (supervisor, widget) = try makeSupervisor(
            scenario: "timer", manifest: makeManifest(), capture: capture
        )
        try await supervisor.load(widget, reason: "open")
        let armed = await capture.waitForCount(1)
        XCTAssertTrue(armed)

        await supervisor.stop(widgetId: widget.id)
        try? await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(capture.captured, ["timer-armed"])
        let runningAfterStop = await supervisor.isRunning(widgetId: widget.id)
        XCTAssertFalse(runningAfterStop)

        try await supervisor.load(widget, reason: "open")
        let reloaded = await capture.waitForCount(3)
        XCTAssertTrue(reloaded)
        XCTAssertEqual(Array(capture.captured.suffix(2)), ["timer-armed", "timer-fired"])
        await supervisor.stopAll()
    }

    func testActionIsForwardedToScript() async throws {
        let capture = RenderCapture()
        let (supervisor, widget) = try makeSupervisor(
            scenario: "render", manifest: makeManifest(), capture: capture
        )
        try await supervisor.load(widget, reason: "open")
        // The stub is single-threaded on stdin: sending the action before it
        // read the host.render response would swallow the notification.
        let firstArrived = await capture.waitForCount(1)
        XCTAssertTrue(firstArrived, "first render never arrived")
        try await supervisor.sendAction(widgetId: widget.id, actionId: "refresh")
        let secondArrived = await capture.waitForCount(2)
        XCTAssertTrue(secondArrived, "action render never arrived")
        XCTAssertEqual(capture.captured, ["hello from stub", "action-received"])
        await supervisor.stopAll()
    }

    func testCrashLoopDisablesWidget() async throws {
        let disabled = expectation(description: "disabled state")
        let capture = RenderCapture()
        let (supervisor, widget) = try makeSupervisor(
            scenario: "crash",
            manifest: makeManifest(),
            capture: capture,
            onStateChange: { _, state in
                if case .disabled = state { disabled.fulfill() }
            }
        )
        // Three crashing spawns inside the 5-minute window trip the loop
        // breaker. Each load may race process death, so tolerate errors.
        for _ in 0..<6 {
            try? await supervisor.load(widget, reason: "open")
            try? await Task.sleep(nanoseconds: 200_000_000)
            if await supervisor.disabledReason(widgetId: widget.id) != nil { break }
        }
        await fulfillment(of: [disabled], timeout: 15)
        let reason = await supervisor.disabledReason(widgetId: widget.id)
        XCTAssertNotNil(reason)
        // Restart clears the breaker (process crashes again, but is allowed to run).
        try? await supervisor.restart(widgetId: widget.id)
        await supervisor.stopAll()
    }
}

/// JSON-RPC framing/dispatch units (Core, no process involved).
final class JsonRpcTests: XCTestCase {
    func testDecodesRequestNotificationAndResponse() throws {
        let request = try JsonRpcCodec.decode(
            line: Data(#"{"jsonrpc":"2.0","id":7,"method":"host.render","params":{"root":{"type":"text"}}}"#.utf8)
        )
        guard case let .request(req) = request else { return XCTFail("expected request") }
        XCTAssertEqual(req.method, "host.render")
        XCTAssertFalse(req.isNotification)

        let notification = try JsonRpcCodec.decode(
            line: Data(#"{"jsonrpc":"2.0","method":"widget.load","params":{}}"#.utf8)
        )
        guard case let .request(note) = notification else { return XCTFail("expected notification") }
        XCTAssertTrue(note.isNotification)

        let response = try JsonRpcCodec.decode(
            line: Data(#"{"jsonrpc":"2.0","id":7,"result":{"revision":1}}"#.utf8)
        )
        guard case .response = response else { return XCTFail("expected response") }

        XCTAssertThrowsError(try JsonRpcCodec.decode(line: Data("not json".utf8)))
    }

    func testOutOfRangeNumericIdIsRejectedNotCrashed() throws {
        // An id larger than Int.max decodes as Double; `Int(_:)` used to trap.
        // Untrusted script stdout can send this, so it must fail decoding cleanly.
        for id in ["1e19", "9999999999999999999", "-1e19"] {
            XCTAssertThrowsError(
                try JsonRpcCodec.decode(
                    line: Data(#"{"jsonrpc":"2.0","id":\#(id),"method":"host.log","params":{}}"#.utf8)
                ),
                "id \(id) should be rejected"
            )
        }
        // A normal in-range id still decodes.
        let ok = try JsonRpcCodec.decode(
            line: Data(#"{"jsonrpc":"2.0","id":42,"method":"host.log","params":{}}"#.utf8)
        )
        guard case let .request(req) = ok, req.id == .number(42) else {
            return XCTFail("expected request with id 42")
        }
    }

    func testDispatcherReturnsMethodNotFound() async throws {
        let dispatcher = JsonRpcDispatcher()
        dispatcher.register(method: "known") { _ in .null }
        let response = await dispatcher.dispatch(
            JsonRpcRequest(id: .number(1), method: "unknown")
        )
        XCTAssertEqual(response?.error?.code, -32601)
    }
}
