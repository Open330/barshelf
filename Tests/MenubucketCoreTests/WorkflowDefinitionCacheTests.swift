import Foundation
import XCTest

@testable import MenubucketCore

/// A promoted widget refreshes every couple of seconds; re-decoding its
/// workflow file each time was ~12% of its CPU. The cache must still see an
/// edit on the very next refresh, with no invalidation hook.
final class WorkflowDefinitionCacheTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wf-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ text: String, to name: String = "workflow.json") throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data("""
        {"schemaVersion":1,"sources":{},"view":{"type":"text","text":"\(text)"}}
        """.utf8).write(to: url)
        return url
    }

    private func text(_ entry: WorkflowDefinitionCache.Entry) -> String? {
        entry.definition.view.objectValue?["text"]?.stringValue
    }

    func testAnUnchangedFileIsDecodedOnce() throws {
        let cache = WorkflowDefinitionCache()
        let url = try write("one")

        for _ in 0..<5 {
            XCTAssertEqual(text(try cache.load(url)), "one")
        }
        XCTAssertEqual(cache.decodeCount, 1, "five refreshes, one decode")
        XCTAssertEqual(cache.count, 1)
    }

    func testAnEditIsPickedUpOnTheNextLoad() throws {
        let cache = WorkflowDefinitionCache()
        let url = try write("before")
        XCTAssertEqual(text(try cache.load(url)), "before")

        _ = try write("after, and longer")  // size and mtime both move
        XCTAssertEqual(text(try cache.load(url)), "after, and longer")
        XCTAssertEqual(cache.decodeCount, 2)
    }

    func testVisibilityUseIsComputedWithTheDecode() throws {
        let cache = WorkflowDefinitionCache()
        let url = try write("${string(widget.visible)}")
        XCTAssertTrue(try cache.load(url).readsWidgetVisibility)
        let plain = try write("hello", to: "plain.json")
        XCTAssertFalse(try cache.load(plain).readsWidgetVisibility)
    }

    func testAMissingFileThrowsRatherThanServingAStaleEntry() throws {
        let cache = WorkflowDefinitionCache()
        let url = try write("gone soon")
        _ = try cache.load(url)
        try FileManager.default.removeItem(at: url)
        XCTAssertThrowsError(try cache.load(url))
    }
}
