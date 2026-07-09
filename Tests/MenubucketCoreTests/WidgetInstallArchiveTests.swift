import Compression
import XCTest

@testable import MenubucketCore

/// URL-install v1 — safe zip extraction + widget.json discovery, exercised
/// against fixture zips built in-memory by `ZipFixture` (full control over
/// entry names, symlink attributes, and compression method).
final class WidgetInstallArchiveTests: XCTestCase {
    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("widget-install-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    private func manifestJSON(id: String, name: String? = nil, extra: String = "") -> Data {
        Data("""
        {
          "schemaVersion": 1,
          "id": "\(id)",
          "name": "\(name ?? id)",
          "entry": { "kind": "exec" }\(extra)
        }
        """.utf8)
    }

    // MARK: Extraction

    func testExtractsStoredAndDeflatedEntries() throws {
        let big = Data(String(repeating: "barshelf ", count: 2000).utf8)
        let zip = ZipFixture.build([
            .file("a.txt", Data("hello".utf8)),
            .file("dir/b.txt", big, deflate: true),
        ])
        let out = workDir.appendingPathComponent("out")
        let written = try SafeZipExtractor.extract(zipData: zip, to: out)

        XCTAssertEqual(Set(written), ["a.txt", "dir/b.txt"])
        XCTAssertEqual(
            try Data(contentsOf: out.appendingPathComponent("a.txt")),
            Data("hello".utf8)
        )
        XCTAssertEqual(
            try Data(contentsOf: out.appendingPathComponent("dir/b.txt")), big
        )
    }

