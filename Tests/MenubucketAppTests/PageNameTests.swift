import XCTest
@testable import MenubucketApp

final class PageNameTests: XCTestCase {
    /// The pages starters arrive on read in the app's words — "Demo" is the
    /// gallery's Everyday. Conventional keys share their display label; other
    /// names, even ones with similar spelling, remain as typed.
    func testBundledPagesUseTheAppsWordsAndOthersStayAsWritten() {
        XCTAssertEqual(PageName.label("Demo"), GalleryEntryText.categoryLabel("demo"))
        XCTAssertEqual(PageName.label("Demo"), String(localized: "Everyday", comment: "Gallery category for clock, calendar, weather and similar widgets"))
        XCTAssertEqual(PageName.label("Files"), String(localized: "Files", comment: "Gallery category"))
        XCTAssertEqual(PageName.label("Productivity"), String(localized: "Productivity", comment: "Gallery category"))
        XCTAssertEqual(PageName.label("General"), String(localized: "General"))
        XCTAssertEqual(PageName.label("Work Stuff"), "Work Stuff")
        XCTAssertEqual(PageName.label("데모"), "데모")
        XCTAssertEqual(PageName.label("Everyday"), PageName.label("Demo"))
        XCTAssertEqual(PageName.label("files"), "files")
        XCTAssertEqual(PageName.label(" Demo "), " Demo ")
    }
}
