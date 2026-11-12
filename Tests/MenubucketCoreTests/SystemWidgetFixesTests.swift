import XCTest
@testable import MenubucketCore

/// Bundled system/utility widgets, evaluated offline with fake sources:
/// rows without a reading stay hidden, failures never read as data, and the
/// actions offered make sense for what is shown.
final class SystemWidgetFixesTests: XCTestCase {
    private func definition(_ name: String) throws -> WorkflowDefinition {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        // Gallery widgets live in widgets/, unlisted samples in examples/.
        let listed = root.appendingPathComponent("widgets/\(name)/workflow.json")
        let url = FileManager.default.fileExists(atPath: listed.path)
            ? listed : root.appendingPathComponent("examples/\(name)/workflow.json")
        return try WorkflowDefinition.decode(from: try Data(contentsOf: url))
    }

    private func evaluate(
        _ name: String, _ sources: [String: JSONValue], settings: JSONValue = .object([:]),
        widget: JSONValue = .object([:])
    ) throws -> WorkflowEngine.Output {
        try WorkflowEngine.evaluate(try definition(name), sources: sources, settings: settings, widget: widget)
    }

    /// Text a person can see: hidden nodes and their children are left out.
    private func visible(_ node: UINode) -> [String] {
        guard node.hidden != true else { return [] }
        return [node.text, node.title, node.subtitle].compactMap { $0 }
            + ((node.children ?? []) + (node.items ?? [])).flatMap(visible)
    }

    private func visibleNodes(_ node: UINode) -> [UINode] {
        guard node.hidden != true else { return [] }
        return [node] + ((node.children ?? []) + (node.items ?? [])).flatMap(visibleNodes)
    }

    private func visibleActions(_ node: UINode) -> [NodeAction] {
        visibleNodes(node).compactMap(\.action)
    }

    // MARK: Sensors

    private func sensors(cpu: JSONValue, gpu: JSONValue = .null, battery: JSONValue = .null,
                         fans: [JSONValue] = []) -> [String: JSONValue] {
        ["data": .object(["sensors": .object([
            "available": .bool(true), "cpu": cpu, "gpu": gpu, "battery": battery, "peak": cpu,
            "power": .null, "fans": .array(fans), "list": .array([]),
        ])])]
    }

    func testSensorsHidesRowsWithoutAReadingOnAFanlessMac() throws {
        let output = try evaluate("sensors", sensors(cpu: .number(48)))
        let shown = visible(output.viewTree)
        XCTAssertTrue(shown.contains("CPU"), "\(shown)")
        for absent in ["GPU", "Battery", "Fans", "none", "—"] {
            XCTAssertFalse(shown.contains(absent), "\(absent) shown: \(shown)")
        }
        XCTAssertTrue(visibleActions(output.viewTree).contains { $0.type == "openApp" && $0.value == "com.apple.ActivityMonitor" })
    }

    func testSensorsThresholdsFollowSettings() throws {
        let hot = sensors(cpu: .number(82))
        XCTAssertEqual(try evaluate("sensors", hot).statusTint, "warning", "75/90 by default")
        let strict = JSONValue.object(["warmC": .number(60), "hotC": .number(80)])
        XCTAssertEqual(try evaluate("sensors", hot, settings: strict).statusTint, "danger")
    }

    // MARK: Top Processes

    func testTopProcessesUsesNativeNamesAndOffersAppActions() throws {
        let output = try evaluate("top-processes", [
            "cpu": .object(["cpu": .object(["usage": .number(30), "coreCount": .number(10)])]),
            "procs": .object(["processes": .array([
                .object(["pid": .number(501), "name": .string("Xcode"), "cpu": .number(8.1), "memory": .number(2.5e9),
                         "bundleID": .string("com.apple.dt.Xcode"), "isApp": .bool(true)]),
                .object(["pid": .number(88), "name": .string("WindowServer"), "cpu": .number(2), "memory": .number(4e8),
                         "bundleID": .null, "isApp": .bool(false)]),
            ])]),
        ])
        let shown = visible(output.viewTree)
        XCTAssertTrue(shown.contains("Xcode"), "\(shown)")
        XCTAssertTrue(shown.contains("81%"), "Activity Monitor scale: \(shown)")
        XCTAssertTrue(shown.contains("WindowServer"), "\(shown)")
        for gone in ["Peak CPU", "Samples", "Top total"] { XCTAssertFalse(shown.contains(gone), gone) }
        let actions = visibleActions(output.viewTree)
        XCTAssertTrue(actions.contains { $0.type == "openApp" && $0.value == "com.apple.dt.Xcode" })
        XCTAssertTrue(actions.contains { $0.type == "quitApp" && $0.value == "501" })
        XCTAssertFalse(actions.contains { $0.type == "quitApp" && $0.value == "88" }, "a daemon is never quittable")
        XCTAssertEqual(output.statusLabel, "81%")
        XCTAssertEqual(output.statusPrefix, "Xcode")
    }

    // MARK: Network

    func testNetworkOffersToCopyTheAddress() throws {
        let output = try evaluate("network", ["data": .object(["network": .object([
            "available": .bool(true), "interface": .string("en0"), "address": .string("192.168.0.8"),
            "download": .number(1000), "upload": .number(500),
        ])])], settings: .object(["interface": .string("en0")]))
        XCTAssertTrue(visibleActions(output.viewTree).contains { $0.type == "copyText" && $0.value == "192.168.0.8" })
    }

    // MARK: Internet Quality

