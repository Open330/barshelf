import AppKit
import MenubucketCore

/// Lightweight, dependency-free update check and install against GitHub Releases.
///
/// No Sparkle: the project ships zero runtime dependencies. The check compares
/// the running `CFBundleShortVersionString` with the latest release tag; when a
/// newer one exists BarShelf can download and install it in place, but only
/// after the downloaded bundle proves it was signed by the same developer as
/// the running build (`MenubucketCore.UpdateInstaller`). Anything that cannot be
/// verified — an ad-hoc local build, a Homebrew-managed copy, a read-only
/// location — falls back to opening the release page, which is all this did
/// before.
@MainActor
enum UpdateChecker {
    static var defaultRepository: String { ReleaseFeed.defaultRepository }
    static var repositoryEnvironmentKey: String { ReleaseFeed.repositoryEnvironmentKey }
    static var repositoryDefaultsKey: String { ReleaseFeed.repositoryDefaultsKey }
    static var homebrewUpgradeCommand: String { UpdateInstaller.homebrewUpgradeCommand }

    static var repository: String { ReleaseFeed.repository }
    static var isUsingOverriddenFeed: Bool { ReleaseFeed.isOverridden }
    static func isValidRepository(_ value: String) -> Bool {
        ReleaseFeed.isValidRepository(value)
    }
    static var latestReleaseAPI: URL { ReleaseFeed.apiURL() }
    static var releasesPage: URL { ReleaseFeed.pageURL() }
    static func appAssetName(version: String) -> String {
        ReleaseFeed.appAssetName(version: version)
    }
    static func compare(_ lhs: String, isNewerThan rhs: String) -> Bool {
        ReleaseFeed.isNewer(lhs, than: rhs)
    }

    /// `explicit` (menu item) surfaces "you're up to date" and errors;
    /// the silent launch check stays quiet unless an update is available.
    static func check(explicit: Bool) {
        Task {
            do {
                let release = try await ReleaseFeed.latest()
                let latest = release.version
                if ReleaseFeed.isNewer(latest, than: currentVersion) {
                    present(
                        latest: latest,
                        name: release.name,
                        url: release.pageURL,
                        asset: release.asset(
                            named: ReleaseFeed.appAssetName(version: latest)
                        )?.url,
                        explicit: explicit
                    )
                } else if explicit {
                    upToDate(current: currentVersion)
                }
            } catch {
                if explicit { presentError(error) }
            }
        }
    }

    static var currentVersion: String {
        AppVersionInfo.current.version ?? "0.0.0"
    }

    // MARK: - Eligibility

    static var appURL: URL { Bundle.main.bundleURL }

    /// Why this copy cannot replace itself, or nil when it can.
    static func installBlocker() -> UpdateInstaller.Blocker? {
        UpdateInstaller.blocker(appURL: appURL, hostTeam: CodeSignature.hostDeveloperIDTeam())
    }

    /// Guards against a second install starting while one is running: two
    /// `replaceItemAt` calls on the same bundle would race, and the loser would
    /// report "your installed copy was left untouched" about a copy the winner
    /// had just replaced.
    private static var installInFlight = false

    // MARK: - Presentation

    private static func present(
        latest: String, name: String?, url: URL, asset: URL?, explicit: Bool
    ) {
        let blocker = installBlocker()
        let alert = NSAlert()
        alert.messageText = "BarShelf \(latest) is available"

        var lines = ["You're on \(currentVersion)."]
        if isUsingOverriddenFeed {
            lines.append("Update source overridden: \(repository)")
        }
        if let name { lines.append(name) }
        switch blocker {
        case .homebrewManaged:
            lines.append("Update it the way you installed it:\n\(homebrewUpgradeCommand)")
        case .some(let reason):
            lines.append(reason.message)
            lines.append("Open the release page to download the build and verify its checksum.")
        case nil where asset == nil:
            lines.append("This release publishes no \(appAssetName(version: latest)).")
            lines.append("Open the release page to download it manually.")
        case nil:
            lines.append(
                "BarShelf can install it and relaunch. The download is verified"
                    + " against this build's Developer ID before anything is replaced."
            )
        }
        alert.informativeText = lines.joined(separator: "\n\n")

        if blocker == nil, let asset {
            alert.addButton(withTitle: "Install and Relaunch")
            alert.addButton(withTitle: "Download…")
            alert.addButton(withTitle: "Later")
            // The launch-time check is unsolicited: it appears seconds after
            // startup, over whatever the user was doing. Replacing and
            // relaunching the app must not be one stray Return away, so the
            // default moves to Later unless the user asked for this check.
            if !explicit {
                alert.buttons[0].keyEquivalent = ""
                alert.buttons[2].keyEquivalent = "\r"
            }
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                install(asset: asset, version: latest, page: url)
            case .alertSecondButtonReturn: NSWorkspace.shared.open(url)
            default: break
            }
            return
        }

