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
    static let latestReleaseAPI = URL(
        string: "https://api.github.com/repos/Open330/barshelf/releases/latest"
    )!
    static let releasesPage = URL(string: "https://github.com/Open330/barshelf/releases/latest")!
    static let homebrewUpgradeCommand = "brew upgrade --cask barshelf"

    private struct Release: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: String
        }

        let tag_name: String
        let html_url: String
        let name: String?
        let assets: [Asset]?
    }

    /// `explicit` (menu item) surfaces "you're up to date" and errors;
    /// the silent launch check stays quiet unless an update is available.
    static func check(explicit: Bool) {
        Task {
            do {
                var request = URLRequest(url: latestReleaseAPI)
                request.timeoutInterval = 15
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    throw UpdateError.badResponse
                }
                let release = try JSONDecoder().decode(Release.self, from: data)
                let latest = release.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
                let current = currentVersion

                if compare(latest, isNewerThan: current) {
                    present(
                        latest: latest,
                        name: release.name,
                        url: URL(string: release.html_url) ?? releasesPage,
                        asset: appAsset(in: release, version: latest)
                    )
                } else if explicit {
                    upToDate(current: current)
                }
            } catch {
                if explicit { presentError(error) }
            }
        }
    }

    static var currentVersion: String {
        AppVersionInfo.current.version ?? "0.0.0"
    }

    /// Semantic-ish numeric compare (`1.2.10` > `1.2.9`); missing components are 0.
    static func compare(_ lhs: String, isNewerThan rhs: String) -> Bool {
        let a = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let b = rhs.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// The app archive for this release, by the name `scripts/release.sh`
    /// publishes. Matched exactly so a future asset cannot be mistaken for it.
    static func appAssetName(version: String) -> String {
        "BarShelf-\(version)-arm64.zip"
    }

    private static func appAsset(in release: Release, version: String) -> URL? {
        let wanted = appAssetName(version: version)
        guard let asset = release.assets?.first(where: { $0.name == wanted }) else { return nil }
        return URL(string: asset.browser_download_url)
    }

    // MARK: - Eligibility

    static var appURL: URL { Bundle.main.bundleURL }

    /// Why this copy cannot replace itself, or nil when it can.
    static func installBlocker() -> UpdateInstaller.Blocker? {
        UpdateInstaller.blocker(
            appURL: appURL, hostTeam: CodeSignature.hostTeamIdentifier()
        )
    }

    // MARK: - Presentation

    private static func present(latest: String, name: String?, url: URL, asset: URL?) {
        let blocker = installBlocker()
        let alert = NSAlert()
        alert.messageText = "BarShelf \(latest) is available"

        var lines = ["You're on \(currentVersion)."]
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
            switch alert.runModal() {
            case .alertFirstButtonReturn: install(asset: asset, version: latest, page: url)
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
        guard let team = CodeSignature.hostTeamIdentifier() else {
            presentInstallFailure(UpdateInstaller.Failure.hostNotSigned, page: page)
            return
        }
        let progress = UpdateProgressPanel(message: "Downloading BarShelf \(version)…")
        progress.show()
        let target = appURL

        Task {
            do {
                let archive = try await download(asset)
                defer { try? FileManager.default.removeItem(at: archive) }
                progress.update("Verifying and installing…")
                try await Task.detached(priority: .userInitiated) {
                    try UpdateInstaller.install(
                        archive: archive, replacing: target, expectedTeam: team
                    )
                }.value
                progress.close()
                relaunch(target, page: page)
            } catch {
                progress.close()
                presentInstallFailure(error, page: page)
            }
        }
    }

    /// Downloads to a temporary file. `URLSession.download` follows GitHub's
    /// redirect to the asset host for us.
    private static func download(_ asset: URL) async throws -> URL {
        var request = URLRequest(url: asset)
        request.timeoutInterval = 120
        let (temporary, response) = try await URLSession.shared.download(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            try? FileManager.default.removeItem(at: temporary)
            throw UpdateError.badResponse
        }
        // The temporary file is deleted when this call returns, so move it
        // somewhere we control before handing it to the installer.
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("barshelf-update-\(UUID().uuidString).zip")
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }

    private static func relaunch(_ app: URL, page: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: app, configuration: configuration) { _, error in
            DispatchQueue.main.async {
                if let error {
                    let alert = NSAlert()
                    alert.messageText = "BarShelf was updated but could not relaunch"
                    alert.informativeText = error.localizedDescription
                        + "\n\nOpen it from \(app.deletingLastPathComponent().path)."
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                    return
                }
                NSApp.terminate(nil)
            }
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

    enum UpdateError: LocalizedError {
        case badResponse
        var errorDescription: String? {
            switch self {
            case .badResponse: return "GitHub returned an unexpected response."
            }
        }
    }
}

/// A small always-on-top panel shown while an update downloads and installs.
///
/// A menu-bar app has no window to host progress, and `ToastCenter` only draws
/// inside the popup — without this the app would sit silent for several seconds
/// after the user asked it to update.
@MainActor
final class UpdateProgressPanel {
    private let panel: NSPanel
    private let label: NSTextField

    init(message: String) {
        label = NSTextField(labelWithString: message)
        label.alignment = .center
        label.font = .systemFont(ofSize: 12)

        let spinner = NSProgressIndicator()
        spinner.style = .bar
        spinner.isIndeterminate = true
        spinner.startAnimation(nil)

        let stack = NSStackView(views: [label, spinner])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        spinner.widthAnchor.constraint(equalToConstant: 240).isActive = true

        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 90),
            styleMask: [.titled, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Updating BarShelf"
        panel.contentView = stack
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
    }

    func show() {
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func update(_ message: String) {
        label.stringValue = message
    }

    func close() {
        panel.orderOut(nil)
    }
}
