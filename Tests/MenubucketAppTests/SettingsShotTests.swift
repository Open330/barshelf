import XCTest
import AppKit
import SwiftUI
import MenubucketCore
@testable import MenubucketApp

/// Renders the real settings pane so its layout can be looked at:
/// `BARSHELF_SHOT_DIR=/tmp swift test --filter SettingsShot`
///
/// Skipped otherwise — it builds a live runtime against the real Application
/// Support directory, which a test suite has no business doing unasked.
@MainActor
final class SettingsShotTests: XCTestCase {
    func testWriteTheSettingsPane() throws {
        guard let dir = ProcessInfo.processInfo.environment["BARSHELF_SHOT_DIR"] else {
            throw XCTSkip("set BARSHELF_SHOT_DIR to write the settings pane")
        }
        let runtime = WidgetRuntime()
        runtime.loadWidgets()
        guard let widget = runtime.widgets.first(where: { $0.id == "dev.barshelf.system" })
            ?? runtime.widgets.first
        else { throw XCTSkip("no widget installed to render settings for") }

        let view = WidgetSettingsView(widget: widget, runtime: runtime)
            .frame(width: 420)
            .background(Color(nsColor: .windowBackgroundColor))
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 420, height: 760)
        hosting.layoutSubtreeIfNeeded()

        let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        let url = URL(fileURLWithPath: dir).appendingPathComponent("settings.png")
        try png.write(to: url)
        print("wrote \(url.path)")
    }
}
