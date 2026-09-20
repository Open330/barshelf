import XCTest
@testable import MenubucketCore

/// The CLI half of the self-update path: `barshelf upgrade` replaces the
/// `barshelf`/`bsf` binaries the way the app replaces its bundle, and has to
/// refuse the same things.
final class CommandLineToolInstallerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-installer-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Preflight

    func testAnEmptyOrMissingArchiveIsRefused() throws {
        let empty = root.appendingPathComponent("empty.tar.gz")
        try Data().write(to: empty)
        XCTAssertThrowsError(try CommandLineToolInstaller.validateArchive(empty))
        XCTAssertThrowsError(
            try CommandLineToolInstaller.validateArchive(root.appendingPathComponent("gone.tar.gz"))
        )
    }

    func testEveryFailureSaysWhatHappenedAndWhatToDo() {
        let failures: [CommandLineToolInstaller.Failure] = [
            .archiveRejected("x"), .extractionFailed("x"), .archiveMissingTool("barshelf"),
            .notARegularFile("bsf"), .destinationNotWritable("/usr/local/bin"),
            .signatureRejected(tool: "barshelf", detail: "not signed"),
            .replaceFailed(tool: "bsf", detail: "x"),
        ]
        for failure in failures {
            XCTAssertFalse(failure.errorDescription?.isEmpty ?? true, "\(failure) says nothing")
            XCTAssertFalse(
                failure.recoverySuggestion?.isEmpty ?? true, "\(failure) suggests nothing"
            )
        }
    }

    func testATarballWithoutTheRequestedToolIsNamedAsSuch() throws {
        let archive = try makeArchive(["bsf": .file(Data("bsf".utf8))])
        let installed = try makeInstalled(["barshelf"])
        XCTAssertThrowsError(
            try CommandLineToolInstaller.install(
                archive: archive, replacing: installed, expectedTeam: "ABCDE12345"
            )
        ) { error in
            guard case let .archiveMissingTool(name) = error as? CommandLineToolInstaller.Failure
            else { return XCTFail("expected archiveMissingTool, got \(error)") }
            XCTAssertEqual(name, "barshelf")
        }
    }

    /// A member called `barshelf` that is a symlink would otherwise have the
    /// signature check follow it out of the staging directory, and the swap
    /// install a link to whatever it pointed at.
    func testASymlinkMemberIsRefusedBeforeItIsEverVerified() throws {
        let archive = try makeArchive(["barshelf": .symlink("/etc/passwd")])
        let staging = root.appendingPathComponent("staging")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try CommandLineToolInstaller.extract(["barshelf"], from: archive, into: staging)
        XCTAssertThrowsError(
            try CommandLineToolInstaller.checkExtracted(
                staging.appendingPathComponent("barshelf"),
                named: "barshelf", signedBy: "ABCDE12345"
            )
        ) { error in
            guard case .notARegularFile = error as? CommandLineToolInstaller.Failure else {
                return XCTFail("expected notARegularFile, got \(error)")
            }
        }
    }

    /// Nothing outside the named members is unpacked — a hostile archive cannot
    /// smuggle a file in next to the binaries it is allowed to replace.
    func testOnlyTheNamedMembersAreUnpacked() throws {
        let archive = try makeArchive([
            "barshelf": .file(Data("new".utf8)),
            "extra.sh": .file(Data("payload".utf8)),
        ])
        let staging = root.appendingPathComponent("staging")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try CommandLineToolInstaller.extract(["barshelf"], from: archive, into: staging)

        let unpacked = try FileManager.default.contentsOfDirectory(atPath: staging.path)
        XCTAssertEqual(unpacked, ["barshelf"])
    }

    func testAnUnwritableDestinationIsRefusedBeforeAnythingIsDownloaded() throws {
        let archive = try makeArchive(["barshelf": .file(Data("new".utf8))])
        XCTAssertThrowsError(
            try CommandLineToolInstaller.install(
                archive: archive,
                replacing: [URL(fileURLWithPath: "/usr/bin/barshelf")],
                expectedTeam: "ABCDE12345"
            )
        ) { error in
            guard case let .destinationNotWritable(path) = error as? CommandLineToolInstaller.Failure
            else { return XCTFail("expected destinationNotWritable, got \(error)") }
            XCTAssertEqual(path, "/usr/bin")
        }
    }

    // MARK: - The path that actually replaces something

    private func borrowSignedBinary() throws -> (url: URL, team: String) {
        guard let fixture = SignedBinaryFixture.shared else {
            throw XCTSkip("no Developer ID signed Mach-O available to install from")
        }
        return fixture
    }

    func testAProperlySignedToolReplacesTheInstalledOne() throws {
        let (binary, team) = try borrowSignedBinary()
        let archive = try makeArchive(["barshelf": .copyOf(binary)])
        let installed = try makeInstalled(["barshelf"])

        try CommandLineToolInstaller.install(
            archive: archive, replacing: installed, expectedTeam: team
        )
        XCTAssertTrue(CodeSignature.isSigned(installed[0], by: team))
    }

    func testTheSameTarballIsRefusedForADifferentDeveloper() throws {
        let (binary, _) = try borrowSignedBinary()
        let archive = try makeArchive(["barshelf": .copyOf(binary)])
        let installed = try makeInstalled(["barshelf"])

        XCTAssertThrowsError(
            try CommandLineToolInstaller.install(
                archive: archive, replacing: installed, expectedTeam: "XXXXXXXXXX"
            )
        ) { error in
            guard case let .signatureRejected(tool, detail) =
                error as? CommandLineToolInstaller.Failure
            else { return XCTFail("expected signatureRejected, got \(error)") }
            XCTAssertEqual(tool, "barshelf")
            XCTAssertEqual(detail, "signed by a different developer")
        }
        XCTAssertEqual(try String(contentsOf: installed[0], encoding: .utf8), "old barshelf")
    }

    /// `barshelf` and `bsf` are one release. If the archive's `bsf` does not
    /// verify, the machine must not be left with a new `barshelf` next to an
    /// old `bsf` — every tool is checked before the first one is swapped.
    func testNothingIsSwappedWhenOneToolFailsVerification() throws {
        let (binary, team) = try borrowSignedBinary()
        let archive = try makeArchive([
            "barshelf": .copyOf(binary),
            "bsf": .file(Data("unsigned".utf8)),
        ])
        let installed = try makeInstalled(["barshelf", "bsf"])

        XCTAssertThrowsError(
            try CommandLineToolInstaller.install(
                archive: archive, replacing: installed, expectedTeam: team
            )
        )
        XCTAssertEqual(try String(contentsOf: installed[0], encoding: .utf8), "old barshelf")
        XCTAssertEqual(try String(contentsOf: installed[1], encoding: .utf8), "old bsf")
    }

    // MARK: - Fixtures

    private enum Member {
        case file(Data)
        case symlink(String)
        case copyOf(URL)
    }

    private func makeArchive(_ members: [String: Member]) throws -> URL {
        let staging = root.appendingPathComponent("archive-src-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        for (name, member) in members {
            let destination = staging.appendingPathComponent(name)
            switch member {
            case let .file(data):
                try data.write(to: destination)
            case let .symlink(target):
                try FileManager.default.createSymbolicLink(
                    atPath: destination.path, withDestinationPath: target
                )
            case let .copyOf(source):
                try FileManager.default.copyItem(at: source, to: destination)
            }
        }
        let archive = root.appendingPathComponent("cli-\(UUID().uuidString).tar.gz")
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-czf", archive.path, "-C", staging.path] + members.keys.sorted()
        try tar.run()
        tar.waitUntilExit()
        XCTAssertEqual(tar.terminationStatus, 0)
        return archive
    }

    private func makeInstalled(_ names: [String]) throws -> [URL] {
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        return try names.map { name in
            let url = bin.appendingPathComponent(name)
            try Data("old \(name)".utf8).write(to: url)
            return url
        }
    }
}

