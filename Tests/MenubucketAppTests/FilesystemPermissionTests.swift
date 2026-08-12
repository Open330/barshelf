import XCTest
@testable import MenubucketApp
import MenubucketCore

final class FilesystemPermissionTests: XCTestCase {
    func testDecodedReadGrantBindsWorkflowWatchAcrossSymlinkSubstitution() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("barshelf-bound-watch-\(UUID().uuidString)")
        let allowed = base.appendingPathComponent("allowed", isDirectory: true)
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        let link = base.appendingPathComponent("selected", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: allowed, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: allowed)

        let manifest = try Manifest.decode(from: Data("""
        { "schemaVersion": 1, "id": "dev.test.bound-watch", "name": "Bound Watch",
          "entry": { "kind": "workflow" },
          "permissions": { "readPaths": ["\(allowed.path)"] } }
        """.utf8))
        let params = try FileSource.Params(from: .object([
            "path": .string(link.path),
            "watch": .bool(true),
        ]))
        let listing = try FileSource.list(
            params, authorizedBy: try XCTUnwrap(manifest.permissions?.readPaths)
        )

        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        let fired = expectation(description: "bound directory changed")
        let watcher = try DirectoryWatcher(directory: listing.directory, debounce: 0.01) {
            fired.fulfill()
        }
        defer { watcher.cancel() }

        try Data("new".utf8).write(to: allowed.appendingPathComponent("new.txt"))
        wait(for: [fired], timeout: 2)
    }
}
