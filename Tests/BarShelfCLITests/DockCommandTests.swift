import XCTest
@testable import BarShelfKit
import MenubucketCore

/// `barshelf dock` (R15).
final class DockCommandTests: XCTestCase {
    private final class FakeDefaults: AppleDockDefaults {
        var values: [String: Any] = [:]
        func value(forKey key: String) -> Any? { values[key] }
        func set(_ value: Any?, forKey key: String) { values[key] = value }
        func synchronize() {}
    }

    private var fileURL: URL!

    override func setUpWithError() throws {
        fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("dock-cli-\(UUID().uuidString).json")
        try DockConfiguration(profiles: [
            DockProfile(id: "w", name: "Work"),
            DockProfile(id: "p", name: "Personal"),
        ]).save(to: fileURL)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    func testListMarksTheActiveProfile() {
        let text = DockCommand.list(DockConfiguration.load(from: fileURL))
        XCTAssertTrue(text.hasPrefix("* 1. Work"))
        XCTAssertTrue(text.contains("  2. Personal"))
    }

    func testUseSendsTheProfileIDToTheApp() {
        var opened: [URL] = []
        let status = DockCommand.run(
            arguments: ["use", "personal"], configurationURL: fileURL,
            openURL: { opened.append($0); return true }
        )
        XCTAssertEqual(status, 0)
        XCTAssertEqual(opened, [URL(string: "barshelf://dock?profile=p")!])
    }

    func testUseRejectsAnUnknownProfileWithoutCallingTheApp() {
        var opened = false
        let status = DockCommand.run(
            arguments: ["use", "Gaming"], configurationURL: fileURL,
            openURL: { _ in opened = true; return true }
        )
        XCTAssertEqual(status, 1)
        XCTAssertFalse(opened)
    }

    func testRestoreAppleDockUsesTheBackupAndLeavesReplaceMode() throws {
        var config = DockConfiguration.load(from: fileURL)
        config.mode = .replace
        config.appleDockBackup = AppleDockVisibility(autohide: false, autohideDelay: 0.2)
        try config.save(to: fileURL)
        let defaults = FakeDefaults()
        defaults.values[AppleDock.autohideKey] = true
        defaults.values[AppleDock.autohideDelayKey] = AppleDock.hiddenDelay

        let status = DockCommand.run(
            arguments: ["restore-apple-dock"], configurationURL: fileURL,
            appleDock: { AppleDock(defaults: defaults) {} }
        )
        XCTAssertEqual(status, 0)
        XCTAssertEqual(defaults.values[AppleDock.autohideKey] as? Bool, false)
        XCTAssertEqual(defaults.values[AppleDock.autohideDelayKey] as? Double, 0.2)
        let saved = DockConfiguration.load(from: fileURL)
        XCTAssertNil(saved.appleDockBackup)
        XCTAssertEqual(saved.mode, .alongside)
    }

    func testUnknownSubcommandFails() {
        XCTAssertEqual(DockCommand.run(arguments: ["fly"], configurationURL: fileURL), 1)
        XCTAssertEqual(DockCommand.run(arguments: [], configurationURL: fileURL), 1)
    }
}
