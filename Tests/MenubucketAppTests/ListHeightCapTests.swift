import AppKit
import SwiftUI
import XCTest
import MenubucketCore
@testable import MenubucketApp

/// A searchable or long list must not grow its card without bound (the
/// Bitwarden card with a few hundred vault items did).
@MainActor
final class ListHeightCapTests: XCTestCase {
    private func list(rows: Int, search: Bool, height: Double? = nil) throws -> UINode {
        var node: [String: Any] = [
            "type": "list",
            "items": (0..<rows).map { ["type": "text", "text": "Item \($0)"] },
        ]
        if search { node["searchPlaceholder"] = "Search vault" }
        if let height { node["height"] = height }
        return try JSONDecoder().decode(UINode.self, from: JSONSerialization.data(withJSONObject: node))
    }

    private func settledHeight(_ node: UINode, cardScrolls: Bool = false) -> CGFloat {
        let host = NSHostingView(rootView: NodeView(node: node).frame(width: 320)
            .environment(\.widgetCardScrolls, cardScrolls))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 2000),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        for _ in 0..<5 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return host.fittingSize.height
    }

    func testASearchableListOfHundredsOfRowsScrollsInsideTheCap() throws {
        let height = settledHeight(try list(rows: 300, search: true))
        XCTAssertLessThanOrEqual(height, 320 + 60, "rows capped, search field above them")
        XCTAssertGreaterThan(height, 200, "and it still shows a good number of rows")
    }

    func testALongListWithoutSearchIsCappedAndAShortOneIsNot() throws {
        XCTAssertLessThanOrEqual(settledHeight(try list(rows: 80, search: false)), 330)
        let short = settledHeight(try list(rows: 3, search: false))
        XCTAssertLessThan(short, 100, "a short list keeps its own height")
        XCTAssertGreaterThan(short, 20)
    }

    func testAShortSearchableListIsNotStretchedToTheCap() throws {
        XCTAssertLessThan(settledHeight(try list(rows: 2, search: true)), 120)
    }

    /// A fixed-height card already scrolls: the list fills it instead.
    func testInACardThatScrollsTheListIsNotCapped() throws {
        XCTAssertGreaterThan(settledHeight(try list(rows: 80, search: true), cardScrolls: true), 1000)
    }

    func testTheAuthorCanSetTheCap() throws {
        XCTAssertLessThanOrEqual(settledHeight(try list(rows: 100, search: false, height: 120)), 130)
    }
}
