import XCTest
@testable import MenubucketApp

final class SearchMatcherTests: XCTestCase {
    func testEveryWordMustAppearInAnyOrder() {
        XCTAssertTrue(SearchMatcher("cpu temp").matches("Temperature · CPU"))
        XCTAssertFalse(SearchMatcher("cpu fan").matches("Temperature · CPU"))
    }

    func testCaseAccentsAndWidthAreIgnored() {
        XCTAssertTrue(SearchMatcher("cafe").matches("Café hours"))
        XCTAssertTrue(SearchMatcher("ＢＡＴＴＥＲＹ").matches("Battery"))
        XCTAssertTrue(SearchMatcher("battery").matches("BATTERY 82%"))
    }

    /// A widget shown by its Korean name is still found by its English one.
    func testWordsCanComeFromEitherName() {
        XCTAssertTrue(SearchMatcher("weather").matches("날씨", "Weather"))
        XCTAssertTrue(SearchMatcher("날씨").matches("날씨", "Weather"))
        XCTAssertFalse(SearchMatcher("battery").matches("날씨", "Weather"))
    }

    func testBlankQueriesMatchNothing() {
        XCTAssertTrue(SearchMatcher("   ").isEmpty)
        XCTAssertFalse(SearchMatcher("").matches("anything"))
        XCTAssertFalse(SearchMatcher("x").matches(nil))
    }
}
