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
/// mode) and the standalone `mbk` CLI.
public enum HeadlessInstaller {
    /// Archive download cap (bytes).
    // Repo archives legitimately reach tens of MB once app assets are in the
    // zip (e.g. file-stack ships hero images/screenshots at ~50 MB), so this
    // guards memory/bandwidth abuse rather than typical repo size.
    public static let maxDownloadBytes = 128 * 1024 * 1024

    /// `~/Library/Application Support/menubucket/widgets` — where the app
    /// loads user-installed widgets from.
    public static var defaultWidgetsDirectory: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("menubucket", isDirectory: true)
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
        if let local = localArchiveSource(for: input) {
            return try await fetchSession(source: local)
        }
        return try await fetchSession(source: WidgetInstallSource.parse(input))
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
            let archive: Data
            do {
                archive = try await download(from: candidate.url)
            } catch HeadlessInstallError.httpStatus(404, let failedURL) {
                lastError = HeadlessInstallError.httpStatus(404, failedURL)
                continue
            }

            let staging = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "menubucket-install-\(UUID().uuidString)", isDirectory: true
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

    /// Copies a candidate into `widgetsDir/<manifest.id>/`, replacing any
    /// existing install (update). Returns the installed directory.
    @discardableResult
    public static func install(
        _ candidate: InstallCandidate, into widgetsDir: URL
    ) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: widgetsDir, withIntermediateDirectories: true)

        let destination = widgetsDir.appendingPathComponent(
            candidate.manifest.id, isDirectory: true
        )
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.copyItem(at: candidate.sourceDirectory, to: destination)
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

        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw HeadlessInstallError.notHTTP(url)
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

    // MARK: Local archives (mbk install ./widget.mbw)

    /// Recognizes `file://…` URLs and existing local `.zip`/`.mbw` paths.
    /// Note: `menubucket://` deep links still go through
    /// `WidgetInstallSource.parse`, which rejects the `file` scheme — local
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
