import XCTest
@testable import MenubucketCore

/// The installer's job is mostly to *refuse*, so most of these assert that a
/// bad update changes nothing on disk.
final class UpdateInstallerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("update-installer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A directory shaped like an app bundle. Unsigned, which is the point:
    /// nothing may accept it as an update.
    @discardableResult
    private func makeApp(
        named name: String, in directory: URL, version: String = "9.9.9", marker: String = "new"
    ) throws -> URL {
        let app = directory.appendingPathComponent(name)
        let macOS = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try marker.write(
            to: macOS.appendingPathComponent("barshelf-app"), atomically: true, encoding: .utf8
        )
        let plist: [String: Any] = [
            "CFBundleShortVersionString": version,
            "CFBundleExecutable": "barshelf-app",
            "CFBundleIdentifier": "com.barshelf.app",
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0
        )
        try data.write(to: app.appendingPathComponent("Contents/Info.plist"))
        return app
    }

    private func zip(_ url: URL, to archive: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--keepParent", url.path, archive.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "ditto failed to build the fixture archive")
    }

    // MARK: - Eligibility

    func testHomebrewInstallsArePointedAtBrewInsteadOfSelfUpdating() {
        let blocker = UpdateInstaller.blocker(
            appURL: URL(fileURLWithPath: "/Applications/BarShelf.app"),
            hostTeam: "ABCDE12345",
            isWritable: { _ in true },
            fileExists: { $0 == "/opt/homebrew/Caskroom/barshelf" }
        )
        // Self-updating would desync brew's records, so it wins over every
        // other consideration — including being perfectly able to do it.
        XCTAssertEqual(blocker, .homebrewManaged)
    }

    func testAnUnsignedHostCannotVerifyAnythingAndSoRefuses() {
        let blocker = UpdateInstaller.blocker(
            appURL: URL(fileURLWithPath: "/Applications/BarShelf.app"),
            hostTeam: nil,
            isSandboxed: false,
            isWritable: { _ in true },
            fileExists: { _ in false }
        )
        XCTAssertEqual(blocker, .notSigned)
    }

    func testAReadOnlyLocationBlocksInstalling() {
        XCTAssertEqual(
            UpdateInstaller.blocker(
                appURL: URL(fileURLWithPath: "/Applications/BarShelf.app"),
                hostTeam: "ABCDE12345",
                isSandboxed: false,
                isWritable: { _ in false },
                fileExists: { _ in false }
            ),
            .notWritable
        )
    }

    func testOnlyTheParentDirectoryNeedsToBeWritable() {
        // An app installed by a package is mode 755 root:wheel inside while
        // /Applications stays group-writable by admins. `replaceItemAt` renames
        // into the parent and unlinks from it, so that install can be updated —
        // refusing it would strand those users on the manual download.
        XCTAssertNil(
            UpdateInstaller.blocker(
                appURL: URL(fileURLWithPath: "/Applications/BarShelf.app"),
                hostTeam: "ABCDE12345",
                isSandboxed: false,
                isWritable: { $0 == "/Applications" },
                fileExists: { _ in false }
            )
        )
    }

    func testASignedWritableNonBrewInstallIsEligible() {
        XCTAssertNil(
            UpdateInstaller.blocker(
                appURL: URL(fileURLWithPath: "/Applications/BarShelf.app"),
                hostTeam: "ABCDE12345",
                isSandboxed: false,
                isWritable: { _ in true },
                fileExists: { _ in false }
            )
        )
    }

    func testAnAppStoreBuildDefersToTheStore() {
        // A sandboxed build cannot spawn ditto or spctl, and the Store owns its
        // updates — offering "Install and Relaunch" would fail at the first
        // Process launch with an unactionable message.
        XCTAssertEqual(
            UpdateInstaller.blocker(
                appURL: URL(fileURLWithPath: "/Applications/BarShelf.app"),
                hostTeam: "ABCDE12345",
                isSandboxed: true,
                isWritable: { _ in true },
                fileExists: { _ in false }
            ),
            .sandboxed
        )
    }

    func testHomebrewOnlyClaimsTheCopyHomebrewActuallyInstalled() {
        // Someone can have the cask installed *and* run a build from elsewhere.
        // Telling them to `brew upgrade` would upgrade the other copy and leave
        // this one stranded forever.
        XCTAssertNil(
            UpdateInstaller.blocker(
                appURL: URL(fileURLWithPath: "/Users/someone/Builds/BarShelf.app"),
                hostTeam: "ABCDE12345",
                isSandboxed: false,
                isWritable: { _ in true },
                fileExists: { $0 == "/opt/homebrew/Caskroom/barshelf" }
            )
        )
    }

    func testTheCaskPathAloneIsNotEnoughWithoutACaskroom() {
        // The standard location is also where a manual install goes.
        XCTAssertNil(
            UpdateInstaller.blocker(
                appURL: URL(fileURLWithPath: UpdateInstaller.homebrewAppPath),
                hostTeam: "ABCDE12345",
                isSandboxed: false,
                isWritable: { _ in true },
                fileExists: { _ in false }
            )
        )
    }

    // MARK: - Archive handling

    func testExpandRoundTripsAnAppBundle() throws {
        let source = root.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try makeApp(named: "BarShelf.app", in: source)
        let archive = root.appendingPathComponent("BarShelf.zip")
        try zip(source.appendingPathComponent("BarShelf.app"), to: archive)

        let destination = root.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try UpdateInstaller.expand(archive: archive, into: destination)

        let app = try UpdateInstaller.locateApp(in: destination)
        XCTAssertEqual(app.lastPathComponent, "BarShelf.app")
        XCTAssertEqual(UpdateInstaller.installedVersion(of: app), "9.9.9")
    }

    func testExpandReportsWhyItFailed() {
        let missing = root.appendingPathComponent("nope.zip")
        XCTAssertThrowsError(
            try UpdateInstaller.expand(archive: missing, into: root)
        ) { error in
            guard case .extractionFailed = error as? UpdateInstaller.Failure else {
                return XCTFail("expected extractionFailed, got \(error)")
            }
        }
    }

    func testAnArchiveWithoutExactlyOneAppIsRefused() throws {
        let empty = root.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        XCTAssertThrowsError(try UpdateInstaller.locateApp(in: empty)) { error in
            XCTAssertEqual(error as? UpdateInstaller.Failure, .archiveHasNoApp)
        }

        let several = root.appendingPathComponent("several")
        try FileManager.default.createDirectory(at: several, withIntermediateDirectories: true)
        try makeApp(named: "BarShelf.app", in: several)
        try makeApp(named: "Other.app", in: several)
        XCTAssertThrowsError(try UpdateInstaller.locateApp(in: several)) { error in
            // Guessing which one to install is exactly the wrong move.
            XCTAssertEqual(error as? UpdateInstaller.Failure, .archiveHasSeveralApps)
        }
    }

    // MARK: - Refusal leaves the installed copy alone

    func testAnUnsignedUpdateIsRejectedAndTheInstalledCopySurvives() throws {
        let installed = try makeApp(named: "BarShelf.app", in: root, version: "1.0.0", marker: "old")
        let staging = root.appendingPathComponent("staging")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let replacement = try makeApp(
            named: "BarShelf.app", in: staging, version: "9.9.9", marker: "new"
        )
        let archive = root.appendingPathComponent("update.zip")
        try zip(replacement, to: archive)

        XCTAssertThrowsError(
            try UpdateInstaller.install(
                archive: archive, replacing: installed,
                expectedTeam: "ABCDE12345", expectedBundleID: nil
            )
        ) { error in
            guard case .signatureRejected = error as? UpdateInstaller.Failure else {
                return XCTFail("expected signatureRejected, got \(error)")
            }
        }

        // The whole contract: a refused update is a no-op on disk.
        let executable = installed.appendingPathComponent("Contents/MacOS/barshelf-app")
        XCTAssertEqual(try String(contentsOf: executable, encoding: .utf8), "old")
        XCTAssertEqual(UpdateInstaller.installedVersion(of: installed), "1.0.0")
    }

    func testAnUnwritableDestinationFailsBeforeAnythingIsDownloadedIntoPlace() throws {
        // access(2) reports true for uid 0 whatever the mode bits say, so as
        // root this would silently exercise a different path and then fail.
        try XCTSkipIf(getuid() == 0, "root bypasses the permission bits this asserts on")
        let installed = try makeApp(named: "BarShelf.app", in: root)
        let archive = root.appendingPathComponent("update.zip")
        try zip(installed, to: archive)

        let parent = installed.deletingLastPathComponent()
        let original = try FileManager.default.attributesOfItem(atPath: parent.path)[.posixPermissions]
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500], ofItemAtPath: parent.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: original ?? 0o755], ofItemAtPath: parent.path
            )
        }

        XCTAssertThrowsError(
            try UpdateInstaller.install(
                archive: archive, replacing: installed,
                expectedTeam: "ABCDE12345", expectedBundleID: nil
            )
        ) { error in
            guard case .destinationNotWritable = error as? UpdateInstaller.Failure else {
                return XCTFail("expected destinationNotWritable, got \(error)")
            }
        }
    }

    func testEveryFailureExplainsItselfAndWhatToDo() {
        let failures: [UpdateInstaller.Failure] = [
            .hostNotSigned, .destinationNotWritable("/Applications"),
            .extractionFailed("bad"), .archiveHasNoApp, .archiveHasSeveralApps,
            .signatureRejected("signed by a different developer"),
            .gatekeeperRejected, .replaceFailed("busy"),
        ]
        for failure in failures {
            XCTAssertFalse(
                failure.errorDescription?.isEmpty ?? true, "\(failure) has no description"
            )
            XCTAssertFalse(
                failure.recoverySuggestion?.isEmpty ?? true, "\(failure) suggests nothing"
            )
        }
    }

    func testAnArchiveThatIsNotAZipIsRefusedBeforeDittoSeesIt() throws {
        let archive = root.appendingPathComponent("not-a-zip.zip")
        try Data(repeating: 0x41, count: 4096).write(to: archive)
        XCTAssertThrowsError(try UpdateInstaller.validateArchive(archive)) { error in
            guard case .archiveRejected = error as? UpdateInstaller.Failure else {
                return XCTFail("expected archiveRejected, got \(error)")
            }
        }
    }

    func testAnEmptyOrMissingArchiveIsRefused() throws {
        let empty = root.appendingPathComponent("empty.zip")
        try Data().write(to: empty)
        XCTAssertThrowsError(try UpdateInstaller.validateArchive(empty))
        XCTAssertThrowsError(
            try UpdateInstaller.validateArchive(root.appendingPathComponent("absent.zip"))
        )
    }

    func testAValidArchivePassesPreflight() throws {
        let source = root.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try makeApp(named: "BarShelf.app", in: source)
        let archive = root.appendingPathComponent("ok.zip")
        try zip(source.appendingPathComponent("BarShelf.app"), to: archive)
        XCTAssertNoThrow(try UpdateInstaller.validateArchive(archive))
    }

    func testABuildOfADifferentProductIsRefusedEvenWhenCorrectlySigned() throws {
        let installed = try makeApp(named: "BarShelf.app", in: root, version: "1.0.0")
        let staging = root.appendingPathComponent("staging")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let replacement = try makeApp(named: "BarShelf.app", in: staging)
        let archive = root.appendingPathComponent("update.zip")
        try zip(replacement, to: archive)

        // The fixture's identifier is com.barshelf.app; asking for another one
        // stands in for a same-developer build of a different product.
        XCTAssertThrowsError(
            try UpdateInstaller.install(
                archive: archive, replacing: installed,
                expectedTeam: "ABCDE12345", expectedBundleID: "com.example.other"
            )
        ) { error in
            guard case let .identityMismatch(expected, found) = error as? UpdateInstaller.Failure
            else { return XCTFail("expected identityMismatch, got \(error)") }
            XCTAssertEqual(expected, "com.example.other")
            XCTAssertEqual(found, "com.barshelf.app")
        }
        XCTAssertEqual(UpdateInstaller.installedVersion(of: installed), "1.0.0")
    }

    // MARK: - Undoing an install that does not run

    /// The whole point of keeping the old bundle: an update the kernel refuses
    /// to launch must not be the only thing left on disk.
    func testRollingBackPutsThePreviousBundleBack() throws {
        let app = try makeApp(named: "BarShelf.app", in: root, version: "2.0.0")
        let previous = try makeApp(named: ".BarShelf.app.barshelf-previous", in: root, version: "1.0.0")
        let installed = UpdateInstaller.Installed(app: app, version: "2.0.0", previous: previous)

        XCTAssertTrue(installed.rollBack())
        XCTAssertEqual(UpdateInstaller.installedVersion(of: app), "1.0.0")
        XCTAssertFalse(FileManager.default.fileExists(atPath: previous.path))
    }

    func testConfirmingDiscardsThePreviousBundleAndKeepsTheNewOne() throws {
        let app = try makeApp(named: "BarShelf.app", in: root, version: "2.0.0")
        let previous = try makeApp(named: ".BarShelf.app.barshelf-previous", in: root, version: "1.0.0")
        let installed = UpdateInstaller.Installed(app: app, version: "2.0.0", previous: previous)

        installed.confirm()
        XCTAssertFalse(FileManager.default.fileExists(atPath: previous.path))
        XCTAssertEqual(UpdateInstaller.installedVersion(of: app), "2.0.0")
    }

    /// A first install has nothing to go back to, and saying otherwise would
    /// have the caller report a recovery that did not happen.
    func testRollingBackReportsFailureWhenThereIsNothingToRestore() throws {
        let app = try makeApp(named: "BarShelf.app", in: root, version: "2.0.0")
        XCTAssertFalse(
            UpdateInstaller.Installed(app: app, version: "2.0.0", previous: nil).rollBack()
        )
        let missing = root.appendingPathComponent("gone.app")
        XCTAssertFalse(
            UpdateInstaller.Installed(app: app, version: "2.0.0", previous: missing).rollBack()
        )
        XCTAssertEqual(UpdateInstaller.installedVersion(of: app), "2.0.0")
    }

    /// Hidden, so Launch Services does not briefly offer two BarShelfs while
    /// the replacement is being proved.
    func testTheKeptBundleIsHiddenAndNamedForThisProject() {
        let name = UpdateInstaller.backupName(
            for: URL(fileURLWithPath: "/Applications/BarShelf.app")
        )
        XCTAssertTrue(name.hasPrefix("."), name)
        XCTAssertTrue(name.contains("BarShelf.app"), name)
        XCTAssertTrue(name.contains("barshelf-previous"), name)
    }

    /// Rehearses the keep-and-restore cycle in a real installation directory,
    /// where permissions and Launch Services are not simulated:
    ///
    ///     BARSHELF_ROLLBACK_DIR=/Applications swift test --filter Rollback
    ///
    /// Skipped otherwise — a test suite should not write to /Applications
    /// because someone ran it.
    func testRollbackWorksInARealApplicationsDirectory() throws {
        guard let directory = ProcessInfo.processInfo.environment["BARSHELF_ROLLBACK_DIR"] else {
            throw XCTSkip("set BARSHELF_ROLLBACK_DIR to rehearse this for real")
        }
        let base = URL(fileURLWithPath: directory)
        let target = base.appendingPathComponent("BarShelfRollbackRehearsal.app")
        let backup = base.appendingPathComponent(UpdateInstaller.backupName(for: target))
        addTeardownBlock {
            try? FileManager.default.removeItem(at: target)
            try? FileManager.default.removeItem(at: backup)
        }

        let (source, team) = try borrowSignedBundle()
        let archive = root.appendingPathComponent("update.zip")
        try zip(source, to: archive)
        _ = try makeApp(named: target.lastPathComponent, in: base, version: "1.0.0")

        let installed = try UpdateInstaller.install(
            archive: archive, replacing: target,
            expectedTeam: team, expectedBundleID: nil, checkGatekeeper: false
        )
        XCTAssertNotEqual(UpdateInstaller.installedVersion(of: target), "1.0.0")
        XCTAssertEqual(installed.previous?.path, backup.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))

        XCTAssertTrue(installed.rollBack())
        XCTAssertEqual(UpdateInstaller.installedVersion(of: target), "1.0.0")
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
    }

    // MARK: - The path that actually replaces something

    private func borrowSignedBundle() throws -> (url: URL, team: String) {
        guard let fixture = SignedBundleFixture.shared else {
            throw XCTSkip("no small Developer ID signed bundle available to install from")
        }
        return fixture
    }

    func testAProperlySignedUpdateReplacesTheInstalledCopy() throws {
        let (source, team) = try borrowSignedBundle()
        let archive = root.appendingPathComponent("update.zip")
        try zip(source, to: archive)

        let installed = try makeApp(named: source.lastPathComponent, in: root, version: "1.0.0")
        // Gatekeeper is checked separately: a nested helper has no stapled
        // ticket of its own, so assessing it standalone proves nothing.
        let result = try UpdateInstaller.install(
            archive: archive, replacing: installed,
            expectedTeam: team, expectedBundleID: nil, checkGatekeeper: false
        )

        XCTAssertNotEqual(result.version, "1.0.0", "the installed copy was not replaced")
        XCTAssertEqual(CodeSignature.teamIdentifier(of: installed), team)
        XCTAssertTrue(CodeSignature.isSigned(installed, by: team))

        // The bundle it displaced is kept until someone says the replacement
        // runs — that is what makes a rollback possible at all.
        let previous = try XCTUnwrap(result.previous, "no rollback point was kept")
        XCTAssertTrue(FileManager.default.fileExists(atPath: previous.path))
        XCTAssertEqual(UpdateInstaller.installedVersion(of: previous), "1.0.0")
        result.confirm()
        XCTAssertFalse(FileManager.default.fileExists(atPath: previous.path))
    }

    func testTheSameArchiveIsRefusedForADifferentDeveloper() throws {
        let (source, _) = try borrowSignedBundle()
        let archive = root.appendingPathComponent("update.zip")
        try zip(source, to: archive)

        let installed = try makeApp(named: source.lastPathComponent, in: root, version: "1.0.0")
        XCTAssertThrowsError(
            try UpdateInstaller.install(
                archive: archive, replacing: installed,
                expectedTeam: "XXXXXXXXXX", expectedBundleID: nil, checkGatekeeper: false
            )
        ) { error in
            guard case let .signatureRejected(detail) = error as? UpdateInstaller.Failure else {
                return XCTFail("expected signatureRejected, got \(error)")
            }
            XCTAssertEqual(detail, "signed by a different developer")
        }
        // A correctly signed build from the wrong developer is still a no-op.
        XCTAssertEqual(UpdateInstaller.installedVersion(of: installed), "1.0.0")
    }

    func testGatekeeperAcceptsSystemCodeAndRefusesAnUnsignedBundle() throws {
        // A fixed, small, always-present bundle: assessing a directory full of
        // applications to find one that passes costs minutes on a CI runner.
        let calculator = URL(fileURLWithPath: "/System/Applications/Calculator.app")
        if FileManager.default.fileExists(atPath: calculator.path) {
            XCTAssertTrue(CodeSignature.passesGatekeeper(calculator))
        }
        // The case that matters: macOS will not run this, so neither will we.
        XCTAssertFalse(CodeSignature.passesGatekeeper(try makeApp(named: "Fake.app", in: root)))
    }

}

