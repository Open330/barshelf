import Foundation

// MARK: - Registry index v0.1 (R06 common contract 2)

/// Curated widget registry index (`registry/index.json`).
///
/// The registry is a curation layer on top of the PUBLISHING repo convention:
/// a single JSON document served from a raw URL. `schemaVersion` must be `1`;
/// entries missing required fields (`id`, `name`, `install.url`) are skipped
/// with a warning instead of failing the whole index.
public struct RegistryIndex: Equatable, Sendable {
    public var schemaVersion: Int
    public var name: String?
    /// ISO-8601 timestamp, kept verbatim for display.
    public var updatedAt: String?
    public var widgets: [RegistryWidgetEntry]

    public init(
        schemaVersion: Int,
        name: String? = nil,
        updatedAt: String? = nil,
        widgets: [RegistryWidgetEntry]
    ) {
        self.schemaVersion = schemaVersion
        self.name = name
        self.updatedAt = updatedAt
        self.widgets = widgets
    }
}

/// One registry entry. `permissions` is **display-only** trust UX — the real
/// gate remains the post-install first-run approval card.
public struct RegistryWidgetEntry: Codable, Equatable, Sendable {
    /// Must match `manifest.id` (verified after install by the manifest flow).
    public var id: String
    public var name: String
    public var description: String?
    public var version: String?
    public var author: String?
    /// SF Symbol name.
    public var icon: String?
    /// "exec" | "workflow" | "script"
    public var kind: String?
    public var tags: [String]?
    /// Optional curated grouping for the gallery's category chips (e.g.
    /// "Developer", "Security"). Display/filter-only. When absent the gallery
    /// falls back to `tags` for chip derivation.
    public var category: String?
    /// Free-text external requirement shown as a gallery badge, e.g.
    /// "aas CLI" or "Deno runtime". Display-only — not an enforcement input.
    public var requires: String?
    /// Optional preview image for the gallery card. Either an `http(s)` URL or
    /// a `file:` URL. Display-only; a
    /// missing or unloadable image degrades to no preview.
    public var screenshot: String?
    /// Optional long-form introduction page. A GitHub Markdown (`blob`) URL,
    /// rendered documentation page, or local `file:` URL can be opened from
    /// the gallery card. Display-only and never fetched by the widget runtime.
    public var readme: String?
    /// Gallery shelf grouping: `"custom"` marks integrations built around the
    /// author's own tools (muxa, aas, otpeek, stashbar). Anything else — or
    /// absent — files under the built-in shelf. Display-only.
    public var collection: String?
    /// Accent color for the gallery card's icon tile — a named accent
    /// ("purple", "green", …) or `#RRGGBB`, the `appearance.accent`
    /// vocabulary. Display-only; absent falls back to the system accent.
    public var accent: String?
    public var install: Install
    public var permissions: PermissionsSummary?
    public var homepage: String?

    public init(
        id: String,
        name: String,
        description: String? = nil,
        version: String? = nil,
        author: String? = nil,
        icon: String? = nil,
        kind: String? = nil,
        tags: [String]? = nil,
        category: String? = nil,
        requires: String? = nil,
        screenshot: String? = nil,
        readme: String? = nil,
        collection: String? = nil,
        accent: String? = nil,
        install: Install,
        permissions: PermissionsSummary? = nil,
        homepage: String? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.version = version
        self.author = author
        self.icon = icon
        self.kind = kind
        self.tags = tags
        self.category = category
        self.requires = requires
        self.screenshot = screenshot
        self.readme = readme
        self.collection = collection
        self.accent = accent
        self.install = install
        self.permissions = permissions
        self.homepage = homepage
    }

    public struct Install: Codable, Equatable, Sendable {
        /// Same format as the R05 install URL contract (GitHub repo / tree /
        /// zip / .mbw / deep link string).
        public var url: String
        /// R08 (C1): name of a directory under the app bundle's
        /// `Resources/widgets/`. When present and the directory exists, the
        /// gallery installs by local copy (no network) — same result as
        /// `HeadlessInstaller.install` (`~/…/widgets/<manifest.id>/`).
        /// Missing/absent directory falls back to `url`.
        public var bundled: String?

