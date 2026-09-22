import AppKit
import MenubucketCore

/// Keeps invalid input in the dialog so it can be corrected before download.
final class WidgetInstallURLPrompt: NSObject, NSTextFieldDelegate {
    let alert = NSAlert()
    let field = NSTextField(frame: NSRect(x: 0, y: 56, width: 340, height: 24))
    let validationLabel = NSTextField(wrappingLabelWithString: "")

    override init() {
        super.init()
        alert.messageText = "Install Widget from URL"
        alert.informativeText = "Enter a GitHub repository URL or a direct .zip/.mbw archive URL."
        field.placeholderString = "https://github.com/user/widget-repo"
        field.setAccessibilityLabel("Widget URL")
        field.delegate = self
        validationLabel.frame = NSRect(x: 0, y: 0, width: 340, height: 48)
        validationLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 80))
        accessory.addSubview(field)
        accessory.addSubview(validationLabel)
        alert.accessoryView = accessory
        alert.addButton(withTitle: "Install").keyEquivalent = "\r"
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        alert.window.initialFirstResponder = field
        validate()
    }

    func run() -> String? {
        guard alert.runModal() == .alertFirstButtonReturn,
              Self.validationMessage(for: field.stringValue) == nil else { return nil }
        return field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func controlTextDidChange(_ notification: Notification) {
        validate()
    }

    private func validate() {
        let message = Self.validationMessage(for: field.stringValue)
        alert.buttons[0].isEnabled = message == nil
        validationLabel.stringValue = message ?? "Ready to review and install this widget."
        let isEmpty = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        validationLabel.textColor = message != nil && !isEmpty ? .systemRed : .secondaryLabelColor
        field.setAccessibilityHelp(validationLabel.stringValue)
    }

    static func validationMessage(for input: String) -> String? {
        if input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Enter a widget URL to continue."
        }
        do {
            _ = try WidgetInstallSource.parse(input)
            return nil
        } catch {
            // Keep guidance short enough to read below the field; the input
            // itself stays editable instead of being repeated in an error.
            return "Use an HTTPS GitHub repository or a .zip/.mbw archive URL."
        }
    }
}
