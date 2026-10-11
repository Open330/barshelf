import XCTest
@testable import MenubucketCore

final class StorageServiceLifecycleTests: XCTestCase {
    func testEvictionReleasesMemoryButPreservesSavedDataAndRejectsLateRecaching() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = StorageService(directory: directory)
        try storage.set(widgetId: "kept", key: "value", value: .number(1))
        try storage.set(widgetId: "removed", key: "value", value: .number(2))
        storage.retain(widgetIDs: ["kept"])
        XCTAssertEqual(storage.cachedWidgetIDs, ["kept"])
        XCTAssertEqual(storage.get(widgetId: "removed", key: "value"), .number(2))
        try storage.set(widgetId: "removed", key: "value", value: .number(3))
        XCTAssertEqual(storage.cachedWidgetIDs, ["kept"])
        storage.retain(widgetIDs: ["kept", "removed"])
        XCTAssertEqual(storage.get(widgetId: "removed", key: "value"), .number(3))
        XCTAssertEqual(storage.cachedWidgetIDs, ["kept", "removed"])
    }

    func testFailedWriteDoesNotReplaceTheLastSuccessfulCachedValue() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = StorageService(directory: directory)
        try storage.set(widgetId: "w", key: "value", value: .number(1))
        let file = directory.appendingPathComponent("w.json")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        XCTAssertThrowsError(try storage.set(widgetId: "w", key: "value", value: .number(2)))
        XCTAssertEqual(storage.get(widgetId: "w", key: "value"), .number(1))
    }
}
