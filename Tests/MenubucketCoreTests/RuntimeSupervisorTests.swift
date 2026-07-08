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
            .appendingPathComponent("mb-supervisor-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Helpers

    /// Thread-safe capture of render texts, fulfilling `expectation` per render.
    private final class RenderCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var texts: [String] = []
        let expectation: XCTestExpectation?

        init(_ expectation: XCTestExpectation? = nil) {
            self.expectation = expectation
        }

        func record(_ params: RenderParams) {
            lock.lock()
            texts.append(params.root.text ?? "<no text>")
            lock.unlock()
            expectation?.fulfill()
        }

        var captured: [String] {
            lock.lock(); defer { lock.unlock() }
            return texts
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
            onStateChange: onStateChange ?? { _, _ in }
        )
        let supervisor = RuntimeSupervisor(configuration: configuration, events: events)
        let descriptor = ScriptWidgetDescriptor(manifest: manifest, directory: tempDir)
        return (supervisor, descriptor)
    }

    // MARK: - Scenarios

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
