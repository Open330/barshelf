import XCTest
@testable import MenubucketCore

final class MuxaWatchManifestTests: XCTestCase {
    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testManifestAllowsOnlyTheExpectedLocalAndSSHStatusCommands() throws {
        let manifestURL = packageRoot.appendingPathComponent("widgets/muxa-watch/widget.json")
        let manifest = try Manifest.decode(from: Data(contentsOf: manifestURL))
        let permissions = try XCTUnwrap(manifest.permissions?.exec)

        XCTAssertTrue(ExecAllowlist.permits(
            command: ["muxa", "status", "--json"],
            permissions: permissions
        ))
        XCTAssertTrue(ExecAllowlist.permits(
            command: [
                "ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=3", "--",
                "jiun-mini", "muxa", "status", "--json",
            ],
            permissions: permissions
        ))

        XCTAssertFalse(ExecAllowlist.permits(
            command: ["ssh", "jiun-mini", "muxa", "watch"],
            permissions: permissions
        ))
        XCTAssertFalse(ExecAllowlist.permits(
            command: [
                "ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=3", "--",
                "jiun-mini", "sh", "-c", "anything",
            ],
            permissions: permissions
        ))
    }

    func testManifestExposesMultiHostSettings() throws {
        let manifestURL = packageRoot.appendingPathComponent("widgets/muxa-watch/widget.json")
        let manifest = try Manifest.decode(from: Data(contentsOf: manifestURL))
        let settings = Dictionary(uniqueKeysWithValues: (manifest.settings ?? []).compactMap {
            setting in setting.key.map { ($0, setting) }
        })

        XCTAssertEqual(settings["includeLocal"]?.defaultValue, .bool(true))
        XCTAssertEqual(settings["sshHosts"]?.defaultValue, .string(""))
        XCTAssertEqual(settings["maxAgents"]?.max, 10)
    }
}