    func testRejectsPathTraversalEntries() throws {
        let out = workDir.appendingPathComponent("out")

        let dotDot = ZipFixture.build([.file("../evil.txt", Data("x".utf8))])
        XCTAssertThrowsError(try SafeZipExtractor.extract(zipData: dotDot, to: out)) { error in
            XCTAssertEqual(error as? ZipExtractionError, .pathTraversal("../evil.txt"))
        }

        let nested = ZipFixture.build([.file("a/../../evil.txt", Data("x".utf8))])
        XCTAssertThrowsError(try SafeZipExtractor.extract(zipData: nested, to: out))

        let absolute = ZipFixture.build([.file("/etc/evil.txt", Data("x".utf8))])
        XCTAssertThrowsError(try SafeZipExtractor.extract(zipData: absolute, to: out))

        // Nothing may have escaped.
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: workDir.appendingPathComponent("evil.txt").path
        ))
    }

    func testSymlinkEntriesAreIgnored() throws {
        let zip = ZipFixture.build([
            .file("ok.txt", Data("ok".utf8)),
            .symlink("link", target: "/etc/passwd"),
        ])
        let out = workDir.appendingPathComponent("out")
        let written = try SafeZipExtractor.extract(zipData: zip, to: out)

        XCTAssertEqual(written, ["ok.txt"])
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: out.appendingPathComponent("link").path)
        )
    }

    func testExtractionSizeLimitIsEnforced() throws {
        let payload = Data(count: 300_000)
        let zip = ZipFixture.build([
            .file("a.bin", payload),
            .file("b.bin", payload),
        ])
        let out = workDir.appendingPathComponent("out")
        XCTAssertThrowsError(
            try SafeZipExtractor.extract(zipData: zip, to: out, maxExtractedBytes: 500_000)
        ) { error in
            XCTAssertEqual(
                error as? ZipExtractionError,
                .extractionTooLarge(limitBytes: 500_000)
            )
        }
    }

    func testGarbageDataIsNotAZip() {
        let out = workDir.appendingPathComponent("out")
        XCTAssertThrowsError(
            try SafeZipExtractor.extract(zipData: Data("not a zip at all".utf8), to: out)
        ) { error in
            XCTAssertEqual(error as? ZipExtractionError, .notAZipArchive)
        }
    }

    // MARK: Discovery

    /// GitHub-style archive: single `repo-main/` wrapper, two widgets under
    /// `widgets/`, one broken manifest — multi-widget discovery from a zip.
    func testDiscoversMultipleWidgetsInFixtureZip() throws {
        let zip = ZipFixture.build([
            .file("repo-main/README.md", Data("# repo".utf8)),
            .file("repo-main/widgets/alpha/widget.json",
                  manifestJSON(id: "com.test.alpha", name: "Alpha",
                               extra: ", \"version\": \"1.2.0\"")),
            .file("repo-main/widgets/alpha/index.ts", Data("// alpha".utf8)),
            .file("repo-main/widgets/beta/widget.json",
                  manifestJSON(id: "com.test.beta", name: "Beta"), deflate: true),
            .file("repo-main/widgets/broken/widget.json", Data("{ not json".utf8)),
        ])
        let out = workDir.appendingPathComponent("out")
        try SafeZipExtractor.extract(zipData: zip, to: out)

        let result = try WidgetDiscovery.discover(under: out)
        XCTAssertEqual(
            result.candidates.map(\.manifest.id),
            ["com.test.alpha", "com.test.beta"]
        )
        XCTAssertEqual(result.candidates[0].displayVersion, "1.2.0")
        XCTAssertNil(result.candidates[1].displayVersion)
        XCTAssertEqual(result.candidates[0].relativePath, "widgets/alpha")
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertEqual(result.failures[0].relativePath, "widgets/broken")
    }

    func testDiscoversWidgetAtRepoRoot() throws {
        let zip = ZipFixture.build([
            .file("repo-main/widget.json", manifestJSON(id: "root-widget")),
            .file("repo-main/index.ts", Data("// code".utf8)),
            // nested widget.json under a widget dir is content, not a widget
            .file("repo-main/examples/widget.json", manifestJSON(id: "nested")),
        ])
        let out = workDir.appendingPathComponent("out")
        try SafeZipExtractor.extract(zipData: zip, to: out)

        let result = try WidgetDiscovery.discover(under: out)
        XCTAssertEqual(result.candidates.map(\.manifest.id), ["root-widget"])
    }

    func testSubdirectoryRestrictsDiscovery() throws {
        let zip = ZipFixture.build([
            .file("repo-main/widgets/alpha/widget.json", manifestJSON(id: "alpha")),
            .file("repo-main/widgets/beta/widget.json", manifestJSON(id: "beta")),
            .file("repo-main/other/gamma/widget.json", manifestJSON(id: "gamma")),
        ])
        let out = workDir.appendingPathComponent("out")
        try SafeZipExtractor.extract(zipData: zip, to: out)

        let scoped = try WidgetDiscovery.discover(under: out, subdirectory: "widgets/alpha")
        XCTAssertEqual(scoped.candidates.map(\.manifest.id), ["alpha"])

        XCTAssertThrowsError(
            try WidgetDiscovery.discover(under: out, subdirectory: "does/not/exist")
        )
    }

    func testInvalidWidgetIDBecomesFailure() throws {
        let zip = ZipFixture.build([
            .file("repo-main/w/widget.json", manifestJSON(id: "../escape")),
        ])
        let out = workDir.appendingPathComponent("out")
        try SafeZipExtractor.extract(zipData: zip, to: out)

        let result = try WidgetDiscovery.discover(under: out)
        XCTAssertTrue(result.candidates.isEmpty)
        XCTAssertEqual(result.failures.count, 1)
    }

    func testWidgetIDValidation() {
        XCTAssertTrue(WidgetDiscovery.isValidWidgetID("com.example.clock"))
        XCTAssertTrue(WidgetDiscovery.isValidWidgetID("clock-widget_2"))
        XCTAssertFalse(WidgetDiscovery.isValidWidgetID(""))
        XCTAssertFalse(WidgetDiscovery.isValidWidgetID(".hidden"))
        XCTAssertFalse(WidgetDiscovery.isValidWidgetID("a/b"))
        XCTAssertFalse(WidgetDiscovery.isValidWidgetID("a..b"))
    }

    func testPermissionSummary() throws {
        let manifest = try Manifest.decode(from: manifestJSON(
            id: "p",
            extra: """
            , "permissions": {
                "exec": [{ "command": "git" }, { "command": "df" }],
                "keychain": true,
                "notifications": true
            }
            """
        ))
        let summary = WidgetDiscovery.permissionSummary(for: manifest)
        XCTAssertEqual(summary.count, 3)
        XCTAssertTrue(summary[0].contains("git"))
        XCTAssertTrue(summary[0].contains("df"))
        XCTAssertTrue(summary[1].lowercased().contains("keychain"))
        XCTAssertTrue(summary[2].lowercased().contains("notification"))

        let none = try Manifest.decode(from: manifestJSON(id: "q"))
        XCTAssertTrue(WidgetDiscovery.permissionSummary(for: none).isEmpty)
    }
}

