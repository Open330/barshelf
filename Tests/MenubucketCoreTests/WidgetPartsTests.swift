import XCTest
@testable import MenubucketCore

/// `sparkline`, stacked `progress` segments, the `processes` system group and
/// the `quitApp` action — the general-purpose parts any widget can use.
final class WidgetPartsTests: XCTestCase {
    private func decode(_ json: String) throws -> UINode {
        try JSONDecoder().decode(UINode.self, from: Data(json.utf8))
    }

    // MARK: sparkline

    func testSparklineDecodesAndIsKnown() throws {
        let node = try decode(#"{"type":"sparkline","values":[1,2.5,3],"min":0,"max":10,"tint":"good","height":40}"#)
        XCTAssertTrue(node.isKnownType)
        XCTAssertEqual(node.values?.values, [1, 2.5, 3])
        XCTAssertEqual(node.min, 0)
        XCTAssertEqual(node.max, 10)
        XCTAssertEqual(node.height, 40)
        XCTAssertEqual(node.tint, "good")
        XCTAssertTrue(UINode.KnownType.allCases.contains(.sparkline))
    }

    func testSparklineValuesAreLenient() throws {
        // What a template can hand over: numeric strings, nulls, junk.
        let node = try decode(#"{"type":"sparkline","values":[1,"2",null,"x",{"a":1},[3],4]}"#)
        XCTAssertEqual(node.values?.values, [1, 2, 4])
        let scalar = try decode(#"{"type":"sparkline","values":"oops"}"#)
        XCTAssertEqual(scalar.values?.values, [])
        let roundTrip = try decode(String(decoding: JSONEncoder().encode(node), as: UTF8.self))
        XCTAssertEqual(roundTrip.values, node.values)
    }

    func testSparklineValuesFromWorkflowExpression() throws {
        let workflow = try WorkflowDefinition.decode(from: Data(#"""
        {"schemaVersion":1,"sources":{},
         "view":{"type":"vstack","children":[
           {"type":"sparkline","values":"${sources.data.history}"},
           {"type":"sparkline","values":["${sources.data.now}", 7]}]}}
        """#.utf8))
        let output = try WorkflowEngine.evaluate(
            workflow,
            sources: ["data": .object([
                "history": .array([.number(3), .number(5), .number(4)]),
                "now": .number(6),
            ])],
            settings: .object([:])
        )
        XCTAssertEqual(output.viewTree.children?[0].values?.values, [3, 5, 4])
        XCTAssertEqual(output.viewTree.children?[1].values?.values, [6, 7])
    }

    func testSparklineDomain() {
        var node = UINode(type: "sparkline", values: [10, 20])
        XCTAssertEqual(node.sparklineDomain, 9...21)
        node.min = 0
        node.max = 100
        XCTAssertEqual(node.sparklineDomain, 0...100)
        node = UINode(type: "sparkline", values: [5, 5, 5])
        let flat = try! XCTUnwrap(node.sparklineDomain)
        XCTAssertLessThan(flat.lowerBound, 5)
        XCTAssertGreaterThan(flat.upperBound, 5)
        XCTAssertNil(UINode(type: "sparkline", values: []).sparklineDomain)
        // An explicit max below the data still yields a usable range.
        node = UINode(type: "sparkline", values: [50, 60], max: 10)
        let pinned = try! XCTUnwrap(node.sparklineDomain)
        XCTAssertLessThan(pinned.lowerBound, pinned.upperBound)
    }

    // MARK: progress segments

    func testSegmentsDecodeLenientlyAndClampToOne() throws {
        let node = try decode(#"""
        {"type":"progress","segments":[
          {"value":0.5,"tint":"accent","label":"User"},
          {"value":"0.3","label":"System"},
          {"value":0.4,"tint":"warning"},
          {"value":0.2},
          {"value":-1}
        ]}
        """#)
        XCTAssertEqual(node.segments?.count, 5)
        XCTAssertEqual(node.segments?[1].value, 0.3)
        let clamped = try XCTUnwrap(node.clampedSegments)
        let values = clamped.map(\.value)
        XCTAssertEqual(values[0], 0.5)
        XCTAssertEqual(values[1], 0.3, accuracy: 1e-9)
        XCTAssertEqual(values[2], 0.2, accuracy: 1e-9) // cut to the room left
        XCTAssertEqual(values[3], 0, accuracy: 1e-9)
        XCTAssertEqual(values[4], 0)
        XCTAssertEqual(values.reduce(0, +), 1, accuracy: 1e-9)
        XCTAssertEqual(clamped[0].label, "User")
    }

    func testProgressWithoutSegmentsIsUnchanged() throws {
        let node = try decode(#"{"type":"progress","value":0.4}"#)
        XCTAssertNil(node.segments)
        XCTAssertNil(node.clampedSegments)
        XCTAssertEqual(node.value, 0.4)
    }

    // MARK: processes

    func testProcessesAbsentUnlessNamed() {
        // A source that names no metrics never gets processes, even granted.
        let implicit = SystemMetrics.authorized(nil, declared: ["cpu", "processes"])
        XCTAssertEqual(implicit.allowed, [.cpu])
        let named = SystemMetrics.authorized([.processes], declared: ["processes"])
        XCTAssertEqual(named.allowed, [.processes])
        XCTAssertEqual(SystemMetrics.authorized([.processes], declared: ["cpu"]).denied, [.processes])
        XCTAssertNil(SystemMetrics.sample(metrics: [.cpu]).objectValue?["processes"])
        XCTAssertNil(SystemMetrics.sample(metrics: [.memory]).objectValue?["processes"])
    }

    func testProcessCountOption() {
        XCTAssertEqual(ProcessMetrics.count(from: nil), 5)
        XCTAssertEqual(ProcessMetrics.count(from: .object(["count": .number(3)])), 3)
        XCTAssertEqual(ProcessMetrics.count(from: .object(["count": .number(50)])), 10)
        XCTAssertEqual(ProcessMetrics.count(from: .object(["count": .number(0)])), 1)
    }

    func testProcessesShape() throws {
        let object = try XCTUnwrap(
            SystemMetrics.sample(metrics: [.processes], processCount: 3).objectValue
        )
        let rows = try XCTUnwrap(object["processes"]?.arrayValue)
        XCTAssertFalse(rows.isEmpty)
        XCTAssertLessThanOrEqual(rows.count, 3)
        var previousCPU = Double.infinity
        for row in rows {
            let fields = try XCTUnwrap(row.objectValue)
            XCTAssertGreaterThan(try XCTUnwrap(fields["pid"]?.numberValue), 0)
            XCTAssertFalse(try XCTUnwrap(fields["name"]?.stringValue).isEmpty)
            let cpu = try XCTUnwrap(fields["cpu"]?.numberValue)
            XCTAssertTrue((0...100).contains(cpu))
            XCTAssertLessThanOrEqual(cpu, previousCPU)
            previousCPU = cpu
            XCTAssertNotNil(fields["memory"]?.numberValue)
            XCTAssertNotNil(fields["isApp"]?.boolValue)
            XCTAssertNotNil(fields["bundleID"])
        }
    }

    func testBusiestRanksByDeltaAndHandlesReusedPids() {
        let rows = ProcessMetrics.busiest(
            current: [1: 500, 2: 2_000, 3: 100],
            previous: [1: 0, 2: 1_900, 3: 900], // pid 3 restarted: counter went back
            elapsedNs: 1_000,
            coreCount: 2,
            limit: 2
        )
        XCTAssertEqual(rows.map(\.pid), [1, 2])
        XCTAssertEqual(rows[0].cpu, 25, accuracy: 1e-9) // 500 ns of 2 × 1000 ns
    }

    /// Cost of one warm sample — every pid's task info. Logged, and bounded
    /// loosely so a regression to something like a subprocess shows up.
    func testProcessSampleCost() {
        let sampler = ProcessMetrics.Sampler()
        _ = sampler.sample(count: 10) // cold: includes the 200 ms baseline
        let start = Date()
        let runs = 5
        for index in 0..<runs {
            _ = sampler.sample(count: 10, now: Date().addingTimeInterval(Double(index + 1)))
        }
        let perSample = Date().timeIntervalSince(start) / Double(runs) * 1000
        print(String(
            format: "processes sample: %.2f ms (%d pids, %d readable)",
            perSample, ProcessMetrics.allPIDs().count, ProcessMetrics.cpuTimes().count
        ))
        XCTAssertLessThan(perSample, 100)
    }

    // MARK: quitApp

    func testQuitAppParsing() throws {
        let byID = try JSONDecoder().decode(NodeAction.self, from: Data(#"{"type":"quitApp","value":"com.apple.TextEdit"}"#.utf8))
        XCTAssertEqual(QuitAppAction.target(of: byID), .bundleID("com.apple.TextEdit"))
        // A pid straight from a processes row arrives as a JSON number.
        let byPID = try JSONDecoder().decode(NodeAction.self, from: Data(#"{"type":"quitApp","value":4242}"#.utf8))
        XCTAssertEqual(byPID.value, "4242")
        XCTAssertEqual(QuitAppAction.target(of: byPID), .pid(4242))
        XCTAssertNil(QuitAppAction.target(of: NodeAction(type: "quitApp")))
        XCTAssertNil(QuitAppAction.target(of: NodeAction(type: "quitApp", value: "0")))
        XCTAssertNil(QuitAppAction.target(of: NodeAction(type: "quitApp", value: "/Applications/Safari.app")))
        XCTAssertNil(QuitAppAction.target(of: NodeAction(type: "openApp", value: "com.apple.Safari")))
    }

    func testQuitAppNeedsDeclaredAndApprovedPermission() {
        let action = NodeAction(type: "quitApp", value: "com.apple.TextEdit")
        let entry = Manifest.Entry(kind: "workflow", main: "workflow.json")
        let undeclared = Manifest(schemaVersion: 1, id: "dev.test.q", name: "Q", entry: entry)
        let declared = Manifest(schemaVersion: 1, id: "dev.test.q", name: "Q", entry: entry,
                                permissions: .init(quitApps: true))
        XCTAssertEqual(QuitAppAction.evaluate(action, manifest: undeclared, status: .approved),
                       .blocked(reason: "permissions.quitApps is not declared"))
        XCTAssertEqual(QuitAppAction.evaluate(action, manifest: declared, status: .pending),
                       .blocked(reason: "permissions are not approved"))
        XCTAssertEqual(QuitAppAction.evaluate(action, manifest: declared, status: .denied),
                       .blocked(reason: "permissions are not approved"))
        XCTAssertEqual(QuitAppAction.evaluate(action, manifest: declared, status: .approved),
                       .allowed(.bundleID("com.apple.TextEdit")))
        XCTAssertTrue(PermissionStore.manifestDeclares(.quitApps, in: declared))
    }

    func testQuitAppsPermissionDecodesAndChangesTheApprovalHash() throws {
        let permissions = try JSONDecoder().decode(
            Manifest.Permissions.self, from: Data(#"{"quitApps":true,"system":["processes"]}"#.utf8))
        XCTAssertEqual(permissions.quitApps, true)
        let entry = Manifest.Entry(kind: "workflow", main: "workflow.json")
        let before = Manifest(schemaVersion: 1, id: "dev.test.q", name: "Q", entry: entry,
                              permissions: .init(system: ["processes"]))
        var after = before
        after.permissions?.quitApps = true
        // Adding the grant sends the widget back for approval.
        XCTAssertNotEqual(PermissionStore.permissionsHash(of: before), PermissionStore.permissionsHash(of: after))
        // An absent grant leaves existing hashes untouched.
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(before.permissions), as: UTF8.self).contains("quitApps"))
    }
}
