import Foundation

/// URL-install v1 — input parsing/normalization.
///
/// Supported inputs:
/// 1. GitHub repo URL: `https://github.com/{user}/{repo}` or
///    `https://github.com/{user}/{repo}/tree/{branch}[/{subdir}]`
/// 2. Direct archive URL: `https://…/*.zip` or `*.mbw`
/// 3. Deep link: `menubucket://install?url=<percent-encoded-url>`
///
/// GitHub repo URLs resolve to codeload archive URLs
/// (`https://codeload.github.com/{user}/{repo}/zip/refs/heads/{branch}`);
/// when no branch is given the candidates are `main` then `master`.
public struct WidgetInstallSource: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case gitHubRepo(owner: String, repo: String, branch: String?)
        case archive
    }

    /// One (archive URL, discovery subdirectory) attempt. GitHub `/tree/a/b/c`
    /// is ambiguous — the branch may be `a`, `a/b`, or `a/b/c` — so each split
    /// becomes its own candidate, tried in order.
    public struct Candidate: Equatable, Sendable {
        public var url: URL
        public var subdirectory: String?

        public init(url: URL, subdirectory: String? = nil) {
            self.url = url
            self.subdirectory = subdirectory
        }
    }

    public var kind: Kind
    /// Attempts in order: first success wins; HTTP 404 (and, for GitHub tree
    /// URLs, a missing subdirectory) falls through to the next candidate.
    public var candidates: [Candidate]
    /// Human-readable description of the source (for logs/dialogs).
    public var displayName: String

    /// Convenience views (first-candidate semantics).
    public var downloadCandidates: [URL] { candidates.map(\.url) }
    public var subdirectory: String? { candidates.first?.subdirectory }

    public init(
        kind: Kind,
        candidates: [Candidate],
        displayName: String
    ) {
        self.kind = kind
        self.candidates = candidates
        self.displayName = displayName
    }

    public init(
        kind: Kind,
        downloadCandidates: [URL],
        subdirectory: String? = nil,
        displayName: String
    ) {
        self.init(
            kind: kind,
            candidates: downloadCandidates.map {
                Candidate(url: $0, subdirectory: subdirectory)
            },
            displayName: displayName
        )
    }

    // MARK: - Parsing

    private static let maxDeepLinkDepth = 1
    private static let archiveExtensions: Set<String> = ["zip", "mbw"]
    private static let gitHubHosts: Set<String> = ["github.com", "www.github.com"]

    public static func parse(_ input: String) throws -> WidgetInstallSource {
        try parse(input, deepLinkDepth: 0)
    }

    private static func parse(_ input: String, deepLinkDepth: Int) throws -> WidgetInstallSource {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw WidgetInstallSourceError.emptyInput
        }
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased()
        else {
            throw WidgetInstallSourceError.notAURL(trimmed)
        }

        if scheme == "menubucket" {
            guard deepLinkDepth < Self.maxDeepLinkDepth else {
                throw WidgetInstallSourceError.nestedDeepLink(trimmed)
            }
            return try parseDeepLink(components, deepLinkDepth: deepLinkDepth)
        }

        guard scheme == "https" || scheme == "http" else {
            throw WidgetInstallSourceError.unsupportedScheme(scheme)
        }
        guard let url = components.url else {
            throw WidgetInstallSourceError.notAURL(trimmed)
        }

        // Archive check first: covers GitHub release assets (…/releases/
        // download/v1/widget.zip) as well as arbitrary hosts.
        let ext = (url.path as NSString).pathExtension.lowercased()
        if archiveExtensions.contains(ext) {
            return WidgetInstallSource(
                kind: .archive,
                downloadCandidates: [url],
                displayName: url.lastPathComponent
            )
        }

        if let host = components.host?.lowercased(), gitHubHosts.contains(host) {
            return try parseGitHubRepo(url: url)
        }

        throw WidgetInstallSourceError.unsupportedURL(trimmed)
    }

    /// `menubucket://install?url=<percent-encoded-url>`
    private static func parseDeepLink(
        _ components: URLComponents, deepLinkDepth: Int
    ) throws -> WidgetInstallSource {
        let action = components.host?.lowercased()
            ?? components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        guard action == "install" else {
            throw WidgetInstallSourceError.unsupportedDeepLinkAction(action)
        }
        // URLComponents.queryItems already percent-decodes the value.
        guard let inner = components.queryItems?
            .first(where: { $0.name == "url" })?.value,
            !inner.isEmpty
        else {
            throw WidgetInstallSourceError.deepLinkMissingURL
        }
        return try parse(inner, deepLinkDepth: deepLinkDepth + 1)
    }

    /// `https://github.com/{user}/{repo}[.git][/tree/{branch}[/{subdir…}]]`
    private static func parseGitHubRepo(url: URL) throws -> WidgetInstallSource {
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 2 else {
            throw WidgetInstallSourceError.malformedGitHubURL(url.absoluteString)
        }

        let owner = parts[0]
        var repo = parts[1]
        if repo.lowercased().hasSuffix(".git") {
            repo = String(repo.dropLast(4))
        }
        guard isValidGitHubName(owner), isValidGitHubName(repo) else {
            throw WidgetInstallSourceError.malformedGitHubURL(url.absoluteString)
        }

        var treePath: [String] = []
        if parts.count > 2 {
            guard parts[2] == "tree", parts.count >= 4 else {
                throw WidgetInstallSourceError.malformedGitHubURL(url.absoluteString)
            }
            treePath = Array(parts[3...])
        }

        func codeloadURL(branch: String) throws -> URL {
            var codeload = URLComponents()
            codeload.scheme = "https"
            codeload.host = "codeload.github.com"
            codeload.path = "/\(owner)/\(repo)/zip/refs/heads/\(branch)"
            guard let result = codeload.url else {
                throw WidgetInstallSourceError.malformedGitHubURL(url.absoluteString)
            }
            return result
        }

        // `/tree/a/b/c`: the branch/path boundary is unknowable from the URL
        // alone (branch names may contain slashes). Try every split,
        // shortest branch first.
        let candidates: [Candidate]
        if treePath.isEmpty {
            candidates = try ["main", "master"].map {
                Candidate(url: try codeloadURL(branch: $0))
            }
        } else {
            candidates = try (1...treePath.count).map { splitIndex in
                let branch = treePath[..<splitIndex].joined(separator: "/")
                let subdir = treePath[splitIndex...].joined(separator: "/")
                return Candidate(
                    url: try codeloadURL(branch: branch),
                    subdirectory: subdir.isEmpty ? nil : subdir
                )
            }
        }

        let branchDisplay = treePath.isEmpty ? nil : treePath.joined(separator: "/")
        return WidgetInstallSource(
            kind: .gitHubRepo(owner: owner, repo: repo, branch: branchDisplay),
            candidates: candidates,
            displayName: "\(owner)/\(repo)" + (branchDisplay.map { "@\($0)" } ?? "")
        )
    }

    private static func isValidGitHubName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 100, name != ".", name != ".." else {
            return false
        }
        return name.allSatisfy { char in
            char.isLetter || char.isNumber || char == "-" || char == "_" || char == "."
        }
    }
}

