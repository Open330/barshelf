import AppKit

/// BarShelf — menu bar host (LSUIElement / accessory).
///
/// `.accessory` is set programmatically so `swift build`-produced binaries run
/// as a menu-bar-only app during development; the packaged BarShelf.app also
/// sets LSUIElement=true in its Info.plist.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // An LSUIElement / `.accessory` app ships with no main menu, so the
        // standard editing key equivalents (⌘A/⌘C/⌘V/⌘X/⌘Z) never reach text
        // fields — e.g. Select All in the search field did nothing. Installing a
        // minimal Edit menu wires those selectors to the first responder.
        NSApp.mainMenu = Self.makeMainMenu()
        statusItemController = StatusItemController()
        // Silent update check shortly after launch — only surfaces UI when a
        // newer release exists (menu item does an explicit check).
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            UpdateChecker.check(explicit: false)
        }
    }

    /// Minimal main menu carrying only the standard Edit commands. Not shown
    /// (accessory app has no visible menu bar) but its key equivalents are
    /// dispatched to the first responder while the app is active — the standard
    /// way menu-bar apps enable cut/copy/paste/select-all in their popovers.
    private static func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        editItem.submenu = edit
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        return main
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
