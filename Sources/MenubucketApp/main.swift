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
    }

    /// `barshelf://install?url=<percent-encoded-url>` deep link
    /// (URL scheme registered via CFBundleURLTypes in Info.plist).
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where ["barshelf", "menubucket"].contains(url.scheme?.lowercased() ?? "") {
            WidgetInstaller.shared.handleDeepLink(url)
        }
    }
}

// CLI mode: `menubucket install <url>` installs headlessly and exits (0/1)
// before NSApplication starts — the basis for a future `mbk` CLI.
let commandLineArguments = CommandLine.arguments
if commandLineArguments.count >= 2, commandLineArguments[1] == "install" {
    exit(WidgetInstallCLI.run(arguments: Array(commandLineArguments.dropFirst(2))))
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
