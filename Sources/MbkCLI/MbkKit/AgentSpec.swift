import Foundation

/// `mbk agent-spec` — prints the widget-authoring spec (docs/AGENTS.md) so an
/// LLM agent can be handed the whole contract in one command.
///
/// Resolution order (filesystem first, so a dev checkout always prints the live
/// file; the embedded copy is the fallback that keeps the packaged bare binary
/// working — the release tarball ships only the `mbk` executable, no resources):
///   1. `<cwd>/docs/AGENTS.md`
///   2. repo-relative to this source file (`#filePath` walk-up) — dev builds
///   3. executable-relative walk-up (like `RuntimeSupervisor.locateSDKModule`)
///   4. the embedded copy (`AgentSpecEmbedded.markdown`)
public enum AgentSpec {
    /// The spec text: on-disk `docs/AGENTS.md` when locatable, else embedded.
    public static func render(fileManager: FileManager = .default) -> String {
        if let url = locate(fileManager: fileManager),
           let text = try? String(contentsOf: url, encoding: .utf8),
           !text.isEmpty {
            return text
        }
        return AgentSpecEmbedded.markdown
    }

    /// Best-effort location of the on-disk `docs/AGENTS.md`. `nil` when only the
    /// embedded copy is available (e.g. the standalone release tarball).
    static func locate(fileManager: FileManager = .default) -> URL? {
        let relative = "docs/AGENTS.md"

        // 1. Current working directory (running from a repo checkout).
        let cwd = URL(fileURLWithPath: fileManager.currentDirectoryPath)
            .appendingPathComponent(relative)
        if fileManager.fileExists(atPath: cwd.path) { return cwd }

        // 2. Repo-relative to this file: Sources/MbkCLI/MbkKit/AgentSpec.swift
        //    → repo root is four parent directories up.
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // MbkKit
            .deletingLastPathComponent()  // MbkCLI
            .deletingLastPathComponent()  // Sources
            .deletingLastPathComponent()  // repo root
        let sourceRelative = repoRoot.appendingPathComponent(relative)
        if fileManager.fileExists(atPath: sourceRelative.path) { return sourceRelative }

        // 3. Executable-relative walk-up (packaged next to a docs/ tree).
        if var directory = executableDirectory() {
            for _ in 0..<6 {
                let candidate = directory.appendingPathComponent(relative)
                if fileManager.fileExists(atPath: candidate.path) { return candidate }
                let parent = directory.deletingLastPathComponent()
                if parent.path == directory.path { break }
                directory = parent
            }
        }

        return nil
    }

    private static func executableDirectory() -> URL? {
        if let executable = Bundle.main.executableURL {
            return executable.resolvingSymlinksInPath().deletingLastPathComponent()
        }
        guard let argv0 = CommandLine.arguments.first else { return nil }
        return URL(fileURLWithPath: argv0)
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
    }
}
