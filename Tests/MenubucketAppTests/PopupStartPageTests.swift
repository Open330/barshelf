import MenubucketCore
import XCTest
@testable import MenubucketApp

final class PopupStartPageTests: XCTestCase {
    private let groups = ["Everyday", "System", "Work"]

    func testRememberingKeepsThePageThePopupWasLeftOn() {
        XCTAssertEqual(PopupStartPage.index(remembers: true, restoring: nil, current: 2, groups: groups), 2)
    }

    func testNotRememberingAlwaysStartsAtTheFirstPage() {
        XCTAssertEqual(PopupStartPage.index(remembers: false, restoring: nil, current: 2, groups: groups), 0)
        XCTAssertEqual(PopupStartPage.index(remembers: false, restoring: "Work", current: 1, groups: groups), 0,
                       "a page saved before the option was turned off is not used")
    }

    /// The first opening after a relaunch goes to the saved page by name, so
    /// reordering pages in between does not land on the wrong one.
    func testTheFirstOpeningAfterLaunchRestoresTheSavedPageByName() {
        XCTAssertEqual(PopupStartPage.index(remembers: true, restoring: "Work", current: 0, groups: groups), 2)
        XCTAssertEqual(PopupStartPage.index(remembers: true, restoring: "Work", current: 0,
                                            groups: ["Work", "Everyday", "System"]), 0)
    }

    func testASavedPageThatIsGoneFallsBackToWhereThePagerIs() {
        XCTAssertEqual(PopupStartPage.index(remembers: true, restoring: "Removed", current: 1, groups: groups), 1)
    }

    func testTheIndexIsKeptInsideThePages() {
        XCTAssertEqual(PopupStartPage.index(remembers: true, restoring: nil, current: 9, groups: groups), 2)
        XCTAssertEqual(PopupStartPage.index(remembers: true, restoring: nil, current: -1, groups: groups), 0)
        XCTAssertEqual(PopupStartPage.index(remembers: true, restoring: "Work", current: 3, groups: []), 0)
    }

    func testOnlyARememberedRealPageIsSaved() {
        XCTAssertEqual(PopupStartPage.nameToSave(remembers: true, index: 1, groups: groups), "System")
        XCTAssertNil(PopupStartPage.nameToSave(remembers: false, index: 1, groups: groups), "off forgets")
        XCTAssertNil(PopupStartPage.nameToSave(remembers: true, index: 5, groups: groups))
    }

    /// On by default, also for a preferences file written before the option
    /// existed: that is how the popup behaved within a run already.
    func testThePreferenceDefaultsToOnAndSurvivesARoundTrip() throws {
        XCTAssertTrue(AppPreferences().popupRemembersPage)
        let old = try JSONDecoder().decode(AppPreferences.self, from: Data(#"{"menuBarSymbol":"star"}"#.utf8))
        XCTAssertTrue(old.popupRemembersPage)
        var off = AppPreferences()
        off.popupRemembersPage = false
        let back = try JSONDecoder().decode(AppPreferences.self, from: JSONEncoder().encode(off))
        XCTAssertFalse(back.popupRemembersPage)
    }
}
