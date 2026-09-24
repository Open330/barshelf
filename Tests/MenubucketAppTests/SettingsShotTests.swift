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
        let wanted = ProcessInfo.processInfo.environment["BARSHELF_SHOT_WIDGET"] ?? "dev.barshelf.system"
        guard let widget = runtime.widgets.first(where: { $0.id == wanted })
            ?? runtime.widgets.first
        else { throw XCTSkip("no widget installed to render settings for") }

        // The whole pane, not its first screen — once per tab.
        WidgetSettingsView.scrollMaxHeight = 2000
        defer {
            WidgetSettingsView.scrollMaxHeight = 420
            WidgetSettingsView.initialMenuBarTab = .look
        }
        for tab in MenuBarSettingsTab.allCases {
            WidgetSettingsView.initialMenuBarTab = tab
            let view = WidgetSettingsView(widget: widget, runtime: runtime)
                .frame(width: 420)
                .background(Color(nsColor: .windowBackgroundColor))
            let hosting = NSHostingView(rootView: view)
            hosting.frame = NSRect(x: 0, y: 0, width: 420, height: 1500)
            hosting.layoutSubtreeIfNeeded()

            let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            let url = URL(fileURLWithPath: dir).appendingPathComponent("settings-\(tab.title.lowercased()).png")
            try png.write(to: url)
            print("wrote \(url.path)")
        }
    }

    func testWriteTheMenuBarDefaults() throws {
        guard let dir = ProcessInfo.processInfo.environment["BARSHELF_SHOT_DIR"] else {
            throw XCTSkip("set BARSHELF_SHOT_DIR to write the settings pane")
        }
        let prefs = AppPrefs(fileURL: URL(fileURLWithPath: dir).appendingPathComponent("shot-app-prefs.json"))
        prefs.update { $0.menuBarPresentation = MenuBarPresentation(width: .fixed, size: .small) }
        // The runtime and the pane must agree on the app-wide style.
        let runtime = WidgetRuntime(appPrefs: prefs)
        runtime.loadWidgets()
        let view = AppSettingsView(appPrefs: prefs, runtime: runtime, section: .menuBar)
            .frame(width: 640, height: 720)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 640, height: 720)
        hosting.layoutSubtreeIfNeeded()

        let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        let url = URL(fileURLWithPath: dir).appendingPathComponent("menubar-defaults.png")
        try png.write(to: url)
        print("wrote \(url.path)")
    }
}
