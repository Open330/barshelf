import XCTest
@testable import MenubucketCore

final class WidgetEntryResolverTests: XCTestCase {
    func testNestedEntryInsidePackageIsAllowed() throws {
        let root = URL(fileURLWithPath: "/tmp/widget-entry")
        XCTAssertEqual(
            try WidgetEntryResolver.resolve(
                directory: root, main: "src/main.ts", defaultName: "index.ts"
            ).path,
            "/tmp/widget-entry/src/main.ts"
        )
    }

    func testAbsoluteAndTraversalEntriesAreRejected() {
        let root = URL(fileURLWithPath: "/tmp/widget-entry")
        XCTAssertThrowsError(try WidgetEntryResolver.resolve(
            directory: root, main: "/tmp/evil.ts", defaultName: "index.ts"
        ))
        XCTAssertThrowsError(try WidgetEntryResolver.resolve(
            directory: root, main: "../evil.ts", defaultName: "index.ts"
        ))
    }
}
