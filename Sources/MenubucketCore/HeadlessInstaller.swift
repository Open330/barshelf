import Foundation

// MARK: - R06 공통 계약 1 — HeadlessInstaller (설치 파이프라인)

/// One installable widget found inside a fetched archive.
///
/// `sourceDirectory` points into the temporary staging area produced by
/// `HeadlessInstaller.fetchCandidates`/`fetchSession`; it stays valid until
/// the staging root is cleaned up (or the OS purges the temp directory).
public struct InstallCandidate: Equatable, Sendable {
    public let manifest: Manifest
    /// Directory containing `widget.json` (inside the extraction staging).
    public let sourceDirectory: URL
    /// Human-readable permission summary (exec / keychain / notifications).
    public let permissionSummary: [String]
    /// Optional `version` string from widget.json (display only).
    public let displayVersion: String?
    /// Path relative to the discovery root (for messages).
    public let relativePath: String

    public init(
        manifest: Manifest,
        sourceDirectory: URL,
        permissionSummary: [String],
        displayVersion: String? = nil,
        relativePath: String = "."
    ) {
        self.manifest = manifest
        self.sourceDirectory = sourceDirectory
        self.permissionSummary = permissionSummary
        self.displayVersion = displayVersion
        self.relativePath = relativePath
    }

    public init(_ discovered: WidgetDiscovery.Candidate) {
        self.init(
            manifest: discovered.manifest,
            sourceDirectory: discovered.directory,
            permissionSummary: WidgetDiscovery.permissionSummary(
                for: discovered.manifest
            ),
            displayVersion: discovered.displayVersion,
            relativePath: discovered.relativePath
        )
    }

    /// "Name (id) v1.2.3" — shared display line for dialogs and CLI output.
    public var displayLine: String {
        var line = "\(manifest.name) (\(manifest.id))"
        if let displayVersion {
            line += " v\(displayVersion)"
        }
        return line
    }
}

/// Headless download → extract → discover → install pipeline (URL-install
/// v1). No UI, no AppKit — shared by the app's `WidgetInstaller` (GUI + CLI
/// mode) and the standalone `barshelf` CLI.
public enum HeadlessInstaller {
    /// Archive download cap (bytes).
    // Repo archives legitimately reach tens of MB once app assets are in the
    // zip (e.g. file-stack ships hero images/screenshots at ~50 MB), so this
    // guards memory/bandwidth abuse rather than typical repo size.
    public static let maxDownloadBytes = 128 * 1024 * 1024

    public final class InstallRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private let origin: URL
        public init(origin: URL) { self.origin = origin }