/// A Developer ID signed Mach-O to stand in for a release `barshelf`.
///
/// Nothing in this repository is signed during a test run, so one is borrowed
/// from an installed application — but only one that still validates **after
/// being copied out of its bundle**. An app's main executable usually does not:
/// its signature binds the bundle's `Info.plist`, and moving it produces
/// "invalid Info.plist". A release `barshelf` is signed standalone, so the
/// fixture has to behave the same way or it would be testing something else.
///
/// Resolved once: walking /Applications per test costs more than the tests it
/// feeds.
enum SignedBinaryFixture {
    static let maximumBytes = 25 * 1024 * 1024

    static let shared: (url: URL, team: String)? = locate()

    private static func locate() -> (URL, String)? {
        let fileManager = FileManager.default
        let probe = fileManager.temporaryDirectory
            .appendingPathComponent("barshelf-signed-binary-fixture", isDirectory: true)
        try? fileManager.createDirectory(at: probe, withIntermediateDirectories: true)
        let copy = probe.appendingPathComponent("standalone")

        for candidate in candidates() {
            let size = (try? candidate.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
            guard let size, size > 0, size <= maximumBytes else { continue }
            // A team identifier alone is not acceptance — Apple's own code
            // carries one and fails the Developer ID requirement.
            guard let team = CodeSignature.teamIdentifier(of: candidate) else { continue }
            try? fileManager.removeItem(at: copy)
            guard (try? fileManager.copyItem(at: candidate, to: copy)) != nil else { continue }
            guard CodeSignature.isSigned(copy, by: team) else { continue }
            return (copy, team)
        }
        try? fileManager.removeItem(at: copy)
        return nil
    }

    private static func candidates() -> [URL] {
        let fileManager = FileManager.default
        var found: [URL] = []
        let applications = (try? fileManager.contentsOfDirectory(
            at: URL(fileURLWithPath: "/Applications"),
            includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        for app in applications where app.pathExtension == "app" {
            let executables = (try? fileManager.contentsOfDirectory(
                at: app.appendingPathComponent("Contents/MacOS"),
                includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            found.append(contentsOf: executables.filter {
                (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            })
        }
        return found
    }
}
