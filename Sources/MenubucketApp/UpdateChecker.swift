import AppKit

/// Lightweight, dependency-free update check against GitHub Releases.
///
/// No Sparkle: the project ships zero runtime dependencies. This compares the
/// running `CFBundleShortVersionString` with the latest release tag and, when a
/// newer one exists, offers to open the release page. Auto-download/replace is
/// intentionally out of scope so users can inspect release notes and verify
/// the published checksum before replacing the app.
@MainActor
enum UpdateChecker {
    static let latestReleaseAPI = URL(
        string: "https://api.github.com/repos/Open330/barshelf/releases/latest"
    )!
    static let releasesPage = URL(string: "https://github.com/Open330/barshelf/releases/latest")!

    private struct Release: Decodable {
        let tag_name: String
        let html_url: String
        let name: String?
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
                    present(latest: latest, name: release.name, url: URL(string: release.html_url) ?? releasesPage)
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

    private static func present(latest: String, name: String?, url: URL) {
        let alert = NSAlert()
        alert.messageText = "BarShelf \(latest) is available"
        alert.informativeText = "You're on \(currentVersion). "
            + (name.map { "\($0)\n\n" } ?? "")
            + "Open the release page to download the build and verify its checksum."
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(url)
        }
    }

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

    private enum UpdateError: LocalizedError {
        case badResponse
        var errorDescription: String? {
            switch self {
            case .badResponse: return "GitHub returned an unexpected response."
            }
        }
    }
}