final class CodeSignatureTests: XCTestCase {
    func testAnUnsignedPathHasNoTeam() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("not-an-app-\(UUID().uuidString).txt")
        try "hello".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }

        XCTAssertNil(CodeSignature.teamIdentifier(of: file))
        XCTAssertNil(
            CodeSignature.teamIdentifier(of: URL(fileURLWithPath: "/nope-\(UUID().uuidString)"))
        )
    }

    func testVerificationFailsForSomethingThatIsNotCode() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("not-an-app-\(UUID().uuidString).txt")
        try "hello".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }

        XCTAssertFalse(CodeSignature.isSigned(file, by: "ABCDE12345"))
    }

    func testTheRequirementPinsDeveloperIDSpecificallyNotJustTheTeam() {
        let requirement = CodeSignature.developerIDRequirement(team: "ABCDE12345")
        // Without the leaf extension an Apple Development certificate from the
        // same team satisfies the requirement — a contributor's debug identity
        // could then sign a "release".
        XCTAssertTrue(requirement.contains("certificate leaf[field.1.2.840.113635.100.6.1.13]"))
        XCTAssertTrue(requirement.contains("certificate 1[field.1.2.840.113635.100.6.2.6]"))
        XCTAssertTrue(requirement.contains(#"certificate leaf[subject.OU] = "ABCDE12345""#))
        XCTAssertTrue(requirement.hasPrefix("anchor apple generic"))
    }

    func testTheHostDeveloperIDTeamIsNeverAWeakerClaimThanItsTeamIdentifier() {
        // Whatever this test binary is signed with, the Developer ID answer has
        // to be either "no" or the same team the signature records.
        if let developerID = CodeSignature.hostDeveloperIDTeam() {
            XCTAssertEqual(developerID, CodeSignature.hostTeamIdentifier())
        }
    }

    func testGatekeeperTimeoutIsTreatedAsRefusal() {
        // An assessment that cannot finish must not pass, and must not hang:
        // spctl reaches the network, which stalls behind a captive portal.
        let started = Date()
        XCTAssertFalse(
            CodeSignature.passesGatekeeper(
                URL(fileURLWithPath: "/System/Applications/Calculator.app"), timeout: 0.001
            )
        )
        XCTAssertLessThan(-started.timeIntervalSinceNow, 5)
    }

    func testStatusesAreDescribedInTermsAUserCanActOn() {
        XCTAssertEqual(CodeSignature.describe(errSecSuccess), "valid")
        XCTAssertEqual(
            CodeSignature.describe(errSecCSReqFailed), "signed by a different developer"
        )
        XCTAssertEqual(CodeSignature.describe(errSecCSUnsigned), "not signed")
        XCTAssertFalse(CodeSignature.describe(errSecCSSignatureFailed).isEmpty)
    }

    /// Pinning against a real Developer ID bundle, when the machine has one.
    func testTeamPinningRejectsEveryOtherDeveloper() throws {
        guard let (bundle, team) = SignedBundleFixture.shared else {
            throw XCTSkip("no Developer ID signed bundle available to verify against")
        }
        XCTAssertTrue(CodeSignature.isSigned(bundle, by: team))
        XCTAssertFalse(CodeSignature.isSigned(bundle, by: "XXXXXXXXXX"))
    }

    /// A team identifier is recorded for Apple's own apps too, but they are not
    /// signed under a Developer ID certificate — so pinning must reject them.
    /// Reading `teamid` and calling it verified would accept any Apple-signed
    /// application as a BarShelf update.
    func testATeamIdentifierAloneIsNotAcceptance() throws {
        let applications = (try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: "/Applications"),
            includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        let appleSigned = applications.first { app in
            guard app.pathExtension == "app",
                  let team = CodeSignature.teamIdentifier(of: app)
            else { return false }
            return !CodeSignature.isSigned(app, by: team)
        }
        guard let appleSigned, let team = CodeSignature.teamIdentifier(of: appleSigned) else {
            throw XCTSkip("no non-Developer-ID signed application present")
        }
        XCTAssertFalse(CodeSignature.isSigned(appleSigned, by: team))
    }
}


/// A small Developer ID signed bundle borrowed from this machine to exercise
/// verify-then-replace for real.
///
/// Resolved once per test process: locating one means code-signing checks and
/// zipping means copying bytes, and doing either per test turned a 90-second CI
/// job into a five-minute one. Nested helper apps are preferred because they
/// are megabytes rather than hundreds, and anything over the cap is skipped
/// rather than waited on.
enum SignedBundleFixture {
    static let maximumBytes = 25 * 1024 * 1024

    static let shared: (url: URL, team: String)? = locate()

    private static func locate() -> (URL, String)? {
        for candidate in candidates() {
            guard let size = allocatedSize(of: candidate, cap: maximumBytes),
                  size > 0
            else { continue }
            // "Has a team identifier" is not the same as "Developer ID signed"
            // — Apple's own apps have one and fail this requirement.
            guard let team = CodeSignature.teamIdentifier(of: candidate),
                  CodeSignature.isSigned(candidate, by: team)
            else { continue }
            return (candidate, team)
        }
        return nil
    }

    private static func candidates() -> [URL] {
        let fileManager = FileManager.default
        let applications = (try? fileManager.contentsOfDirectory(
            at: URL(fileURLWithPath: "/Applications"),
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        let tops = applications.filter { $0.pathExtension == "app" }
        var nested: [URL] = []
        for app in tops {
            let frameworks = app.appendingPathComponent("Contents/Frameworks")
            let children = (try? fileManager.contentsOfDirectory(
                at: frameworks, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            )) ?? []
            nested.append(contentsOf: children.filter { $0.pathExtension == "app" })
        }
        return nested + tops
    }

    /// On-disk size, abandoning the walk as soon as it exceeds `cap` — sizing a
    /// large application otherwise costs more than the test it is guarding.
    static func allocatedSize(of url: URL, cap: Int) -> Int? {
        guard let walker = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey], options: []
        ) else { return nil }
        var total = 0
        for case let file as URL in walker {
            let values = try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
            total += values?.totalFileAllocatedSize ?? 0
            if total > cap { return nil }
        }
        return total
    }
}
