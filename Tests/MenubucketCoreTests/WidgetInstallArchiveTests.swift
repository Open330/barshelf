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

    func testDiscoveryRejectsLegacyFilesPermission() throws {
        let zip = ZipFixture.build([
            .file("repo-main/widget.json", manifestJSON(
                id: "legacy-files",
                extra: ", \"permissions\": { \"files\": [] }"
            )),
        ])
        let out = workDir.appendingPathComponent("legacy-files-out")
        try SafeZipExtractor.extract(zipData: zip, to: out)

        let result = try WidgetDiscovery.discover(under: out)
        XCTAssertTrue(result.candidates.isEmpty)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertTrue(result.failures[0].reason.contains("permissions.files"))
        XCTAssertTrue(result.failures[0].reason.contains("permissions.readPaths"))
    }

    func testDiscoveryRejectsUnsupportedManifestSchemaVersion() throws {
        let zip = ZipFixture.build([
            .file("repo-main/widget.json", Data("""
            { "schemaVersion": 2, "id": "future-widget", "name": "Future",
              "entry": { "kind": "exec" } }
            """.utf8)),
        ])
        let out = workDir.appendingPathComponent("unsupported-version-out")
        try SafeZipExtractor.extract(zipData: zip, to: out)

        let result = try WidgetDiscovery.discover(under: out)

        XCTAssertTrue(result.candidates.isEmpty)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertTrue(result.failures[0].reason.contains("schemaVersion 2"))
        XCTAssertTrue(result.failures[0].reason.contains("supported version: 1"))
    }

    func testInstallSessionDoesNotCreateCandidateForUnsupportedManifestVersion() throws {
        let widget = workDir.appendingPathComponent("future-widget", isDirectory: true)
        try FileManager.default.createDirectory(
            at: widget, withIntermediateDirectories: true
        )
        try Data("""
        { "schemaVersion": 2, "id": "future-widget", "name": "Future",
          "entry": { "kind": "exec" } }
        """.utf8).write(to: widget.appendingPathComponent("widget.json"))

        let session = try HeadlessInstaller.fetchSession(directory: widget)
        defer { session.cleanup() }

        XCTAssertTrue(session.candidates.isEmpty)
        XCTAssertEqual(session.failures.count, 1)
        XCTAssertTrue(session.failures[0].reason.contains("schemaVersion 2"))
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

        let none = try Manifest.decode(from: Data("""
        { "schemaVersion": 1, "id": "q", "name": "q",
          "entry": { "kind": "workflow" } }
        """.utf8))
        XCTAssertTrue(WidgetDiscovery.permissionSummary(for: none).isEmpty)

        let undeclaredExec = try Manifest.decode(from: manifestJSON(
            id: "undeclared-exec",
            extra: """
            , "source": { "kind": "exec", "command": ["./widget.sh"] }
            """
        ))
        XCTAssertEqual(
            WidgetDiscovery.permissionSummary(for: undeclaredExec),
            ["exec: missing required command allowlist"]
        )

        let workflow = WorkflowDefinition(
            sources: ["data": .init(use: "exec")],
            view: .object(["type": .string("text"), "text": .string("ok")])
        )
        XCTAssertEqual(
            WidgetDiscovery.permissionSummary(for: none, workflow: workflow),
            ["exec: missing required command allowlist"]
        )
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

    func testInspectRejectsEntriesThatWouldEscapeTheDestination() {
        for name in ["../evil", "/etc/passwd", "a/../../b", "a//b", "a\\b"] {
            XCTAssertThrowsError(
                try SafeZipExtractor.validatePath(name), "accepted \(name)"
            ) { error in
                XCTAssertEqual(error as? ZipExtractionError, .pathTraversal(name))
            }
        }
        XCTAssertNoThrow(try SafeZipExtractor.validatePath("BarShelf.app/Contents/Info.plist"))
    }

    func testInspectEnforcesTheUncompressedCeilingWithoutWritingAnything() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("inspect-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(repeating: 0x41, count: 64 * 1024)
            .write(to: directory.appendingPathComponent("payload.bin"))

        let archive = directory.appendingPathComponent("payload.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = [
            "-c", "-k", directory.appendingPathComponent("payload.bin").path, archive.path,
        ]
        try process.run()
        process.waitUntilExit()

        let data = try Data(contentsOf: archive)
        XCTAssertNoThrow(try SafeZipExtractor.inspect(zipData: data))
        XCTAssertThrowsError(
            try SafeZipExtractor.inspect(zipData: data, maxExtractedBytes: 1024)
        ) { error in
            XCTAssertEqual(error as? ZipExtractionError, .extractionTooLarge(limitBytes: 1024))
        }
    }

}

