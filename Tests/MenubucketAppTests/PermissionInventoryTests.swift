import XCTest
@testable import MenubucketApp
import MenubucketCore

final class PermissionInventoryTests: XCTestCase {
    private func manifest(_ id: String, _ permissions: String) throws -> Manifest {
        try Manifest.decode(from: Data("""
        { "schemaVersion": 1, "id": "\(id)", "name": "\(id)", "entry": { "kind": "workflow" },
          "permissions": \(permissions) }
        """.utf8))
    }

    func testGroupsByCapabilityWithEachWidgetOnce() throws {
        let a = try manifest("a", #"{"exec":[{"command":"/bin/date"},{"command":"/bin/date","allowedArgs":[["-u"]]}],"readPaths":["~/Downloads"],"notifications":true}"#)
        let b = try manifest("b", #"{"exec":[{"command":"/usr/bin/git"}],"readPaths":["~/Downloads"],"network":["api.github.com"]}"#)
        let groups = PermissionInventory.build([
            .init(id: "a", name: "Alpha", manifest: a, state: .allowed),
            .init(id: "b", name: "Beta", manifest: b, state: .notAsked),
        ])
        XCTAssertEqual(groups.map(\.kind), [.commands, .network, .files, .notifications])
        let commands = try XCTUnwrap(groups.first { $0.kind == .commands })
        XCTAssertEqual(commands.entries.map(\.detail), ["/bin/date", "/usr/bin/git"])
        XCTAssertEqual(commands.entries[0].widgets.map(\.name), ["Alpha"], "two entries for one command list the widget once")
        let files = try XCTUnwrap(groups.first { $0.kind == .files })
        XCTAssertEqual(files.entries.first?.widgets.map(\.name), ["Alpha", "Beta"])
        XCTAssertEqual(files.widgetCount, 2)
        XCTAssertEqual(files.entries.first?.widgets.last?.state, .notAsked)
    }

    /// No approval is not no access: System reads telemetry and may quit
    /// apps (asking each time) without an approval card, and still shows.
    func testWidgetsThatNeedNoApprovalAreListedToo() throws {
        let system = try manifest("system", #"{"system":["cpu","memory"],"quitApps":true}"#)
        let groups = PermissionInventory.build([.init(id: "system", name: "System", manifest: system, state: .notNeeded)])
        XCTAssertEqual(groups.map(\.kind), [.quitApps, .system])
    }

    /// Privacy ▸ Allowed ▸ By Capability lists what is in effect: a waiting
    /// or denied request is not access, and no-approval access still is.
    func testInEffectLeavesOutWaitingAndDeniedRequests() throws {
        let allowed = try manifest("a", #"{"network":["api.example.com"]}"#)
        let waiting = try manifest("w", #"{"vault":{"provider":"bitwarden"},"network":["evil.example"]}"#)
        let denied = try manifest("d", #"{"readPaths":["~/Documents"]}"#)
        let free = try manifest("s", #"{"system":["cpu"]}"#)
        let groups = PermissionInventory.inEffect([
            .init(id: "a", name: "Allowed", manifest: allowed, state: .allowed),
            .init(id: "w", name: "Waiting", manifest: waiting, state: .notAsked),
            .init(id: "d", name: "Denied", manifest: denied, state: .denied),
            .init(id: "s", name: "System", manifest: free, state: .notNeeded),
        ])
        let names = Set(groups.flatMap(\.entries).flatMap(\.widgets).map(\.name))
        XCTAssertEqual(names, ["Allowed", "System"])
        XCTAssertFalse(groups.flatMap(\.entries).map(\.detail).contains("evil.example"))
    }

    func testNothingDeclaredMeansNoGroups() throws {
        let plain = try manifest("plain", "{}")
        XCTAssertTrue(PermissionInventory.build([.init(id: "plain", name: "Plain", manifest: plain, state: .notNeeded)]).isEmpty)
    }
}
