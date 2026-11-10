import Darwin
import Foundation
import XCTest
@testable import MenubucketCore

/// `fs.json`: one small JSON file read in process, bound to the same
/// device/inode authorization as `fs.directory`.
final class FileJSONSourceTests: XCTestCase {
    private var root: URL!
    private var outside: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("fsjson-\(UUID().uuidString)").resolvingSymlinksInPath()
        root = base.appendingPathComponent("root")
        outside = base.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    private func read(_ path: String, maxBytes: Int? = nil, roots: [String]? = nil) throws -> [String: JSONValue] {
        var with: [String: JSONValue] = ["path": .string(path)]
        if let maxBytes { with["maxBytes"] = .number(Double(maxBytes)) }
        let params = try FileSource.JSONFileParams(from: .object(with))
        let value = try FileSource.readJSON(params, authorizedBy: roots ?? [root.path])
        guard let object = value.objectValue else { throw CocoaError(.coderReadCorrupt) }
        return object
    }

    func testReadsAndParses() throws {
        let file = root.appendingPathComponent("s.json")
        try Data(#"{"phase":"ac","n":3}"#.utf8).write(to: file)
        let out = try read(file.path)
        XCTAssertEqual(out["exists"], .bool(true))
        XCTAssertEqual(out["valid"], .bool(true))
        XCTAssertEqual(out["value"]?.objectValue?["phase"], .string("ac"))
        XCTAssertEqual(out["size"], .number(20))
        XCTAssertNotNil(out["modifiedAt"]?.numberValue)
    }

    func testMissingAndGarbledAreReadingsNotErrors() throws {
        XCTAssertEqual(try read(root.appendingPathComponent("none.json").path)["exists"], .bool(false))
        let file = root.appendingPathComponent("bad.json")
        try Data("{".utf8).write(to: file)
        let out = try read(file.path)
        XCTAssertEqual(out["exists"], .bool(true))
        XCTAssertEqual(out["valid"], .bool(false))
        XCTAssertEqual(out["value"], .null)
    }

    func testJSONNullIsValid() throws {
        let file = root.appendingPathComponent("null.json")
        try Data("null".utf8).write(to: file)
        let out = try read(file.path)
        XCTAssertEqual(out["valid"], .bool(true))
        XCTAssertEqual(out["value"], .null)
    }

    /// The app that owns the folder isn't installed: its folder is absent,
    /// and so is the declared root itself.
    func testAbsentFolderInsideARootIsMissing() throws {
        let path = root.appendingPathComponent("App/status.json").path
        XCTAssertEqual(try read(path)["exists"], .bool(false))
        let absentRoot = root.appendingPathComponent("NotInstalled").path
        XCTAssertEqual(try read(absentRoot + "/status.json", roots: [absentRoot])["exists"], .bool(false))
    }

    func testOutsideTheRootsIsRefusedEvenWhenAbsent() throws {
        let file = outside.appendingPathComponent("s.json")
        try Data("{}".utf8).write(to: file)
        XCTAssertThrowsError(try read(file.path))
        XCTAssertThrowsError(try read(outside.appendingPathComponent("gone/s.json").path))
        XCTAssertThrowsError(try read(root.path + "/../outside/s.json"))
    }

    func testSymlinksAreNotFollowed() throws {
        let target = outside.appendingPathComponent("secret.json")
        try Data("{}".utf8).write(to: target)
        let link = root.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try read(link.path))
        // A symlinked folder that leads out of the root is refused too.
        let folder = root.appendingPathComponent("away")
        try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: outside)
        XCTAssertThrowsError(try read(folder.appendingPathComponent("secret.json").path))
    }

    /// A folder that doesn't exist yet behind a symlink that leads out of
    /// the root is not "missing": the walk stops at the symlinked folder and
    /// that one fails the device/inode check.
    func testMissingBehindAnEscapingSymlinkIsRefused() throws {
        let folder = root.appendingPathComponent("away")
        try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: outside)
        XCTAssertThrowsError(try read(folder.appendingPathComponent("missing/status.json").path))
    }

    /// Once authorized, reads go through the open folder: replacing its
    /// path with a symlink to somewhere else changes nothing.
    func testReadsStayOnTheAuthorizedFolder() throws {
        let folder = root.appendingPathComponent("app")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"who":"inside"}"#.utf8).write(to: folder.appendingPathComponent("s.json"))
        try Data(#"{"who":"outside"}"#.utf8).write(to: outside.appendingPathComponent("s.json"))
        let directory = try FileSource.openAuthorizedDirectory(path: folder.path, readPaths: [root.path])
        try FileManager.default.moveItem(at: folder, to: root.appendingPathComponent("app-old"))
        try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: outside)
        let out = try FileSource.readJSON(named: "s.json", in: directory, displayPath: "s.json", maxBytes: 1024)
        XCTAssertEqual(out.objectValue?["value"]?.objectValue?["who"], .string("inside"))
    }

    func testFIFOIsRefusedWithoutBlocking() throws {
        let fifo = root.appendingPathComponent("pipe.json")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        XCTAssertThrowsError(try read(fifo.path))
    }

    func testDirectoryIsNotAFile() throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("d.json"), withIntermediateDirectories: true)
        XCTAssertThrowsError(try read(root.appendingPathComponent("d.json").path))
    }

    func testSizeCap() throws {
        let file = root.appendingPathComponent("big.json")
        try Data(#""abcdefgh""#.utf8).write(to: file) // 10 bytes
        XCTAssertEqual(try read(file.path, maxBytes: 10)["valid"], .bool(true))
        XCTAssertThrowsError(try read(file.path, maxBytes: 9))
    }

    func testParameterValidation() {
        XCTAssertThrowsError(try FileSource.JSONFileParams(from: .object([:])))
        XCTAssertThrowsError(try FileSource.JSONFileParams(from: .object(["path": .string("a\0b")])))
        for bad: JSONValue in [.number(0), .number(1.5), .number(6_000_000), .string("10"), .number(-1)] {
            XCTAssertThrowsError(try FileSource.JSONFileParams(from: .object(["path": .string("/x"), "maxBytes": bad])), "\(bad)")
        }
        XCTAssertEqual(try FileSource.JSONFileParams(from: .object(["path": .string("/x")])).maxBytes,
                       FileSource.JSONFileParams.defaultMaxBytes)
        XCTAssertThrowsError(try read(root.path + "/"))
    }
}
