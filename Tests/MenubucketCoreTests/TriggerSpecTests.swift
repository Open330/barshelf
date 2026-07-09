import XCTest
@testable import MenubucketCore

final class TriggerSpecTests: XCTestCase {
    private func manifest(triggersJSON: String) throws -> Manifest {
        let json = """
        {
          "schemaVersion": 1,
          "id": "dev.test.triggers",
          "name": "Triggers",
          "entry": { "kind": "workflow" },
          "refresh": { "triggers": \(triggersJSON) }
        }
        """
        return try Manifest.decode(from: Data(json.utf8))
    }

    func testDecodesMixedStringsAndObjects() throws {
        let manifest = try manifest(
            triggersJSON: #"["wake", "popup-open", {"fs": "~/Downloads"}, "url"]"#
        )
        XCTAssertEqual(
            manifest.refresh?.triggers,
            [.wake, .popupOpen, .fs(path: "~/Downloads"), .url]
        )
    }

    func testDropsUnrecognizedEntriesLeniently() throws {
        let manifest = try manifest(
            triggersJSON: #"["wake", "nonsense", 42, {"unknown": "x"}, {"fs": "  "}, "url"]"#
        )
        // Unknown strings, non-string/object values, unknown object keys, and
        // an empty fs path are all dropped without failing the decode.
        XCTAssertEqual(manifest.refresh?.triggers, [.wake, .url])
    }

    func testAbsentTriggersDecodeToNil() throws {
        let json = """
        { "schemaVersion": 1, "id": "x", "name": "X",
          "entry": { "kind": "workflow" }, "refresh": { "interval": 60 } }
        """
        let manifest = try Manifest.decode(from: Data(json.utf8))
        XCTAssertNil(manifest.refresh?.triggers)
        XCTAssertEqual(manifest.refresh?.interval, 60)
    }

    func testManifestWithoutRefreshStaysBackwardCompatible() throws {
        let json = """
        { "schemaVersion": 1, "id": "x", "name": "X", "entry": { "kind": "exec" } }
        """
        let manifest = try Manifest.decode(from: Data(json.utf8))
        XCTAssertNil(manifest.refresh)
    }

    func testTriggersRoundTripThroughEncoder() throws {
        let original = try manifest(
            triggersJSON: #"["wake", "popup-open", {"fs": "~/Downloads"}, "url"]"#
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try Manifest.decode(from: data)
        XCTAssertEqual(decoded.refresh?.triggers, original.refresh?.triggers)
    }

    func testJSONParseHelpers() {
        XCTAssertEqual(TriggerSpec(json: .string("wake")), .wake)
        XCTAssertEqual(TriggerSpec(json: .string("popupOpen")), .popupOpen)
        XCTAssertEqual(TriggerSpec(json: .string("open")), .popupOpen)
        XCTAssertNil(TriggerSpec(json: .string("bogus")))
        XCTAssertNil(TriggerSpec(json: .number(1)))
        XCTAssertEqual(TriggerSpec(json: .object(["fs": .string("/tmp")])), .fs(path: "/tmp"))
    }
}
