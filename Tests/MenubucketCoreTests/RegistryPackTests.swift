import XCTest
@testable import MenubucketCore

final class RegistryPackTests: XCTestCase {
    private func doc(_ packs: String) -> String {
        """
        {"schemaVersion":1,"widgets":[
          {"id":"a","name":"A","install":{"url":"https://example.com/a"}},
          {"id":"b","name":"B","install":{"url":"https://example.com/b"}}
        ]\(packs)}
        """
    }

    func testIndexWithoutPacksStillParses() throws {
        let (index, warnings) = try RegistryIndex.parse(Data(doc("").utf8))
        XCTAssertEqual(index.widgets.count, 2)
        XCTAssertTrue(index.packs.isEmpty)
        XCTAssertTrue(warnings.isEmpty)
    }

    func testPacksKeepOnlyListedWidgetsInOrderOnce() throws {
        let (index, warnings) = try RegistryIndex.parse(Data(doc(#","packs":[{"id":"dev","name":"Developer","widgetIDs":["b","zzz","a","b"]}]"#).utf8))
        XCTAssertEqual(index.packs.map(\.widgetIDs), [["b", "a"]])
        XCTAssertTrue(warnings.contains { $0.contains("zzz") })
    }

    /// One bad pack, or packs of the wrong shape, never cost the widgets.
    func testMalformedPacksAreSkipped() throws {
        let packs = #","packs":[42,{"id":"","name":"x","widgetIDs":["a"]},{"id":"e","name":"E","widgetIDs":["nope"]},{"id":"ok","name":"OK","widgetIDs":["a"]},{"id":"ok","name":"Again","widgetIDs":["b"]}]"#
        let (index, warnings) = try RegistryIndex.parse(Data(doc(packs).utf8))
        XCTAssertEqual(index.widgets.count, 2)
        XCTAssertEqual(index.packs.map(\.id), ["ok"])
        XCTAssertGreaterThanOrEqual(warnings.count, 4)
        let (notList, listWarnings) = try RegistryIndex.parse(Data(doc(#","packs":{"x":1}"#).utf8))
        XCTAssertEqual(notList.widgets.count, 2)
        XCTAssertTrue(notList.packs.isEmpty)
        XCTAssertFalse(listWarnings.isEmpty)
    }
}
