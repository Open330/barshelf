import BarShelfDock
import BarShelfAutomation
import AppKit
import MenubucketCore

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
        // Before the stores load, so a settings file moved aside at launch
        // is reported.
        SettingsFileProblems.shared.start()
        statusItemController = StatusItemController()
        if let menu = NSApp.mainMenu { statusItemController?.installCommands(in: menu) }
        // First launch: the starter widgets were just seeded, so walk through
        // them, the shortcut, and the menu bar once.
        if let runtime = HubWindowController.shared.runtime {
            OnboardingWindowController.shared.showIfNeeded(runtime: runtime)
        }
        // `replace` hides the Apple Dock again; a crash's leftover backup is
        // put back otherwise.
        DockStore.shared.reconcileAppleDockAtLaunch()
        // Record that this build genuinely came up — after the status item
        // exists, so the receipt attests to the thing a user would look for
        // rather than to a process having been created. An updater waits for
        // it before quitting the build it replaced; see `LaunchReceipt`.
        LaunchReceiptStore.write(
            version: AppVersionInfo.current.version,
            bundlePath: Bundle.main.bundleURL.path
        )
        // After the receipt: starting or adopting the helper can wait on
        // another process for seconds, and an updater that is watching for
        // the receipt would count a slow start as a failed one.
        // The engine has no views of its own; it asks the app for the drag-in
        // helper when macOS has not trusted BarShelf yet.
        AutomationController.shared.presentAccessibilityHelper = { onTrusted in
            AccessibilityHelper.shared.show(onGranted: onTrusted)
        }
        // In the packaged app the extension runs in a helper process (this
        // same executable), so it survives the app crashing or stalling.
        if Bundle.main.bundleURL.pathExtension == "app", let executable = Bundle.main.executableURL {
            let helper = AutomationHelperClient(executable: executable)
            helper.onQuitRequested = { NSApp.terminate(nil) }
            helper.onReopenRequested = { HubWindowController.shared.reopen() }
            AutomationController.shared.useHelper(helper)
        }
        AutomationController.shared.startAtLaunch()
        // An update replaces the bundle but not a widget extension already
        // running from it; that one would keep drawing desktop widgets with
        // old code until the Mac restarts.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
            StaleWidgetExtension.restartIfStale()
        }
        // Silent update check shortly after launch — only surfaces UI when a
        // newer release exists (menu item does an explicit check).
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            UpdateChecker.check(explicit: false)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        AutomationController.shared.stopForTermination()
        HubWindowController.shared.runtime?.usageStore.flush()
        // Never leave the Mac without a dock while BarShelf is not running.
        DockStore.shared.restoreAppleDockForTermination()
    }

    /// Opening an already-running menu bar app from Finder should reveal it.
    /// Accessory apps have no default document window for AppKit to reopen.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        HubWindowController.shared.reopen()
        return false
    }

    /// Minimal main menu carrying only the standard Edit commands. Not shown
    /// (accessory app has no visible menu bar) but its key equivalents are
    /// dispatched to the first responder while the app is active — the standard
    /// way menu-bar apps enable cut/copy/paste/select-all in their popovers.
    /// The Edit menu's title; `installCommands` finds the menu by it.
    static var editMenuTitle: String {
        String(localized: "Edit", comment: "The main menu's Edit menu (Undo, Cut, Copy, Paste).")
    }

    private static func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: editMenuTitle)
        editItem.submenu = edit
        edit.addItem(withTitle: String(localized: "Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: String(localized: "Redo"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: String(localized: "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: String(localized: "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: String(localized: "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: String(localized: "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
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

/// The app's entry point. The `barshelf-app` executable is one line that
/// calls `BarShelfApp.main()`; everything else lives in this library so
/// development tools (see `Sources/BarShelfMedia`) can drive the real views
/// without shipping inside the app.
public enum BarShelfApp {
    /// AppKit holds its delegate weakly.
    @MainActor private static let delegate = AppDelegate()

    @MainActor
    public static func main() -> Never {
        let commandLineArguments = CommandLine.arguments
        // `barshelf-app automation-helper`: the keyboard extension's own
        // process, started by the app (see AutomationHelperProcess).
        if commandLineArguments.count >= 2, commandLineArguments[1] == AutomationHelperProcess.argument {
            AutomationHelperProcess.run(arguments: Array(commandLineArguments.dropFirst(2)))
        }

        // App-binary headless mode: `barshelf-app install <url>` installs and exits
        // before NSApplication starts. Public automation should use the standalone
        // `barshelf install` CLI, which shares the same installer pipeline.
        if commandLineArguments.count >= 2, commandLineArguments[1] == "install" {
            exit(WidgetInstallCLI.run(arguments: Array(commandLineArguments.dropFirst(2))))
        }

        // `barshelf-app screenshot <dir>` renders the real widget UI to PNGs offscreen
        // (README / registry previews) and exits — no window, no TCC permissions.
        if commandLineArguments.count >= 2, commandLineArguments[1] == "screenshot" {
            let outDir = commandLineArguments.count >= 3 ? commandLineArguments[2] : "./screenshots"
            exit(MainActor.assumeIsolated { ScreenshotMode.run(outputDir: outDir) })
        }

        // `barshelf-app screenshot-hub <dir>` renders the BarShelf window, onboarding,
        // and the popup in the app's language (see HubScreenshotMode).
        if commandLineArguments.count >= 2, commandLineArguments[1] == "screenshot-hub" {
            let rest = Array(commandLineArguments.dropFirst(2))
            let outDir = rest.first.flatMap { $0.hasPrefix("-") ? nil : $0 } ?? "./hub-shots"
            let only = rest.firstIndex(of: "--only").flatMap { rest.indices.contains($0 + 1) ? rest[$0 + 1] : nil }
            exit(MainActor.assumeIsolated {
                HubScreenshotMode.run(outputDir: outDir, dark: rest.contains("--dark"), only: only, live: rest.contains("--live"))
            })
        }

        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
        exit(0)
    }
}
