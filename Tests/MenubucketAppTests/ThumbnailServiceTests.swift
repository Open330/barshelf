import AppKit
import XCTest
@testable import MenubucketApp

final class ThumbnailServiceTests: XCTestCase {
    func testCacheKeyRetainsSubsecondModificationIdentity() {
        let early = ThumbnailService.cacheKey(
            path: "/tmp/sample.pdf", modifiedAt: 1_000.125, pointSize: 32)
        let later = ThumbnailService.cacheKey(
            path: "/tmp/sample.pdf", modifiedAt: 1_000.875, pointSize: 32)

        XCTAssertNotEqual(early, later)
    }

    func testCacheKeyAcceptsNonFiniteMetadataAndSanitizesPointSize() {
        XCTAssertNoThrow(ThumbnailService.cacheKey(
            path: "/tmp/sample.pdf", modifiedAt: Double.infinity, pointSize: CGFloat.nan))
        XCTAssertNoThrow(ThumbnailService.cacheKey(
            path: "/tmp/sample.pdf", modifiedAt: Double.nan, pointSize: CGFloat.infinity))

        let negative = ThumbnailService.cacheKey(
            path: "/tmp/sample.pdf", modifiedAt: 10, pointSize: -50)
        let minimum = ThumbnailService.cacheKey(
            path: "/tmp/sample.pdf", modifiedAt: 10, pointSize: 1)
        let oversized = ThumbnailService.cacheKey(
            path: "/tmp/sample.pdf", modifiedAt: 10, pointSize: 9_999)
        let maximum = ThumbnailService.cacheKey(
            path: "/tmp/sample.pdf", modifiedAt: 10, pointSize: 512)

        XCTAssertEqual(negative, minimum)
        XCTAssertEqual(oversized, maximum)
    }
}
