import XCTest
@testable import MenubucketApp

final class AppVersionInfoTests: XCTestCase {
    func testReadsAndTrimsPackagedVersionMetadata() {
        let info = AppVersionInfo(infoDictionary: [
            "CFBundleShortVersionString": " 0.1.2 ",
            "CFBundleVersion": " 202607130915 ",
        ])

        XCTAssertEqual(info.version, "0.1.2")
        XCTAssertEqual(info.build, "202607130915")
        XCTAssertEqual(info.versionLabel, "0.1.2")
    }

    func testDevelopmentBuildFallbackWhenMetadataIsMissing() {
        let info = AppVersionInfo(infoDictionary: [:])

        XCTAssertNil(info.version)
        XCTAssertNil(info.build)
        XCTAssertEqual(info.versionLabel, "Development build")
    }

    func testBlankOrNonStringValuesAreIgnored() {
        let info = AppVersionInfo(infoDictionary: [
            "CFBundleShortVersionString": "  ",
            "CFBundleVersion": 42,
        ])

        XCTAssertNil(info.version)
        XCTAssertNil(info.build)
    }

    func testSourceCommitIsReadFromTheBundle() {
        let info = AppVersionInfo(infoDictionary: [
            "CFBundleShortVersionString": "0.2.0",
            "CFBundleVersion": "202609201200",
            "BarShelfSourceCommit": "a1b2c3d4e5f6",
        ])
        XCTAssertEqual(info.sourceCommit, "a1b2c3d4e5f6")
        XCTAssertFalse(info.isFromDirtyTree)
    }

    func testABuildFromUncommittedChangesSaysSo() {
        let info = AppVersionInfo(infoDictionary: [
            "BarShelfSourceCommit": "a1b2c3d4e5f6-dirty",
        ])
        // Hiding this would make an unreproducible build look like a release.
        XCTAssertTrue(info.isFromDirtyTree)
    }

    func testBuildsWithoutProvenanceDegradeQuietly() {
        // `swift run` builds carry no Info.plist keys at all.
        let info = AppVersionInfo(infoDictionary: [:])
        XCTAssertNil(info.sourceCommit)
        XCTAssertFalse(info.isFromDirtyTree)
        XCTAssertEqual(info.versionLabel, "Development build")
    }

    func testTheInfoPlistTemplateCarriesEveryKeyTheAppReads() throws {
        let template = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("scripts/Info.plist.template")
        let contents = try String(contentsOf: template, encoding: .utf8)
        for key in ["CFBundleShortVersionString", "CFBundleVersion", "BarShelfSourceCommit"] {
            XCTAssertTrue(contents.contains("<key>\(key)</key>"), "template lost \(key)")
        }
        // The placeholder has to be substituted by build_app.sh, or the app
        // would display the literal token.
        let script = try String(
            contentsOf: template.deletingLastPathComponent()
                .appendingPathComponent("build_app.sh"),
            encoding: .utf8
        )
        XCTAssertTrue(script.contains("__APP_COMMIT__"), "build_app.sh never fills the commit in")
    }

}