        public init(url: String, bundled: String? = nil) {
            self.url = url
            self.bundled = bundled
        }
    }

    /// Gallery display summary. Informational only — not an enforcement input.
    public struct PermissionsSummary: Codable, Equatable, Sendable {
        /// Command names the widget declares in `permissions.exec`.
        public var exec: [String]?
        public var keychain: Bool?
        public var notifications: Bool?
        /// Host patterns the widget declares in `permissions.network` (R12).
        public var network: [String]?

        public init(
            exec: [String]? = nil,
            keychain: Bool? = nil,
            notifications: Bool? = nil,
            network: [String]? = nil
        ) {
            self.exec = exec
            self.keychain = keychain
            self.notifications = notifications
            self.network = network
        }
    }
}

// MARK: - Version comparison (gallery update detection)

/// Dotted-number version ordering for the gallery's "Update available" check
/// (registry `version` vs the installed `widget.json` version).
///
/// Lenient by design: each version is split on `.`, numeric components compare
/// numerically, and any non-numeric or extra components fall back to a stable
/// string comparison so a malformed version never crashes or falsely upgrades.
public enum SemanticVersionOrder {
    /// True iff `candidate` is a strictly newer release than `installed`.
    /// Returns `false` when either side is missing or the two are equal.
    public static func isNewer(_ candidate: String?, than installed: String?) -> Bool {
        guard let candidate, let installed else { return false }
        return compare(candidate, installed) == .orderedDescending
    }

    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = components(of: lhs)
        let right = components(of: rhs)
        let count = max(left.count, right.count)
        for index in 0..<count {
            let l = index < left.count ? left[index] : .number(0)
            let r = index < right.count ? right[index] : .number(0)
            switch (l, r) {
            case let (.number(a), .number(b)) where a != b:
                return a < b ? .orderedAscending : .orderedDescending
            case let (.text(a), .text(b)) where a != b:
                return a < b ? .orderedAscending : .orderedDescending
            case (.number, .text):
                // Numeric release outranks a pre-release/text component.
                return .orderedDescending
            case (.text, .number):
                return .orderedAscending
            default:
                continue
            }
        }
        return .orderedSame
    }

    private enum Component: Equatable {
        case number(Int)
        case text(String)
    }

    private static func components(of version: String) -> [Component] {
        let trimmed = version.trimmingCharacters(in: .whitespaces)
            .drop { $0 == "v" || $0 == "V" }
        return trimmed
            .split(whereSeparator: { $0 == "." || $0 == "-" || $0 == "+" })
            .map { part in
                if let value = Int(part) { return .number(value) }
                return .text(String(part))
            }
    }
}

public enum RegistryError: Error, LocalizedError, Equatable {
    case invalidJSON(String)
    case unsupportedSchemaVersion(Int)
    case httpStatus(Int, URL)
    case responseTooLarge(limitBytes: Int)
    case fileNotFound(String)
    case allSourcesFailed([String])

    public var errorDescription: String? {
        switch self {
        case let .invalidJSON(detail):
            return "registry index is not valid JSON: \(detail)"
        case let .unsupportedSchemaVersion(version):
            return "unsupported registry schemaVersion \(version) (expected 1)"
        case let .httpStatus(code, url):
            return "registry download failed (HTTP \(code)): \(url.absoluteString)"
        case let .responseTooLarge(limit):
            return "registry index exceeds the \(limit / (1024 * 1024)) MB limit"
        case let .fileNotFound(path):
            return "registry file not found: \(path)"
        case let .allSourcesFailed(details):
            return "could not load the widget registry:\n"
                + details.joined(separator: "\n")
        }
    }
}

// MARK: - Lenient parsing

