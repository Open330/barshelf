import XCTest
import MenubucketCore
@testable import MenubucketApp

@MainActor
final class UpdateCheckerTests: XCTestCase {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // MenubucketAppTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
    }

    func testVersionComparisonIsNumericNotLexicographic() {
        XCTAssertTrue(UpdateChecker.compare("1.2.10", isNewerThan: "1.2.9"))
        XCTAssertTrue(UpdateChecker.compare("0.2.0", isNewerThan: "0.1.4"))
        XCTAssertFalse(UpdateChecker.compare("0.1.3", isNewerThan: "0.1.3"))
        XCTAssertFalse(UpdateChecker.compare("0.1.3", isNewerThan: "0.2.0"))
        // Missing components count as zero.
        XCTAssertTrue(UpdateChecker.compare("1.1", isNewerThan: "1.0.9"))
        XCTAssertFalse(UpdateChecker.compare("1.0", isNewerThan: "1.0.0"))
    }

    /// The updater downloads the asset whose name it can predict. If
    /// `release.sh` ever renames it, in-app updates would quietly stop working
    /// and every user would silently fall back to the manual download.
    func testTheExpectedAssetNameMatchesWhatTheReleaseScriptPublishes() throws {
        let script = try String(
            contentsOf: repositoryRoot.appendingPathComponent("scripts/release.sh"),
            encoding: .utf8
        )
        XCTAssertTrue(
            script.contains(#"APP_ZIP="${RELEASE_DIR}/${APP_DISPLAY_NAME}-${VERSION}-${ARCH}.zip""#),
            "release.sh no longer names the app archive the way UpdateChecker expects"
        )
        XCTAssertTrue(
            script.contains("APP_DISPLAY_NAME=${APP_DISPLAY_NAME:-BarShelf}"),
            "release.sh no longer defaults the display name to BarShelf"
        )
        // arm64 is the only architecture release.sh will build for.
        XCTAssertTrue(script.contains(#"public BarShelf releases currently support arm64 only"#))
        // `locateApp` only looks at the top level of the expanded archive, so
        // the zip has to keep the .app as its root entry. Drop --keepParent and
        // every in-app update fails with "contains no application".
        XCTAssertTrue(
            script.contains(#"ditto -c -k --keepParent "${APP_BUNDLE_PATH}" "${APP_ZIP}""#),
            "release.sh no longer zips the app with --keepParent"
        )

        XCTAssertEqual(
            UpdateChecker.appAssetName(version: "0.2.0"), "BarShelf-0.2.0-arm64.zip"
        )
    }

    /// The cask must not claim the app updates itself: BarShelf defers to
    /// Homebrew for Homebrew-managed copies, and `auto_updates true` would make
    /// `brew upgrade` skip them — leaving those users with no update path.
    func testTheCaskDoesNotClaimSelfUpdating() throws {
        let cask = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Casks/barshelf.rb"),
            encoding: .utf8
        )
        XCTAssertFalse(cask.contains("auto_updates"))
    }

    func testHomebrewCommandIsTheOneTheCaskIsInstalledWith() throws {
        XCTAssertEqual(UpdateChecker.homebrewUpgradeCommand, "brew upgrade --cask barshelf")
        let cask = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Casks/barshelf.rb"),
            encoding: .utf8
        )
        XCTAssertTrue(cask.contains(#"cask "barshelf" do"#))
    }

    func testCaskroomPathsCoverBothHomebrewPrefixes() {
        // Apple Silicon and Intel prefixes — a user on either must be detected.
        XCTAssertEqual(
            Set(UpdateInstaller.homebrewCaskroots),
            ["/opt/homebrew/Caskroom/barshelf", "/usr/local/Caskroom/barshelf"]
        )
    }

    // MARK: - Update feed

    func testTheFeedDefaultsToTheProjectRepository() {
        // No override set in the test environment.
        XCTAssertEqual(UpdateChecker.repository, UpdateChecker.defaultRepository)
        XCTAssertFalse(UpdateChecker.isUsingOverriddenFeed)
        XCTAssertEqual(
            UpdateChecker.latestReleaseAPI.absoluteString,
            "https://api.github.com/repos/Open330/barshelf/releases/latest"
        )
        XCTAssertEqual(
            UpdateChecker.releasesPage.absoluteString,
            "https://github.com/Open330/barshelf/releases/latest"
        )
    }

    func testAPreferenceOverrideRedirectsTheFeedAndIsAnnounced() {
        let defaults = UserDefaults.standard
        let key = UpdateChecker.repositoryDefaultsKey
        defaults.set("example/barshelf-staging", forKey: key)
        defer { defaults.removeObject(forKey: key) }

        XCTAssertEqual(UpdateChecker.repository, "example/barshelf-staging")
        XCTAssertTrue(UpdateChecker.isUsingOverriddenFeed)
        XCTAssertEqual(
            UpdateChecker.latestReleaseAPI.absoluteString,
            "https://api.github.com/repos/example/barshelf-staging/releases/latest"
        )
    }

    func testTheOverrideCannotPointAtAnotherHost() {
        // It names a repository, never a URL — so the feed always resolves to
        // api.github.com and a download can never be redirected elsewhere.
        for hostile in [
            "https://evil.example.com/repo",
            "../../etc/passwd",
            "owner/repo/extra",
            "owner",
            "",
            "/repo",
            "owner/",
            "owner/../..",
            "own er/repo",
            "owner/repo?x=1",
        ] {
            XCTAssertFalse(
                UpdateChecker.isValidRepository(hostile), "accepted \(hostile)"
            )
        }
        XCTAssertTrue(UpdateChecker.isValidRepository("Open330/barshelf"))
        XCTAssertTrue(UpdateChecker.isValidRepository("some-owner/some.repo_1"))
    }

    func testAnInvalidOverrideFallsBackInsteadOfBreakingUpdates() {
        let defaults = UserDefaults.standard
        let key = UpdateChecker.repositoryDefaultsKey
        defaults.set("https://evil.example.com/x", forKey: key)
        defer { defaults.removeObject(forKey: key) }

        XCTAssertEqual(UpdateChecker.repository, UpdateChecker.defaultRepository)
        XCTAssertFalse(UpdateChecker.isUsingOverriddenFeed)
    }

}