public enum WidgetInstallSourceError: Error, Equatable, LocalizedError {
    case emptyInput
    case notAURL(String)
    case unsupportedScheme(String)
    case unsupportedURL(String)
    case malformedGitHubURL(String)
    case unsupportedDeepLinkAction(String)
    case deepLinkMissingURL
    case nestedDeepLink(String)

    public var errorDescription: String? {
        switch self {
        case .emptyInput:
            return "no URL given"
        case let .notAURL(input):
            return "not a valid URL: \(input)"
        case let .unsupportedScheme(scheme):
            return "unsupported URL scheme \"\(scheme)\" (expected https, or menubucket://install)"
        case let .unsupportedURL(input):
            return "unsupported URL: \(input) (expected a GitHub repo URL or a .zip/.mbw archive URL)"
        case let .malformedGitHubURL(input):
            return "malformed GitHub URL: \(input) (expected https://github.com/{user}/{repo}[/tree/{branch}[/{subdir}]])"
        case let .unsupportedDeepLinkAction(action):
            return "unsupported menubucket:// action \"\(action)\" (expected menubucket://install?url=…)"
        case .deepLinkMissingURL:
            return "menubucket://install requires a url query parameter"
        case let .nestedDeepLink(input):
            return "menubucket:// deep links cannot nest: \(input)"
        }
    }
}
