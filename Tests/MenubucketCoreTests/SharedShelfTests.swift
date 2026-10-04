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

    private func text(_ value: String) -> UINode { UINode(type: "text", text: value) }

    /// Usage-meter shape: sections in a list, one card per account.
    func testCardsInSectionsInAListBecomeParts() {
        let tree = UINode(type: "vstack", children: [
            UINode(type: "hstack", children: [text("aas"), text("0% left")]),
            UINode(type: "list", items: [
                UINode(type: "section", children: [
                    UINode(type: "card", children: [text("work@claude"), text("97% left")]),
                    UINode(type: "card", children: [text("home@claude"), text("40% left")]),
                ], title: "Claude"),
                UINode(type: "section", children: [
                    UINode(type: "card", children: [text("team@codex")]),
                ], title: "Codex"),
            ]),
        ])
        let parts = SharedShelf.parts(of: tree)
        XCTAssertEqual(parts.map(\.title), ["Claude", "work@claude", "home@claude", "Codex", "team@codex"])
        XCTAssertEqual(parts[1].group, "Claude")
        XCTAssertEqual(parts[4].group, "Codex")
        // Sections hold the cards, so an automatic pick skips them.
        XCTAssertEqual(parts.filter(\.isGroup).map(\.title), ["Claude", "Codex"])
    }

    /// System-monitor shape: no cards, so each label-and-reading row is one.
    func testPlainRowsBecomePartsWhenThereIsNoStructure() {
        let tree = UINode(type: "vstack", children: [
            UINode(type: "hstack", children: [UINode(type: "spacer"), text("2.25")]),
            UINode(type: "vstack", children: [
                UINode(type: "hstack", children: [text("CPU"), text("15%")]),
                UINode(type: "progress", value: 0.15),
            ]),
            UINode(type: "hstack", children: [text("Memory"), text("65%")]),
        ])
        XCTAssertEqual(SharedShelf.parts(of: tree).map(\.title), ["CPU", "Memory"])
    }

    /// Keys stay the same from one refresh to the next, so a user's choice
    /// survives; duplicates are told apart.
    func testPartKeysAreStableAndUnique() {
        let tree = UINode(type: "list", items: [text("Same"), text("Same"), UINode(id: "x", type: "text", text: "Other")])
        let keys = SharedShelf.parts(of: tree).map(\.key)
        XCTAssertEqual(keys, ["/Same", "/Same#2", "id:x"])
        XCTAssertEqual(SharedShelf.parts(of: tree).map(\.key), keys)
    }

    /// A snapshot written before parts existed still reads.
    func testSnapshotsWithoutPartsStillDecode() throws {
        let json = #"{"widgetID":"a","name":"A"}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(SharedShelf.Snapshot.self, from: Data(json.utf8))
        XCTAssertEqual(snapshot.parts, [])
        XCTAssertNil(snapshot.statusLabel)
    }
}
