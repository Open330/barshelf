import XCTest
import MenubucketCore
@testable import MenubucketApp

final class SharedShelfPublisherTests: XCTestCase {
    @MainActor
    func testAnOldTimeoutCannotClearANewerRefreshRequest() throws {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: container) }
        var timeouts: [() -> Void] = []
        let publisher = SharedShelfPublisher(container: container, reload: {},
            scheduleRefreshTimeout: { timeouts.append($0) })
        publisher.publishIndex([.init(id: "sys", name: "System")])
        try SharedShelf.requestRefresh(widgetID: "sys", in: container)
        publisher.takeRefreshRequests()
        publisher.publish(.init(widgetID: "sys", name: "System"))
        try SharedShelf.requestRefresh(widgetID: "sys", in: container)
        publisher.takeRefreshRequests()
        XCTAssertEqual(timeouts.count, 2)
        timeouts[0]()
        XCTAssertTrue(publisher.isAnswering("sys"))
        XCTAssertNotNil(SharedShelf.pendingRefreshRequests(in: container)["sys"])
        timeouts[1]()
        XCTAssertFalse(publisher.isAnswering("sys"))
        XCTAssertNil(SharedShelf.pendingRefreshRequests(in: container)["sys"])
    }

    @MainActor
    func testRemovingFinalEntryReloadsImmediatelyAndRejectsLateRepublish() throws {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: container) }
        var reloads = 0
        let publisher = SharedShelfPublisher(container: container, reload: { reloads += 1 })
        publisher.publishIndex([.init(id: "private", name: "Private")])
        publisher.publish(.init(widgetID: "private", name: "Private", viewTree: UINode(type: "text", text: "old reading")))
        try SharedShelf.requestRefresh(widgetID: "private", in: container)
        publisher.publishIndex([])
        XCTAssertEqual(reloads, 1, "index pruning must not wait for another snapshot to invalidate WidgetKit")
        XCTAssertNil(SharedShelf.readSnapshot(widgetID: "private", from: container))
        XCTAssertTrue(SharedShelf.pendingRefreshRequests(in: container).isEmpty)
        publisher.publish(.init(widgetID: "private", name: "Private", viewTree: UINode(type: "text", text: "late reading")))
        XCTAssertNil(SharedShelf.readSnapshot(widgetID: "private", from: container))
    }

    /// With no BarShelf widget on the desktop nothing is written or
    /// reloaded; the first one placed gets the held readings at once.
    @MainActor
    func testNothingIsWrittenUntilADesktopWidgetIsPlaced() throws {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: container) }
        var reloads = 0
        var answer: ((Int?) -> Void)?
        var probes = 0
        let publisher = SharedShelfPublisher(container: container, reload: { reloads += 1 },
            placementProbe: { probes += 1; answer = $0 })
        publisher.publishIndex([.init(id: "sys", name: "System")])
        let start = Date()
        publisher.publish(.init(widgetID: "sys", name: "System", viewTree: UINode(type: "text", text: "1")), now: start)
        answer?(0)
        reloads = 0
        for second in 1...20 {
            publisher.publish(.init(widgetID: "sys", name: "System", viewTree: UINode(type: "text", text: "\(second)")),
                              now: start.addingTimeInterval(Double(second) * 30))
        }
        XCTAssertEqual(probes, 2, "asked again after five minutes, not on every render")
        answer?(0)
        XCTAssertEqual(reloads, 0)
        // The first render went out before the first answer; the rest were held.
        XCTAssertEqual(SharedShelf.readSnapshot(widgetID: "sys", from: container)?.viewTree?.text, "1")

        // Asked again on a timer too, in case no further render comes.
        XCTAssertTrue(publisher.isWaitingToAskAgain)

        publisher.placementChanged(to: 1)
        XCTAssertEqual(SharedShelf.readSnapshot(widgetID: "sys", from: container)?.viewTree?.text, "20")
        XCTAssertEqual(reloads, 1)
        XCTAssertFalse(publisher.isWaitingToAskAgain)
    }

    /// A reading that did not change is not written again, until the copy
    /// on the desktop would soon read as old.
    @MainActor
    func testAnUnchangedReadingIsWrittenOnlyBeforeItTurnsStale() throws {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: container) }
        let publisher = SharedShelfPublisher(container: container, reload: {}, placementProbe: nil)
        publisher.publishIndex([.init(id: "sys", name: "System")])
        // Whole seconds: the shared file keeps dates to the second.
        let start = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        func render(at offset: TimeInterval, text: String = "same") -> SharedShelf.Snapshot {
            let date = start.addingTimeInterval(offset)
            return .init(widgetID: "sys", name: "System", viewTree: UINode(type: "text", text: text),
                         updatedAt: date, staleAfter: date.addingTimeInterval(3600))
        }
        func writtenAt() -> Date? { SharedShelf.readSnapshot(widgetID: "sys", from: container)?.updatedAt }

        publisher.publish(render(at: 0), now: start)
        XCTAssertEqual(writtenAt(), start)
        publisher.publish(render(at: 600), now: start.addingTimeInterval(600))
        XCTAssertEqual(writtenAt(), start, "unchanged and fresh: skipped")
        publisher.publish(render(at: 700, text: "new"), now: start.addingTimeInterval(700))
        XCTAssertEqual(writtenAt(), start.addingTimeInterval(700), "changed: written")
        // 15 minutes before the written copy turns stale, the same reading is
        // written again so the desktop keeps saying it is current.
        let nearStale = 700 + 3600 - SharedShelfPublisher.minimumReloadInterval + 1
        publisher.publish(render(at: nearStale, text: "new"), now: start.addingTimeInterval(nearStale))
        XCTAssertEqual(writtenAt(), start.addingTimeInterval(nearStale))
    }

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

    /// A render held while nothing was placed must not be flushed over a
    /// newer one written for a desktop refresh in the meantime.
    @MainActor
    func testAHeldRenderNeverReplacesANewerOne() throws {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: container) }
        let publisher = SharedShelfPublisher(container: container, reload: {},
            scheduleRefreshTimeout: { _ in }, placementProbe: { $0(0) })
        publisher.publishIndex([.init(id: "sys", name: "System")])
        publisher.publish(.init(widgetID: "sys", name: "System", viewTree: UINode(type: "text", text: "first")))
        publisher.publish(.init(widgetID: "sys", name: "System", viewTree: UINode(type: "text", text: "held-old")))
        try SharedShelf.requestRefresh(widgetID: "sys", in: container)
        publisher.takeRefreshRequests()
        publisher.publish(.init(widgetID: "sys", name: "System", viewTree: UINode(type: "text", text: "fresh")))
        XCTAssertEqual(SharedShelf.readSnapshot(widgetID: "sys", from: container)?.viewTree?.text, "fresh")
        publisher.placementChanged(to: 1)
        XCTAssertEqual(SharedShelf.readSnapshot(widgetID: "sys", from: container)?.viewTree?.text, "fresh")
    }

    /// The first placement's reload waits for a held widget's thumbnails,
    /// so WidgetKit reads the snapshot, not an empty folder.
    @MainActor
    func testFirstPlacementReloadsOnceTheHeldSnapshotsAreWritten() async throws {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: container) }
        let image = container.appendingPathComponent("a.png")
        try Data("not really a picture".utf8).write(to: image)
        var seenAtReload: [Bool] = []
        let publisher = SharedShelfPublisher(container: container, reload: {
            seenAtReload.append(SharedShelf.readSnapshot(widgetID: "files", from: container) != nil)
        }, placementProbe: { $0(0) })
        publisher.publishIndex([.init(id: "files", name: "Files")])
        // The first render goes out before the answer; the next is held.
        publisher.publish(.init(widgetID: "other", name: "Other"))
        publisher.publish(try fileTileSnapshot(path: image.path))
        XCTAssertNil(SharedShelf.readSnapshot(widgetID: "files", from: container))
        seenAtReload = []
        publisher.placementChanged(to: 1)
        for _ in 0..<50 where seenAtReload.isEmpty {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(seenAtReload, [true])
    }

}
