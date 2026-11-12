import XCTest
@testable import MenubucketApp
import MenubucketCore

final class OnboardingPermissionTests: XCTestCase {
    func testClockPermissionDescriptionOnlySummarizesReadOnlyDateArguments() {
        let reading = ExecPermissionText.describe(command: "/bin/date", args: ["+{\"weekday\":\"%A\"}"])
        XCTAssertFalse(reading.contains("weekday"))
        XCTAssertNotEqual(ExecPermissionText.describe(command: "/bin/date", args: ["102402002026"]), reading)
        XCTAssertNotEqual(ExecPermissionText.describe(command: "/tmp/date", args: ["+%A"]), reading)
    }

    func testFoldersMacOSGuardsAreNamedBeforeTheirPrompt() throws {
        XCTAssertNotNil(OnboardingView.protectedFolder(in: try manifest(readPaths: ["~/Downloads"])))
        XCTAssertNotNil(OnboardingView.protectedFolder(in: try manifest(readPaths: ["~/Documents/Notes"])))
        XCTAssertNil(OnboardingView.protectedFolder(in: try manifest(readPaths: ["~/DownloadsArchive"])))
        XCTAssertNil(OnboardingView.protectedFolder(in: try manifest(readPaths: ["/tmp"])))
        XCTAssertNil(OnboardingView.protectedFolder(in: try manifest(readPaths: [])))
    }

    /// The welcome lists every starter's permissions; none comes pre-approved
    /// just by being seeded, and the store stays the only gate.
    func testStartersStillNeedTheirOwnApproval() throws {
        // Today reads BarShelf's own clock and declares nothing to approve.
        let starters = ["recent-files-grid"]
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("barshelf-onboarding-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PermissionStore(fileURL: directory.appendingPathComponent("permissions.json"))
        for name in starters {
            let manifest = try Manifest.decode(from: Data(contentsOf: root
                .appendingPathComponent("widgets/\(name)/widget.json")))
            XCTAssertTrue(PermissionStore.requiresApproval(for: manifest), name)
            XCTAssertEqual(store.status(for: manifest), .pending, name)
        }
    }

    /// The welcome's menu bar step offers to add the bundled System widget
    /// in one click, without a permission prompt: it must stay
    /// permission-free and able to show in the menu bar.
    func testSystemCanBeOfferedForTheMenuBarWithoutAPrompt() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let manifest = try Manifest.decode(from: Data(contentsOf: root.appendingPathComponent("widgets/system/widget.json")))
        XCTAssertFalse(PermissionStore.requiresApproval(for: manifest))
        XCTAssertEqual(manifest.statusItem?.isPromotable, true)
    }

    private func manifest(readPaths: [String]) throws -> Manifest {
        let paths = readPaths.map { "\"\($0)\"" }.joined(separator: ", ")
        return try Manifest.decode(from: Data("""
        { "schemaVersion": 1, "id": "dev.test.folder", "name": "Folder",
          "entry": { "kind": "workflow" },
          "permissions": { "readPaths": [\(paths)] } }
        """.utf8))
    }
}
