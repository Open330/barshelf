import XCTest
@testable import MenubucketApp

/// Pages are the names their widgets share, so renaming, merging and
/// removing a page are all rewrites of those names (`ShelfPageEdit`).
final class ShelfPageEditTests: XCTestCase {
    private let pages: [(group: String, widgets: [(id: String, manifestGroup: String)])] = [
        ("System", [("cpu", "System"), ("ram", "System")]),
        ("Agents", [("watch", "Developer")]),
        ("Files", [("recent", "Files")]),
    ]

    func testRenameKeepsThePagesPlaceAndItsWidgetsOrder() throws {
        let plan = try XCTUnwrap(ShelfPageEdit.rename("System", to: " Machine ", pages: pages))
        XCTAssertEqual(plan.pageOrder, ["Machine", "Agents", "Files"])
        XCTAssertEqual(plan.placements, [
            .init(id: "cpu", group: "Machine", order: 0),
            .init(id: "ram", group: "Machine", order: 1),
        ])
    }

    func testRenamingBackToTheManifestNameDropsTheOverride() throws {
        let plan = try XCTUnwrap(ShelfPageEdit.rename("Agents", to: "Developer", pages: pages))
        XCTAssertEqual(plan.placements, [.init(id: "watch", group: nil, order: 0)])
        XCTAssertEqual(plan.pageOrder, ["System", "Developer", "Files"])
    }

    func testMergeAppendsAfterTheTargetsWidgetsAndDropsThePage() throws {
        let plan = try XCTUnwrap(ShelfPageEdit.rename("Agents", to: "System", pages: pages))
        XCTAssertEqual(plan.pageOrder, ["System", "Files"])
        XCTAssertEqual(plan.placements, [
            .init(id: "cpu", group: nil, order: 0),
            .init(id: "ram", group: nil, order: 1),
            .init(id: "watch", group: "System", order: 2),
        ])
    }

    func testNothingToDo() {
        XCTAssertNil(ShelfPageEdit.rename("System", to: "System", pages: pages))
        XCTAssertNil(ShelfPageEdit.rename("System", to: "   ", pages: pages))
        XCTAssertNil(ShelfPageEdit.rename("Missing", to: "New", pages: pages))
    }
}