    func testInternetQualityNamesItsHostAndSaysNoReply() throws {
        let settings = JSONValue.object(["pingHost": .string("9.9.9.9"), "slowMs": .number(300)])
        let down = try evaluate("internet-quality", [
            "ping": .object(["ok": .bool(false), "loss": .number(100)]),
            "speed": .object(["skipped": .bool(true)]),
        ], settings: settings)
        let shown = visible(down.viewTree).joined(separator: "\n")
        XCTAssertTrue(shown.contains("9.9.9.9"), shown)
        XCTAssertFalse(shown.contains("1.1.1.1"), shown)
        XCTAssertFalse(shown.contains("— ms"), shown)
        XCTAssertEqual(down.statusLabel, "No reply")
        XCTAssertTrue(shown.contains("No reply"), "badge and menu bar agree: \(shown)")

        let slow = try evaluate("internet-quality", [
            "ping": .object(["ok": .bool(true), "avg": .number(150), "jitter": .number(2), "loss": .number(0)]),
            "speed": .object(["skipped": .bool(true)]),
        ], settings: .object(["slowMs": .number(120)]))
        XCTAssertTrue(visible(slow.viewTree).contains("Unstable"), "\(visible(slow.viewTree))")
    }

    // MARK: Keep Awake

    func testKeepAwakeWithoutTheGuardOffersNoRequestButtons() throws {
        let missing: [String: JSONValue] = [
            "status": .object(["exists": .bool(false), "valid": .bool(false), "value": .null]),
            "pending": .object(["exists": .bool(false), "valid": .bool(false), "value": .null]),
        ]
        let output = try evaluate("keep-awake", missing, settings: .object(["lidClosed": .bool(false), "untilTime": .string("18:00")]))
        let actions = visibleActions(output.viewTree)
        XCTAssertFalse(actions.contains { $0.type == "run" }, "request buttons with no guard: \(actions)")
        XCTAssertTrue(actions.contains { $0.type == "openURL" && $0.url == "https://github.com/jiunbae/settings" })
    }

    // MARK: Bluetooth Battery

    func testBluetoothBatteryLeavesTheMenuBarToItsIconWithNoDevices() throws {
        let output = try evaluate("bluetooth-battery", ["bt": .object(["devices": .array([]), "lowest": .null])])
        XCTAssertEqual(output.statusLabel, "")
    }

    // MARK: Listening Ports

    func testListeningPortsOffersOpenOnlyForLikelyWebServers() throws {
        func port(_ n: Int, _ name: String) -> JSONValue {
            .object(["id": .string("1:\(n)"), "port": .number(Double(n)), "pid": .number(1), "name": .string(name),
                     "scope": .string("local"), "address": .string("127.0.0.1"), "target": .string("localhost:\(n)")])
        }
        let output = try evaluate("listening-ports", ["ports": .object(["ports": .array([
            port(3000, "node"), port(5432, "postgres"), port(6379, "redis-server"),
            port(7000, "ControlCenter"), port(5000, "ControlCenter"), port(49152, "rapportd"), port(8080, "python3"),
        ])])])
        let opens = visibleActions(output.viewTree).filter { $0.type == "openURL" }.compactMap(\.url)
        XCTAssertEqual(Set(opens), ["http://localhost:3000", "http://localhost:8080"])
        XCTAssertEqual(output.statusLabel, "7")
    }

    // MARK: Tailscale

    func testTailscaleSaysWhatIsWrongInItsOwnWords() throws {
        let output = try evaluate("tailscale", ["ts": .object([
            "installed": .bool(true), "ok": .bool(false),
            "error": .string("failed to connect to local Tailscale daemon for /localapi/v0/status; not running?"),
        ])])
        let nodes = visibleNodes(output.viewTree)
        let banner = try XCTUnwrap(nodes.first { $0.type == "banner" })
        XCTAssertEqual(banner.text, "Tailscale isn’t running")
        XCTAssertTrue(visibleActions(output.viewTree).contains { $0.type == "openApp" && $0.value == "io.tailscale.ipn.macos" })
        XCTAssertFalse(nodes.contains { $0.type == "badge" }, "no 0/0 online badge while it is down")
    }

    func testTailscaleMissingOffersTheDownload() throws {
        let output = try evaluate("tailscale", ["ts": .object(["installed": .bool(false), "ok": .bool(false)])])
        XCTAssertTrue(visibleActions(output.viewTree).contains { $0.type == "openURL" && $0.url == "https://tailscale.com/download" })
    }

    func testTailscaleCopiesHostnames() throws {
        let output = try evaluate("tailscale", ["ts": .object([
            "installed": .bool(true), "ok": .bool(true), "backendState": .string("Running"),
            "self": .object(["name": .string("mba"), "dns": .string("mba.tail1.ts.net"), "ip": .string("100.64.0.1")]),
            "exitNode": .null, "health": .array([]), "peerCount": .number(1), "onlineCount": .number(1),
            "peers": .array([.object(["id": .string("p1"), "name": .string("mini"), "dns": .string("mini.tail1.ts.net"),
                                      "ip": .string("100.64.0.2"), "os": .string("macOS"), "online": .bool(true),
                                      "lastSeen": .null, "exitNode": .bool(false)])]),
        ])], settings: .object(["showOffline": .bool(true)]))
        let copies = visibleActions(output.viewTree).filter { $0.type == "copyText" }.compactMap(\.value)
        XCTAssertTrue(copies.contains("mba.tail1.ts.net"), "\(copies)")
        XCTAssertTrue(copies.contains("mini.tail1.ts.net"), "\(copies)")
        XCTAssertTrue(visible(output.viewTree).contains("1/1 online"))
    }
}
