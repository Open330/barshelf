import AppKit
import SwiftUI
import XCTest
@testable import MenubucketApp

@MainActor
final class SearchFieldCoordinatorTests: XCTestCase {
    func testReturnAndArrowsUseUpdatedResultsCallbacks() {
        var submitted: [String] = []
        var movements: [Int] = []
        let coordinator = SearchField.Coordinator(SearchField(
            text: .constant(""), onSubmit: { submitted.append("stale") }
        ))
        coordinator.parent = SearchField(
            text: .constant("current query"),
            onSubmit: { submitted.append("current result") },
            onMoveSelection: { movements.append($0) }
        )
        let field = NSSearchField()
        let editor = NSTextView()
        XCTAssertTrue(coordinator.control(
            field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))
        ))
        XCTAssertTrue(coordinator.control(
            field, textView: editor, doCommandBy: #selector(NSResponder.moveDown(_:))
        ))
        XCTAssertTrue(coordinator.control(
            field, textView: editor, doCommandBy: #selector(NSResponder.moveUp(_:))
        ))
        XCTAssertEqual(submitted, ["current result"])
        XCTAssertEqual(movements, [1, -1])
    }

    func testOrdinaryWidgetSearchKeepsNativeArrowHandling() {
        let coordinator = SearchField.Coordinator(SearchField(text: .constant("query")))
        XCTAssertFalse(coordinator.control(
            NSSearchField(), textView: NSTextView(), doCommandBy: #selector(NSResponder.moveDown(_:))
        ))
    }
}
