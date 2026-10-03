import XCTest
@testable import MenubucketCore

final class SharedShelfTests: XCTestCase {
    private var container: URL!

    override func setUpWithError() throws {
        container = FileManager.default.temporaryDirectory
            .appendingPathComponent("shared-shelf-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: container)
    }

    func testIndexAndSnapshotsRoundTrip() throws {
        let index = SharedShelf.Index(entries: [
            .init(id: "dev.barshelf.battery", name: "Battery", icon: "battery.100percent", accent: "green", page: "System"),
        ])
        try SharedShelf.writeIndex(index, to: container)
        XCTAssertEqual(SharedShelf.readIndex(from: container), index)

        let snapshot = SharedShelf.Snapshot(
            widgetID: "dev.barshelf.battery", name: "Battery",
            viewTree: UINode(type: "text", text: "80%"),
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        try SharedShelf.writeSnapshot(snapshot, to: container)
        XCTAssertEqual(SharedShelf.readSnapshot(widgetID: "dev.barshelf.battery", from: container), snapshot)
    }

    /// A widget id becomes a file name; nothing may leave the folder.
    func testOnlyPlainWidgetIDsBecomeFileNames() {
        XCTAssertEqual(SharedShelf.snapshotFileName(for: "dev.barshelf.muxa-watch--jiun-mbp"), "dev.barshelf.muxa-watch--jiun-mbp.json")
        for bad in ["", ".", "..", "../etc", "a/b", ".hidden", "x y", String(repeating: "a", count: 300)] {
            XCTAssertNil(SharedShelf.snapshotFileName(for: bad), bad)
        }
    }

    /// A widget that was uninstalled, or that turned out to be sensitive,
    /// leaves nothing behind.
    func testPruningRemovesSnapshotsNoLongerOffered() throws {
        for id in ["keep.one", "drop.one"] {
            try SharedShelf.writeSnapshot(.init(widgetID: id, name: id), to: container)
        }
        SharedShelf.pruneSnapshots(keeping: ["keep.one"], in: container)
        XCTAssertNotNil(SharedShelf.readSnapshot(widgetID: "keep.one", from: container))
        XCTAssertNil(SharedShelf.readSnapshot(widgetID: "drop.one", from: container))
    }

    /// Placed widgets are bound to the kind and the group; renaming either
    /// strands every widget a user has placed.
    func testTheKindAndGroupNeverChange() {
        XCTAssertEqual(SharedShelf.widgetKind, "com.barshelf.app.shelf-widget")
        XCTAssertEqual(SharedShelf.appGroupID, "728FW73BS8.com.barshelf.shared")
    }
}
