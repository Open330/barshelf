import XCTest
import MenubucketCore
@testable import MenubucketApp

final class DirectorySettingPolicyTests: XCTestCase {
    func testOnlyHostDirectoryInputsGetReadRootConstraints() {
        let workflow = WorkflowDefinition(sources: [
            "files": .init(use: "fs.directory", with: .object(["path": .string("${settings.folder}")])),
            "external": .init(use: "exec", with: .object(["path": .string("${settings.outputFolder}")])),
        ], view: .null)
        XCTAssertEqual(DirectorySettingPolicy.constrainedKeys(in: workflow), ["folder"])
    }

    func testAllowedRootAndChildrenExcludeSimilarNamesAndSymlinkEscapes() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("Downloads")
        let outside = base.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: outside)
        XCTAssertTrue(DirectorySettingPolicy.allows(root.path, roots: [root.path]))
        XCTAssertTrue(DirectorySettingPolicy.allows(root.appendingPathComponent("subfolder").path, roots: [root.path]))
        XCTAssertFalse(DirectorySettingPolicy.allows(root.path + "Archive", roots: [root.path]))
        XCTAssertFalse(DirectorySettingPolicy.allows(root.appendingPathComponent("escape").path, roots: [root.path]))
        XCTAssertFalse(DirectorySettingPolicy.allows("", roots: [root.path]))
    }

    func testInvalidFolderDoesNotReplaceSavedFolderOrBlockOtherSettings() {
        let saved: [String: JSONValue] = ["folder": .string("/tmp/Downloads"), "count": .number(10)]
        let draft: [String: JSONValue] = ["folder": .string("/tmp/Documents"), "count": .number(20)]
        let settings: [Manifest.Setting] = [.init(key: "folder", type: "directory"), .init(key: "count", type: "number")]
        let result = DirectorySettingPolicy.saving(draft, over: saved, settings: settings, roots: ["/tmp/Downloads"])
        XCTAssertEqual(result["folder"], saved["folder"])
        XCTAssertEqual(result["count"], draft["count"])
        XCTAssertEqual(DirectorySettingPolicy.saving(draft, over: saved, settings: settings, roots: []), draft)
    }
}
