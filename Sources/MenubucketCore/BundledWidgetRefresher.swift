import CryptoKit
import Foundation

/// Keeps already-installed bundled widgets in step with the app.
///
/// `StarterWidgetSeeder` copies the bundled starters exactly once, which is
/// right for onboarding and wrong for maintenance: a widget's behaviour lives
/// in `widget.json` / `workflow.json`, so a fix to the System widget's number
/// formatting shipped inside BarShelf.app never reached anyone who already
/// had the widget — the only way to deliver it was to run `barshelf install`
/// on every machine by hand.
///
/// On launch this compares the version of each *installed* widget against the
/// bundled copy with the same manifest id and swaps in the newer one. It is
/// deliberately narrow:
///
/// - It never installs a widget the user does not already have, so widgets
///   deleted on purpose stay deleted.
/// - It matches on manifest id, not directory name, because seeded starters
///   live under their folder name (`today`) while installs live under their
///   id (`dev.barshelf.today`).
/// - It skips symlinks, which are how duplicated widget instances
///   (`dev.barshelf.system--ram`) are represented; replacing the real
///   directory keeps every alias pointing at the fresh copy.
/// - It skips a widget whose files changed since BarShelf last wrote them
///   (see `Ledger`), so a hand-edited widget is never silently overwritten.
///
/// Widget settings live in `prefs.json`, keyed by widget id, so replacing the
/// directory wholesale preserves the user's configuration.
public enum BundledWidgetRefresher {
    /// Written next to the user widget directory, e.g.
    /// `~/Library/Application Support/barshelf/.bundled-widgets.json`.
    public static let ledgerFileName = ".bundled-widgets.json"

    public struct Refresh: Equatable {
        /// Manifest id of the refreshed widget.
        public var id: String
        /// Directory name it is installed under (id, or a seeded folder name).
        public var directoryName: String
        /// Version that was installed, when the old manifest declared one.
        public var from: String?
        /// Version now installed.
        public var to: String

        public init(id: String, directoryName: String, from: String?, to: String) {
            self.id = id
            self.directoryName = directoryName
            self.from = from
            self.to = to
        }

        /// "dev.barshelf.system 0.3.0 → 0.3.1" — for the launch log.
        public var summary: String {
            "\(id) \(from ?? "?") → \(to)"
        }
    }

    public struct Outcome: Equatable {
        /// Widgets updated this run.
        public var refreshed: [Refresh]
        /// Ids of widgets that had a newer bundled version available but were
        /// left alone because their files were modified locally.
        public var skippedLocallyModified: [String]

        public var didRefresh: Bool { !refreshed.isEmpty }

        public init(refreshed: [Refresh] = [], skippedLocallyModified: [String] = []) {
            self.refreshed = refreshed
            self.skippedLocallyModified = skippedLocallyModified
        }
    }

    /// Updates every installed widget that the app bundle ships a newer
    /// version of. No-ops in a development checkout (`./widgets/` present) and
    /// when the app has no bundled widget resources.
    ///
    /// Failures are best-effort: a widget that cannot be read or replaced is
    /// skipped and launch continues.
    @discardableResult
    public static func refreshIfNeeded(
        bundledWidgetsDirectory: URL?,
        userWidgetsDirectory: URL,
        developmentWidgetsDirectory: URL? = nil
    ) -> Outcome {
        let fm = FileManager.default

        if let dev = developmentWidgetsDirectory, fm.fileExists(atPath: dev.path) {
            return Outcome()
        }
        guard let bundledRoot = bundledWidgetsDirectory,
              fm.fileExists(atPath: bundledRoot.path)
        else { return Outcome() }

        let installed = installedWidgets(in: userWidgetsDirectory)
        guard !installed.isEmpty else { return Outcome() }
        let bundled = bundledWidgets(in: bundledRoot)
        guard !bundled.isEmpty else { return Outcome() }

        let ledgerURL = userWidgetsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent(ledgerFileName)
        var ledger = Ledger.read(from: ledgerURL)
        var outcome = Outcome()

        for entry in installed {
            guard let replacement = bundled[entry.id] else { continue }
            // A record describes the files BarShelf wrote for *that* version.
            // When the installed version differs, something else installed it
            // since — the gallery's Update, `barshelf install` — and those
            // files are the new baseline, not an edit. Keeping the old record
            // would flag the fresh install as modified and block every later
            // bundled update for good.
            var record = ledger.record(for: entry.id)
            if let stale = record, stale.version != entry.version {
                record = nil
            }
            guard isNewer(replacement.version, than: entry.version) else {
                // Already current. Record what is on disk when there is no
                // valid record, so a later hand-edit is detectable.
                if record == nil, let version = entry.version {
                    ledger.set(
                        id: entry.id,
                        version: version,
                        digest: digest(of: entry.directory)
                    )
                }
                continue
            }

            // A recorded digest that no longer matches means the user edited
            // the widget in place. Leave it alone — the gallery's explicit
            // "Update" still overwrites it on request.
            if let record, record.digest != digest(of: entry.directory) {
                outcome.skippedLocallyModified.append(entry.id)
                continue
            }

            do {
                try HeadlessInstaller.installDirectory(
                    from: replacement.directory, to: entry.directory
                )
            } catch {
                continue
            }
            ledger.set(
                id: entry.id,
                version: replacement.version,
                digest: digest(of: entry.directory)
            )
            outcome.refreshed.append(Refresh(
                id: entry.id,
                directoryName: entry.directory.lastPathComponent,
                from: entry.version,
                to: replacement.version
            ))
        }

        if ledger.isDirty {
            ledger.write(to: ledgerURL)
        }
        return outcome
    }

