import Foundation
import XCTest
@testable import MenubucketApp

final class PopupEventRoutingTests: XCTestCase {
    func testOnlyEventsFromThePopupWindowAreHandled() {
        let popupWindow = NSObject()
        let hubWindow = NSObject()

        XCTAssertTrue(PopupEventRouting.belongsToPopup(
            eventWindow: popupWindow, popupWindow: popupWindow
        ))
        XCTAssertFalse(PopupEventRouting.belongsToPopup(
            eventWindow: hubWindow, popupWindow: popupWindow
        ))
        XCTAssertFalse(PopupEventRouting.belongsToPopup(
            eventWindow: nil, popupWindow: popupWindow
        ))
    }
}
