import XCTest
@testable import BarShelfKit
import MenubucketCore

/// R06 Track A — `barshelf new` → `validate` → `pack` → `validate(.mbw)` roundtrip
/// for all three scaffold kinds, in a temporary directory.
final class BarShelfRoundtripTests: XCTestCase {
    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("barshelf-roundtrip-\(UUID().uuidString)", isDirectory: true)
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

    func testHiddenEntryAndDependenciesSurvivePacking() throws {
        let widget = workDir.appendingPathComponent("hidden")
        try WidgetScaffold.create(name: "hidden", kind: .script, at: widget)
        let manifestURL = widget.appendingPathComponent("widget.json")
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        manifest["entry"] = ["kind": "script", "runtime": "deno-ts@1", "main": ".entry.ts"]
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
        try FileManager.default.moveItem(at: widget.appendingPathComponent("index.ts"),
                                        to: widget.appendingPathComponent(".entry.ts"))
        let dependencies = widget.appendingPathComponent(".lib")
        try FileManager.default.createDirectory(at: dependencies, withIntermediateDirectories: true)
        let dependency = "export const value = 42;"
        try dependency.write(to: dependencies.appendingPathComponent("value.ts"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: widget.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try "metadata".write(to: widget.appendingPathComponent(".git/config"), atomically: true, encoding: .utf8)

        let archive = workDir.appendingPathComponent("hidden.mbw")
        try WidgetPacker.pack(directory: widget, output: archive)
        XCTAssertTrue(try WidgetValidator.validate(path: archive).isValid)
        let extracted = workDir.appendingPathComponent("hidden-extracted")
        try SafeZipExtractor.extract(zipData: Data(contentsOf: archive), to: extracted)
        XCTAssertTrue(FileManager.default.fileExists(atPath: extracted.appendingPathComponent(".entry.ts").path))
        XCTAssertEqual(try String(contentsOf: extracted.appendingPathComponent(".lib/value.ts"), encoding: .utf8), dependency)
        XCTAssertFalse(FileManager.default.fileExists(atPath: extracted.appendingPathComponent(".git").path))
    }

    func testPackingRejectsInternalAndEscapingSymlinksWithoutReplacingOutput() throws {
        let widget = workDir.appendingPathComponent("links")
        try WidgetScaffold.create(name: "links", kind: .script, at: widget)
        let output = workDir.appendingPathComponent("existing.mbw")
        let original = Data("previous archive".utf8)
        try original.write(to: output)
        let link = widget.appendingPathComponent("dependency.ts")
        for target in ["index.ts", "../existing.mbw"] {
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target)
            XCTAssertThrowsError(try WidgetPacker.pack(directory: widget, output: output)) { error in
                XCTAssertEqual(error as? WidgetPacker.PackError, .symbolicLink("dependency.ts"))
            }
            XCTAssertEqual(try Data(contentsOf: output), original)
            try FileManager.default.removeItem(at: link)
        }
    }

    func testPackingKeepsHiddenCodeButExcludesPrivateConfiguration() throws {
        let widget = workDir.appendingPathComponent("private-config")
        try WidgetScaffold.create(name: "private-config", kind: .script, at: widget)
        let privatePaths = [".env", ".env.production", ".envrc", ".npmrc", ".netrc", "secret.pem", "private.key", ".claude/settings.local.json", ".vscode/settings.json"]
        for path in privatePaths {
            let file = widget.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "TOKEN=must-not-distribute".write(to: file, atomically: true, encoding: .utf8)
        }
        try "export const publicValue = 42;".write(to: widget.appendingPathComponent(".module.ts"), atomically: true, encoding: .utf8)
        try "export const value = 1;".write(to: widget.appendingPathComponent("-source.ts"), atomically: true, encoding: .utf8)
        let archive = workDir.appendingPathComponent("safe.mbw")
        let output = try WidgetPacker.pack(directory: widget, output: archive)
        XCTAssertTrue(output.excludedPaths.contains(".env"))
        XCTAssertTrue(output.excludedPaths.contains(".claude"))
        let extracted = workDir.appendingPathComponent("safe-extracted")
        try SafeZipExtractor.extract(zipData: Data(contentsOf: archive), to: extracted)
        for path in privatePaths {
            XCTAssertFalse(FileManager.default.fileExists(atPath: extracted.appendingPathComponent(path).path), path)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: extracted.appendingPathComponent(".module.ts").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: extracted.appendingPathComponent("-source.ts").path))
        XCTAssertTrue(WidgetValidator.validate(directory: extracted).isValid)
    }

