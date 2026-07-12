import XCTest
@testable import MenubucketCore

/// M1: full manifest v0.1 decoding (statusItem, permissions.exec details,
/// keychain, settings, refresh.watchPaths/runInBackground/deadlineField).
final class ManifestV01Tests: XCTestCase {
    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // MenubucketCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // package root
    }

    func testParsesOtpeekExampleManifest() throws {
        let url = packageRoot.appendingPathComponent("Tests/fixtures/otpeek.widget.json")
        let manifest = try Manifest.decode(from: try Data(contentsOf: url))

        XCTAssertEqual(manifest.id, "dev.barshelf.otpeek")
        XCTAssertEqual(manifest.source?.command, ["otpeek", "list", "--json"])
        XCTAssertEqual(manifest.source?.discover?.first, "$OTPEEK_BIN")
        XCTAssertEqual(manifest.source?.adapter, "otpeek")
        XCTAssertEqual(manifest.statusItem?.mode, "none")
        XCTAssertEqual(manifest.permissions?.keychain, true)

        let exec = try XCTUnwrap(manifest.permissions?.exec?.first)
        XCTAssertEqual(exec.command, "otpeek")
        XCTAssertEqual(exec.allowedArgs, [
            ["list", "--json"],
            ["list", "--folder", "*", "--json"],
            ["code", "*", "--json"],
        ])
        XCTAssertEqual(exec.sensitiveOutput, true)
        XCTAssertEqual(exec.maxOutputBytes, 262_144)
        XCTAssertEqual(exec.env?.contains("OTPEEK_VAULT_PASSWORD"), true)

        // The source command must satisfy the widget's own allowlist.
        XCTAssertTrue(ExecAllowlist.permits(
            command: manifest.source?.command ?? [],
            permissions: manifest.permissions?.exec
        ))
        XCTAssertEqual(manifest.permissions?.network, ["www.google.com"], "favicon fetch host")
        XCTAssertEqual(
            manifest.settings?.compactMap(\.key),
            ["showIcons", "favoritesOnly", "favoritesFirst", "folder"]
        )
    }

    func testParsesAasManifestPermissions() throws {
        let url = packageRoot.appendingPathComponent("Tests/fixtures/aas-usage.widget.json")
        let manifest = try Manifest.decode(from: try Data(contentsOf: url))

        let exec = try XCTUnwrap(manifest.permissions?.exec?.first)
        XCTAssertEqual(exec.command, "aas")
        XCTAssertEqual(exec.allowedArgs, [["usage", "--json"]])
        XCTAssertEqual(exec.sensitiveOutput, false)
        XCTAssertEqual(manifest.permissions?.keychain, false)
        XCTAssertEqual(manifest.permissions?.env, ["AAS_BIN"])
        XCTAssertEqual(manifest.settings, [])
    }

    func testDecodesFullRefreshAndStatusItemAndSettings() throws {
        let json = Data("""
        {
          "schemaVersion": 1,
          "id": "dev.example.full",
          "name": "Full",
          "entry": { "kind": "exec" },
          "refresh": {
            "onOpen": true, "interval": 30, "staleAfterSec": 120,
            "deadlineField": null,
            "watchPaths": ["~/Downloads", "/tmp/flag"],
            "runInBackground": true
          },
          "statusItem": {
            "mode": "dynamic", "icon": "gauge",
            "labelFrom": "statusText", "tooltipFrom": "summary"
          },
          "settings": [
            { "key": "region", "type": "string", "label": "Region", "default": "us-east-1" },
            { "key": "limit", "type": "number", "default": 5 }
          ]
        }
        """.utf8)
        let manifest = try Manifest.decode(from: json)

        XCTAssertEqual(manifest.refresh?.watchPaths, ["~/Downloads", "/tmp/flag"])
        XCTAssertEqual(manifest.refresh?.runInBackground, true)
        XCTAssertNil(manifest.refresh?.deadlineField, "reserved field, null decodes as nil")
        XCTAssertEqual(manifest.statusItem?.mode, "dynamic")
        XCTAssertEqual(manifest.statusItem?.labelFrom, "statusText")
        XCTAssertEqual(manifest.settings?.count, 2)
        XCTAssertEqual(manifest.settings?[0].defaultValue, .string("us-east-1"))
        XCTAssertEqual(manifest.settings?[1].defaultValue, .number(5))
    }

    func testUnsupportedEntryKindsStillDecode() throws {
        for kind in ["script", "workflow", "builtin"] {
            let json = Data("""
            { "schemaVersion": 1, "id": "dev.example.\(kind)", "name": "X",
              "entry": { "kind": "\(kind)" } }
            """.utf8)
            let manifest = try Manifest.decode(from: json)
            XCTAssertEqual(manifest.entry.kind, kind, "kind \(kind) must decode (M1 shows an error card)")
        }
    }

    func testManifestRoundTripsThroughCodable() throws {
        let manifest = Manifest(
            schemaVersion: 1,
            id: "dev.example.rt",
            name: "RoundTrip",
            entry: .init(kind: "exec"),
            refresh: .init(onOpen: true, interval: 10, watchPaths: ["/tmp"], runInBackground: true),
            statusItem: .init(mode: "none"),
            permissions: .init(
                exec: [.init(command: "x", allowedArgs: [["a", "*"]], env: ["X_BIN"], sensitiveOutput: true)],
                env: ["X_BIN"],
                keychain: true
            ),
            settings: [.init(key: "k", type: "bool", defaultValue: .bool(true))]
        )
        let data = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(Manifest.self, from: data)
        XCTAssertEqual(decoded, manifest)
    }
}
