import XCTest
import MbkKit
import MenubucketCore

/// R06 Track A — `mbk new` → `validate` → `pack` → `validate(.mbw)` roundtrip
/// for all three scaffold kinds, in a temporary directory.
final class MbkRoundtripTests: XCTestCase {
    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mbk-roundtrip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workDir, withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    func testExecRoundtrip() throws {
        try assertRoundtrip(kind: .exec, name: "my-exec-widget")
    }

    func testWorkflowRoundtrip() throws {
        try assertRoundtrip(kind: .workflow, name: "my-workflow-widget")
    }

    func testScriptRoundtrip() throws {
        try assertRoundtrip(kind: .script, name: "my-script-widget")
    }

    private func assertRoundtrip(
        kind: WidgetScaffold.Kind, name: String
    ) throws {
        // new
        let widgetDir = workDir.appendingPathComponent(name, isDirectory: true)
        let files = try WidgetScaffold.create(name: name, kind: kind, at: widgetDir)
        XCTAssertTrue(files.contains("widget.json"))

        // validate (directory)
        let dirReport = WidgetValidator.validate(directory: widgetDir)
        XCTAssertTrue(
            dirReport.isValid,
            "\(kind.rawValue) scaffold should validate: \(dirReport.issues)"
        )
        XCTAssertEqual(dirReport.validatedWidgets, ["."])

        // the manifest kind matches the scaffold kind
        let manifest = try Manifest.decode(
            from: Data(contentsOf: widgetDir.appendingPathComponent("widget.json"))
        )
        XCTAssertEqual(manifest.id, name)
        XCTAssertEqual(manifest.entry.kind, kind.rawValue)

        // pack
        let archiveURL = workDir.appendingPathComponent("\(name).mbw")
        let output = try WidgetPacker.pack(directory: widgetDir, output: archiveURL)
        XCTAssertEqual(output.archiveURL, archiveURL.standardizedFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: archiveURL.path))
        // widget files + manifest.sha256
        XCTAssertEqual(output.fileCount, files.count + 1)

        // validate (.mbw) — including the manifest.sha256 checksum check
        let archiveReport = try WidgetValidator.validate(path: archiveURL)
        XCTAssertTrue(
            archiveReport.isValid,
            "packed \(kind.rawValue) archive should validate: \(archiveReport.issues)"
        )
    }

    func testPackedArchiveContainsMatchingSHA256() throws {
        let widgetDir = workDir.appendingPathComponent("sha-widget", isDirectory: true)
        try WidgetScaffold.create(name: "sha-widget", kind: .exec, at: widgetDir)
        let archiveURL = workDir.appendingPathComponent("sha-widget.mbw")
        let output = try WidgetPacker.pack(directory: widgetDir, output: archiveURL)

        let extracted = workDir.appendingPathComponent("extracted", isDirectory: true)
        try SafeZipExtractor.extract(
            zipData: Data(contentsOf: archiveURL), to: extracted
        )
        let recorded = try String(
            contentsOf: extracted.appendingPathComponent("manifest.sha256"),
            encoding: .utf8
        )
        XCTAssertTrue(recorded.hasPrefix(output.manifestSHA256))
        let manifestData = try Data(
            contentsOf: extracted.appendingPathComponent("widget.json")
        )
        XCTAssertEqual(WidgetValidator.sha256Hex(of: manifestData), output.manifestSHA256)
    }

    func testTamperedArchiveFailsValidation() throws {
        let widgetDir = workDir.appendingPathComponent("tamper-widget", isDirectory: true)
        try WidgetScaffold.create(name: "tamper-widget", kind: .exec, at: widgetDir)
        let archiveURL = workDir.appendingPathComponent("tamper-widget.mbw")
        try WidgetPacker.pack(directory: widgetDir, output: archiveURL)

        // Re-pack after modifying widget.json but keeping the old checksum.
        let extracted = workDir.appendingPathComponent("tampered", isDirectory: true)
        try SafeZipExtractor.extract(
            zipData: Data(contentsOf: archiveURL), to: extracted
        )
        let manifestURL = extracted.appendingPathComponent("widget.json")
        var manifest = try String(contentsOf: manifestURL, encoding: .utf8)
        manifest = manifest.replacingOccurrences(
            of: "\"version\": \"0.1.0\"", with: "\"version\": \"6.6.6\""
        )
        try manifest.write(to: manifestURL, atomically: true, encoding: .utf8)

        let report = WidgetValidator.validate(directory: extracted)
        XCTAssertFalse(report.isValid)
        XCTAssertTrue(report.issues.contains {
            $0.file.hasSuffix("manifest.sha256") && $0.message.contains("mismatch")
        }, "expected a checksum mismatch issue, got \(report.issues)")
    }

    func testScaffoldRefusesNonEmptyDirectory() throws {
        let widgetDir = workDir.appendingPathComponent("occupied", isDirectory: true)
        try FileManager.default.createDirectory(
            at: widgetDir, withIntermediateDirectories: true
        )
        try "hi".write(
            to: widgetDir.appendingPathComponent("existing.txt"),
            atomically: true, encoding: .utf8
        )
        XCTAssertThrowsError(
            try WidgetScaffold.create(name: "occupied", kind: .exec, at: widgetDir)
        )
    }

    func testScaffoldRejectsInvalidName() {
        XCTAssertThrowsError(
            try WidgetScaffold.create(
                name: "../evil", kind: .exec,
                at: workDir.appendingPathComponent("evil")
            )
        )
    }
}
