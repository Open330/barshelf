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
        }
        for tab in MenuBarSettingsTab.allCases {
            let view = WidgetSettingsView(widget: widget, runtime: runtime, initialTab: tab)
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

    /// Every page of the hub's sidebar, each in the real window layout.
    func testWriteTheHubPages() throws {
        guard let dir = ProcessInfo.processInfo.environment["BARSHELF_SHOT_DIR"] else {
            throw XCTSkip("set BARSHELF_SHOT_DIR to write the hub pages")
        }
        let prefs = AppPrefs(fileURL: URL(fileURLWithPath: dir).appendingPathComponent("shot-app-prefs.json"))
        let runtime = WidgetRuntime(appPrefs: prefs)
        runtime.loadWidgets()
        let wanted = ProcessInfo.processInfo.environment["BARSHELF_SHOT_TABS"]
            .map { Set($0.split(separator: ",").map(String.init)) }
        var shots: [(name: String, tab: HubTab, select: String?)] = HubTab.allCases.map { ($0.rawValue, $0, nil) }
        if let first = runtime.widgets.first(where: { $0.id == "dev.barshelf.system" }) ?? runtime.widgets.first {
            shots.append(("widgets-inspector", .shelf, first.id))
        }
        for (name, tab, select) in shots where wanted?.contains(name) ?? true {
            let model = HubModel(tab: tab)
            model.settingsWidgetID = select
            let view = HubView(runtime: runtime, appPrefs: prefs, model: model)
                .frame(width: 1040, height: 720)
            let hosting = NSHostingView(rootView: view)
            hosting.frame = NSRect(x: 0, y: 0, width: 1040, height: 720)
            let window = NSWindow(
                contentRect: hosting.frame, styleMask: [.titled, .resizable],
                backing: .buffered, defer: false
            )
            window.contentView = hosting
            hosting.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))

            let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            let url = URL(fileURLWithPath: dir).appendingPathComponent("hub-\(name).png")
            try png.write(to: url)
            print("wrote \(url.path)")
        }
    }

    func testWriteTheOnboardingSteps() throws {
        guard let dir = ProcessInfo.processInfo.environment["BARSHELF_SHOT_DIR"] else {
            throw XCTSkip("set BARSHELF_SHOT_DIR to write the onboarding steps")
        }
        let prefs = AppPrefs(fileURL: URL(fileURLWithPath: dir).appendingPathComponent("shot-app-prefs.json"))
        let runtime = WidgetRuntime(appPrefs: prefs)
        runtime.loadWidgets()
        for step in OnboardingView.Step.allCases {
            let view = OnboardingView(runtime: runtime, appPrefs: prefs, startAt: step) { _ in }
            let hosting = NSHostingView(rootView: view)
            hosting.frame = NSRect(x: 0, y: 0, width: 560, height: 500)
            let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = hosting
            hosting.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("onboarding-\(step.rawValue).png"))
        }
    }

    /// The real popup, on the real runtime and its cached widget data:
    /// `BARSHELF_SHOT_DIR=/tmp swift test --filter testWriteThePopup`.
    /// Set BARSHELF_SHOT_EDIT=1 to render edit mode.
    func testWriteThePopup() throws {
        guard let dir = ProcessInfo.processInfo.environment["BARSHELF_SHOT_DIR"] else {
            throw XCTSkip("set BARSHELF_SHOT_DIR to write the popup")
        }
        let prefs = AppPrefs(fileURL: URL(fileURLWithPath: dir).appendingPathComponent("shot-app-prefs.json"))
        let runtime = WidgetRuntime(appPrefs: prefs)
        runtime.loadWidgets()
        let pager = PagerState()
        pager.isEditing = ProcessInfo.processInfo.environment["BARSHELF_SHOT_EDIT"] == "1"
        for scheme in [ColorScheme.light, .dark] {
            let view = RootView(runtime: runtime, pager: pager)
                .environment(\.colorScheme, scheme)
                .frame(width: 360, height: 760)
            let hosting = NSHostingView(rootView: view)
            hosting.frame = NSRect(x: 0, y: 0, width: 360, height: 760)
            hosting.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = hosting
            hosting.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("popup-\(scheme == .dark ? "dark" : "light").png"))
        }
    }
}
