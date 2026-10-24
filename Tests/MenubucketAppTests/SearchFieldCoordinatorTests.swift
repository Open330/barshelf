import AppKit
import SwiftUI
import XCTest
@testable import MenubucketApp

/// The search field's Return, Escape and arrow handling against a real
/// offscreen field editor. Marked text is set directly, as an input method
/// would; no keyboard, input method or VoiceOver is involved.
@MainActor
final class SearchFieldCoordinatorTests: XCTestCase {
    private var submits = 0
    private var cancels = 0
    private var moves: [Int] = []
    private var text = ""

    private func makeField() throws -> (SearchField.Coordinator, NSSearchField, NSTextView, NSWindow) {
        let coordinator = SearchField.Coordinator(SearchField(
            text: Binding(get: { self.text }, set: { self.text = $0 }),
            onSubmit: { self.submits += 1 },
            onCancel: { self.cancels += 1 },
            onMoveSelection: { self.moves.append($0) }
        ))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 40),
            styleMask: [.titled], backing: .buffered, defer: true
        )
        let field = NSSearchField(frame: NSRect(x: 0, y: 0, width: 200, height: 22))
        field.delegate = coordinator
        window.contentView?.addSubview(field)
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        return (coordinator, field, editor, window)
    }

    private let commands: [Selector] = [
        #selector(NSResponder.insertNewline(_:)),
        #selector(NSResponder.cancelOperation(_:)),
        #selector(NSResponder.moveUp(_:)),
        #selector(NSResponder.moveDown(_:)),
    ]

    func testWhileComposingTheInputMethodKeepsReturnEscapeAndArrows() throws {
        let (coordinator, field, editor, window) = try makeField()
        editor.insertText("날", replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.setMarkedText("ㅆ", selectedRange: NSRange(location: 1, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(editor.hasMarkedText())

        for command in commands {
            XCTAssertFalse(coordinator.control(field, textView: editor, doCommandBy: command), "\(command)")
        }
        XCTAssertEqual(submits, 0, "Return during composition must not run a result")
        XCTAssertEqual(cancels, 0, "Escape during composition must not close search")
        XCTAssertEqual(moves, [], "arrows during composition must not move the selection")
        XCTAssertTrue(editor.hasMarkedText(), "the composition is left to the input method")
        XCTAssertEqual(editor.string, "날ㅆ")
        _ = window
    }

    func testOnceCommittedSearchHandlesTheKeysAgain() throws {
        let (coordinator, field, editor, window) = try makeField()
        editor.setMarkedText("씨", selectedRange: NSRange(location: 1, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.unmarkText()
        XCTAssertFalse(editor.hasMarkedText())
        coordinator.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        XCTAssertEqual(text, "씨", "the committed text reaches the query")

        XCTAssertTrue(coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.moveDown(_:))))
        XCTAssertTrue(coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.moveUp(_:))))
        XCTAssertTrue(coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertTrue(coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        XCTAssertEqual(moves, [1, -1])
        XCTAssertEqual(submits, 1)
        XCTAssertEqual(cancels, 1)
        _ = window
    }
}
