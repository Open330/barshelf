import XCTest
@testable import BarShelfKit
import MenubucketCore

/// `barshelf upgrade` — the terminal half of self-updating.
final class UpgradeCommandTests: XCTestCase {
    private var root: URL!

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // BarShelfCLITests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
    }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("barshelf-upgrade-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Arguments

    func testTheDocumentedFlagsParse() throws {
        let check = try XCTUnwrap(UpgradeCommand.parse(["--check"]))
        XCTAssertTrue(check.checkOnly)

        let both = try XCTUnwrap(UpgradeCommand.parse(["-y", "--restart"]))
        XCTAssertTrue(both.assumeYes)
        XCTAssertTrue(both.restart)

        let app = try XCTUnwrap(UpgradeCommand.parse(["--app", "/tmp/BarShelf.app"]))
        XCTAssertEqual(app.appPath, "/tmp/BarShelf.app")

        let none = try XCTUnwrap(UpgradeCommand.parse([]))
        XCTAssertFalse(none.checkOnly)
        XCTAssertFalse(none.assumeYes)
        XCTAssertFalse(none.restart)
        XCTAssertNil(none.appPath)
    }

    func testUnknownFlagsAndAMissingPathAreRejected() {
        XCTAssertNil(UpgradeCommand.parse(["--nope"]))
        XCTAssertNil(UpgradeCommand.parse(["--app"]))
        // A bare path is not a flag; `upgrade` takes no positional argument.
        XCTAssertNil(UpgradeCommand.parse(["/Applications/BarShelf.app"]))
    }

    /// Bad arguments have to fail before any network call, or `--help`-hunting
    /// turns into a download.
    func testBadArgumentsFailWithoutReachingTheNetwork() {
        for command in ["upgrade", "update", "self-update"] {
            XCTAssertEqual(BarShelfMain.run(arguments: [command, "--nope"]), 1, command)
        }
    }

    func testTheHelpMentionsUpgrade() {
        XCTAssertTrue(BarShelfMain.usage.contains("barshelf upgrade"))
    }

    // MARK: - What gets replaced

    func testBothBinariesAreFoundNextToTheRunningOne() throws {
        let bin = try makeBin(["barshelf": .file, "bsf": .file])
        let found = UpgradeCommand.companionTools(of: bin.appendingPathComponent("barshelf"))
        XCTAssertEqual(found.map(\.lastPathComponent), ["barshelf", "bsf"])
    }

    /// `bsf` symlinked to `barshelf` is one file. Replacing it twice would have
    /// the second swap overwrite what the first installed.
    func testALinkedCompanionIsNotReplacedTwice() throws {
        let bin = try makeBin(["barshelf": .file, "bsf": .link("barshelf")])
        let found = UpgradeCommand.companionTools(of: bin.appendingPathComponent("barshelf"))
        XCTAssertEqual(found.map(\.lastPathComponent), ["barshelf"])
    }

    func testAMissingCompanionIsSimplySkipped() throws {
        let bin = try makeBin(["barshelf": .file])
        let found = UpgradeCommand.companionTools(of: bin.appendingPathComponent("barshelf"))
        XCTAssertEqual(found.map(\.lastPathComponent), ["barshelf"])
    }

    /// A release binary that has been renamed cannot be matched to an archive
    /// member, so it must not be reported as updatable.
    func testARenamedBinaryHasNothingToReplace() throws {
        let bin = try makeBin(["barshelf-old": .file])
        let found = UpgradeCommand.companionTools(of: bin.appendingPathComponent("barshelf-old"))
        XCTAssertTrue(found.isEmpty)
    }

    // MARK: - Homebrew-managed CLI

    /// `<prefix>/bin` precedes `~/.local/bin` on a default PATH, so a
    /// `brew install barshelf-cli` copy is the one that runs. Replacing it
    /// would leave brew convinced it still has the version it installed, and
    /// the next `brew upgrade`/`reinstall` would silently revert the update.
    func testACLIInsideTheCellarIsRecognisedAsHomebrewManaged() {
        for prefix in ["/opt/homebrew", "/usr/local"] {
            XCTAssertTrue(UpdateInstaller.isHomebrewManaged(
                tool: URL(fileURLWithPath: "\(prefix)/Cellar/barshelf-cli/0.3.0/bin/barshelf")
            ), prefix)
        }
    }

    func testACLIOutsideTheCellarIsLeftAlone() {
        for path in [
            "/Users/someone/.local/bin/barshelf",
            "/usr/local/bin/barshelf",
            // Prefix matching must not catch a neighbouring directory.
            "/opt/homebrew/Cellarium/barshelf",
        ] {
            XCTAssertFalse(UpdateInstaller.isHomebrewManaged(
                tool: URL(fileURLWithPath: path)
            ), path)
        }
    }

    /// It is the resolved path that matters: what sits on PATH is a symlink
    /// into the Cellar, and only following it reveals who owns the file.
    func testTheSymlinkOnPathIsFollowedBeforeJudging() throws {
        let cellar = root.appendingPathComponent("Cellar/barshelf-cli/0.3.0/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: cellar, withIntermediateDirectories: true)
        let real = cellar.appendingPathComponent("barshelf")
        try Data("binary".utf8).write(to: real)

        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let link = bin.appendingPathComponent("barshelf")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let cellars = [root.appendingPathComponent("Cellar").path + "/"]
        XCTAssertTrue(UpdateInstaller.isHomebrewManaged(tool: link, cellars: cellars))
        XCTAssertFalse(UpdateInstaller.isHomebrewManaged(
            tool: link, cellars: ["/somewhere/else/Cellar/"]
        ))
    }

    func testTheTwoBrewCommandsNameTheRightArtifacts() throws {
        XCTAssertEqual(UpdateInstaller.homebrewUpgradeCommand, "brew upgrade --cask barshelf")
        XCTAssertEqual(UpdateInstaller.homebrewCLIUpgradeCommand, "brew upgrade barshelf-cli")
        // The cask has to still be the cask those commands name.
        let cask = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Casks/barshelf.rb"),
            encoding: .utf8
        )
        XCTAssertTrue(cask.contains(#"cask "barshelf" do"#))
    }

    // MARK: - Finding the app

    func testTheAppIsLookedForWhereTheDocsSayItLives() {
        XCTAssertEqual(
            UpgradeCommand.appSearchPaths,
            ["/Applications/BarShelf.app", "~/Applications/BarShelf.app"]
        )
    }

    func testAnExplicitPathWinsAndAnAbsentOneIsNil() throws {
        let app = root.appendingPathComponent("Elsewhere.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        XCTAssertEqual(UpgradeCommand.installedApp(explicitPath: app.path)?.path, app.path)
        XCTAssertNil(
            UpgradeCommand.installedApp(
                explicitPath: root.appendingPathComponent("Nope.app").path
            )
        )
    }

    /// `--app` updating a copy elsewhere must not report the one in
    /// /Applications as "still running the previous build" — and `--restart`
    /// must not then quit that one and reopen the other.
    func testTheRunningAppIsMatchedByBundleNotByExecutableName() {
        let selector = UpgradeCommand.processSelector(
            for: URL(fileURLWithPath: "/tmp/staging/BarShelf.app")
        )
        XCTAssertEqual(
            selector,
            ["-U", String(getuid()), "-f", "/tmp/staging/BarShelf.app/Contents/MacOS/barshelf-app"]
        )
        XCTAssertNotEqual(
            selector,
            UpgradeCommand.processSelector(
                for: URL(fileURLWithPath: "/Applications/BarShelf.app")
            )
        )
    }

    // MARK: - Drift against the release script

    /// The upgrade downloads assets whose names it predicts. If `release.sh`
    /// renames or repacks them, every `barshelf upgrade` would fail with "this
    /// release publishes no …" and nobody would find out from the release.
    func testTheCLIAssetIsNamedAndPackedTheWayTheUpgradeExpects() throws {
        let script = try String(
            contentsOf: repositoryRoot.appendingPathComponent("scripts/release.sh"),
            encoding: .utf8
        )
        XCTAssertTrue(
            script.contains(#"CLI_TAR="${RELEASE_DIR}/barshelf-cli-${VERSION}-${ARCH}.tar.gz""#),
            "release.sh no longer names the CLI archive the way ReleaseFeed expects"
        )
        // The members are extracted by name, at the root of the tarball.
        XCTAssertTrue(
            script.contains(#"tar -czf "${CLI_TAR}" -C "${DIST_DIR}" barshelf bsf"#),
            "release.sh no longer packs barshelf and bsf at the archive root"
        )
        XCTAssertEqual(CommandLineToolInstaller.toolNames, ["barshelf", "bsf"])
        XCTAssertEqual(
            ReleaseFeed.cliAssetName(version: "0.2.1"), "barshelf-cli-0.2.1-arm64.tar.gz"
        )
    }

    /// The CLI and the app report the same version because they ship together;
    /// `upgrade` relies on one release tag covering both.
    func testTheCLIVersionIsTheVersionTheTreeBuilds() throws {
        let script = try String(
            contentsOf: repositoryRoot.appendingPathComponent("scripts/build_app.sh"),
            encoding: .utf8
        )
        XCTAssertTrue(
            script.contains("APP_VERSION=${APP_VERSION:-\(BarShelfMain.version)}"),
            "the CLI reports \(BarShelfMain.version) but build_app.sh builds another version"
        )
    }

    // MARK: - Fixtures

    private enum Entry {
        case file
        case link(String)
    }

    private func makeBin(_ entries: [String: Entry]) throws -> URL {
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        for (name, entry) in entries.sorted(by: { $0.key < $1.key }) {
            let url = bin.appendingPathComponent(name)
            switch entry {
            case .file:
                try Data("binary".utf8).write(to: url)
            case let .link(target):
                try FileManager.default.createSymbolicLink(
                    atPath: url.path, withDestinationPath: target
                )
            }
        }
        return bin
    }
}
