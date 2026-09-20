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
                        asset: appAsset(in: release, version: latest),
                        explicit: explicit
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
                let archive = try await download(asset) { received, expected in
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
                progress.close()
                // A build that reports a different version would have the check
                // offering the same "update" again on every launch.
                if let installed, installed != version {
                    presentVersionSurprise(expected: version, installed: installed, app: target)
                }
                relaunch(target, page: page)
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

    /// Downloads to a temporary file, with the guards every other download in
    /// this app uses: HTTPS only, redirects confined to GitHub's own hosts, and
    /// a hard size ceiling. Cancellable, and reports progress per chunk.
    private static func download(
        _ asset: URL,
        progress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> URL {
        guard asset.scheme?.lowercased() == "https" else {
            throw UpdateError.insecureURL(asset)
        }
        var request = URLRequest(url: asset)
        request.timeoutInterval = 60
        let redirectGuard = HeadlessInstaller.InstallRedirectGuard(origin: asset)
        let (bytes, response) = try await URLSession.shared.bytes(
            for: request, delegate: redirectGuard
        )
        guard let http = response as? HTTPURLResponse else { throw UpdateError.badResponse }
        // A redirect could otherwise land on a non-HTTPS host.
        guard response.url?.scheme?.lowercased() == "https" else {
            throw UpdateError.insecureURL(response.url ?? asset)
        }
        guard http.statusCode == 200 else { throw UpdateError.badResponse }

        let expected = response.expectedContentLength
        let limit = HeadlessInstaller.maxDownloadBytes
        if expected > Int64(limit) { throw UpdateError.tooLarge(limitBytes: limit) }

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("barshelf-update-\(UUID().uuidString).zip")
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: destination) else {
            throw UpdateError.badResponse
        }
        defer { try? handle.close() }

        var buffer = Data()
        buffer.reserveCapacity(1 << 20)
        var received: Int64 = 0
        var lastReported: Int64 = 0
        progress(0, expected)
        do {
            for try await byte in bytes {
                try Task.checkCancellation()
                buffer.append(byte)
                received += 1
                if received > Int64(limit) { throw UpdateError.tooLarge(limitBytes: limit) }
                if buffer.count >= 1 << 20 {
                    try handle.write(contentsOf: buffer)
                    buffer.removeAll(keepingCapacity: true)
                }
                if received - lastReported >= 256 * 1024 {
                    lastReported = received
                    progress(received, expected)
                }
            }
            try handle.write(contentsOf: buffer)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        progress(received, expected)
        return destination
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
        case insecureURL(URL)
        case tooLarge(limitBytes: Int)

        var errorDescription: String? {
            switch self {
            case .badResponse:
                return "GitHub returned an unexpected response."
            case let .insecureURL(url):
                return "The release asset is not served over HTTPS (\(url.host ?? "unknown host"))."
            case let .tooLarge(limit):
                return "The release asset is larger than \(limit / 1_048_576) MB."
            }
        }
    }
}