// MARK: - In-memory zip fixture builder

/// Writes minimal, spec-conformant zip archives (local headers + central
/// directory + EOCD). Supports stored and raw-DEFLATE entries plus unix
/// symlink attributes — enough to exercise every SafeZipExtractor branch,
/// including hostile entry names that `zip`/`ditto` refuse to produce.
private enum ZipFixture {
    struct Entry {
        let name: String
        let data: Data
        let deflate: Bool
        let unixMode: UInt16

        static func file(_ name: String, _ data: Data, deflate: Bool = false) -> Entry {
            Entry(name: name, data: data, deflate: deflate, unixMode: 0o100644)
        }

        static func symlink(_ name: String, target: String) -> Entry {
            Entry(name: name, data: Data(target.utf8), deflate: false, unixMode: 0o120777)
        }
    }

    static func build(_ entries: [Entry]) -> Data {
        var archive = Data()
        var centralDirectory = Data()

        for entry in entries {
            let nameBytes = Data(entry.name.utf8)
            let payload = entry.deflate ? rawDeflate(entry.data) : entry.data
            let method: UInt16 = entry.deflate ? 8 : 0
            let localOffset = UInt32(archive.count)
            let crc = crc32(entry.data)

            // Local file header
            archive.appendUInt32(0x0403_4b50)
            archive.appendUInt16(20)                      // version needed
            archive.appendUInt16(0)                       // flags
            archive.appendUInt16(method)
            archive.appendUInt16(0)                       // mod time
            archive.appendUInt16(0)                       // mod date
            archive.appendUInt32(crc)
            archive.appendUInt32(UInt32(payload.count))   // compressed size
            archive.appendUInt32(UInt32(entry.data.count))
            archive.appendUInt16(UInt16(nameBytes.count))
            archive.appendUInt16(0)                       // extra len
            archive.append(nameBytes)
            archive.append(payload)

            // Central directory entry
            centralDirectory.appendUInt32(0x0201_4b50)
            centralDirectory.appendUInt16(0x031E)         // made by: unix
            centralDirectory.appendUInt16(20)
            centralDirectory.appendUInt16(0)
            centralDirectory.appendUInt16(method)
            centralDirectory.appendUInt16(0)
            centralDirectory.appendUInt16(0)
            centralDirectory.appendUInt32(crc)
            centralDirectory.appendUInt32(UInt32(payload.count))
            centralDirectory.appendUInt32(UInt32(entry.data.count))
            centralDirectory.appendUInt16(UInt16(nameBytes.count))
            centralDirectory.appendUInt16(0)              // extra len
            centralDirectory.appendUInt16(0)              // comment len
            centralDirectory.appendUInt16(0)              // disk
            centralDirectory.appendUInt16(0)              // internal attrs
            centralDirectory.appendUInt32(UInt32(entry.unixMode) << 16)
            centralDirectory.appendUInt32(localOffset)
            centralDirectory.append(nameBytes)
        }

        let centralOffset = UInt32(archive.count)
        archive.append(centralDirectory)

        // End of central directory
        archive.appendUInt32(0x0605_4b50)
        archive.appendUInt16(0)
        archive.appendUInt16(0)
        archive.appendUInt16(UInt16(entries.count))
        archive.appendUInt16(UInt16(entries.count))
        archive.appendUInt32(UInt32(centralDirectory.count))
        archive.appendUInt32(centralOffset)
        archive.appendUInt16(0)

        return archive
    }

    /// Raw DEFLATE via the Compression framework (COMPRESSION_ZLIB).
    private static func rawDeflate(_ input: Data) -> Data {
        precondition(!input.isEmpty, "fixture deflate needs a non-empty payload")
        var output = Data(count: input.count + 1024)
        let count = output.withUnsafeMutableBytes { dst -> Int in
            input.withUnsafeBytes { src -> Int in
                compression_encode_buffer(
                    dst.bindMemory(to: UInt8.self).baseAddress!, dst.count,
                    src.bindMemory(to: UInt8.self).baseAddress!, input.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        precondition(count > 0, "fixture deflate failed")
        return output.prefix(count)
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8(value >> 8))
    }

    mutating func appendUInt32(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }
}
