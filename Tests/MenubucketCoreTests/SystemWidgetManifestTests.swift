import XCTest
@testable import MenubucketCore

/// The bundled `system` and `sensors` widgets are the reference for the
/// `system` source, so their manifests must stay in step with what their
/// workflows actually read — a drift here ships a widget that fails at refresh.
final class SystemWidgetManifestTests: XCTestCase {
    private var widgetsDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // MenubucketCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("widgets", isDirectory: true)
    }

    private func load(_ name: String) throws -> (Manifest, WorkflowDefinition) {
        let directory = widgetsDirectory.appendingPathComponent(name, isDirectory: true)
        let manifest = try Manifest.decode(
            from: Data(contentsOf: directory.appendingPathComponent("widget.json"))
        )
        let workflow = try WorkflowDefinition.decode(
            from: Data(contentsOf: directory.appendingPathComponent("workflow.json"))
        )
        return (manifest, workflow)
    }

    func testBundledSystemWidgetsDeclareEveryMetricTheyRead() throws {
        for name in ["system", "sensors"] {
            let (manifest, workflow) = try load(name)
            let requested = WidgetDiscovery.requestedSystemMetrics(workflow)
            XCTAssertFalse(requested.isEmpty, "\(name) should read system telemetry")
            let (allowed, denied) = SystemMetrics.authorized(
                requested, declared: manifest.permissions?.system
            )
            XCTAssertEqual(allowed, requested, "\(name) reads more than it declares")
            XCTAssertTrue(denied.isEmpty, "\(name) is missing \(denied.map(\.rawValue))")
        }
    }

    func testBundledSystemWidgetsNeedNoSubprocess() throws {
        for name in ["system", "sensors"] {
            let (manifest, workflow) = try load(name)
            XCTAssertFalse(
                WidgetDiscovery.manifestRequiresExecPermission(manifest, workflow: workflow),
                "\(name) should not shell out any more"
            )
            XCTAssertTrue(manifest.permissions?.exec?.isEmpty ?? true)
            XCTAssertNil(manifest.permissions?.readPaths)
            XCTAssertNil(manifest.permissions?.network)
        }
    }

    func testBundledSystemWidgetsArePromotableWithAStatusLabel() throws {
        for name in ["system", "sensors"] {
            let (manifest, workflow) = try load(name)
            let statusItem = try XCTUnwrap(manifest.statusItem, name)
            XCTAssertTrue(statusItem.isPromotable, "\(name) should offer a menu-bar value")
            XCTAssertTrue(statusItem.showsLabel, "\(name) should render a label")
            // A label-showing widget with no status template would promote to
            // an empty menu-bar cell.
            XCTAssertNotNil(workflow.status?.label, "\(name) declares no status.label")
            XCTAssertNotNil(workflow.status?.tooltip, "\(name) declares no status.tooltip")
        }
    }

    func testPromotedWidgetsCarryAnIntervalTheMenuBarCanUse() throws {
        for name in ["system", "sensors"] {
            let (manifest, _) = try load(name)
            let interval = try XCTUnwrap(manifest.refresh?.interval, name)
            XCTAssertGreaterThanOrEqual(interval, SchedulePolicy.minMenuBarIntervalSec)
            XCTAssertLessThanOrEqual(interval, 10, "\(name) would look frozen in the menu bar")
        }
    }

    func testPermissionSummaryNamesTheTelemetryGroups() throws {
        let (manifest, workflow) = try load("sensors")
        let summary = WidgetDiscovery.permissionSummary(for: manifest, workflow: workflow)
        XCTAssertEqual(summary, ["system: reads sensors telemetry"])
    }

    func testPermissionSummaryFlagsAWorkflowThatDeclaresNothing() throws {
        let (manifest, workflow) = try load("sensors")
        var stripped = manifest
        stripped.permissions?.system = nil
        XCTAssertEqual(
            WidgetDiscovery.permissionSummary(for: stripped, workflow: workflow),
            ["system: missing required telemetry declaration"]
        )
    }
}
