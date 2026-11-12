import XCTest
@testable import MenubucketCore

final class JSONFileTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("barshelf-jsonfile-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func asideFiles() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.contains(".corrupt-") }.sorted()
    }

    func testMissingFileIsNilAndNothingIsMovedOrAnnounced() throws {
        let url = directory.appendingPathComponent("prefs.json")
        let announced = expectation(forNotification: JSONFile.problemNotification, object: nil)
        announced.isInverted = true
        XCTAssertNil(JSONFile.load([String: Int].self, from: url))
        wait(for: [announced], timeout: 0.1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    /// The defaults a store falls back to must never be saved over the
    /// user's file: it is moved aside first, and that is announced.
    func testUndecodableFileIsMovedAsideAndAnnounced() throws {
        let url = directory.appendingPathComponent("prefs.json")
        try JSONFile.write(Data("{\"pinned\": [\"a\"".utf8), to: url)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var problem: JSONFile.Problem?
        let announced = expectation(forNotification: JSONFile.problemNotification, object: nil) { note in
            problem = note.userInfo?[JSONFile.problemKey] as? JSONFile.Problem
            return true
        }

        XCTAssertNil(JSONFile.load([String: [String]].self, from: url, now: now))
        wait(for: [announced], timeout: 1)

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let aside = try asideFiles()
        XCTAssertEqual(aside.count, 1)
        XCTAssertTrue(aside[0].hasPrefix("prefs.json.corrupt-"), aside[0])
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent(aside[0]), encoding: .utf8), "{\"pinned\": [\"a\"")
        guard case .unreadable(let movedTo)? = problem?.kind else { return XCTFail("\(String(describing: problem))") }
        XCTAssertEqual(movedTo?.lastPathComponent, aside[0])

        // A second bad file in the same second keeps the first one.
        try JSONFile.write(Data("nope".utf8), to: url)
        XCTAssertNil(JSONFile.load([String: [String]].self, from: url, now: now))
        XCTAssertEqual(try asideFiles().count, 2)
    }

    func testSaveReportsAFailedWrite() throws {
        // A regular file where the directory should be.
        try JSONFile.write(Data("x".utf8), to: directory.appendingPathComponent("blocker"))
        let url = directory.appendingPathComponent("blocker/prefs.json")
        let announced = expectation(forNotification: JSONFile.problemNotification, object: nil) { note in
            (note.userInfo?[JSONFile.problemKey] as? JSONFile.Problem)?.kind == .writeFailed
        }
        XCTAssertFalse(JSONFile.save(["a": 1], to: url))
        wait(for: [announced], timeout: 1)

        let quiet = expectation(forNotification: JSONFile.problemNotification, object: nil)
        quiet.isInverted = true
        XCTAssertFalse(JSONFile.save(["a": 1], to: url, announce: false))
        wait(for: [quiet], timeout: 0.1)
    }

    func testLenientContainersDropOnlyWhatTheyCannotRead() throws {
        struct Point: Decodable, Equatable { let x: Int }
        let json = Data(#"{"keep": {"x": 1}, "bad": {"x": "one"}, "also": {"x": 2}}"#.utf8)
        let dictionary = try JSONDecoder().decode(LenientDictionary<Point>.self, from: json)
        XCTAssertEqual(dictionary.entries, ["keep": Point(x: 1), "also": Point(x: 2)])

        let array = try JSONDecoder().decode(LenientArray<Point>.self, from: Data(#"[{"x": 1}, 7, {"x": 3}]"#.utf8))
        XCTAssertEqual(array.elements, [Point(x: 1), Point(x: 3)])
    }

    /// A file that is there but cannot be read (permissions) is set aside
    /// like an undecodable one; when even that fails, no save replaces it
    /// until it can be.
    func testAFileThatCannotBeReadOrSetAsideIsNeverReplaced() throws {
        try XCTSkipIf(getuid() == 0, "root reads and renames anything")
        let fm = FileManager.default
        let url = directory.appendingPathComponent("prefs.json")
        try JSONFile.write(Data(#"{"pinned": ["mine"]}"#.utf8), to: url)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        // A folder nothing can be renamed in.
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
            try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        }

        XCTAssertNil(JSONFile.load([String: [String]].self, from: url))
        XCTAssertTrue(fm.fileExists(atPath: url.path))
        XCTAssertFalse(JSONFile.save(["pinned": ["default"]], to: url, announce: false))
        XCTAssertThrowsError(try JSONFile.write(["pinned": ["default"]], to: url))

        // Once the folder allows it, the next save sets the original aside
        // first, then writes.
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        XCTAssertTrue(JSONFile.save(["pinned": ["new"]], to: url, announce: false))
        let aside = try XCTUnwrap(try asideFiles().first)
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: directory.appendingPathComponent(aside).path)
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent(aside), encoding: .utf8), #"{"pinned": ["mine"]}"#)
        XCTAssertEqual(try JSONDecoder().decode([String: [String]].self, from: Data(contentsOf: url)), ["pinned": ["new"]])
    }

    func testAFileThatCannotBeReadIsSetAside() throws {
        try XCTSkipIf(getuid() == 0, "root reads and renames anything")
        let fm = FileManager.default
        let url = directory.appendingPathComponent("prefs.json")
        try JSONFile.write(Data(#"{"pinned": ["mine"]}"#.utf8), to: url)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        XCTAssertNil(JSONFile.load([String: [String]].self, from: url))
        XCTAssertFalse(fm.fileExists(atPath: url.path))
        let aside = try XCTUnwrap(try asideFiles().first)
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: directory.appendingPathComponent(aside).path)
        XCTAssertTrue(JSONFile.save(["pinned": ["new"]], to: url, announce: false))
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent(aside), encoding: .utf8), #"{"pinned": ["mine"]}"#)
    }

    /// A number too large for a Double used to stop the array decoder from
    /// moving on, looping forever at launch.
    func testLenientArraySkipsAValueNothingCanDecode() throws {
        let array = try JSONDecoder().decode(LenientArray<String>.self, from: Data(#"[1e400, "ok", {"n": 1e400}, "two"]"#.utf8))
        XCTAssertEqual(array.elements, ["ok", "two"])
    }

}