    /// Whether the bundled version supersedes what is installed.
    ///
    /// A manifest without a `version` is treated as older than anything the
    /// bundle declares: the versionless installs in the wild are widgets that
    /// predate the field, and the app bundle is the authority for its own ids.
    static func isNewer(_ bundled: String, than installed: String?) -> Bool {
        guard let installed, !installed.isEmpty else { return true }
        return SemanticVersionOrder.isNewer(bundled, than: installed)
    }

    // MARK: - Scanning

    /// An installed widget: its manifest may legitimately omit `version`
    /// (older hand-written widgets do), in which case anything bundled that
    /// declares one counts as newer.
    struct WidgetOnDisk {
        var id: String
        var version: String?
        var directory: URL
    }

    /// A widget shipped inside the app bundle. Only versioned widgets are
    /// indexed — without a version there is nothing to compare against.
    struct BundledWidget {
        var id: String
        var version: String
        var directory: URL
    }

    /// Installed widgets, keyed by nothing — order follows the directory so
    /// the launch log is stable. Symlinked instance aliases and dotfiles are
    /// skipped; a directory without a readable `widget.json` is ignored.
    static func installedWidgets(in root: URL) -> [WidgetOnDisk] {
        children(of: root).compactMap { url in
            guard let summary = ManifestSummary.read(fromWidgetDirectory: url)
            else { return nil }
            return WidgetOnDisk(
                id: summary.id, version: summary.version, directory: url
            )
        }
    }

    /// Bundled widgets keyed by manifest id. A duplicate id keeps the first
    /// directory found, so the bundle is never ambiguous about what "newer"
    /// means.
    static func bundledWidgets(in root: URL) -> [String: BundledWidget] {
        var index: [String: BundledWidget] = [:]
        for url in children(of: root) {
            guard let summary = ManifestSummary.read(fromWidgetDirectory: url),
                  let version = summary.version,
                  index[summary.id] == nil
            else { continue }
            index[summary.id] = BundledWidget(
                id: summary.id, version: version, directory: url
            )
        }
        return index
    }

    /// Real (non-symlink) child directories, dotfiles excluded, sorted by name.
    private static func children(of root: URL) -> [URL] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { return [] }
        return names.sorted().compactMap { name in
            guard !name.hasPrefix(".") else { return nil }
            let url = root.appendingPathComponent(name, isDirectory: true)
            guard let values = try? url.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            ), values.isDirectory == true, values.isSymbolicLink != true
            else { return nil }
            return url
        }
    }

    // MARK: - Content digest

    /// SHA-256 over the directory's files: every relative path and its bytes,
    /// in sorted order. Used only to tell "as BarShelf wrote it" apart from
    /// "edited since", so it covers content and layout, not file metadata.
    static func digest(of directory: URL) -> String {
        let fm = FileManager.default
        var hasher = SHA256()
        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return "" }

        var files: [(path: String, url: URL)] = []
        let prefix = directory.standardizedFileURL.path
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?
                .isRegularFile == true else { continue }
            var relative = url.standardizedFileURL.path
            if relative.hasPrefix(prefix) {
                relative = String(relative.dropFirst(prefix.count))
            }
            files.append((relative, url))
        }

        for file in files.sorted(by: { $0.path < $1.path }) {
            hasher.update(data: Data(file.path.utf8))
            if let contents = try? Data(contentsOf: file.url) {
                hasher.update(data: contents)
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Ledger

    /// What BarShelf last wrote for each bundled widget. Its only job is to
    /// answer "have these files changed since we put them there?", so a
    /// missing or corrupt ledger simply means "no opinion" and the refresher
    /// falls back to comparing versions.
    struct Ledger {
        struct Record: Codable, Equatable {
            var version: String
            var digest: String
        }

        private struct Document: Codable {
            var version: Int
            var widgets: [String: Record]
        }

        private static let formatVersion = 1

        private var widgets: [String: Record] = [:]
        private(set) var isDirty = false

        static func read(from url: URL) -> Ledger {
            var ledger = Ledger()
            guard let data = try? Data(contentsOf: url),
                  let document = try? JSONDecoder().decode(Document.self, from: data),
                  document.version == formatVersion
            else { return ledger }
            ledger.widgets = document.widgets
            return ledger
        }

        func record(for id: String) -> Record? { widgets[id] }

        mutating func set(id: String, version: String, digest: String) {
            let record = Record(version: version, digest: digest)
            guard widgets[id] != record else { return }
            widgets[id] = record
            isDirty = true
        }

        func write(to url: URL) {
            let document = Document(version: Self.formatVersion, widgets: widgets)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let data = try? encoder.encode(document) else { return }
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try? data.write(to: url, options: .atomic)
        }
    }
}

// MARK: - Manifest id/version probe

/// The two fields the refresher needs out of a `widget.json`.
///
/// Decoding the full `Manifest` would validate and reject perfectly
/// installable widgets (unsupported schema versions, missing entry points),
/// and `version` is not part of `Manifest` at all — it is read alongside it
/// wherever a version is displayed. This reads just the pair.
struct ManifestSummary: Decodable {
    var id: String
    var version: String?

    static func read(fromWidgetDirectory directory: URL) -> ManifestSummary? {
        let manifest = directory.appendingPathComponent(WidgetDiscovery.manifestFileName)
        guard let data = try? Data(contentsOf: manifest),
              let summary = try? JSONDecoder().decode(ManifestSummary.self, from: data),
              !summary.id.isEmpty
        else { return nil }
        return summary
    }
}
