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
                isWritable: { _ in false },
                fileExists: { _ in false }
            ),
            .notWritable
        )
    }

    func testASignedWritableNonBrewInstallIsEligible() {
        XCTAssertNil(
            UpdateInstaller.blocker(
                appURL: URL(fileURLWithPath: "/Applications/BarShelf.app"),
                hostTeam: "ABCDE12345",
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
                archive: archive, replacing: installed, expectedTeam: "ABCDE12345"
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
                archive: archive, replacing: installed, expectedTeam: "ABCDE12345"
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

    // MARK: - The path that actually replaces something

    /// A small Developer ID signed bundle from this machine, used to exercise
    /// verify-then-replace for real. Nested helper apps are preferred because
    /// they are megabytes rather than hundreds.
    private func borrowSignedBundle() throws -> (url: URL, team: String) {
        let fileManager = FileManager.default
        let applications = URL(fileURLWithPath: "/Applications")
        let tops = (try? fileManager.contentsOfDirectory(
            at: applications, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        var candidates: [URL] = []
        for app in tops where app.pathExtension == "app" {
            let frameworks = app.appendingPathComponent("Contents/Frameworks")
            let nested = (try? fileManager.contentsOfDirectory(
                at: frameworks, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            )) ?? []
            candidates.append(contentsOf: nested.filter { $0.pathExtension == "app" })
        }
        candidates.append(contentsOf: tops.filter { $0.pathExtension == "app" })

        for candidate in candidates {
            if let team = CodeSignature.teamIdentifier(of: candidate),
               CodeSignature.isSigned(candidate, by: team) {
                return (candidate, team)
            }
        }
        throw XCTSkip("no Developer ID signed bundle available to install from")
    }

    func testAProperlySignedUpdateReplacesTheInstalledCopy() throws {
        let (source, team) = try borrowSignedBundle()
        let archive = root.appendingPathComponent("update.zip")
        try zip(source, to: archive)

        let installed = try makeApp(named: source.lastPathComponent, in: root, version: "1.0.0")
        // Gatekeeper is checked separately: a nested helper has no stapled
        // ticket of its own, so assessing it standalone proves nothing.
        let version = try UpdateInstaller.install(
            archive: archive, replacing: installed,
            expectedTeam: team, checkGatekeeper: false
        )

        XCTAssertNotEqual(version, "1.0.0", "the installed copy was not replaced")
        XCTAssertEqual(CodeSignature.teamIdentifier(of: installed), team)
        XCTAssertTrue(CodeSignature.isSigned(installed, by: team))
    }

    func testTheSameArchiveIsRefusedForADifferentDeveloper() throws {
        let (source, _) = try borrowSignedBundle()
        let archive = root.appendingPathComponent("update.zip")
        try zip(source, to: archive)

        let installed = try makeApp(named: source.lastPathComponent, in: root, version: "1.0.0")
        XCTAssertThrowsError(
            try UpdateInstaller.install(
                archive: archive, replacing: installed,
                expectedTeam: "XXXXXXXXXX", checkGatekeeper: false
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

    func testGatekeeperAcceptsAnInstalledNotarizedApplication() throws {
        let applications = (try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: "/Applications"),
            includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        guard let notarized = applications.first(where: { app in
            app.pathExtension == "app" && CodeSignature.teamIdentifier(of: app) != nil
                && CodeSignature.passesGatekeeper(app)
        }) else {
            throw XCTSkip("no notarized application available to assess")
        }
        XCTAssertTrue(CodeSignature.passesGatekeeper(notarized))
        // An unsigned directory is not something macOS will run.
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

    func testStatusesAreDescribedInTermsAUserCanActOn() {
        XCTAssertEqual(CodeSignature.describe(errSecSuccess), "valid")
        XCTAssertEqual(
            CodeSignature.describe(errSecCSReqFailed), "signed by a different developer"
        )
        XCTAssertEqual(CodeSignature.describe(errSecCSUnsigned), "not signed")
        XCTAssertFalse(CodeSignature.describe(errSecCSSignatureFailed).isEmpty)
    }

    /// Pinning against a real Developer ID bundle, when the machine has one.
    /// Skipped rather than asserted away on a runner that has none.
    func testTeamPinningAcceptsOnlyTheSameDeveloper() throws {
        let candidates = (try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: "/Applications"),
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        let signed = candidates.first { url in
            url.pathExtension == "app" && CodeSignature.teamIdentifier(of: url) != nil
        }
        guard let signed, let team = CodeSignature.teamIdentifier(of: signed) else {
            throw XCTSkip("no Developer ID signed application available to verify against")
        }
        XCTAssertTrue(CodeSignature.isSigned(signed, by: team))
        XCTAssertFalse(CodeSignature.isSigned(signed, by: "XXXXXXXXXX"))
    }
}
