import XCTest
@testable import MenubucketCore

final class WidgetSnapshotTests: XCTestCase {
    func testSerializationRoundTrip() throws {
        let tree = UINode(
            id: "root",
            type: "vstack",
            children: [UINode(id: "t", type: "text", text: "cached", role: "body")]
        )
        let updatedAt = Date(timeIntervalSince1970: 1_752_000_000) // whole second (ISO8601-safe)
        let snapshot = WidgetSnapshot(
            widgetID: "dev.menubucket.hello",
            viewTree: tree,
            updatedAt: updatedAt,
            error: "aas not found",
            isLoading: true
        )

        let data = try snapshot.serialized()
        let restored = try WidgetSnapshot.deserialize(data)

        XCTAssertEqual(restored.widgetID, snapshot.widgetID)
        XCTAssertEqual(restored.viewTree, tree)
        XCTAssertEqual(restored.updatedAt, updatedAt)
        XCTAssertEqual(restored.error, "aas not found")
        XCTAssertFalse(restored.isLoading, "isLoading is transient and must not persist")
    }

    func testStaleness() {
        var snapshot = WidgetSnapshot(widgetID: "w")
        XCTAssertTrue(snapshot.isStale(after: 600), "no updatedAt → always stale")

        let now = Date()
        snapshot.updatedAt = now.addingTimeInterval(-100)
        XCTAssertFalse(snapshot.isStale(after: 600, now: now))
        XCTAssertTrue(snapshot.isStale(after: 60, now: now))
        XCTAssertTrue(snapshot.isStale(after: nil, now: now), "nil staleAfterSec → always stale")
    }

    /// The app suppresses per-widget publishes when a rewritten snapshot is
    /// `==` the stored one (R05 perf). This pins the equality semantics that
    /// suppression relies on: identical content compares equal, and every
    /// UI-visible field (tree, error, isLoading, updatedAt) breaks equality.
    func testEqualitySemanticsForPublishSuppression() {
        let base = WidgetSnapshot(
            widgetID: "w",
            viewTree: UINode(type: "text", text: "hello", role: "body"),
            updatedAt: Date(timeIntervalSince1970: 1_752_000_000),
            error: nil,
            isLoading: false
        )
        let identical = WidgetSnapshot(
            widgetID: "w",
            viewTree: UINode(type: "text", text: "hello", role: "body"),
            updatedAt: Date(timeIntervalSince1970: 1_752_000_000),
            error: nil,
            isLoading: false
        )
        XCTAssertEqual(base, identical, "identical content must suppress a re-publish")

        var changed = base
        changed.isLoading = true
        XCTAssertNotEqual(base, changed, "isLoading toggles must publish (spinner)")

        changed = base
        changed.error = "boom"
        XCTAssertNotEqual(base, changed, "error changes must publish (banner)")

        changed = base
        changed.updatedAt = base.updatedAt?.addingTimeInterval(1)
        XCTAssertNotEqual(base, changed, "updatedAt changes must publish (caption)")

        changed = base
        changed.viewTree = UINode(type: "text", text: "bye", role: "body")
        XCTAssertNotEqual(base, changed, "tree changes must publish (content)")
    }
}