extension RegistryIndex {
    /// Parses an index document. Throws on malformed JSON or a schema-version
    /// mismatch; individually broken entries are skipped and reported in
    /// `warnings` ("잘못된 entry는 건너뛰고 경고").
    public static func parse(_ data: Data) throws -> (index: RegistryIndex, warnings: [String]) {
        let raw: RawIndex
        do {
            raw = try JSONDecoder().decode(RawIndex.self, from: data)
        } catch {
            throw RegistryError.invalidJSON(String(describing: error))
        }
        guard raw.schemaVersion == 1 else {
            throw RegistryError.unsupportedSchemaVersion(raw.schemaVersion)
        }

        var warnings = raw.widgets.warnings
        var entries: [RegistryWidgetEntry] = []
        for entry in raw.widgets.entries {
            if let problem = validationProblem(entry) {
                warnings.append("skipped entry \"\(entry.id)\": \(problem)")
                continue
            }
            entries.append(entry)
        }

        let index = RegistryIndex(
            schemaVersion: raw.schemaVersion,
            name: raw.name,
            updatedAt: raw.updatedAt,
            widgets: entries
        )
        return (index, warnings)
    }

    private static func validationProblem(_ entry: RegistryWidgetEntry) -> String? {
        if entry.id.trimmingCharacters(in: .whitespaces).isEmpty {
            return "empty id"
        }
        if entry.name.trimmingCharacters(in: .whitespaces).isEmpty {
            return "empty name"
        }
        if entry.install.url.trimmingCharacters(in: .whitespaces).isEmpty {
            return "empty install.url"
        }
        return nil
    }

    private struct RawIndex: Decodable {
        var schemaVersion: Int
        var name: String?
        var updatedAt: String?
        var widgets: LossyEntries
    }

    /// Decodes each array element independently so one malformed entry (e.g.
    /// missing `name`, wrong type) cannot take down the whole index.
    private struct LossyEntries: Decodable {
        var entries: [RegistryWidgetEntry] = []
        var warnings: [String] = []

        init(from decoder: Decoder) throws {
            var container = try decoder.unkeyedContainer()
            var position = 0
            while !container.isAtEnd {
                do {
                    entries.append(try container.decode(RegistryWidgetEntry.self))
                } catch {
                    // Advance past the broken element (decode failures do not
                    // move the cursor).
                    _ = try? container.decode(Blank.self)
                    warnings.append(
                        "skipped widgets[\(position)]: \(shortDecodingError(error))"
                    )
                }
                position += 1
            }
        }

        private struct Blank: Decodable {
            init(from decoder: Decoder) throws {}
        }

        private func shortDecodingError(_ error: Error) -> String {
            guard let decodingError = error as? DecodingError else {
                return error.localizedDescription
            }
            switch decodingError {
            case let .keyNotFound(key, _):
                return "missing required field \"\(key.stringValue)\""
            case let .typeMismatch(_, context), let .valueNotFound(_, context),
                 let .dataCorrupted(context):
                let path = context.codingPath.map(\.stringValue)
                    .joined(separator: ".")
                return path.isEmpty
                    ? context.debugDescription
                    : "\(path): \(context.debugDescription)"
            @unknown default:
                return String(describing: decodingError)
            }
        }
    }
}

// MARK: - RegistryClient (env → remote default → bundled fallback, 24h cache)

/// Loads the registry index with the v0.1 resolution order:
///
/// 1. `BARSHELF_REGISTRY` environment variable, then legacy
///    `MENUBUCKET_REGISTRY` — an http(s) URL or a local file path
///    (`~` expansion supported).
/// 2. The default remote index URL (placeholder constant).
/// 3. Bundled/local fallback files (offline / development).
///
/// Remote fetches go through a 24-hour disk cache; `forceRefresh` bypasses it
/// (manual refresh). A failed fetch falls back to a stale cache before moving
/// on to the next source.
public final class RegistryClient: @unchecked Sendable {
    public static let environmentVariable = "BARSHELF_REGISTRY"
    public static let legacyEnvironmentVariable = "MENUBUCKET_REGISTRY"

    /// Placeholder — real registry repo TBD.
    public static let defaultRemoteIndexURL = URL(
        string: "https://raw.githubusercontent.com/barshelf/registry/main/index.json"
    )!

