import AppKit
import XCTest
@testable import MenubucketApp

@MainActor
final class WidgetInstallURLPromptTests: XCTestCase {
    func testEditingEnablesInstallOnlyForSupportedURLsAndRetainsInvalidInput() {
        let prompt = WidgetInstallURLPrompt()
        XCTAssertFalse(prompt.alert.buttons[0].isEnabled)
        XCTAssertFalse(prompt.validationLabel.stringValue.isEmpty)

        prompt.field.stringValue = "https://github.com/example/widget"
        prompt.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        XCTAssertTrue(prompt.alert.buttons[0].isEnabled)

        prompt.field.stringValue = "https:///widget.zip"
        prompt.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        XCTAssertFalse(prompt.alert.buttons[0].isEnabled)
        XCTAssertEqual(prompt.field.stringValue, "https:///widget.zip")
        XCTAssertEqual(prompt.field.accessibilityLabel(), "Widget URL")
        XCTAssertEqual(prompt.alert.buttons[1].keyEquivalent, "\u{1b}")
    }

    func testArchiveAndDeepLinkInputsKeepExistingInstallSupport() {
        for value in [
            "  https://example.com/widget.zip?token=example  ",
            "https://example.com/widget.mbw",
            "barshelf://install?url=https%3A%2F%2Fexample.com%2Fwidget.zip",
        ] {
            XCTAssertNil(WidgetInstallURLPrompt.validationMessage(for: value))
        }
        for value in ["", " \n", "http://example.com/widget.zip", "https://example.com/page"] {
            XCTAssertNotNil(WidgetInstallURLPrompt.validationMessage(for: value))
        }
    }
}
