import Foundation

/// First-run starter widget seeding (R07 onboarding).
///
/// A packaged BarShelf.app launches with cwd `/`, so a fresh install found
/// no `./widgets/` directory and the popup opened empty with no guidance. On
/// first run the CLI-free starter widgets bundled in
/// `BarShelf.app/Contents/Resources/widgets/` are copied into the user
/// widget directory (`~/Library/Application Support/barshelf/widgets/`).
///
/// A marker file (`.seeded-v1`, next to the widgets directory) makes seeding a
/// one-time event: users who delete the starters on purpose are not re-seeded
/// on the next launch.
public enum StarterWidgetSeeder {
    /// Bundled widgets that run without external CLIs or the Deno runtime.
    /// `aas-usage`, `otpeek` and `clock-script` are deliberately *not* seeded
    /// (they need the aas/otpeek CLIs or Deno) — users discover them in the
    /// gallery, where their requirements are shown.
    public static let starterWidgetNames = ["today", "recent-files-grid"]

    /// Written next to the user widget directory, e.g.
    /// `~/Library/Application Support/barshelf/.seeded-v1`.
    public static let markerFileName = ".seeded-v1"

    public struct Outcome: Equatable {
        /// Widget directory names copied this run (empty when skipped).
        public var seededNames: [String]

        /// True when this run copied starter widgets — the caller may show
        /// the one-time welcome card.
        public var didSeed: Bool { !seededNames.isEmpty }

        public init(seededNames: [String]) {
            self.seededNames = seededNames
        }
    }

    /// Copies the starter widgets into `userWidgetsDirectory` when this looks
    /// like a first run. No-ops when:
    /// - `developmentWidgetsDirectory` exists (dev mode `./widgets/` — the
    ///   development behavior is unchanged),
    /// - the marker file already exists (seeded once before),
    /// - the user widget directory already has entries (existing user — only
    ///   the marker is written, nothing is copied),
    /// - there is no bundled widgets directory (plain `swift build` binary).
    ///
    /// Copy failures are best-effort and never block app startup.
    @discardableResult
    public static func seedIfNeeded(
        bundledWidgetsDirectory: URL?,
        userWidgetsDirectory: URL,
        developmentWidgetsDirectory: URL? = nil
    ) -> Outcome {
        let fm = FileManager.default

        if let dev = developmentWidgetsDirectory, fm.fileExists(atPath: dev.path) {
            return Outcome(seededNames: [])
        }

        let markerURL = userWidgetsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent(markerFileName)
        if fm.fileExists(atPath: markerURL.path) {
            return Outcome(seededNames: [])
        }

        // An existing non-empty widget directory means the user installed
        // widgets before seeding existed — never write into it.
        if let entries = try? fm.contentsOfDirectory(atPath: userWidgetsDirectory.path),
           entries.contains(where: { !$0.hasPrefix(".") }) {
            writeMarker(at: markerURL)
            return Outcome(seededNames: [])
        }

        guard let bundled = bundledWidgetsDirectory,
              fm.fileExists(atPath: bundled.path)
        else {
            // No bundled resources — leave the marker unwritten so a later
            // packaged launch can still seed.
            return Outcome(seededNames: [])
        }

        var seeded: [String] = []
        for name in starterWidgetNames {
            let source = bundled.appendingPathComponent(name, isDirectory: true)
            let manifest = source.appendingPathComponent("widget.json")
            guard fm.fileExists(atPath: manifest.path) else { continue }
            let destination = userWidgetsDirectory
                .appendingPathComponent(name, isDirectory: true)
            guard !fm.fileExists(atPath: destination.path) else { continue }
            do {
                try fm.createDirectory(
                    at: userWidgetsDirectory, withIntermediateDirectories: true
                )
                try fm.copyItem(at: source, to: destination)
                seeded.append(name)
            } catch {
                // Best-effort: skip this starter, keep launching.
            }
        }
        if !seeded.isEmpty {
            writeMarker(at: markerURL)
        }
        return Outcome(seededNames: seeded)
    }

    private static func writeMarker(at url: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let stamp = ISO8601DateFormatter().string(from: Date())
        try? Data("seeded \(stamp)\n".utf8).write(to: url, options: .atomic)
    }
}
