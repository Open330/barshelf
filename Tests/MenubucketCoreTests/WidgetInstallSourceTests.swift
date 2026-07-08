import XCTest

@testable import MenubucketCore

/// URL-install v1 — input parsing/normalization (GitHub URL variants,
/// direct archives, menubucket:// deep links).
final class WidgetInstallSourceTests: XCTestCase {

    // MARK: GitHub URL variants

    func testBareGitHubRepoURLFallsBackMainThenMaster() throws {
        let source = try WidgetInstallSource.parse("https://github.com/alice/my-widget")
        XCTAssertEqual(
            source.kind, .gitHubRepo(owner: "alice", repo: "my-widget", branch: nil)
        )
        XCTAssertEqual(source.downloadCandidates.map(\.absoluteString), [
            "https://codeload.github.com/alice/my-widget/zip/refs/heads/main",
            "https://codeload.github.com/alice/my-widget/zip/refs/heads/master",
        ])
        XCTAssertNil(source.subdirectory)
    }

    func testGitHubRepoURLWithTrailingSlashAndGitSuffix() throws {
        let slash = try WidgetInstallSource.parse("https://github.com/alice/my-widget/")
        XCTAssertEqual(
            slash.kind, .gitHubRepo(owner: "alice", repo: "my-widget", branch: nil)
        )

        let git = try WidgetInstallSource.parse("https://github.com/alice/my-widget.git")
        XCTAssertEqual(
            git.kind, .gitHubRepo(owner: "alice", repo: "my-widget", branch: nil)
        )
        XCTAssertEqual(
            git.downloadCandidates.first?.absoluteString,
            "https://codeload.github.com/alice/my-widget/zip/refs/heads/main"
        )
    }

    func testGitHubTreeBranchURL() throws {
        let source = try WidgetInstallSource.parse(
            "https://github.com/alice/my-widget/tree/develop"
        )
        XCTAssertEqual(
            source.kind, .gitHubRepo(owner: "alice", repo: "my-widget", branch: "develop")
        )
        XCTAssertEqual(source.downloadCandidates.map(\.absoluteString), [
            "https://codeload.github.com/alice/my-widget/zip/refs/heads/develop"
        ])
        XCTAssertNil(source.subdirectory)
    }

    func testGitHubTreeBranchSubdirectoryURL() throws {
        let source = try WidgetInstallSource.parse(
            "https://github.com/alice/mono/tree/main/widgets/clock"
        )
        XCTAssertEqual(
            source.kind, .gitHubRepo(owner: "alice", repo: "mono", branch: "main")
        )
        XCTAssertEqual(source.subdirectory, "widgets/clock")
        XCTAssertEqual(source.downloadCandidates.map(\.absoluteString), [
            "https://codeload.github.com/alice/mono/zip/refs/heads/main"
        ])
    }

    func testMalformedGitHubURLsAreRejected() {
        // owner only
        XCTAssertThrowsError(try WidgetInstallSource.parse("https://github.com/alice"))
        // non-tree subpath
        XCTAssertThrowsError(
            try WidgetInstallSource.parse("https://github.com/alice/repo/issues/3")
        )
        // tree without a branch
        XCTAssertThrowsError(
            try WidgetInstallSource.parse("https://github.com/alice/repo/tree")
        )
    }

    // MARK: Direct archives

    func testDirectZipAndMbwArchiveURLs() throws {
        let zip = try WidgetInstallSource.parse("https://example.com/downloads/widget.zip")
        XCTAssertEqual(zip.kind, .archive)
        XCTAssertEqual(
            zip.downloadCandidates.map(\.absoluteString),
            ["https://example.com/downloads/widget.zip"]
        )

        let mbw = try WidgetInstallSource.parse("https://example.com/widget.MBW")
        XCTAssertEqual(mbw.kind, .archive)
    }

    func testGitHubReleaseAssetZipParsesAsArchive() throws {
        let source = try WidgetInstallSource.parse(
            "https://github.com/alice/repo/releases/download/v1.0/widget.zip"
        )
        XCTAssertEqual(source.kind, .archive)
    }

    func testArchiveURLKeepsQueryString() throws {
        let source = try WidgetInstallSource.parse(
            "https://example.com/w.zip?token=abc%2F123"
        )
        XCTAssertEqual(source.kind, .archive)
        XCTAssertEqual(
            source.downloadCandidates.first?.absoluteString,
            "https://example.com/w.zip?token=abc%2F123"
        )
    }

    // MARK: Deep links

    func testDeepLinkUnwrapsPercentEncodedURL() throws {
        let inner = "https://github.com/alice/my-widget/tree/main/widgets/clock"
        let encoded = inner.addingPercentEncoding(
            withAllowedCharacters: .alphanumerics
        )!
        let source = try WidgetInstallSource.parse(
            "menubucket://install?url=\(encoded)"
        )
        XCTAssertEqual(
            source.kind, .gitHubRepo(owner: "alice", repo: "my-widget", branch: "main")
        )
        XCTAssertEqual(source.subdirectory, "widgets/clock")
    }

    func testDeepLinkWithArchiveURL() throws {
        let source = try WidgetInstallSource.parse(
            "menubucket://install?url=https%3A%2F%2Fexample.com%2Fwidget.zip"
        )
        XCTAssertEqual(source.kind, .archive)
    }

    func testDeepLinkErrors() {
        // unknown action
        XCTAssertThrowsError(
            try WidgetInstallSource.parse("menubucket://remove?url=https://a.com/w.zip")
        )
        // missing url parameter
        XCTAssertThrowsError(try WidgetInstallSource.parse("menubucket://install"))
        // nested deep links are refused
        XCTAssertThrowsError(
            try WidgetInstallSource.parse(
                "menubucket://install?url=menubucket%3A%2F%2Finstall%3Furl%3Dhttps%3A%2F%2Fa.com%2Fw.zip"
            )
        )
    }

    // MARK: General rejection

    func testUnsupportedInputsAreRejected() {
        XCTAssertThrowsError(try WidgetInstallSource.parse(""))
        XCTAssertThrowsError(try WidgetInstallSource.parse("   "))
        XCTAssertThrowsError(try WidgetInstallSource.parse("ftp://example.com/w.zip"))
        XCTAssertThrowsError(try WidgetInstallSource.parse("file:///tmp/w.zip"))
        // https but neither GitHub nor an archive
        XCTAssertThrowsError(try WidgetInstallSource.parse("https://example.com/widgets"))
    }
}
