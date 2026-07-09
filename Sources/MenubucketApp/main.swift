import AppKit

/// BarShelf — menu bar host (LSUIElement / accessory).
///
/// `.accessory` is set programmatically so `swift build`-produced binaries run
/// as a menu-bar-only app during development; the packaged BarShelf.app also
/// sets LSUIElement=true in its Info.plist.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItemController = StatusItemController()
        // Silent update check shortly after launch — only surfaces UI when a
        // newer release exists (menu item does an explicit check).
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            UpdateChecker.check(explicit: false)
        }
    }

    /// `barshelf://install?url=<percent-encoded-url>` deep link
    /// (URL scheme registered via CFBundleURLTypes in Info.plist).
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme?.lowercased() == "barshelf" {
            WidgetInstaller.shared.handleDeepLink(url)
        }
    }
}

// App-binary headless mode: `barshelf-app install <url>` installs and exits
// before NSApplication starts. Public automation should use the standalone
// `barshelf install` CLI, which shares the same installer pipeline.
let commandLineArguments = CommandLine.arguments
if commandLineArguments.count >= 2, commandLineArguments[1] == "install" {
    exit(WidgetInstallCLI.run(arguments: Array(commandLineArguments.dropFirst(2))))
}

// `barshelf-app screenshot <dir>` renders the real widget UI to PNGs offscreen
// (landing-page / README assets) and exits — no window, no TCC permissions.
if commandLineArguments.count >= 2, commandLineArguments[1] == "screenshot" {
    let outDir = commandLineArguments.count >= 3 ? commandLineArguments[2] : "./site/shots"
    exit(MainActor.assumeIsolated { ScreenshotMode.run(outputDir: outDir) })
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
