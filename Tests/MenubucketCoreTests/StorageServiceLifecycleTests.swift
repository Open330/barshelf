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

    private func asideFiles(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains(".corrupt-") }
    }

    func testMissingFileIsAnEmptyNamespaceAndNothingIsSetAside() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = StorageService(directory: directory)
        XCTAssertNil(storage.get(widgetId: "w", key: "value"))
        XCTAssertEqual(storage.snapshot(widgetId: "w"), [:])
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        try storage.set(widgetId: "w", key: "value", value: .number(1))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["w.json"])
    }

    /// A namespace file this build cannot decode is the widget's saved data:
    /// the empty namespace it falls back to must not be written over it.
    func testUndecodableFileIsSetAsideBeforeAWriteCanReplaceIt() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("w.json")
        let corrupt = Data(#"{"entries": {"token": {"value": "kept"#.utf8)
        try corrupt.write(to: file)
        try Data(#"{"entries": {"value": {"value": 7}}}"#.utf8)
            .write(to: directory.appendingPathComponent("other.json"))
        let announced = expectation(forNotification: JSONFile.problemNotification, object: nil) { note in
            (note.userInfo?[JSONFile.problemKey] as? JSONFile.Problem)?.file.lastPathComponent == "w.json"
        }

        let storage = StorageService(directory: directory)
        XCTAssertNil(storage.get(widgetId: "w", key: "token"))
        wait(for: [announced], timeout: 1)
        try storage.set(widgetId: "w", key: "value", value: .number(1))

        let aside = try asideFiles(in: directory)
        XCTAssertEqual(aside.count, 1)
        XCTAssertEqual(aside.first?.lastPathComponent.hasPrefix("w.json.corrupt-"), true)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(aside.first)), corrupt)
        // The store works from empty, and another widget's file is untouched.
        XCTAssertEqual(storage.get(widgetId: "w", key: "value"), .number(1))
        XCTAssertEqual(StorageService(directory: directory).snapshot(widgetId: "w"), ["value": .number(1)])
        XCTAssertEqual(storage.get(widgetId: "other", key: "value"), .number(7))
    }

    /// A file that can be neither read nor moved aside is left alone: writes
    /// throw instead of replacing it.
    func testAFileThatCannotBeReadOrSetAsideIsNotReplaced() throws {
        try XCTSkipIf(getuid() == 0, "root reads and renames anything")
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("w.json")
        let original = Data(#"{"entries": {"value": {"value": 7}}}"#.utf8)
        try original.write(to: file)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        // A folder nothing can be renamed in.
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
            try? fm.removeItem(at: directory)
        }

        let storage = StorageService(directory: directory)
        XCTAssertNil(storage.get(widgetId: "w", key: "value"))
        XCTAssertThrowsError(try storage.set(widgetId: "w", key: "value", value: .number(1)))
        XCTAssertNil(storage.get(widgetId: "w", key: "value"), "a refused write is not cached")

        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        XCTAssertEqual(try Data(contentsOf: file), original)
    }
}
