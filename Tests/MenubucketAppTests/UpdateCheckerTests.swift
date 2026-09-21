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
    ///
    /// The cask lives in Open330/homebrew-tap now, so what is checked here is
    /// the template the release workflow writes it from.
    func testTheCaskTemplateDoesNotClaimSelfUpdating() throws {
        XCTAssertFalse(tapBumpWorkflow().contains("auto_updates true"))
    }

    func testHomebrewCommandIsTheOneTheCaskIsInstalledWith() throws {
        XCTAssertEqual(UpdateChecker.homebrewUpgradeCommand, "brew upgrade --cask barshelf")
        XCTAssertTrue(tapBumpWorkflow().contains(#"cask "barshelf" do"#))
    }

    private func tapBumpWorkflow() -> String {
        (try? String(
            contentsOf: repositoryRoot.appendingPathComponent(".github/workflows/tap-bump.yml"),
            encoding: .utf8
        )) ?? ""
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


    // MARK: - Settings picker labels

    func testPickerShowsTheDisplayTitleForAnOption() {
        let entry = Manifest.Setting(
            key: "menuBarStyle", type: "enum",
            options: ["value", "labeled"],
            optionTitles: ["Value only", "With label"]
        )
        // "value" and "labeled" mean nothing in a picker.
        XCTAssertEqual(WidgetSettingsView.optionTitle("value", in: entry), "Value only")
        XCTAssertEqual(WidgetSettingsView.optionTitle("labeled", in: entry), "With label")
    }

    func testAMiscountedOrMissingTitleListFallsBackToTheRawValue() {
        let noTitles = Manifest.Setting(key: "k", type: "enum", options: ["grid", "list"])
        XCTAssertEqual(WidgetSettingsView.optionTitle("grid", in: noTitles), "grid")

        // Wrong length: labelling the wrong choice is worse than looking plain.
        let miscounted = Manifest.Setting(
            key: "k", type: "enum", options: ["a", "b", "c"], optionTitles: ["A", "B"]
        )
        XCTAssertEqual(WidgetSettingsView.optionTitle("a", in: miscounted), "a")

        let blank = Manifest.Setting(
            key: "k", type: "enum", options: ["a", "b"], optionTitles: ["A", "  "]
        )
        XCTAssertEqual(WidgetSettingsView.optionTitle("b", in: blank), "b")
        XCTAssertEqual(WidgetSettingsView.optionTitle("zzz", in: blank), "zzz")
    }

    func testBundledMenuBarSettingsAreAllLabelled() throws {
        for name in ["system", "sensors"] {
            let manifest = try Manifest.decode(from: Data(contentsOf:
                repositoryRoot.appendingPathComponent("widgets/\(name)/widget.json")))
            let settings = try XCTUnwrap(manifest.settings, name)
            XCTAssertFalse(settings.isEmpty)
            for setting in settings where setting.type == "enum" {
                let options = try XCTUnwrap(setting.options, "\(name).\(setting.key ?? "?")")
                let titles = try XCTUnwrap(
                    setting.optionTitles, "\(name).\(setting.key ?? "?") has no optionTitles"
                )
                XCTAssertEqual(titles.count, options.count, "\(name).\(setting.key ?? "?")")
            }
        }
    }

}
