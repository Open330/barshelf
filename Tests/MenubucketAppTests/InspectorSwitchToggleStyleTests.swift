import XCTest
@testable import MenubucketApp

/// The inspector's on/off rows draw their own label beside a switch whose
/// label is hidden, and a hidden-label switch drops its title from
/// accessibility. The row must stand in as one toggle named by that label.
///
/// Read from source: SwiftUI builds its accessibility tree only for a
/// connected assistive client, which a test run does not have.
final class InspectorSwitchToggleStyleTests: XCTestCase {
    func testTheRowIsOneToggleNamedByItsLabel() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("Sources/MenubucketApp/WidgetSettingsView.swift"), encoding: .utf8)
        let start = try XCTUnwrap(text.range(of: "struct InspectorSwitchToggleStyle: ToggleStyle"))
        let style = String(text[start.lowerBound...].prefix(1500))
        XCTAssertTrue(style.contains(".accessibilityElement(children: .ignore)"), "the drawn label and the switch must not read as two elements")
        XCTAssertTrue(style.contains(".accessibilityRepresentation {")
            && style.contains("Toggle(isOn: configuration.$isOn) { configuration.label }"),
            "the row must read as a toggle carrying the row's label")
    }

    func testInspectorTogglesUseTheStyle() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("Sources/MenubucketApp/WidgetSettingsView.swift"), encoding: .utf8)
        XCTAssertTrue(text.contains(".toggleStyle(InspectorSwitchToggleStyle())"))
        XCTAssertFalse(text.contains(".toggleStyle(.checkbox)"), "on/off rows in the inspector are switches")
    }
}
