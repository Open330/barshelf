import Foundation

/// Resolves a registry entry's free-text `requires` string (e.g. "aas CLI",
/// "Deno runtime") to a PATH-availability status for the gallery's
/// "requires" badge.
///
/// Design constraints (W1-GALLERY):
/// - **Display-only.** This never blocks or changes an install; it only tells
///   the gallery whether the underlying CLI/runtime looks present.
/// - **Cheap + cached.** Lookups are pure `FileManager` stats over the PATH
///   directories (no `Process`, no shell), and every binary result is memoized
///   so repeated SwiftUI `body` renders cost nothing after the first probe.
///   Callers should still resolve statuses off the main thread on first load
///   (see `GalleryModel`), but the underlying work is a handful of `stat(2)`s.
public final class RequirementChecker: @unchecked Sendable {
    public static let shared = RequirementChecker()

    /// Whether the requirement's binary was found on PATH.
    ///
    /// `.unknown` covers requirements we cannot map to a candidate binary
    /// (empty string, or noise-only text) — the gallery then shows the neutral
    /// "requires X" badge without a present/missing verdict.
    public enum Status: Equatable, Sendable {
        case satisfied
        case missing
        case unknown
    }

    /// PATH directories searched, mirroring `ExecService`'s discovery order so
    /// the badge matches what a widget's exec command would actually resolve.
    private static var searchDirectories: [String] {
        var directories: [String] = []
        if let envPath = ProcessInfo.processInfo.environment["PATH"] {
            directories.append(
                contentsOf: envPath.split(separator: ":").map(String.init)
            )
        }
        directories.append(contentsOf: ExecService.fallbackPathDirectories)
        return directories.filter { !$0.isEmpty }
    }

    /// Words that describe *what kind* of dependency it is rather than the
    /// binary name; dropped when extracting candidate binaries.
    private static let noiseTokens: Set<String> = [
        "cli", "runtime", "tool", "command", "binary", "app", "the", "a",
    ]

    private let lock = NSLock()
    /// binary name (lowercased) → found on PATH.
    private var cache: [String: Bool] = [:]

    public init() {}

    /// Extracts candidate binary names from a free-text requirement.
    ///
    /// Heuristic: take the requirement's leading token(s) before any noise
    /// word ("CLI", "runtime", …), and offer both the verbatim and lowercased
    /// spellings (e.g. "Deno runtime" → ["Deno", "deno"], "aas CLI" → ["aas"]).
    /// Returns `[]` when nothing usable remains.
    public static func candidateBinaries(from requires: String) -> [String] {
        let cleaned = requires
            .replacingOccurrences(
                of: "\\([^)]*\\)", with: " ", options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return [] }

        var names: [String] = []
        for token in cleaned.split(whereSeparator: { $0 == " " || $0 == "/" }) {
            let word = token.trimmingCharacters(
                in: CharacterSet.alphanumerics.inverted
            )
            if word.isEmpty { continue }
            if noiseTokens.contains(word.lowercased()) {
                // A noise word ends the binary name (e.g. "aas CLI" → "aas").
                if !names.isEmpty { break }
                continue
            }
            names.append(word)
            // The first meaningful token is almost always the binary; stop so
            // trailing descriptive prose ("with a configured vault") is ignored.
            break
        }

        var candidates: [String] = []
        for name in names {
            let lower = name.lowercased()
            if !candidates.contains(name) { candidates.append(name) }
            if !candidates.contains(lower) { candidates.append(lower) }
        }
        return candidates
    }

    /// PATH status for a `requires` string. Cached per binary name.
    public func status(forRequires requires: String) -> Status {
        let candidates = Self.candidateBinaries(from: requires)
        guard !candidates.isEmpty else { return .unknown }
        for candidate in candidates where isAvailable(candidate) {
            return .satisfied
        }
        return .missing
    }

    /// Whether `name` resolves to an executable on PATH. Bare names only —
    /// paths/slashes are treated as their own candidate. Result is memoized.
    public func isAvailable(_ name: String) -> Bool {
        let key = name.lowercased()
        lock.lock()
        if let cached = cache[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let found = Self.resolveOnPath(name)

        lock.lock()
        cache[key] = found
        lock.unlock()
        return found
    }

    /// Drops all memoized results (e.g. after the user installs a CLI and
    /// re-opens the gallery).
    public func invalidateCache() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
    }

    private static func resolveOnPath(_ name: String) -> Bool {
        let fm = FileManager.default
        for directory in searchDirectories {
            let path = (directory as NSString).appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: path, isDirectory: &isDirectory),
               !isDirectory.boolValue,
               fm.isExecutableFile(atPath: path) {
                return true
            }
        }
        return false
    }
}
