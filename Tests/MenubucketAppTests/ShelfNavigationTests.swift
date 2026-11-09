@testable import MenubucketApp
import XCTest

final class ShelfNavigationTests: XCTestCase {
    private let pages = [["a", "b", "c"], [], ["d"], ["e", "f"]]

    func testNothingChosenChoosesTheFirstWidget() {
        XCTAssertEqual(ShelfNavigation.next(from: nil, in: pages, dx: 0, dy: 1), "a")
        XCTAssertEqual(ShelfNavigation.next(from: "gone", in: pages, dx: 1, dy: 0), "a")
        XCTAssertNil(ShelfNavigation.next(from: nil, in: [[], []], dx: 0, dy: 1))
    }

    func testUpAndDownStayInThePageAndStopAtItsEnds() {
        XCTAssertEqual(ShelfNavigation.next(from: "a", in: pages, dx: 0, dy: 1), "b")
        XCTAssertEqual(ShelfNavigation.next(from: "c", in: pages, dx: 0, dy: 1), "c")
        XCTAssertEqual(ShelfNavigation.next(from: "a", in: pages, dx: 0, dy: -1), "a")
    }

    func testLeftAndRightSkipEmptyPagesAndKeepTheRowWhereTheyCan() {
        XCTAssertEqual(ShelfNavigation.next(from: "c", in: pages, dx: 1, dy: 0), "d", "row 2 → the only row")
        XCTAssertEqual(ShelfNavigation.next(from: "d", in: pages, dx: 1, dy: 0), "e")
        XCTAssertEqual(ShelfNavigation.next(from: "f", in: pages, dx: -1, dy: 0), "d")
        XCTAssertEqual(ShelfNavigation.next(from: "b", in: pages, dx: -1, dy: 0), "b", "nothing to the left")
    }
}
