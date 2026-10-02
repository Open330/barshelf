import AppKit
import SwiftUI

/// `barshelf-app screenshot-hub <dir>` renders every page of the BarShelf
/// window, each onboarding step, and the popup to PNGs, then exits.
///
/// Unlike `screenshot`, this draws through `NSHostingView`, which renders
/// native controls, and it runs in the app bundle, so the strings come out
/// in the app's language: add `-AppleLanguages "(ko)"` to see the Korean UI.
///
/// It builds a live runtime, which seeds starter widgets and writes state
/// under the home folder, so it refuses to run unless `CFFIXED_USER_HOME`
/// points somewhere disposable.
enum HubScreenshotMode {
    @MainActor
    static func run(outputDir: String) -> Int32 {
        guard let home = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"], !home.isEmpty else {
            FileHandle.standardError.write(Data(
                "screenshot-hub writes widget state; set CFFIXED_USER_HOME to a scratch folder\n".utf8
            ))
            return 2
        }
        _ = NSApplication.shared
        let dir = URL(fileURLWithPath: (outputDir as NSString).expandingTildeInPath)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let prefs = AppPrefs(fileURL: URL(fileURLWithPath: home).appendingPathComponent("shot-app-prefs.json"))
        let runtime = WidgetRuntime(appPrefs: prefs)
        runtime.loadWidgets()
        RunLoop.main.run(until: Date().addingTimeInterval(1))

        var ok = true
        for tab in HubTab.allCases {
            let model = HubModel(tab: tab)
            ok = render(HubView(runtime: runtime, appPrefs: prefs, model: model),
                        size: NSSize(width: 1040, height: 720), name: "hub-\(tab.rawValue)", to: dir) && ok
        }
        if let first = runtime.widgets.first {
            let model = HubModel(tab: .shelf)
            model.settingsWidgetID = first.id
            ok = render(HubView(runtime: runtime, appPrefs: prefs, model: model),
                        size: NSSize(width: 1040, height: 720), name: "hub-inspector", to: dir) && ok
        }
        for step in OnboardingView.Step.allCases {
            ok = render(OnboardingView(runtime: runtime, appPrefs: prefs, startAt: step) { _ in },
                        size: NSSize(width: 560, height: 500), name: "onboarding-\(step.rawValue)", to: dir) && ok
        }
        ok = render(RootView(runtime: runtime, pager: PagerState()),
                    size: NSSize(width: 360, height: 640), name: "popup", to: dir) && ok
        return ok ? 0 : 1
    }

    @MainActor
    private static func render<Content: View>(_ view: Content, size: NSSize, name: String, to dir: URL) -> Bool {
        let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return false }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        let url = dir.appendingPathComponent("\(name).png")
        do {
            try png.write(to: url)
            print("wrote \(url.path)")
            return true
        } catch {
            FileHandle.standardError.write(Data("\(name): \(error.localizedDescription)\n".utf8))
            return false
        }
    }
}
