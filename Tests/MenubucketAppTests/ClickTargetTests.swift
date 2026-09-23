import XCTest
@testable import MenubucketApp

@MainActor
final class ClickTargetTests: XCTestCase {
    func testTargetsResolveOrFallBack() {
        XCTAssertEqual(StatusItemController.clickTargetURL("https://example.com")?.host, "example.com")
        XCTAssertEqual(StatusItemController.clickTargetURL(" com.apple.finder ")?.lastPathComponent, "Finder.app")
        XCTAssertEqual(StatusItemController.clickTargetURL("/System/Applications/Utilities/Activity Monitor.app")?.lastPathComponent,
                       "Activity Monitor.app")
        XCTAssertEqual(StatusItemController.clickTargetURL("x-apple.systempreferences:com.apple.preference.security")?.scheme,
                       "x-apple.systempreferences", "a URL needs no slashes")
        XCTAssertNil(StatusItemController.clickTargetURL("com.example.not-an-app"))
        XCTAssertNil(StatusItemController.clickTargetURL("/no/such/thing.app"))
        XCTAssertNil(StatusItemController.clickTargetURL("   "))
    }
}
