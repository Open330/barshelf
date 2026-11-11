import XCTest
@testable import MenubucketCore

final class TendWatchManifestTests: XCTestCase {
    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testManifestAllowsOnlyTheExpectedLocalAndSSHStatusCommands() throws {
        let manifestURL = packageRoot.appendingPathComponent("Tests/fixtures/tend-watch.widget.json")
        let manifest = try Manifest.decode(from: Data(contentsOf: manifestURL))
        let permissions = try XCTUnwrap(manifest.permissions?.exec)

        XCTAssertTrue(ExecAllowlist.permits(
            command: ["tend", "status", "--json"],
            permissions: permissions
        ))
        XCTAssertTrue(ExecAllowlist.permits(
            command: [
                "ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=3", "--",
                "jiun-mini", "tend", "status", "--json",
            ],
            permissions: permissions
        ))

        XCTAssertFalse(ExecAllowlist.permits(
            command: ["ssh", "jiun-mini", "tend", "watch"],
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

    func testManifestExposesOneSourcePerInstanceSettings() throws {
        let manifestURL = packageRoot.appendingPathComponent("Tests/fixtures/tend-watch.widget.json")
        let manifest = try Manifest.decode(from: Data(contentsOf: manifestURL))
        let settings = Dictionary(uniqueKeysWithValues: (manifest.settings ?? []).compactMap {
            setting in setting.key.map { ($0, setting) }
        })

        XCTAssertEqual(settings["sshHost"]?.defaultValue, .string(""))
        XCTAssertNil(settings["includeLocal"])
        XCTAssertNil(settings["sshHosts"])
        XCTAssertEqual(settings["maxAgents"]?.max, 10)
    }
}
