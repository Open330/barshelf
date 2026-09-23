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
            widgetID: "dev.barshelf.hello",
            viewTree: tree,
            updatedAt: updatedAt,
            error: "aas not found",
            safeForSensitiveCache: true,
            isLoading: true
        )

        let data = try snapshot.serialized()
        let restored = try WidgetSnapshot.deserialize(data)

        XCTAssertEqual(restored.widgetID, snapshot.widgetID)
        XCTAssertEqual(restored.viewTree, tree)
        XCTAssertEqual(restored.updatedAt, updatedAt)
        XCTAssertEqual(restored.error, "aas not found")
        XCTAssertEqual(restored.safeForSensitiveCache, true)
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

    func testStatusTextSurvivesTheRenderCache() throws {
        let snapshot = WidgetSnapshot(
            widgetID: "dev.example.system",
            viewTree: UINode(type: "text", text: "hi"),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            statusLabel: "42%",
            statusTooltip: "CPU 42% · Memory 61%"
        )
        let restored = try WidgetSnapshot.deserialize(snapshot.serialized())
        // A promoted widget must have something to draw at cold start, before
        // its first refresh of the session completes.
        XCTAssertEqual(restored.statusLabel, "42%")
        XCTAssertEqual(restored.statusTooltip, "CPU 42% · Memory 61%")
    }

    func testSnapshotsWrittenBeforeStatusTextStillDecode() throws {
        let legacy = #"{"widgetID":"dev.example.old","viewTree":{"type":"text","text":"hi"}}"#
        let restored = try WidgetSnapshot.deserialize(Data(legacy.utf8))
        XCTAssertEqual(restored.widgetID, "dev.example.old")
        XCTAssertNil(restored.statusLabel)
        XCTAssertNil(restored.statusTooltip)
    }

    func testMetricStatusSurvivesCacheAndLegacyCachesStillDecode() throws {
        let snapshot = WidgetSnapshot(
            widgetID: "dev.example.network",
            statusMetrics: [
                StatusMetric(label: "↓", value: "12 MB/s", active: true,
                             accessibilityLabel: "Download network activity"),
                StatusMetric(label: "↑", value: "", tint: "secondary")
            ]
        )
        let restored = try WidgetSnapshot.deserialize(snapshot.serialized())
        XCTAssertEqual(restored.statusMetrics, snapshot.statusMetrics)

        let legacy = #"{"widgetID":"dev.example.old","statusLabel":"42%"}"#
        XCTAssertNil(try WidgetSnapshot.deserialize(Data(legacy.utf8)).statusMetrics)
    }

}