        if blocker == .homebrewManaged {
            alert.addButton(withTitle: "Copy brew Command")
            alert.addButton(withTitle: "Release Notes")
            alert.addButton(withTitle: "Later")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(homebrewUpgradeCommand, forType: .string)
            case .alertSecondButtonReturn: NSWorkspace.shared.open(url)
            default: break
            }
            return
        }

        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Install

    private static func install(asset: URL, version: String, page: URL) {
        guard !installInFlight else { return }
        guard let team = CodeSignature.hostDeveloperIDTeam() else {
            presentInstallFailure(UpdateInstaller.Failure.hostNotSigned, page: page)
            return
        }
        installInFlight = true

        // The same panel widget installs use: a determinate bar driven by
        // Content-Length, and a Cancel that actually stops the work.
        let progress = DownloadProgressPanel(
            title: "Updating BarShelf", message: "Downloading BarShelf \(version)…"
        )
        let target = appURL
        let bundleID = Bundle.main.bundleIdentifier

        let work = Task {
            do {
                let archive = try await ReleaseFeed.download(asset) { received, expected in
                    progress.update(received: received, expected: expected)
                }
                defer { try? FileManager.default.removeItem(at: archive) }
                try Task.checkCancellation()
                progress.setMessage("Verifying and installing…")
                let installed = try await Task.detached(priority: .userInitiated) {
                    try UpdateInstaller.install(
                        archive: archive,
                        replacing: target,
                        expectedTeam: team,
                        expectedBundleID: bundleID
                    )
                }.value
                installInFlight = false
                // A build that reports a different version would have the check
                // offering the same "update" again on every launch.
                if let reported = installed.version, reported != version {
                    progress.close()
                    presentVersionSurprise(expected: version, installed: reported, app: target)
                    relaunch(installed, page: page, progress: nil)
                } else {
                    // The panel stays up through the restart: the wait below is
                    // seconds long and briefly shows two menu bar icons, which
                    // needs explaining while it happens.
                    progress.setMessage("Restarting BarShelf…")
                    relaunch(installed, page: page, progress: progress)
                }
            } catch is CancellationError {
                installInFlight = false
                progress.close()
            } catch {
                installInFlight = false
                progress.close()
                presentInstallFailure(error, page: page)
            }
        }
        progress.onCancel = { work.cancel() }
        progress.show()
    }

    private static func presentVersionSurprise(
        expected: String, installed: String, app: URL
    ) {
        let alert = NSAlert()
        alert.messageText = "The update reports a different version"
        alert.informativeText = "BarShelf \(expected) was announced, but the"
            + " installed build reports \(installed). It is signed correctly and"
            + " has been installed; the release asset may be mismatched."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Starts the replacement, waits for it to prove it is running, and only
    /// then quits.
    ///
    /// The order matters. Quitting as soon as `openApplication` reports success
    /// is how an update once left a machine with no BarShelf for a day: the new
    /// process existed and held a pid, but the kernel never let it run, and by
    /// then the build that could have said so was gone. Waiting for the
    /// replacement's launch receipt costs a few seconds and two menu bar icons
    /// in the meantime; the alternative costs the app.
    private static func relaunch(
        _ installed: UpdateInstaller.Installed,
        page: URL,
        progress: DownloadProgressPanel?
    ) {
        let app = installed.app
        let previous = LaunchReceiptStore.read()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: app, configuration: configuration) { _, error in
            if let error {
                DispatchQueue.main.async {
                    progress?.close()
                    presentRelaunchFailure(
                        installed, page: page, detail: error.localizedDescription
                    )
                }
                return
            }
            // Off the main thread: the wait polls, and the run loop has to keep
            // turning for the panel to draw and for Cancel to work.
            DispatchQueue.global(qos: .userInitiated).async {
                let receipt = LaunchReceiptStore.waitForRelaunch(replacing: previous)
                DispatchQueue.main.async {
                    progress?.close()
                    guard receipt != nil else {
                        presentRelaunchFailure(installed, page: page, detail: nil)
                        return
                    }
                    installed.confirm()
                    NSApp.terminate(nil)
                }
            }
        }
    }

    /// The replacement is in place but is not running, and this build still
    /// is. Put the working one back on disk, say exactly what happened, and
    /// stay alive — quitting now would leave nothing.
    private static func presentRelaunchFailure(
        _ installed: UpdateInstaller.Installed, page: URL, detail: String?
    ) {
        let rolledBack = installed.rollBack()
        let alert = NSAlert()
        alert.messageText = "BarShelf was updated but did not start"
        var text = detail.map { $0 + "\n\n" } ?? ""
        text += "The new build was installed at \(installed.app.path) but did not"
            + " come up within \(Int(LaunchReceiptStore.defaultTimeout)) seconds."
        text += rolledBack
            ? "\n\nThe version you were running has been put back, and this copy"
                + " is still it — nothing was lost. Updating again will try the"
                + " same thing, so it is worth reporting."
            : "\n\nThe previous version could not be restored. This copy keeps"
                + " running for now, but do not quit it before reinstalling"
                + " BarShelf from the release page."
        alert.informativeText = text
        alert.addButton(withTitle: "Open Releases")
        alert.addButton(withTitle: "Show in Finder")
        alert.addButton(withTitle: "Later")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            NSWorkspace.shared.open(page)
        case .alertSecondButtonReturn:
            NSWorkspace.shared.activateFileViewerSelecting([installed.app])
        default: break
        }
    }

    private static func presentInstallFailure(_ error: Error, page: URL) {
        let alert = NSAlert()
        alert.messageText = "The update was not installed"
        var text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        if let suggestion = (error as? LocalizedError)?.recoverySuggestion {
            text += "\n\n" + suggestion
        }
        // Nothing was replaced — say so, so a failure does not read as a
        // half-finished install.
        text += "\n\nYour installed copy was left untouched."
        alert.informativeText = text
        alert.addButton(withTitle: "Open Releases")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(page)
        }
    }

    // MARK: - Simple outcomes

    private static func upToDate(current: String) {
        let alert = NSAlert()
        alert.messageText = "You're up to date"
        alert.informativeText = "BarShelf \(current) is the latest version."
            + (isUsingOverriddenFeed ? "\n\nUpdate source overridden: \(repository)" : "")
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private static func presentError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Couldn't check for updates"
        alert.informativeText = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Open Releases")
        if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.open(releasesPage)
        }
    }
}
