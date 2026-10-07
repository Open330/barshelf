import XCTest
import MenubucketCore
@testable import MenubucketApp

final class SharedShelfPublisherTests: XCTestCase {
    /// macOS budgets widget reloads; changes inside 15 minutes wait.
    func testReloadsAreAtLeastFifteenMinutesApart() {
        let now = Date()
        XCTAssertEqual(SharedShelfPublisher.reloadDelay(lastReload: nil, now: now), 0)
        XCTAssertEqual(SharedShelfPublisher.reloadDelay(lastReload: now.addingTimeInterval(-60), now: now), 14 * 60, accuracy: 0.001)
        XCTAssertEqual(SharedShelfPublisher.reloadDelay(lastReload: now.addingTimeInterval(-3600), now: now), 0)
    }

    /// A test or dev build without the App Group writes nothing, so macOS
    /// never asks the user about another app's data.
    func testAnUnentitledBuildPublishesNothing() {
        let publisher = SharedShelfPublisher(container: nil)
        XCTAssertFalse(publisher.isEnabled)
        publisher.publishIndex([.init(id: "a", name: "A")])
        publisher.withdraw(widgetID: "a")
        XCTAssertNil(SharedShelfPublisher.entitledContainer(), "the test runner has no App Group entitlement")
    }

    func testTheBuildSignsTheExtensionBeforeTheAppAndNeverDeep() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let script = try String(contentsOf: root.appendingPathComponent("scripts/build_app.sh"), encoding: .utf8)
        let ext = try XCTUnwrap(script.range(of: #"sign_code "${WIDGET_EXTENSION_PATH}""#))
        let app = try XCTUnwrap(script.range(of: #"sign_code "${APP_BUNDLE_PATH}" "${HOST_ENTITLEMENTS}""#))
        XCTAssertTrue(ext.upperBound < app.lowerBound, "the extension is signed before the app around it")
        let developerIDPath = script[ext.lowerBound..<app.upperBound]
        XCTAssertFalse(developerIDPath.contains("--deep"))
    }

    /// A file tile as Stashbar draws it: its path is in the id, the image,
    /// the open action, and the drag payload.
    private func fileTileSnapshot(path: String) throws -> SharedShelf.Snapshot {
        let json = """
        {"type": "grid", "items": [{"type": "vstack", "id": "tile-\(path)",
          "action": {"type": "openFile", "path": "\(path)"}, "drag": {"filePath": "\(path)"},
          "children": [{"type": "image", "size": 52, "source": {"kind": "fileThumbnail", "path": "\(path)"}},
                       {"type": "text", "role": "caption", "text": "a.png"}]}]}
        """
        let tree = try JSONDecoder().decode(UINode.self, from: Data(json.utf8))
        return SharedShelf.Snapshot(widgetID: "files", name: "Files", viewTree: tree, updatedAt: Date())
    }

    func testNoLocalPathReachesTheSharedFolder() throws {
        let snapshot = try fileTileSnapshot(path: "/Users/someone/Secret/a.png")
        XCTAssertEqual(SharedShelfPublisher.imagePaths(in: snapshot), ["/Users/someone/Secret/a.png"])
        let shared = SharedShelfPublisher.sharing(snapshot, thumbnails: ["/Users/someone/Secret/a.png": "x.png"])
        let encoded = String(decoding: try JSONEncoder().encode(shared), as: UTF8.self)
        XCTAssertFalse(encoded.contains("Secret"), encoded)
        XCTAssertEqual(shared.parts.first?.summary?.thumbnail, "x.png")
    }

    /// A widget withdrawn while its thumbnails are being made stays out.
    @MainActor
    func testAWithdrawnWidgetIsNotWrittenBackByALateExport() async throws {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: container) }
        let image = container.appendingPathComponent("a.png")
        try Data("not really a picture".utf8).write(to: image)

        let publisher = SharedShelfPublisher(container: container)
        publisher.publishIndex([.init(id: "files", name: "Files")])
        publisher.publish(try fileTileSnapshot(path: image.path))
        publisher.withdraw(widgetID: "files")
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertNil(SharedShelf.readSnapshot(widgetID: "files", from: container))
    }

    @MainActor
    func testAnExportThatFinishesWritesTheSnapshotWithItsThumbnail() async throws {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: container) }
        let image = container.appendingPathComponent("a.png")
        try Data("not really a picture".utf8).write(to: image)

        let publisher = SharedShelfPublisher(container: container)
        publisher.publishIndex([.init(id: "files", name: "Files")])
        publisher.publish(try fileTileSnapshot(path: image.path))
        var shared: SharedShelf.Snapshot?
        for _ in 0..<50 where shared == nil {
            try await Task.sleep(nanoseconds: 100_000_000)
            shared = SharedShelf.readSnapshot(widgetID: "files", from: container)
        }
        let thumbnail = try XCTUnwrap(shared?.parts.first?.summary?.thumbnail)
        let folder = try XCTUnwrap(SharedShelf.imagesDirectory(for: "files", in: container))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent(thumbnail).path))
    }

    /// The refresh button on the desktop: the request reaches the runtime
    /// once, the answer is written at once, and the request is cleared.
    @MainActor
    func testADesktopRefreshRequestIsAnsweredAndCleared() throws {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: container) }
        let publisher = SharedShelfPublisher(container: container)
        publisher.publishIndex([.init(id: "sys", name: "System")])
        var asked: [String] = []
        publisher.onRefreshRequest = { asked.append($0) }

        try SharedShelf.requestRefresh(widgetID: "sys", in: container)
        try SharedShelf.requestRefresh(widgetID: "not-offered", in: container)
        publisher.takeRefreshRequests()
        publisher.takeRefreshRequests()
        XCTAssertEqual(asked, ["sys"], "once per request, and only for offered widgets")
        XCTAssertTrue(publisher.isAnswering("sys"))

        publisher.publish(SharedShelf.Snapshot(widgetID: "sys", name: "System", viewTree: UINode(type: "text", text: "CPU 3%")))
        XCTAssertFalse(publisher.isAnswering("sys"))
        XCTAssertNotNil(SharedShelf.readSnapshot(widgetID: "sys", from: container))
        XCTAssertTrue(SharedShelf.pendingRefreshRequests(in: container).isEmpty)
    }
}
