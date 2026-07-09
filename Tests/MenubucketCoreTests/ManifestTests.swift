import XCTest
@testable import MenubucketCore

final class ManifestTests: XCTestCase {
    /// Package root, derived from this test file's location.
    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // MenubucketCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // package root
    }

    func testParsesAasUsageExampleManifest() throws {
        let url = packageRoot
            .appendingPathComponent("widgets/aas-usage/widget.json")
        let data = try Data(contentsOf: url)
        let manifest = try Manifest.decode(from: data)

        XCTAssertEqual(manifest.schemaVersion, 1)
        XCTAssertEqual(manifest.id, "dev.barshelf.aas-usage")
        XCTAssertEqual(manifest.name, "aas Usage")
        XCTAssertEqual(manifest.icon, "gauge")
        XCTAssertEqual(manifest.bucket?.group, "Agents")
        XCTAssertEqual(manifest.bucket?.order, 20)
        XCTAssertEqual(manifest.bucket?.size, "M")
        XCTAssertEqual(manifest.entry.kind, "exec")
        XCTAssertEqual(manifest.source?.command, ["aas", "usage", "--json"])
        XCTAssertEqual(manifest.source?.discover?.first, "$AAS_BIN")
        XCTAssertEqual(manifest.source?.discover?.last, "PATH")
        XCTAssertEqual(manifest.source?.timeoutMs, 25000)
        XCTAssertEqual(manifest.source?.output, "data")
        XCTAssertEqual(manifest.source?.adapter, "aas-usage")
        XCTAssertEqual(manifest.refresh?.onOpen, true)
        XCTAssertNil(manifest.refresh?.interval, "\"interval\": null must decode as nil")
        XCTAssertEqual(manifest.refresh?.staleAfterSec, 600)
    }

    func testParsesHelloExampleManifest() throws {
        let url = packageRoot
            .appendingPathComponent("widgets/hello/widget.json")
        let data = try Data(contentsOf: url)
        let manifest = try Manifest.decode(from: data)

        XCTAssertEqual(manifest.id, "dev.barshelf.hello")
        XCTAssertEqual(manifest.bucket?.group, "Demo")
        XCTAssertEqual(manifest.bucket?.order, 10)
        XCTAssertEqual(manifest.bucket?.size, "S")
        XCTAssertEqual(manifest.source?.command, ["./hello.sh"])
        XCTAssertEqual(manifest.source?.output, "viewtree")
        XCTAssertNil(manifest.source?.adapter)
        XCTAssertEqual(manifest.refresh?.interval, 60)
    }

    func testToleratesPermissionsSettingsAndUnknownFields() throws {
        // M0 decodes only its subset; full v0.1 manifests (permissions, settings,
        // statusItem, future keys) must not fail to parse.
        let json = """
        {
          "schemaVersion": 1,
          "id": "dev.example.full",
          "name": "Full",
          "entry": { "kind": "exec" },
          "source": { "kind": "exec", "command": ["true"], "output": "viewtree" },
          "refresh": { "onOpen": true, "interval": null, "staleAfterSec": 60,
                       "deadlineField": null, "watchPaths": [], "runInBackground": false },
          "statusItem": { "mode": "none" },
          "permissions": {
            "exec": [{ "command": "true", "allowedArgs": [[]], "maxOutputBytes": 1048576 }],
            "network": [], "readPaths": [], "env": [], "keychain": false
          },
          "settings": [{ "key": "theme", "type": "string", "default": "auto" }],
          "someFutureKey": { "nested": true }
        }
        """.data(using: .utf8)!

        let manifest = try Manifest.decode(from: json)
        XCTAssertEqual(manifest.id, "dev.example.full")
        XCTAssertEqual(manifest.refresh?.staleAfterSec, 60)
    }

    func testMissingRequiredFieldFails() {
        let json = """
        { "schemaVersion": 1, "name": "No ID", "entry": { "kind": "exec" } }
        """.data(using: .utf8)!
        XCTAssertThrowsError(try Manifest.decode(from: json))
    }

    func testStoragePermissionAcceptsBoolAndObjectShapes() throws {
        func permission(_ storageJSON: String) throws -> Manifest.StoragePermission? {
            let json = """
            { "schemaVersion": 1, "id": "dev.example.s", "name": "S",
              "entry": { "kind": "workflow" },
              "source": { "kind": "workflow" },
              "permissions": { "storage": \(storageJSON) } }
            """.data(using: .utf8)!
            return try Manifest.decode(from: json).permissions?.storage
        }

        // Original script convention: bool.
        XCTAssertEqual(try permission("true"), .init(granted: true))
        XCTAssertEqual(try permission("false"), .init(granted: false))
        // Object form with a byte cap.
        let object = try permission("{ \"maxBytes\": 4096 }")
        XCTAssertEqual(object?.maxBytes, 4096)
        XCTAssertEqual(object?.granted, true)
        // Round-trips: bool grant stays a bool, object stays an object.
        let boolData = try JSONEncoder().encode(Manifest.StoragePermission(granted: true))
        XCTAssertEqual(String(data: boolData, encoding: .utf8), "true")
    }
}