    private func packageFiles(_ directory: URL) throws -> [String: Data] {
        let root = directory.standardizedFileURL.path + "/"
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: []))
        var files: [String: Data] = [:]
        for case let file as URL in enumerator {
            if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                files[String(file.standardizedFileURL.path.dropFirst(root.count))] = try Data(contentsOf: file)
            }
        }
        return files
    }

    func testStandardCredentialAndDevelopmentFilesNeverReachArchiveButHiddenModulesDo() throws {
        let widget = workDir.appendingPathComponent("standard-private-files")
        try WidgetScaffold.create(name: "standard-private-files", kind: .script, at: widget)
        let privatePaths = [
            ".mcp.json", ".mcp.json.local", ".cursor/mcp.json", ".gemini/settings.json",
            ".docker/config.json", ".kube/config", ".config/gcloud/application_default_credentials.json",
            ".pgpass", ".yarnrc.yml", ".yarnrc", ".pnpmrc", ".terraformrc", "terraform.rc",
            ".terraform/providers/credentials", "terraform.tfstate", "terraform.tfstate.backup",
            ".s3cfg", ".boto", ".dev.vars", ".dev.vars.staging", ".vault-token", ".envrc.local",
            ".gitconfig", ".hg/hgrc", ".hgrc", ".svn/wc.db",
            ".bash_history", ".zsh_history", ".sh_history", ".ash_history", ".history",
            ".python_history", ".node_repl_history", ".irb_history", ".pry_history", ".rediscli_history",
            ".mysql_history", ".psql_history", ".sqlite_history", ".fish_history", "fish_history",
            ".bash_sessions/session.history", ".zsh_sessions/session.history", ".lesshst", ".viminfo",
            ".entry.ts.swp", ".entry.ts.swo", ".entry.ts.swn", "index.ts~", "#index.ts#", ".#index.ts",
            "id_rsa", "id_ed25519", "id_ecdsa", "id_dsa", "id_xmss", "id_ed25519_sk", "id_ecdsa_sk",
            "keys/client.p12", "keys/client.PFX", "keys/client.p8", "keys/client.jks", "keys/client.keystore",
            "keys/client.ppk", "keys/client.pkcs12", "keys/client.pkcs8", "vendor/.AWS/credentials",
        ]
        for (index, path) in privatePaths.enumerated() {
            let file = widget.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("PRIVATE_SENTINEL_\(index)_MUST_NOT_SHIP".utf8).write(to: file)
        }
        let safeHidden = [
            ".entry.ts": "import { value } from './.lib/value.ts'; console.log(value);",
            ".lib/value.ts": "export const value = 42;",
            ".lib/credentials.ts": "export const credentialSettingName = 'token';",
            ".feature/module.ts": "export const feature = true;",
        ]
        for (path, code) in safeHidden {
            let file = widget.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(code.utf8).write(to: file)
        }
        let manifestURL = widget.appendingPathComponent("widget.json")
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        manifest["entry"] = ["kind": "script", "runtime": "deno-ts@1", "main": ".entry.ts"]
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
        let sourceBefore = try packageFiles(widget)
        let archive = workDir.appendingPathComponent("standard-private-files.mbw")
        let output = try WidgetPacker.pack(directory: widget, output: archive)
        let extracted = workDir.appendingPathComponent("standard-private-files-extracted")
        try SafeZipExtractor.extract(zipData: Data(contentsOf: archive), to: extracted)
        let shared = try packageFiles(extracted)
        for path in privatePaths {
            XCTAssertNil(shared[path], path)
            XCTAssertTrue(output.excludedPaths.contains { path == $0 || path.hasPrefix($0 + "/") },
                          "exclusion must be reported: \(path)")
        }
        XCTAssertFalse(shared.values.contains { String(decoding: $0, as: UTF8.self).contains("PRIVATE_SENTINEL_") })
        for (path, code) in safeHidden { XCTAssertEqual(shared[path], Data(code.utf8), path) }
        XCTAssertEqual(try packageFiles(widget), sourceBefore, "packing must never remove local private files")
        XCTAssertTrue(try WidgetValidator.validate(path: archive).isValid)
    }

    func testUnsafePackDestinationsPreserveSourceAndExistingDirectories() throws {
        let widget = workDir.appendingPathComponent("source")
        try WidgetScaffold.create(name: "source", kind: .script, at: widget)
        let other = workDir.appendingPathComponent("keep-this-directory")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try Data("unrelated user file".utf8).write(to: other.appendingPathComponent("keep.txt"))
        let before = try packageFiles(workDir)
        for output in [widget, widget.appendingPathComponent("widget.json"), widget.appendingPathComponent("index.ts"),
                       widget.appendingPathComponent("new/release.mbw"), other, workDir!] {
            XCTAssertThrowsError(try WidgetPacker.pack(directory: widget, output: output)) { error in
                guard case WidgetPacker.PackError.unsafeOutput = error else { return XCTFail("\(error)") }
            }
            XCTAssertEqual(try packageFiles(workDir), before)
            var directory: ObjCBool = false
            XCTAssertTrue(FileManager.default.fileExists(atPath: widget.path, isDirectory: &directory))
            XCTAssertTrue(directory.boolValue)
            XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
        }
    }

    func testPackBoundaryResolvesSourceAndDestinationParentSymlinks() throws {
        let widget = workDir.appendingPathComponent("real-source")
        try WidgetScaffold.create(name: "real-source", kind: .script, at: widget)
        let alias = workDir.appendingPathComponent("source-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: widget)
        let outputLink = workDir.appendingPathComponent("output.mbw")
        let manifest = widget.appendingPathComponent("widget.json")
        try FileManager.default.createSymbolicLink(at: outputLink, withDestinationURL: manifest)
        let before = try packageFiles(widget)
        for output in [outputLink, alias.appendingPathComponent("new/output.mbw"), widget.appendingPathComponent("output.mbw")] {
            XCTAssertThrowsError(try WidgetPacker.pack(directory: alias, output: output)) { error in
                guard case WidgetPacker.PackError.unsafeOutput = error else { return XCTFail("\(error)") }
            }
            XCTAssertEqual(try packageFiles(widget), before)
        }
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: outputLink.path), manifest.path)
    }

    func testDefaultPackOutputInsideCurrentPackageReportsActionableError() throws {
        let widget = workDir.appendingPathComponent("current-package")
        try WidgetScaffold.create(name: "current-package", kind: .script, at: widget)
        let before = try packageFiles(widget)
        // Exercise production default resolution without changing the test
        // process's global working directory while other tests are running.
        XCTAssertThrowsError(try WidgetPacker.pack(directory: widget, output: nil,
            operations: .init(currentDirectory: widget))) { error in
            XCTAssertTrue(error.localizedDescription.contains("outside the widget directory"))
            XCTAssertTrue(error.localizedDescription.contains("-o ../widget.mbw"))
        }
        XCTAssertEqual(try packageFiles(widget), before)
    }

    func testZipAndCommitFailuresPreservePreviousArchiveAndCleanTemporaryFiles() throws {
        let widget = workDir.appendingPathComponent("failure-source")
        try WidgetScaffold.create(name: "failure-source", kind: .script, at: widget)
        let output = workDir.appendingPathComponent("previous.mbw")
        try WidgetPacker.pack(directory: widget, output: output)
        let before = try packageFiles(workDir)
        let entries = try FileManager.default.contentsOfDirectory(atPath: workDir.path).sorted()
        var failedZip = WidgetPacker.Operations()
        failedZip.zip = { temporary, _, _ in
            try Data("partial failed archive".utf8).write(to: temporary)
            throw WidgetPacker.PackError.zipFailed(status: 1, output: "injected failure")
        }
        var failedCommit = WidgetPacker.Operations()
        failedCommit.commit = { temporary, _ in
            XCTAssertTrue(FileManager.default.fileExists(atPath: temporary.path))
            throw CocoaError(.fileWriteNoPermission)
        }
        var missingTemporaryArchive = WidgetPacker.Operations()
        let zip = missingTemporaryArchive.zip
        missingTemporaryArchive.zip = { temporary, files, staging in
            try zip(temporary, files, staging)
            try FileManager.default.removeItem(at: temporary) // real rename must fail, preserving destination
        }
        for operations in [failedZip, failedCommit, missingTemporaryArchive] {
            XCTAssertThrowsError(try WidgetPacker.pack(directory: widget, output: output, operations: operations))
            XCTAssertEqual(try packageFiles(workDir), before)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: workDir.path).sorted(), entries)
            XCTAssertTrue(try WidgetValidator.validate(path: output).isValid)
        }
    }

    func testValidationFailureKeepsPreviousArchiveAndInvalidSourceBytes() throws {
        let widget = workDir.appendingPathComponent("validation-source")
        try WidgetScaffold.create(name: "validation-source", kind: .script, at: widget)
        let output = workDir.appendingPathComponent("valid-before.mbw")
        try WidgetPacker.pack(directory: widget, output: output)
        let archive = try Data(contentsOf: output)
        let manifest = widget.appendingPathComponent("widget.json")
        let invalid = Data("not json".utf8)
        try invalid.write(to: manifest)
        XCTAssertThrowsError(try WidgetPacker.pack(directory: widget, output: output))
        XCTAssertEqual(try Data(contentsOf: output), archive)
        XCTAssertEqual(try Data(contentsOf: manifest), invalid)
    }

    func testRepeatedExternalPackingExcludesOldArchivesAndTheirPrivatePayload() throws {
        let widget = workDir.appendingPathComponent("repeat-source")
        try WidgetScaffold.create(name: "repeat-source", kind: .script, at: widget)
        let legacySecret = widget.appendingPathComponent("legacy-secret.txt")
        try Data("LEGACY_SECRET_MUST_NOT_LEAK".utf8).write(to: legacySecret)
        let oldArchive = workDir.appendingPathComponent("old.mbw")
        try WidgetPacker.pack(directory: widget, output: oldArchive)
        try FileManager.default.removeItem(at: legacySecret)
        let nested = widget.appendingPathComponent("old-release.mbw")
        try FileManager.default.copyItem(at: oldArchive, to: nested)
        let oldBytes = try Data(contentsOf: nested)
        try Data("CURRENT_SECRET_MUST_NOT_LEAK".utf8).write(to: widget.appendingPathComponent(".env"))
        let output = workDir.appendingPathComponent("release.mbw")
        try WidgetPacker.pack(directory: widget, output: output)
        let updatedCode = Data("console.log('second release');".utf8)
        try updatedCode.write(to: widget.appendingPathComponent("index.ts"))
        let second = try WidgetPacker.pack(directory: widget, output: output)
        XCTAssertTrue(second.excludedPaths.contains("old-release.mbw"))
        XCTAssertTrue(second.excludedPaths.contains(".env"))
        let extracted = workDir.appendingPathComponent("second-release")
        try SafeZipExtractor.extract(zipData: Data(contentsOf: output), to: extracted)
        let files = try packageFiles(extracted)
        XCTAssertFalse(files.keys.contains { $0.lowercased().hasSuffix(".mbw") })
        XCTAssertFalse(files.values.contains { String(decoding: $0, as: UTF8.self).contains("SECRET_MUST_NOT_LEAK") })
        XCTAssertEqual(files["index.ts"], updatedCode)
        XCTAssertEqual(try Data(contentsOf: nested), oldBytes)
        XCTAssertTrue(try WidgetValidator.validate(path: output).isValid)
    }

    func testExternalOutputThroughSymlinkedParentCanBeReplacedSafely() throws {
        let widget = workDir.appendingPathComponent("external-source")
        try WidgetScaffold.create(name: "external-source", kind: .script, at: widget)
        let directory = workDir.appendingPathComponent("external-output")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let alias = workDir.appendingPathComponent("output-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory)
        let output = alias.appendingPathComponent("release.mbw")
        try WidgetPacker.pack(directory: widget, output: output)
        let updated = Data("console.log('updated');".utf8)
        try updated.write(to: widget.appendingPathComponent("index.ts"))
        let result = try WidgetPacker.pack(directory: widget, output: output)
        XCTAssertEqual(result.archiveURL, output.standardizedFileURL)
        XCTAssertTrue(try WidgetValidator.validate(path: output).isValid)
        let extracted = workDir.appendingPathComponent("external-extracted")
        try SafeZipExtractor.extract(zipData: Data(contentsOf: output), to: extracted)
        XCTAssertEqual(try Data(contentsOf: extracted.appendingPathComponent("index.ts")), updated)
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
        if kind == .workflow {
            XCTAssertEqual(manifest.permissions?.readPaths, ["~/Downloads"])
        }

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
