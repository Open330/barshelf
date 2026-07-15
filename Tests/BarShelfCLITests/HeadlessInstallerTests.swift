import XCTest
import BarShelfKit
import MenubucketCore

/// R06 공통 계약 1 — HeadlessInstaller against a local zip archive
/// (packed with `WidgetPacker`, i.e. real /usr/bin/zip deflate output).
final class HeadlessInstallerTests: XCTestCase {
    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("barshelf-install-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workDir, withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    private func makeArchive(name: String) throws -> URL {
        let widgetDir = workDir.appendingPathComponent(name, isDirectory: true)
        try WidgetScaffold.create(name: name, kind: .exec, at: widgetDir)
        let archiveURL = workDir.appendingPathComponent("\(name).mbw")
        try WidgetPacker.pack(directory: widgetDir, output: archiveURL)
        return archiveURL
    }

    func testFetchSessionAcceptsLocalDirectory() async throws {
        // `barshelf install ./my-widget` — a widget directory, no packing required.
        let widgetDir = workDir.appendingPathComponent("dir-widget", isDirectory: true)
        try WidgetScaffold.create(name: "dir-widget", kind: .exec, at: widgetDir)

        // Relative and absolute paths both resolve to the same directory install.
        for input in [widgetDir.path, "file://" + widgetDir.path] {
            let session = try await HeadlessInstaller.fetchSession(input: input)
            defer { session.cleanup() }
            XCTAssertEqual(session.candidates.count, 1, "input: \(input)")
            // Staging is a temp copy — the user's source dir must survive cleanup.
            session.cleanup()
            XCTAssertTrue(FileManager.default.fileExists(atPath: widgetDir.path))
        }

        // Install end-to-end from the directory.
        let installedRoot = workDir.appendingPathComponent("installed", isDirectory: true)
        let candidates = try await HeadlessInstaller.fetchCandidates(from: URL(fileURLWithPath: widgetDir.path))
        let dest = try HeadlessInstaller.install(candidates[0], into: installedRoot)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("widget.json").path))
    }

    func testFetchCandidatesFromLocalZipAndInstall() async throws {
        let archiveURL = try makeArchive(name: "local-widget")

        let candidates = try await HeadlessInstaller.fetchCandidates(from: archiveURL)
        XCTAssertEqual(candidates.count, 1)
        let candidate = try XCTUnwrap(candidates.first)
        XCTAssertEqual(candidate.manifest.id, "local-widget")
        XCTAssertEqual(candidate.manifest.entry.kind, "exec")
        XCTAssertEqual(candidate.displayVersion, "0.1.0")
        XCTAssertEqual(candidate.permissionSummary, ["exec: ./widget.sh"])

        let widgetsDir = workDir.appendingPathComponent("widgets", isDirectory: true)
        let installed = try HeadlessInstaller.install(candidate, into: widgetsDir)
        XCTAssertEqual(installed.lastPathComponent, "local-widget")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: installed.appendingPathComponent("widget.json").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: installed.appendingPathComponent("widget.sh").path
        ))
        XCTAssertTrue(HeadlessInstaller.isInstalled(id: "local-widget", in: widgetsDir))
    }

    func testReinstallReplacesExistingDirectory() async throws {
        let archiveURL = try makeArchive(name: "twice-widget")
        let widgetsDir = workDir.appendingPathComponent("widgets", isDirectory: true)

        let first = try await HeadlessInstaller.fetchCandidates(from: archiveURL)
        let installed = try HeadlessInstaller.install(
            try XCTUnwrap(first.first), into: widgetsDir
        )
        // Leftover from the "old" install must not survive an update.
        let leftover = installed.appendingPathComponent("stale-file.txt")
        try "stale".write(to: leftover, atomically: true, encoding: .utf8)

        let second = try await HeadlessInstaller.fetchCandidates(from: archiveURL)
        let reinstalled = try HeadlessInstaller.install(
            try XCTUnwrap(second.first), into: widgetsDir
        )
        XCTAssertEqual(installed, reinstalled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: leftover.path))
    }

    func testFailedUpdateKeepsExistingInstall() throws {
        let widgetsDir = workDir.appendingPathComponent("widgets", isDirectory: true)
        let existing = widgetsDir.appendingPathComponent("safe-widget", isDirectory: true)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        let marker = existing.appendingPathComponent("working.txt")
        try "still here".write(to: marker, atomically: true, encoding: .utf8)

        let missingSource = workDir.appendingPathComponent("missing-source", isDirectory: true)
        let manifest = Manifest(
            schemaVersion: 1, id: "safe-widget", name: "Safe",
            entry: .init(kind: "workflow")
        )
        let candidate = InstallCandidate(
            manifest: manifest, sourceDirectory: missingSource, permissionSummary: []
        )

        XCTAssertThrowsError(try HeadlessInstaller.install(candidate, into: widgetsDir))
        XCTAssertEqual(try String(contentsOf: marker), "still here")
    }

    func testFetchSessionAcceptsLocalPathString() async throws {
        let archiveURL = try makeArchive(name: "path-widget")

        // Plain filesystem path (what `barshelf install ./x.mbw` passes through).
        let session = try await HeadlessInstaller.fetchSession(input: archiveURL.path)
        defer { session.cleanup() }
        XCTAssertEqual(session.candidates.map(\.manifest.id), ["path-widget"])
        XCTAssertTrue(session.failures.isEmpty)
    }

    func testFetchSessionRejectsMissingLocalArchive() async {
        do {
            _ = try await HeadlessInstaller.fetchSession(
                input: workDir.appendingPathComponent("missing.mbw").path
            )
            XCTFail("expected an error")
        } catch {
            // Missing local files fall through to URL parsing, which rejects
            // non-URL input.
        }
    }

    func testFetchCandidatesFailsOnArchiveWithoutWidgets() async throws {
        // A zip with no widget.json anywhere.
        let emptyDir = workDir.appendingPathComponent("no-widget", isDirectory: true)
        try FileManager.default.createDirectory(
            at: emptyDir, withIntermediateDirectories: true
        )
        try "just text".write(
            to: emptyDir.appendingPathComponent("readme.txt"),
            atomically: true, encoding: .utf8
        )
        let zipURL = workDir.appendingPathComponent("no-widget.zip")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.arguments = ["-X", "-q", zipURL.path, "readme.txt"]
        zip.currentDirectoryURL = emptyDir
        try zip.run()
        zip.waitUntilExit()
        XCTAssertEqual(zip.terminationStatus, 0)

        do {
            _ = try await HeadlessInstaller.fetchCandidates(from: zipURL)
            XCTFail("expected noWidgetsFound")
        } catch let error as HeadlessInstallError {
            guard case .noWidgetsFound = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testListWidgetsExitCodes() throws {
        let widgetsDir = workDir.appendingPathComponent("installed", isDirectory: true)
        // Missing directory → still exit 0 ("no widgets installed").
        XCTAssertEqual(BarShelfMain.listWidgets(in: widgetsDir), 0)

        let widgetDir = widgetsDir.appendingPathComponent("list-widget", isDirectory: true)
        try WidgetScaffold.create(name: "list-widget", kind: .exec, at: widgetDir)
        XCTAssertEqual(BarShelfMain.listWidgets(in: widgetsDir), 0)
    }
}