final class GitHubSubdirectoryInstallTests: XCTestCase {
    func testSubdirectoryAndArchiveInstallsBothExecuteShebangScripts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = Data("""
        {"schemaVersion":1,"id":"download-test","name":"Download Test",
         "entry":{"kind":"exec"},"source":{"command":["./widget.sh"]},
         "permissions":{"exec":[{"command":"./widget.sh","allowedArgs":[]}]}}
        """.utf8)
        let script = Data("#!/bin/sh\nprintf 'download works'\n".utf8)
        let files = ["widget.json": manifest, "widget.sh": script, "data.txt": Data("ordinary data".utf8)]
        let entries: [[String: String]] = files.keys.sorted().map {
            ["name": $0, "type": "file", "download_url": "https://raw.githubusercontent.com/example/repo/main/widget/\($0)"]
        }
        let listing = try JSONSerialization.data(withJSONObject: entries)
        let raw = root.appendingPathComponent("raw")
        var count = 0
        // Exercise the actual contents-API write path without a live network.
        try await HeadlessInstaller.downloadContents(
            owner: "example", repo: "repo", path: "widget", ref: "main",
            into: raw, depth: 0, fileCount: &count,
            fetch: { request in
                (listing, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            },
            downloadFile: { try XCTUnwrap(files[$0.lastPathComponent]) }
        )
        XCTAssertEqual(count, files.count)

        let archive = root.appendingPathComponent("archive")
        try SafeZipExtractor.extract(zipData: ZipFixture.build(files.map { .file($0.key, $0.value) }), to: archive)
        for (index, source) in [raw, archive].enumerated() {
            let discovery = try WidgetDiscovery.discover(under: source)
            let candidate = InstallCandidate(try XCTUnwrap(discovery.candidates.first))
            let installed = try HeadlessInstaller.install(candidate, into: root.appendingPathComponent("installed-\(index)"), hostVersion: nil)
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: installed.appendingPathComponent("widget.sh").path))
            XCTAssertFalse(FileManager.default.isExecutableFile(atPath: installed.appendingPathComponent("data.txt").path))
            let result = try ExecService.captureSync(command: ["./widget.sh"], discover: nil,
                                                     timeoutMs: 2000, workingDirectory: installed).get()
            XCTAssertEqual(result.exitCode, 0)
            XCTAssertEqual(String(data: result.stdout, encoding: .utf8), "download works")
        }
    }
}

// MARK: - Installed packages by manifest id

/// First-run seeding names starters by folder (`today`), not by id. Installed
/// state and updates find them by the manifest inside, and an install never
/// writes over something that is not the widget it installs.
extension WidgetInstallArchiveTests {
    private var widgets: URL { workDir.appendingPathComponent("widgets", isDirectory: true) }

    @discardableResult
    private func makeWidget(_ name: String, id: String, version: String, in directory: URL? = nil) throws -> URL {
        let folder = (directory ?? widgets).appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try manifestJSON(id: id, extra: ",\n  \"version\": \"\(version)\"")
            .write(to: folder.appendingPathComponent("widget.json"))
        return folder
    }

    private func version(in folder: URL) throws -> String? {
        let data = try Data(contentsOf: folder.appendingPathComponent("widget.json"))
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["version"] as? String
    }

    private func candidate(id: String, version: String) throws -> InstallCandidate {
        let source = try makeWidget(UUID().uuidString, id: id, version: version,
                                    in: workDir.appendingPathComponent("download", isDirectory: true))
        return InstallCandidate(
            manifest: try Manifest.decode(from: Data(contentsOf: source.appendingPathComponent("widget.json"))),
            sourceDirectory: source, permissionSummary: []
        )
    }

    /// Every path under `root`, with each regular file's contents: what must
    /// not change when an install is refused.
    private func tree(_ root: URL) -> [String: Data?] {
        var result: [String: Data?] = [:]
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil, options: []) else { return [:] }
        for case let url as URL in enumerator {
            let relative = String(url.path.dropFirst(root.path.count))
            let isLink = (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
            let contents: Data?
            if isLink {
                contents = Data(("link:" + ((try? fm.destinationOfSymbolicLink(atPath: url.path)) ?? "")).utf8)
            } else {
                contents = try? Data(contentsOf: url) // nil for folders
            }
            // updateValue, not subscript: assigning nil would drop the path.
            result.updateValue(contents, forKey: relative)
        }
        return result
    }