        public func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            guard let destination = request.url,
                  HeadlessInstaller.redirectAllowed(from: origin, to: destination)
            else {
                completionHandler(nil)
                return
            }
            completionHandler(request)
        }
    }

    /// Same-origin redirects are accepted. GitHub release/repository URLs may
    /// additionally move to GitHub's controlled download hosts.
    public static func redirectAllowed(from origin: URL, to destination: URL) -> Bool {
        guard origin.scheme?.lowercased() == "https",
              destination.scheme?.lowercased() == "https",
              let originHost = origin.host?.lowercased(),
              let destinationHost = destination.host?.lowercased()
        else { return false }
        if originHost == destinationHost {
            return (origin.port ?? 443) == (destination.port ?? 443)
        }
        let githubOrigins: Set<String> = [
            "github.com", "www.github.com", "api.github.com", "codeload.github.com"
        ]
        let githubDestinations: Set<String> = [
            "codeload.github.com", "objects.githubusercontent.com",
            "release-assets.githubusercontent.com", "raw.githubusercontent.com"
        ]
        return githubOrigins.contains(originHost) && githubDestinations.contains(destinationHost)
    }

    /// `~/Library/Application Support/barshelf/widgets` — where the app
    /// loads user-installed widgets from.
    public static var defaultWidgetsDirectory: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("barshelf", isDirectory: true)
            .appendingPathComponent("widgets", isDirectory: true)
    }

    // MARK: Session (rich result: source + staging + failures)

    /// Full fetch result. Callers that need failure details / explicit
    /// staging cleanup use this instead of the plain candidate list.
    public struct Session {
        public let source: WidgetInstallSource
        /// Temporary extraction root — call `cleanup()` when done.
        public let stagingRoot: URL
        public let discovery: WidgetDiscovery.Result

        public var candidates: [InstallCandidate] {
            discovery.candidates.map(InstallCandidate.init)
        }

        public var failures: [WidgetDiscovery.Failure] {
            discovery.failures
        }

        public func cleanup() {
            try? FileManager.default.removeItem(at: stagingRoot)
        }
    }

    /// Fetches, extracts and discovers every installable widget behind
    /// `input` (R05 URL contract: GitHub repo / .zip / .mbw / deep link;
    /// plus local archive paths for CLI use).
    public static func fetchSession(input: String) async throws -> Session {
        if let directory = localDirectorySource(for: input) {
            return try fetchSession(directory: directory)
        }
        if let local = localArchiveSource(for: input) {
            return try await fetchSession(source: local)
        }
        return try await fetchSession(source: WidgetInstallSource.parse(input))
    }

    /// Installs from a local widget directory (e.g. `barshelf install ./my-widget`).
    /// The directory is copied into a temp staging root — never discovered in
    /// place — so `Session.cleanup()` and permission-preserving copy behave
    /// exactly like the archive path and never touch the user's source.
    public static func fetchSession(directory: URL) throws -> Session {
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("barshelf-install-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            let copy = staging.appendingPathComponent(directory.lastPathComponent, isDirectory: true)
            try FileManager.default.copyItem(at: directory, to: copy)
            let discovery = try WidgetDiscovery.discover(under: staging, subdirectory: nil)
            let source = WidgetInstallSource(
                kind: .archive,
                downloadCandidates: [directory.standardizedFileURL],
                subdirectory: nil,
                displayName: directory.standardizedFileURL.path
            )
            return Session(source: source, stagingRoot: staging, discovery: discovery)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    /// Resolves `input` to an existing local *directory* (bare path or
    /// `file://`), or nil. Archive files fall through to `localArchiveSource`.
    static func localDirectorySource(for input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let url: URL
        if trimmed.lowercased().hasPrefix("file://") {
            guard let parsed = URL(string: trimmed), parsed.isFileURL else { return nil }
            url = parsed
        } else if !trimmed.contains("://") {
            url = URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath)
        } else {
            return nil
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return url.standardizedFileURL
    }

    /// Tries each source candidate end-to-end (download → extract →
    /// discover). HTTP 404 and a missing discovery subdirectory both fall
    /// through to the next candidate — this is what resolves the GitHub
    /// branch-name/subpath ambiguity (`/tree/feat/x` may be branch `feat`
    /// with path `x`, or branch `feat/x`).
    public static func fetchSession(
        source: WidgetInstallSource
    ) async throws -> Session {
        var lastError: Error = HeadlessInstallError.noDownloadCandidates
        for candidate in source.candidates {
            // Subdirectory install: fetch just that folder via the GitHub
            // contents API (raw files) so a small widget in a large repo does
            // not pull the whole-repo archive (which can exceed the size cap).
            // Any failure falls through to the full-archive path below.
            if candidate.subdirectory != nil {
                do {
                    if let session = try await fetchSubdirectorySession(source: source, candidate: candidate) {
                        return session
                    }
                } catch {
                    FileHandle.standardError.write(Data("subdir-fetch failed: \(error)\n".utf8))
                }
            }

            let archive: Data
            do {
                archive = try await download(from: candidate.url)
            } catch HeadlessInstallError.httpStatus(404, let failedURL) {
                lastError = HeadlessInstallError.httpStatus(404, failedURL)
                continue
            }

            let staging = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "barshelf-install-\(UUID().uuidString)", isDirectory: true
                )
            do {
                try SafeZipExtractor.extract(zipData: archive, to: staging)
                let discovery = try WidgetDiscovery.discover(
                    under: staging, subdirectory: candidate.subdirectory
                )
                return Session(source: source, stagingRoot: staging, discovery: discovery)
            } catch let error as WidgetDiscovery.DiscoveryError {
                guard case .subdirectoryNotFound = error else {
                    try? FileManager.default.removeItem(at: staging)
                    throw error
                }
                try? FileManager.default.removeItem(at: staging)
                lastError = error
                continue
            } catch {
                try? FileManager.default.removeItem(at: staging)
                throw error
            }
        }
        throw lastError
    }

    // MARK: Subdirectory fetch (GitHub contents API)

    /// Per-fetch caps so a hostile or huge subdirectory can't blow past the
    /// download limits file-by-file.
    static let maxSubdirFiles = 64
    static let maxSubdirDepth = 6

    /// Downloads only `candidate.subdirectory` from a GitHub repo (parsed from
    /// the codeload URL) via the contents API, staging it so
    /// `WidgetDiscovery` finds the widget exactly as it would in an extracted
    /// archive. Returns nil when the candidate is not a GitHub codeload URL.
    private static func fetchSubdirectorySession(
        source: WidgetInstallSource,
        candidate: WidgetInstallSource.Candidate
    ) async throws -> Session? {
        guard let subdir = candidate.subdirectory,
              candidate.url.host == "codeload.github.com" else { return nil }
        // /{owner}/{repo}/zip/refs/heads/{branch…}
        let parts = candidate.url.path.split(separator: "/").map(String.init)
        guard parts.count >= 6, parts[2] == "zip", parts[3] == "refs", parts[4] == "heads"
        else { return nil }
        let owner = parts[0], repo = parts[1]
        let branch = parts[5...].joined(separator: "/")

        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("barshelf-install-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            // Stage the subdirectory's contents flat at the staging root so
            // `WidgetDiscovery` finds widget.json directly — no `{repo}-{branch}`
            // wrapper to unwrap and no subdirectory to descend.
            var fileCount = 0
            try await downloadContents(
                owner: owner, repo: repo, path: subdir, ref: branch,
                into: staging, depth: 0, fileCount: &fileCount
            )
            let discovery = try WidgetDiscovery.discover(under: staging, subdirectory: nil)
            return Session(source: source, stagingRoot: staging, discovery: discovery)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    private struct ContentsEntry: Decodable {
        let name: String
        let type: String
        let downloadURL: URL?
        enum CodingKeys: String, CodingKey {
            case name, type
            case downloadURL = "download_url"
        }
    }

    /// Recursively writes a GitHub directory's files into `dest`. Bounded by
    /// `maxSubdirFiles`/`maxSubdirDepth` and the per-file download cap.
    private static func downloadContents(
        owner: String, repo: String, path: String, ref: String,
        into dest: URL, depth: Int, fileCount: inout Int
    ) async throws {
        guard depth <= maxSubdirDepth else {
            throw HeadlessInstallError.noWidgetsFound(details: ["subdirectory nesting too deep"])
        }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.github.com"
        components.path = "/repos/\(owner)/\(repo)/contents/\(path)"
        components.queryItems = [URLQueryItem(name: "ref", value: ref)]
        guard let apiURL = components.url else { return }

        var request = URLRequest(url: apiURL)
        request.timeoutInterval = 30
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("barshelf", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw HeadlessInstallError.notHTTP(apiURL) }
        guard http.statusCode == 200 else { throw HeadlessInstallError.httpStatus(http.statusCode, apiURL) }
        let entries = try JSONDecoder().decode([ContentsEntry].self, from: data)

        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        for entry in entries {
            if entry.type == "dir" {
                try await downloadContents(
                    owner: owner, repo: repo, path: "\(path)/\(entry.name)", ref: ref,
                    into: dest.appendingPathComponent(entry.name, isDirectory: true),
                    depth: depth + 1, fileCount: &fileCount
                )
            } else if entry.type == "file", let downloadURL = entry.downloadURL {
                fileCount += 1
                guard fileCount <= maxSubdirFiles else {
                    throw HeadlessInstallError.noWidgetsFound(details: ["subdirectory has too many files"])
                }
                let bytes = try await download(from: downloadURL)
                try bytes.write(to: dest.appendingPathComponent(entry.name), options: .atomic)
            }
        }
    }

    // MARK: Contract API

    /// R06 계약 1: fetches every install candidate behind `url`. Manifest
    /// decode failures are skipped (use `fetchSession` for failure details);
    /// an empty archive throws `.noWidgetsFound`. The extraction staging the
    /// candidates point into lives in the temp directory until the OS (or an
    /// explicit `Session.cleanup()`) removes it.
    public static func fetchCandidates(
        from url: URL
    ) async throws -> [InstallCandidate] {
        let session = try await fetchSession(input: url.absoluteString)
        guard !session.discovery.candidates.isEmpty else {
            session.cleanup()
            throw HeadlessInstallError.noWidgetsFound(
                details: session.failures.map { "\($0.relativePath): \($0.reason)" }
            )
        }
        return session.candidates
    }

    /// Stages a complete candidate beside the live install, then swaps it in.
    /// Copy/validation failures therefore leave the previous widget intact.
    @discardableResult
    public static func install(
        _ candidate: InstallCandidate, into widgetsDir: URL
    ) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: widgetsDir, withIntermediateDirectories: true)

        let destination = widgetsDir.appendingPathComponent(
            candidate.manifest.id, isDirectory: true
        )
        let transactionID = UUID().uuidString
        let staging = widgetsDir.appendingPathComponent(
            ".install-\(candidate.manifest.id)-\(transactionID)", isDirectory: true
        )
        let backupName = ".backup-\(candidate.manifest.id)-\(transactionID)"
        let backup = widgetsDir.appendingPathComponent(backupName, isDirectory: true)

        do {
            try fm.copyItem(at: candidate.sourceDirectory, to: staging)
            guard fm.fileExists(
                atPath: staging.appendingPathComponent("widget.json").path
            ) else {
                throw HeadlessInstallError.noWidgetsFound(details: ["staged widget has no widget.json"])
            }

            if fm.fileExists(atPath: destination.path) {
                _ = try fm.replaceItemAt(
                    destination,
                    withItemAt: staging,
                    backupItemName: backupName,
                    options: []
                )
                try? fm.removeItem(at: backup)
            } else {
                try fm.moveItem(at: staging, to: destination)
            }
        } catch {
            try? fm.removeItem(at: staging)
            if !fm.fileExists(atPath: destination.path), fm.fileExists(atPath: backup.path) {
                try? fm.moveItem(at: backup, to: destination)
            }
            throw error
        }
        return destination
    }

    public static func isInstalled(id: String, in widgetsDir: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: widgetsDir.appendingPathComponent(id).path
        )
    }

    // MARK: Download

    /// Tries each download candidate in order; HTTP 404 falls through to the
    /// next one (GitHub main → master fallback).
    public static func download(source: WidgetInstallSource) async throws -> Data {
        var lastError: Error = HeadlessInstallError.noDownloadCandidates
        for url in source.downloadCandidates {
            do {
                return try await download(from: url)
            } catch HeadlessInstallError.httpStatus(404, let failedURL) {
                lastError = HeadlessInstallError.httpStatus(404, failedURL)
                continue
            }
        }
        throw lastError
    }

    public static func download(from url: URL) async throws -> Data {
        if url.isFileURL {
            return try readLocalArchive(at: url)
        }
        guard url.scheme?.lowercased() == "https" else {
            throw HeadlessInstallError.notHTTP(url)
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        let redirectGuard = InstallRedirectGuard(origin: url)
        let (bytes, response) = try await URLSession.shared.bytes(
            for: request, delegate: redirectGuard
        )
        guard let http = response as? HTTPURLResponse else {
            throw HeadlessInstallError.notHTTP(url)
        }
        guard response.url?.scheme?.lowercased() == "https" else {
            throw HeadlessInstallError.notHTTP(response.url ?? url)
        }
        guard http.statusCode == 200 else {
            throw HeadlessInstallError.httpStatus(http.statusCode, url)
        }
        let expected = response.expectedContentLength
        if expected > Int64(maxDownloadBytes) {
            throw HeadlessInstallError.downloadTooLarge(limitBytes: maxDownloadBytes)
        }

        var data = Data()
        data.reserveCapacity(expected > 0 ? Int(expected) : 1 << 20)
        for try await byte in bytes {
            data.append(byte)
            if data.count > maxDownloadBytes {
                throw HeadlessInstallError.downloadTooLarge(
                    limitBytes: maxDownloadBytes
                )
            }
        }
        return data
    }

    // MARK: Local archives (barshelf install ./widget.mbw)

    /// Recognizes `file://…` URLs and existing local `.zip`/`.mbw` paths.
    /// Deep links still go through `WidgetInstallSource.parse`, which rejects
    /// the `file` scheme — local
    /// archives are only reachable from direct CLI/API input.
    static func localArchiveSource(for input: String) -> WidgetInstallSource? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let url: URL
        if trimmed.lowercased().hasPrefix("file://") {
            guard let parsed = URL(string: trimmed), parsed.isFileURL else {
                return nil
            }
            url = parsed
        } else if !trimmed.contains("://") {
            url = URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath)
        } else {
            return nil
        }

        let ext = url.pathExtension.lowercased()
        guard ext == "zip" || ext == "mbw" else { return nil }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        return WidgetInstallSource(
            kind: .archive,
            downloadCandidates: [url.standardizedFileURL],
            subdirectory: nil,
            displayName: url.standardizedFileURL.path
        )
    }

    private static func readLocalArchive(at url: URL) throws -> Data {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        if let size = attributes?[.size] as? Int, size > maxDownloadBytes {
            throw HeadlessInstallError.downloadTooLarge(limitBytes: maxDownloadBytes)
        }
        return try Data(contentsOf: url)
    }
}

public enum HeadlessInstallError: Error, LocalizedError, Equatable {
    case noDownloadCandidates
    case notHTTP(URL)
    case httpStatus(Int, URL)
    case downloadTooLarge(limitBytes: Int)
    case noWidgetsFound(details: [String])

    public var errorDescription: String? {
        switch self {
        case .noDownloadCandidates:
            return "no download URL could be derived from the input"
        case let .notHTTP(url):
            return "unexpected non-HTTP response from \(url.absoluteString)"
        case let .httpStatus(code, url):
            return "download failed (HTTP \(code)): \(url.absoluteString)"
        case let .downloadTooLarge(limit):
            return "download exceeds the \(limit / (1024 * 1024)) MB limit"
        case let .noWidgetsFound(details):
            var message = "no widget.json found in the archive"
            if !details.isEmpty {
                message += "\n" + details.joined(separator: "\n")
            }
            return message
        }
    }
}
