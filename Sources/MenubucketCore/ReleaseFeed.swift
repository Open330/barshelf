import Foundation

/// Reading BarShelf's own GitHub releases: which version is current, which
/// asset carries it, and fetching that asset safely.
///
/// Shared so the app's "Check for Updates…" and `barshelf upgrade` cannot
/// drift apart. A second copy of "which host may we follow a redirect to" is
/// exactly the kind of duplication that ends with one of them missing a guard.
public enum ReleaseFeed {
    public static let defaultRepository = "Open330/barshelf"

    /// Environment override, for a build launched from a terminal.
    public static let repositoryEnvironmentKey = "BARSHELF_UPDATE_REPO"
    /// Preference override, for an installed app:
    /// `defaults write com.barshelf.app BarShelfUpdateRepository owner/repo`
    ///
    /// Deliberately not read across processes: `barshelf upgrade` uses the
    /// environment variable instead. A CLI reading the app's preference domain
    /// would make "which feed am I on?" depend on machine state that no test
    /// can set without writing to the real user's preferences.
    public static let repositoryDefaultsKey = "BarShelfUpdateRepository"

    /// The repository to read releases from.
    ///
    /// Overridable so a release can be rehearsed before it is the public
    /// `latest` — otherwise the only way to test that an update installs is to
    /// publish it to everyone, and a self-updater whose accept path has never
    /// been run is not one to rely on. A pre-release cannot serve: this reads
    /// `/releases/latest`, which excludes them.
    ///
    /// Deliberately an `owner/repo` pair and never a URL: the feed
    /// then always resolves to api.github.com and cannot point a download at
    /// another host. It is not a way to install foreign code either — what it
    /// finds still has to be signed by the expected Developer ID team.
    public static var repository: String {
        let candidates = [
            ProcessInfo.processInfo.environment[repositoryEnvironmentKey],
            UserDefaults.standard.string(forKey: repositoryDefaultsKey),
        ]
        for candidate in candidates where candidate.map(isValidRepository) == true {
            return candidate!
        }
        return defaultRepository
    }

    public static var isOverridden: Bool { repository != defaultRepository }

    /// `owner/repo`, nothing else — no scheme, no path traversal, no host.
    public static func isValidRepository(_ value: String) -> Bool {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        return parts.allSatisfy { part in
            !part.isEmpty && part.rangeOfCharacter(from: allowed.inverted) == nil
                && part != "." && part != ".."
        }
    }

    public static func apiURL(repository: String = repository) -> URL {
        URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    }

    public static func pageURL(repository: String = repository) -> URL {
        URL(string: "https://github.com/\(repository)/releases/latest")!
    }

    /// Asset names `scripts/release.sh` publishes. Matched exactly, so a future
    /// asset cannot be mistaken for the app or the CLI.
    public static func appAssetName(version: String) -> String {
        "BarShelf-\(version)-arm64.zip"
    }

    public static func cliAssetName(version: String) -> String {
        "barshelf-cli-\(version)-arm64.tar.gz"
    }

    /// Semantic-ish numeric compare (`1.2.10` > `1.2.9`); missing components
    /// are zero, so `1.1` beats `1.0.9` and ties with `1.1.0`.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: - Release

    public struct Release: Sendable, Equatable {
        public struct Asset: Sendable, Equatable {
            public var name: String
            public var url: URL
        }

        public var tag: String
        public var name: String?
        public var pageURL: URL
        public var assets: [Asset]

        /// Tag without its `v`, which is how the bundle reports its version.
        public var version: String {
            tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        }

        public func asset(named name: String) -> Asset? {
            assets.first { $0.name == name }
        }
    }

    public enum FeedError: Error, LocalizedError, Equatable {
        case badResponse
        case insecureURL(String)
        case tooLarge(limitBytes: Int)

        public var errorDescription: String? {
            switch self {
            case .badResponse:
                return "GitHub returned an unexpected response."
            case let .insecureURL(host):
                return "The release asset is not served over HTTPS (\(host))."
            case let .tooLarge(limit):
                return "The release asset is larger than \(limit / 1_048_576) MB."
            }
        }
    }

    private struct APIRelease: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: String
        }

        let tag_name: String
        let html_url: String
        let name: String?
        let assets: [Asset]?
    }

    public static func latest(
        repository: String = repository,
        session: URLSession = .shared
    ) async throws -> Release {
        var request = URLRequest(url: apiURL(repository: repository))
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw FeedError.badResponse
        }
        let decoded = try JSONDecoder().decode(APIRelease.self, from: data)
        return Release(
            tag: decoded.tag_name,
            name: decoded.name,
            pageURL: URL(string: decoded.html_url) ?? pageURL(repository: repository),
            assets: (decoded.assets ?? []).compactMap { asset in
                URL(string: asset.browser_download_url).map {
                    Release.Asset(name: asset.name, url: $0)
                }
            }
        )
    }

    // MARK: - Download

    /// Fetches an asset to a temporary file with the guards every download in
    /// this project uses: HTTPS only, redirects confined to GitHub's own hosts,
    /// and a hard size ceiling. Cancellable, and reports progress per chunk.
    public static func download(
        _ asset: URL,
        session: URLSession = .shared,
        progress: @escaping @Sendable (Int64, Int64) -> Void = { _, _ in }
    ) async throws -> URL {
        guard asset.scheme?.lowercased() == "https" else {
            throw FeedError.insecureURL(asset.host ?? "unknown host")
        }
        var request = URLRequest(url: asset)
        request.timeoutInterval = 60
        let guardDelegate = HeadlessInstaller.InstallRedirectGuard(origin: asset)
        let (bytes, response) = try await session.bytes(for: request, delegate: guardDelegate)
        guard let http = response as? HTTPURLResponse else { throw FeedError.badResponse }
        // A redirect could otherwise land on a non-HTTPS host.
        guard response.url?.scheme?.lowercased() == "https" else {
            throw FeedError.insecureURL(response.url?.host ?? "unknown host")
        }
        guard http.statusCode == 200 else { throw FeedError.badResponse }

        let expected = response.expectedContentLength
        let limit = HeadlessInstaller.maxDownloadBytes
        if expected > Int64(limit) { throw FeedError.tooLarge(limitBytes: limit) }

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("barshelf-update-\(UUID().uuidString)-\(asset.lastPathComponent)")
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: destination) else {
            throw FeedError.badResponse
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
                if received > Int64(limit) { throw FeedError.tooLarge(limitBytes: limit) }
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
}
