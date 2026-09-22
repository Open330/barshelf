import AppKit
import XCTest
@testable import MenubucketApp

@MainActor
final class WidgetImageLoaderTests: XCTestCase {
    func testOldURLCompletionCannotReplaceNewImage() {
        let loader = WidgetImageLoader()
        var finishOld: ((NSImage?) -> Void)!
        var finishNew: ((NSImage?) -> Void)!
        loader.load(identity: "old") { finishOld = $0; return nil }
        loader.load(identity: "new") { finishNew = $0; return nil }
        let expected = NSImage(size: NSSize(width: 12, height: 12))
        finishNew(expected)
        finishOld(NSImage(size: NSSize(width: 24, height: 24)))
        XCTAssertTrue(loader.image(for: "new") === expected)
        XCTAssertNil(loader.image(for: "old"))
    }

    func testHiddenOrRevokedImageIgnoresPendingCompletionEvenAfterSameURLReload() {
        let loader = WidgetImageLoader()
        var finishOld: ((NSImage?) -> Void)!
        loader.load(identity: "same") { finishOld = $0; return nil }
        loader.reset()
        let expected = NSImage(size: NSSize(width: 12, height: 12))
        loader.load(identity: "same") { _ in expected }
        finishOld(NSImage(size: NSSize(width: 24, height: 24)))
        XCTAssertTrue(loader.image(for: "same") === expected)
        loader.reset()
        XCTAssertNil(loader.image(for: "same"))
    }

    func testCoalescesVisibleRequestsAndAllowsRetryAfterFailure() {
        let loader = WidgetImageLoader()
        var completion: ((NSImage?) -> Void)!
        var requests = 0
        let request: (@escaping (NSImage?) -> Void) -> NSImage? = {
            requests += 1
            completion = $0
            return nil
        }
        loader.load(identity: "image", request: request)
        loader.load(identity: "image", request: request)
        XCTAssertEqual(requests, 1)
        completion(nil)
        loader.load(identity: "image", request: request)
        XCTAssertEqual(requests, 2)
    }
}