    func testInstalledPackagesAreFoundByManifestIDNotFolderName() throws {
        let today = try makeWidget("today", id: "dev.barshelf.today", version: "0.1.0")
        try makeWidget("dev.barshelf.today--work", id: "dev.barshelf.today", version: "0.1.0")
        try FileManager.default.createSymbolicLink(
            at: widgets.appendingPathComponent("dev.barshelf.today--link"), withDestinationURL: today
        )
        try makeWidget(".install-today-x", id: "dev.barshelf.today", version: "9")
        // A folder named after one widget holding another is that other one.
        let other = try makeWidget("dev.barshelf.clock", id: "dev.barshelf.other", version: "1")
        let broken = widgets.appendingPathComponent("broken", isDirectory: true)
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: broken.appendingPathComponent("widget.json"))
        try Data("x".utf8).write(to: widgets.appendingPathComponent("plain-file"))

        let found = HeadlessInstaller.installedPackages(in: widgets)
        XCTAssertEqual(found["dev.barshelf.today"]?.directory.lastPathComponent, "today",
                       "the seeded folder, not an instance alias (folder or link) or a staging copy")
        XCTAssertEqual(found["dev.barshelf.today"]?.isSymbolicLink, false)
        XCTAssertEqual(found["dev.barshelf.other"]?.directory.lastPathComponent, other.lastPathComponent)
        XCTAssertNil(found["dev.barshelf.clock"], "a folder name is not an install")
        XCTAssertEqual(found.count, 2)
        XCTAssertTrue(HeadlessInstaller.isInstalled(id: "dev.barshelf.today", in: widgets))
        XCTAssertFalse(HeadlessInstaller.isInstalled(id: "dev.barshelf.clock", in: widgets),
                       "a folder named after an id but holding something else is not that widget")
        XCTAssertTrue(HeadlessInstaller.installedPackages(in: widgets, isCancelled: { true }).isEmpty)
    }

    /// Updating a seeded starter replaces its folder in place; no second
    /// `dev.barshelf.today/` appears beside it.
    func testUpdatingASeededStarterReplacesItsFolderInPlace() throws {
        let seeded = try makeWidget("today", id: "dev.barshelf.today", version: "0.1.0")
        let installed = try HeadlessInstaller.install(
            candidate(id: "dev.barshelf.today", version: "0.1.1"), into: widgets, hostVersion: nil
        )
        XCTAssertEqual(installed.lastPathComponent, "today")
        XCTAssertEqual(try version(in: seeded), "0.1.1")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: widgets.path), ["today"],
                       "no id-named copy, staging or backup is left behind")
    }

    /// With both a seeded and an id-named copy, the one BarShelf loads (first
    /// by name, as discovery sorts) is the one updated; the other is left
    /// untouched, never deleted by the installer.
    func testWithTwoCopiesTheLoadedOneIsUpdatedAndTheOtherLeftAlone() throws {
        let canonical = try makeWidget("dev.barshelf.today", id: "dev.barshelf.today", version: "0.1.0")
        let seeded = try makeWidget("today", id: "dev.barshelf.today", version: "0.0.9")
        XCTAssertEqual(HeadlessInstaller.installedPackages(in: widgets)["dev.barshelf.today"]?.directory.lastPathComponent,
                       canonical.lastPathComponent)
        _ = try HeadlessInstaller.install(candidate(id: "dev.barshelf.today", version: "0.2.0"), into: widgets, hostVersion: nil)
        XCTAssertEqual(try version(in: canonical), "0.2.0")
        XCTAssertEqual(try version(in: seeded), "0.0.9")
    }

    /// A failed update leaves the seeded folder and its siblings exactly as
    /// they were.
    func testAFailedUpdateOfASeededStarterKeepsIt() throws {
        try makeWidget("today", id: "dev.barshelf.today", version: "0.1.0")
        try makeWidget("dev.barshelf.clock", id: "dev.barshelf.clock", version: "1")
        let before = tree(widgets)
        let empty = workDir.appendingPathComponent("download/empty", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let broken = InstallCandidate(
            manifest: try Manifest.decode(from: manifestJSON(id: "dev.barshelf.today")),
            sourceDirectory: empty, permissionSummary: []
        )
        XCTAssertThrowsError(try HeadlessInstaller.install(broken, into: widgets, hostVersion: nil))
        XCTAssertEqual(tree(widgets), before)
    }

    /// A widget not installed yet still goes to `<id>/`.
    func testANewWidgetIsInstalledUnderItsID() throws {
        let installed = try HeadlessInstaller.install(
            candidate(id: "dev.barshelf.clock", version: "1"), into: widgets, hostVersion: nil
        )
        XCTAssertEqual(installed.lastPathComponent, "dev.barshelf.clock")
        XCTAssertTrue(HeadlessInstaller.isInstalled(id: "dev.barshelf.clock", in: widgets))
    }

    /// `<id>` is taken by something that is not this widget: a file, a broken
    /// package, another widget's package, or a dangling link. The install is
    /// refused and nothing in the widgets folder changes.
    func testAnOccupiedIDPathIsNeverOverwritten() throws {
        let id = "dev.barshelf.clock"
        let occupants: [(String, () throws -> Void)] = [
            ("file", { try Data("notes".utf8).write(to: self.widgets.appendingPathComponent(id)) }),
            ("broken", {
                let folder = self.widgets.appendingPathComponent(id, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try Data("{ broken".utf8).write(to: folder.appendingPathComponent("widget.json"))
                try Data("keep me".utf8).write(to: folder.appendingPathComponent("notes.txt"))
            }),
            ("foreign", { try self.makeWidget(id, id: "dev.someone.else", version: "3") }),
            ("dangling link", {
                try FileManager.default.createSymbolicLink(
                    atPath: self.widgets.appendingPathComponent(id).path, withDestinationPath: "/nonexistent/\(UUID())"
                )
            }),
        ]
        for (label, occupy) in occupants {
            try? FileManager.default.removeItem(at: widgets)
            try FileManager.default.createDirectory(at: widgets, withIntermediateDirectories: true)
            try occupy()
            let before = tree(widgets)
            XCTAssertThrowsError(try HeadlessInstaller.install(candidate(id: id, version: "2"), into: widgets, hostVersion: nil), label) { error in
                guard case HeadlessInstallError.destinationOccupied = error else {
                    return XCTFail("\(label): \(error)")
                }
                XCTAssertTrue(error.localizedDescription.contains("nothing was changed"), label)
            }
            XCTAssertEqual(tree(widgets), before, label)
        }
    }

    /// A package that is a link counts as installed (BarShelf runs it), but
    /// an update neither replaces the link, nor writes through it, nor puts
    /// a second copy beside it.
    func testALinkedPackageIsInstalledButNotUpdatedThroughTheLink() throws {
        let elsewhere = try makeWidget("my-widget", id: "dev.me.widget", version: "1",
                                       in: workDir.appendingPathComponent("projects", isDirectory: true))
        try FileManager.default.createDirectory(at: widgets, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: widgets.appendingPathComponent("my-widget"), withDestinationURL: elsewhere
        )
        let package = try XCTUnwrap(HeadlessInstaller.installedPackages(in: widgets)["dev.me.widget"])
        XCTAssertTrue(package.isSymbolicLink)
        XCTAssertTrue(HeadlessInstaller.isInstalled(id: "dev.me.widget", in: widgets))

        let before = tree(widgets)
        XCTAssertThrowsError(try HeadlessInstaller.install(candidate(id: "dev.me.widget", version: "2"), into: widgets, hostVersion: nil)) { error in
            guard case HeadlessInstallError.symbolicLinkInstall = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(tree(widgets), before)
        XCTAssertEqual(try version(in: elsewhere), "1", "the linked project is not written")
    }

    /// The write boundary checks the id itself: a public candidate cannot
    /// name a path outside the widgets folder.
    func testAnInvalidIDIsRefusedBeforeAnyWrite() throws {
        try FileManager.default.createDirectory(at: widgets, withIntermediateDirectories: true)
        let source = try makeWidget("src", id: "dev.ok", version: "1",
                                    in: workDir.appendingPathComponent("download", isDirectory: true))
        for id in ["../escape", "a/b", ".hidden", ""] {
            var manifest = try Manifest.decode(from: Data(contentsOf: source.appendingPathComponent("widget.json")))
            manifest.id = id
            let bad = InstallCandidate(manifest: manifest, sourceDirectory: source, permissionSummary: [])
            XCTAssertThrowsError(try HeadlessInstaller.install(bad, into: widgets, hostVersion: nil), id) { error in
                guard case HeadlessInstallError.invalidWidgetID = error else { return XCTFail("\(id): \(error)") }
            }
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: widgets.path), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: workDir.appendingPathComponent("escape").path))
    }
}
