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
}