    public static let maxResponseBytes = 5 * 1024 * 1024

    public typealias Fetcher = @Sendable (URL) async throws -> Data

    public struct Configuration {
        public var environment: [String: String]
        public var defaultRemoteURL: URL?
        /// Checked in order; the first existing file wins.
        public var bundledFallbacks: [URL]
        public var cacheDirectory: URL
        public var cacheMaxAge: TimeInterval
        public var fetch: Fetcher

        public init(
            environment: [String: String] = ProcessInfo.processInfo.environment,
            defaultRemoteURL: URL? = RegistryClient.defaultRemoteIndexURL,
            bundledFallbacks: [URL] = [],
            cacheDirectory: URL = RegistryClient.defaultCacheDirectory,
            cacheMaxAge: TimeInterval = 24 * 60 * 60,
            fetch: @escaping Fetcher = RegistryClient.urlSessionFetcher
        ) {
            self.environment = environment
            self.defaultRemoteURL = defaultRemoteURL
            self.bundledFallbacks = bundledFallbacks
            self.cacheDirectory = cacheDirectory
            self.cacheMaxAge = cacheMaxAge
            self.fetch = fetch
        }
    }

    public enum Source: Equatable, Sendable {
        /// `BARSHELF_REGISTRY` pointing at a local file.
        case environmentFile(String)
        /// Fresh fetch from a remote URL (env override or the default).
        case remote(URL)
        /// Served from the disk cache of a remote URL.
        case cache(URL)
        /// Bundled/local fallback file.
        case bundled(URL)

        public var displayName: String {
            switch self {
            case let .environmentFile(path): return "env file \(path)"
            case let .remote(url): return url.absoluteString
            case let .cache(url): return "cached \(url.absoluteString)"
            case let .bundled(url): return "bundled \(url.path)"
            }
        }
    }

    public struct LoadResult: Sendable {
        public let index: RegistryIndex
        public let source: Source
        /// Parse warnings plus soft failures of higher-priority sources.
        public let warnings: [String]
    }

    private let configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    public static var defaultCacheDirectory: URL {
        let base = FileManager.default.urls(
            for: .cachesDirectory, in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("barshelf", isDirectory: true)
    }

    public static let urlSessionFetcher: Fetcher = { url in
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw RegistryError.httpStatus(http.statusCode, url)
        }
        guard data.count <= RegistryClient.maxResponseBytes else {
            throw RegistryError.responseTooLarge(
                limitBytes: RegistryClient.maxResponseBytes
            )
        }
        return data
    }

    // MARK: Load

    /// Resolves and loads the index. `forceRefresh` bypasses fresh caches
    /// (manual refresh button); stale-cache fallback still applies when the
    /// network is down.
    public func load(forceRefresh: Bool = false) async throws -> LoadResult {
        var warnings: [String] = []
        var failures: [String] = []

        // 1. Environment override.
        if let environmentOverride = Self.registryOverride(in: configuration.environment) {
            let variableName = environmentOverride.name
            let value = environmentOverride.value
            if let url = URL(string: value),
               url.scheme == "http" || url.scheme == "https" {
                do {
                    return try await loadRemote(
                        url, forceRefresh: forceRefresh, warnings: warnings
                    )
                } catch {
                    failures.append("\(value): \(describe(error))")
                }
            } else {
                let path = NSString(string: value).expandingTildeInPath
                do {
                    let (index, parseWarnings) = try Self.parseFile(
                        URL(fileURLWithPath: path)
                    )
                    return LoadResult(
                        index: index,
                        source: .environmentFile(path),
                        warnings: warnings + parseWarnings
                    )
                } catch {
                    failures.append("\(path): \(describe(error))")
                }
            }
            warnings.append(
                "\(variableName) failed (\(failures.last ?? value)); "
                    + "falling back to the default registry"
            )
        }

        // 2. Default remote URL.
        if let remote = configuration.defaultRemoteURL {
            do {
                return try await loadRemote(
                    remote, forceRefresh: forceRefresh, warnings: warnings
                )
            } catch {
                failures.append("\(remote.absoluteString): \(describe(error))")
                warnings.append(
                    "remote registry unavailable; using the bundled index"
                )
            }
        }

        // 3. Bundled fallback(s).
        for candidate in configuration.bundledFallbacks {
            guard FileManager.default.fileExists(atPath: candidate.path) else {
                continue
            }
            do {
                let (index, parseWarnings) = try Self.parseFile(candidate)
                return LoadResult(
                    index: index,
                    source: .bundled(candidate),
                    warnings: warnings + parseWarnings
                )
            } catch {
                failures.append("\(candidate.path): \(describe(error))")
            }
        }

        throw RegistryError.allSourcesFailed(
            failures.isEmpty ? ["no registry sources configured"] : failures
        )
    }

