import XCTest
@testable import MenubucketCore

/// What a widget author can say about its desktop widget (0.6.1), and the
/// refresh button's request files.
final class DesktopHintsTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    func testMarkedItemsAreTheOnlyItems() throws {
        let tree = try decode(UINode.self, """
        {"type": "vstack", "children": [
          {"type": "text", "text": "Header that is not an item"},
          {"type": "section", "title": "Disks", "children": [
            {"type": "hstack", "desktopRole": "item", "children": [
              {"type": "text", "text": "Macintosh HD"}, {"type": "text", "text": "61%"}]},
            {"type": "hstack", "desktopRole": "item", "children": [
              {"type": "text", "text": "Backup"}, {"type": "text", "text": "12%"}]}]},
          {"type": "card", "title": "Not marked"}]}
        """)
        let parts = SharedShelf.parts(of: tree)
        XCTAssertEqual(parts.map(\.title), ["Macintosh HD", "Backup"])
        XCTAssertEqual(parts.map(\.group), ["Disks", "Disks"])
    }

    func testHiddenNodesAreLeftOutAndNotShared() throws {
        let tree = try decode(UINode.self, """
        {"type": "vstack", "children": [
          {"type": "card", "title": "Shown"},
          {"type": "card", "title": "Private", "desktopRole": "hide"}]}
        """)
        XCTAssertEqual(SharedShelf.parts(of: tree).map(\.title), ["Shown"])
        let encoded = String(decoding: try JSONEncoder().encode(SharedShelf.scrubbed(tree)), as: UTF8.self)
        XCTAssertFalse(encoded.contains("Private"))
    }

    func testAuthorRolesOutrankTheGuess() throws {
        let tree = try decode(UINode.self, """
        {"type": "vstack", "children": [
          {"type": "text", "text": "Sensors", "role": "caption"},
          {"type": "text", "text": "CPU", "desktopRole": "title"},
          {"type": "text", "text": "41°", "size": 12, "desktopRole": "value"},
          {"type": "text", "text": "fan 1200 rpm", "size": 24},
          {"type": "text", "text": "8 cores", "desktopRole": "detail"}]}
        """)
        let summary = SharedShelf.summarize(tree)
        XCTAssertEqual(summary.title, "CPU")
        XCTAssertEqual(summary.value, "41°")
        XCTAssertEqual(summary.detail, "8 cores")
    }

    func testTheManifestDesktopBlockIsLenient() throws {
        let good = try decode(Manifest.Desktop.self, #"{"style": "meters", "offer": false}"#)
        XCTAssertEqual(good, Manifest.Desktop(style: "meters", offer: false))
        // Wrong types are dropped, not a reason to refuse the widget.
        XCTAssertEqual(try decode(Manifest.Desktop.self, #"{"style": 3, "offer": "no"}"#), Manifest.Desktop())
        XCTAssertEqual(try decode(Manifest.Desktop.self, #""meters""#), Manifest.Desktop())
    }

    func testRefreshRequestsAreReadOnceAndLapse() throws {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: container) }
        let now = Date(timeIntervalSince1970: 1_000_000)
        try SharedShelf.requestRefresh(widgetID: "dev.barshelf.system", in: container, now: now)
        try SharedShelf.requestRefresh(widgetID: "../escape", in: container, now: now)
        XCTAssertEqual(SharedShelf.pendingRefreshRequests(in: container, now: now).keys.sorted(), ["dev.barshelf.system"])
        // Past its lifetime a request is gone, file and all.
        let later = now.addingTimeInterval(SharedShelf.refreshRequestLifetime + 1)
        XCTAssertTrue(SharedShelf.pendingRefreshRequests(in: container, now: later).isEmpty)
        XCTAssertTrue(SharedShelf.pendingRefreshRequests(in: container, now: now).isEmpty)

        try SharedShelf.requestRefresh(widgetID: "dev.barshelf.system", in: container, now: now)
        SharedShelf.clearRefreshRequest(widgetID: "dev.barshelf.system", in: container)
        XCTAssertTrue(SharedShelf.pendingRefreshRequests(in: container, now: now).isEmpty)
    }
}