    private static func registryOverride(
        in environment: [String: String]
    ) -> (name: String, value: String)? {
        for name in [environmentVariable, legacyEnvironmentVariable] {
            if let value = environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return (name, value)
            }
        }
        return nil
    }

    // MARK: Remote + cache

    private func loadRemote(
        _ url: URL, forceRefresh: Bool, warnings: [String]
    ) async throws -> LoadResult {
        let cacheFile = cacheFileURL(for: url)

        if !forceRefresh, let age = cacheAge(of: cacheFile),
           age < configuration.cacheMaxAge {
            do {
                let (index, parseWarnings) = try Self.parseFile(cacheFile)
                return LoadResult(
                    index: index,
                    source: .cache(url),
                    warnings: warnings + parseWarnings
                )
            } catch {
                // Corrupt cache — fall through to a fresh fetch.
                try? FileManager.default.removeItem(at: cacheFile)
            }
        }

        do {
            let data = try await configuration.fetch(url)
            guard data.count <= Self.maxResponseBytes else {
                throw RegistryError.responseTooLarge(
                    limitBytes: Self.maxResponseBytes
                )
            }
            let (index, parseWarnings) = try Self.parse(validating: data)
            writeCache(data, to: cacheFile)
            return LoadResult(
                index: index,
                source: .remote(url),
                warnings: warnings + parseWarnings
            )
        } catch {
            // Network (or validation) failure: a stale cache beats nothing.
            if FileManager.default.fileExists(atPath: cacheFile.path),
               let (index, parseWarnings) = try? Self.parseFile(cacheFile) {
                return LoadResult(
                    index: index,
                    source: .cache(url),
                    warnings: warnings + parseWarnings + [
                        "refresh failed (\(describe(error))); showing cached data"
                    ]
                )
            }
            throw error
        }
    }

    public func cacheFileURL(for url: URL) -> URL {
        var hash: UInt64 = 5381
        for byte in url.absoluteString.utf8 {
            hash = (hash &* 33) ^ UInt64(byte)
        }
        let host = url.host?.replacingOccurrences(
            of: "[^A-Za-z0-9.-]", with: "-", options: .regularExpression
        ) ?? "local"
        return configuration.cacheDirectory.appendingPathComponent(
            "registry-\(host)-\(String(hash, radix: 16)).json"
        )
    }

    private func cacheAge(of file: URL) -> TimeInterval? {
        guard let attributes = try? FileManager.default
            .attributesOfItem(atPath: file.path),
            let modified = attributes[.modificationDate] as? Date else {
            return nil
        }
        return Date().timeIntervalSince(modified)
    }

    private func writeCache(_ data: Data, to file: URL) {
        let fm = FileManager.default
        do {
            try fm.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: file, options: .atomic)
        } catch {
            // Cache is best-effort only.
        }
    }

    // MARK: Helpers

    private static func parseFile(_ file: URL) throws
        -> (RegistryIndex, [String]) {
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw RegistryError.fileNotFound(file.path)
        }
        let data = try Data(contentsOf: file)
        return try parse(validating: data)
    }

    private static func parse(validating data: Data)
        throws -> (RegistryIndex, [String]) {
        let (index, warnings) = try RegistryIndex.parse(data)
        return (index, warnings)
    }

    private func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription
            ?? error.localizedDescription
    }
}
