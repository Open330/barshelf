import AppKit
import Foundation
import MenubucketCore

// MARK: - Shared install flow (download → extract → discover → copy)

/// URL-install v1 pipeline shared by the GUI installer and the CLI mode.
/// The actual work (parsing / download / zip / discovery / copy) lives in
/// MenubucketCore's `HeadlessInstaller`; this type keeps the app-internal
/// API stable and pins the install directory to the app-support location.
enum WidgetInstallFlow {
    static let maxDownloadBytes = HeadlessInstaller.maxDownloadBytes

    static var widgetsInstallDirectory: URL {
        WidgetRuntime.applicationSupportDirectory
            .appendingPathComponent("widgets", isDirectory: true)
    }

    static var bundledWidgetRoots: [URL] {
        var roots: [URL] = []
        if let resources = Bundle.main.resourceURL {
            roots.append(resources.appendingPathComponent("widgets", isDirectory: true))
        }
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // MenubucketApp
            .deletingLastPathComponent()  // Sources
            .deletingLastPathComponent()  // repo root
        roots.append(repoRoot.appendingPathComponent("widgets", isDirectory: true))
        return roots
    }

    struct Prepared {
        let source: WidgetInstallSource
        /// Temporary extraction root — caller removes it when done.
        let stagingRoot: URL
        let discovery: WidgetDiscovery.Result
    }

    /// Parses the input, downloads the archive (128 MB cap), extracts it
    /// safely (256 MB cap) and discovers widget candidates.
    static func prepare(input: String) async throws -> Prepared {
        let session = try await HeadlessInstaller.fetchSession(input: input)
        return Prepared(
            source: session.source,
            stagingRoot: session.stagingRoot,
            discovery: session.discovery
        )
    }

    static func bundledWidgetDirectory(named name: String) -> URL? {
        guard isSafeBundledName(name) else { return nil }
        let fm = FileManager.default
        for root in bundledWidgetRoots {
            let candidate = root.appendingPathComponent(name, isDirectory: true)
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return candidate
            }
        }
        return nil
    }

    static func discoverBundledWidget(at directory: URL) throws -> WidgetDiscovery.Result {
        try WidgetDiscovery.discover(under: directory)
    }

    /// Tries each download candidate in order; HTTP 404 falls through to the
    /// next one (GitHub main → master fallback).
    static func download(source: WidgetInstallSource) async throws -> Data {
        try await HeadlessInstaller.download(source: source)
    }

    static func download(from url: URL) async throws -> Data {
        try await HeadlessInstaller.download(from: url)
    }

    /// Progress-reporting variant of `prepare` for the interactive URL
    /// installer. Mirrors `HeadlessInstaller.fetchSession` (download → extract
    /// → discover, with the 404 / subdirectory-not-found candidate fallbacks)
    /// but streams byte counts to `progress` so the UI can show a determinate
    /// bar. Inputs that are not remote HTTP URLs (local directories/archives)
    /// fall back to the plain pipeline. Honors `Task` cancellation.
    ///
    /// `progress`: `(bytesReceived, expectedTotal)` — `expectedTotal <= 0`
    /// means the length is unknown (caller shows an indeterminate spinner).
    static func prepare(
        input: String,
        progress: @escaping (Int64, Int64) -> Void
    ) async throws -> Prepared {
        let source: WidgetInstallSource
        do {
            source = try WidgetInstallSource.parse(input)
        } catch {
            // Not a parseable remote URL (e.g. a local directory/archive path):
            // there is no network wait to report — use the standard pipeline.
            return try await prepare(input: input)
        }
        guard !source.candidates.contains(where: { $0.url.isFileURL }) else {
            return try await prepare(input: input)
        }

        var lastError: Error = WidgetInstallFlowError.noDownloadCandidates
        for candidate in source.candidates {
            let archive: Data
            do {
                archive = try await download(from: candidate.url, progress: progress)
            } catch WidgetInstallFlowError.httpStatus(404, let failedURL) {
                lastError = WidgetInstallFlowError.httpStatus(404, failedURL)
                continue
            }

            let staging = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "barshelf-install-\(UUID().uuidString)", isDirectory: true
                )
            do {
                _ = try SafeZipExtractor.extract(zipData: archive, to: staging)
                let discovery = try WidgetDiscovery.discover(
                    under: staging, subdirectory: candidate.subdirectory
                )
                return Prepared(
                    source: source, stagingRoot: staging, discovery: discovery
                )
            } catch let error as WidgetDiscovery.DiscoveryError {
                try? FileManager.default.removeItem(at: staging)
                guard case .subdirectoryNotFound = error else { throw error }
                lastError = error
                continue
            } catch {
                try? FileManager.default.removeItem(at: staging)
                throw error
            }
        }
        throw lastError
    }

    /// Streaming HTTP download with a byte-count callback and cooperative
    /// cancellation. Enforces the same size cap as the headless pipeline.
    static func download(
        from url: URL,
        progress: @escaping (Int64, Int64) -> Void
    ) async throws -> Data {
        guard url.scheme?.lowercased() == "https" else {
            throw WidgetInstallFlowError.notHTTP(url)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        let redirectGuard = HeadlessInstaller.InstallRedirectGuard(origin: url)
        let (bytes, response) = try await URLSession.shared.bytes(
            for: request, delegate: redirectGuard
        )
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse else {
            throw WidgetInstallFlowError.notHTTP(url)
        }
        guard response.url?.scheme?.lowercased() == "https" else {
            throw WidgetInstallFlowError.notHTTP(response.url ?? url)
        }
        guard http.statusCode == 200 else {
            throw WidgetInstallFlowError.httpStatus(http.statusCode, url)
        }
        let expected = response.expectedContentLength
        if expected > Int64(maxDownloadBytes) {
            throw WidgetInstallFlowError.downloadTooLarge(limitBytes: maxDownloadBytes)
        }

        var data = Data()
        data.reserveCapacity(expected > 0 ? Int(expected) : 1 << 20)
        var received: Int64 = 0
        var lastReported: Int64 = 0
        progress(0, expected)
        for try await byte in bytes {
            try Task.checkCancellation()
            data.append(byte)
            received += 1
            if received - lastReported >= 64 * 1024 {
                lastReported = received
                progress(received, expected)
            }
            if data.count > maxDownloadBytes {
                throw WidgetInstallFlowError.downloadTooLarge(limitBytes: maxDownloadBytes)
            }
        }
        progress(received, expected)
        return data
    }

    /// Copies a validated candidate into the install directory.
    /// Returns `true` when an existing install was replaced (update).
    @discardableResult
    static func install(candidate: WidgetDiscovery.Candidate) throws -> Bool {
        let isUpdate = isInstalled(id: candidate.manifest.id)
        try HeadlessInstaller.install(
            InstallCandidate(candidate), into: widgetsInstallDirectory,
            hostVersion: WidgetRuntime.hostVersion
        )
        return isUpdate
    }

    /// An install failure in the app's language. Core keeps English text
    /// (the command line has no string catalog); the refusals that protect
    /// files on disk get words that say what was kept and what to do. Paths
    /// and ids stay as they are, so they can be found and copied.
    static func userFacingDescription(of error: Error) -> String {
        explainFailure(error).message
    }

    /// An install failure as what happened and what to do, with the raw
    /// text (addresses, archive paths, parser output) kept apart: it goes
    /// to the log and behind "Copy Details", never into the sentence.
    struct Failure: Equatable {
        let cause: String
        let fix: String
        let detail: String?

        var message: String { "\(cause) \(fix)" }
    }

    static func explainFailure(_ error: Error) -> Failure {
        switch error as? HeadlessInstallError {
        case let .invalidWidgetID(id):
            return Failure(
                cause: String(localized: "“\(id)” isn’t a valid widget ID, so nothing was installed."),
                fix: String(localized: "The widget’s author needs to fix the id in its widget.json."),
                detail: nil)
        case let .symbolicLinkInstall(path):
            return Failure(
                cause: String(localized: "This widget is installed as a link to a folder elsewhere (\(path)). BarShelf doesn’t update linked widgets and changed nothing."),
                fix: String(localized: "To update it, update the folder the link points to — for example with git pull — or remove the link and install the widget again."),
                detail: nil)
        case let .destinationOccupied(path):
            return Failure(
                cause: String(localized: "Something that isn’t this widget is already at \(path). BarShelf left it exactly as it was."),
                fix: String(localized: "Move or rename it in Finder, then install again."),
                detail: nil)
        case let .needsNewerHost(reason):
            // Core's reason names the version ("Needs BarShelf 0.8.0 or
            // later …"); keep it, so a pack list or onboarding says which.
            let required = reason.firstMatch(of: #/BarShelf\s+(\S+)\s+or later/#).map { String($0.1) }
            return Failure(
                cause: required.map { String(localized: "This widget needs BarShelf \($0) or later.") }
                    ?? String(localized: "This widget needs a newer version of BarShelf."),
                fix: String(localized: "Update BarShelf, then install the widget again."),
                detail: reason)
        case .noDownloadCandidates:
            return noDownload(detail: error.localizedDescription)
        case let .notHTTP(url):
            return insecure(url)
        case let .httpStatus(code, url):
            return http(code, url)
        case let .downloadTooLarge(limit):
            return tooLarge(limit)
        case let .noWidgetsFound(details):
            return noWidgets(details)
        case nil:
            break
        }
        switch error as? WidgetInstallFlowError {
        case .noDownloadCandidates:
            return noDownload(detail: nil)
        case let .notHTTP(url):
            return insecure(url)
        case let .httpStatus(code, url):
            return http(code, url)
        case let .downloadTooLarge(limit):
            return tooLarge(limit)
        case let .noWidgetsFound(details):
            return noWidgets(details)
        case nil:
            break
        }
        if case let .subdirectoryNotFound(folder)? = error as? WidgetDiscovery.DiscoveryError {
            return Failure(
                cause: String(localized: "The folder “\(folder)” isn’t in this repository."),
                fix: String(localized: "Check the folder name and branch in the link, then try again."),
                detail: nil)
        }
        // Network and file errors: classified like a widget's refresh error,
        // in install words; the system's own text stays in Details.
        let raw = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        let explanation = ErrorExplainer.explain(raw, context: .install)
        return Failure(cause: explanation.cause, fix: explanation.fix, detail: raw)
    }

    private static func noDownload(detail: String?) -> Failure {
        Failure(
            cause: String(localized: "BarShelf couldn’t find a widget to download at that address."),
            fix: String(localized: "Use a link to a GitHub repository or folder, or to a .zip file."),
            detail: detail)
    }

    private static func insecure(_ url: URL) -> Failure {
        Failure(
            cause: String(localized: "That address doesn’t offer a secure download."),
            fix: String(localized: "Use an https:// link to the widget."),
            detail: url.absoluteString)
    }

    private static func http(_ code: Int, _ url: URL) -> Failure {
        let explanation = ErrorExplainer.explain("HTTP \(code)", context: .install)
        return Failure(cause: explanation.cause, fix: explanation.fix, detail: "HTTP \(code): \(url.absoluteString)")
    }

    private static func tooLarge(_ limitBytes: Int) -> Failure {
        Failure(
            cause: String(localized: "The download is larger than the \(limitBytes / (1024 * 1024)) MB BarShelf accepts for a widget."),
            fix: String(localized: "Check that the link points to the widget itself, not a whole project."),
            detail: nil)
    }

    private static func noWidgets(_ details: [String]) -> Failure {
        guard !details.isEmpty else {
            return Failure(
                cause: String(localized: "There’s no BarShelf widget in this download."),
                fix: String(localized: "Check that the link points to a widget’s folder or repository."),
                detail: nil)
        }
        return Failure(
            cause: String(localized: "A widget was found, but BarShelf couldn’t read it."),
            fix: String(localized: "The widget’s author needs to fix its widget.json."),
            detail: details.joined(separator: "\n"))
    }

    /// A widget folder that discovery skipped, for an install summary: its
    /// folder and a plain reason. The parser's own message goes to the log.
    static func describeSkipped(_ failure: WidgetDiscovery.Failure) -> String {
        NSLog("barshelf: install skipped %@: %@", failure.relativePath, failure.reason)
        let reason = failure.reason.hasPrefix("invalid widget id")
            ? String(localized: "its widget ID isn’t valid")
            : String(localized: "its widget.json couldn’t be read")
        return "\(failure.relativePath): \(reason)"
    }

    static func isInstalled(id: String) -> Bool {
        HeadlessInstaller.isInstalled(id: id, in: widgetsInstallDirectory)
    }

    static func describe(_ candidate: WidgetDiscovery.Candidate) -> String {
        var line = "\(candidate.manifest.name) (\(candidate.manifest.id))"
        if let version = candidate.displayVersion {
            line += " v\(version)"
        }
        return line
    }

    private static func isSafeBundledName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed == (trimmed as NSString).lastPathComponent,
              trimmed != ".",
              trimmed != "..",
              !trimmed.contains("..")
        else { return false }
        return true
    }
}

enum WidgetInstallFlowError: Error, LocalizedError {
    case noDownloadCandidates
    case notHTTP(URL)
    case httpStatus(Int, URL)
    case downloadTooLarge(limitBytes: Int)
    case noWidgetsFound(details: [String])

    var errorDescription: String? {
        switch self {
        case .noDownloadCandidates:
            return String(localized: "no download URL could be derived from the input")
        case let .notHTTP(url):
            return String(localized: "unexpected non-HTTP response from \(url.absoluteString)")
        case let .httpStatus(code, url):
            return String(localized: "download failed (HTTP \(code)): \(url.absoluteString)")
        case let .downloadTooLarge(limit):
            return String(localized: "download exceeds the \(limit / (1024 * 1024)) MB limit")
        case let .noWidgetsFound(details):
            var message = String(localized: "no widget.json found in the archive")
            if !details.isEmpty {
                message += "\n" + details.joined(separator: "\n")
            }
            return message
        }
    }
}

// MARK: - GUI installer (menu item + barshelf:// deep link)

/// Interactive install: URL prompt → per-widget confirmation dialog (name /
/// version / permission summary) → completion summary. Installed files are
/// picked up by WidgetRuntime hot reload; `onInstalled` additionally asks the
/// runtime to rescan for the first-install case where the watch directory did
/// not exist at launch.
final class WidgetInstaller {
    static let shared = WidgetInstaller()

    /// Called on the main thread after at least one widget was installed.
    var onInstalled: (() -> Void)?

    /// Opens the popup after a multi-widget install summary is dismissed
    /// (main thread).
    var onOpenPopup: (() -> Void)?

    /// Opens the popup and jumps to / highlights the freshly installed widget
    /// after a single-widget install success (main thread).
    var onReveal: ((String) -> Void)?

    /// `barshelf://refresh?widget=<id>` routing hook (main thread). The
    /// integrator wires this to `WidgetRuntime.handleURLRefreshTrigger`. The
    /// argument is the optional `widget` query item (`nil` → refresh all
    /// url-trigger widgets).
    var onRefreshRequest: ((_ widgetID: String?) -> Void)?
    /// `barshelf://dock?profile=<id|name|number>`, `?next`, `?previous` (R15).
    var onDockRequest: ((_ query: [URLQueryItem]) -> Void)?
    /// `barshelf://accessibility` — the Accessibility drag-in helper.
    var onAccessibilityRequest: (() -> Void)?

    /// Menu entry point: "Install Widget from URL…".
    func promptForURL() {
        NSApp.activate()
        let prompt = WidgetInstallURLPrompt()
        guard let input = prompt.run() else { return }
        install(input: input)
    }

    /// Deep link entry point. Routes by host:
    /// - `barshelf://refresh?widget=<id>` → `onRefreshRequest` (no `widget`
    ///   query item → refresh all url-trigger widgets).
    /// - `barshelf://show?widget=<id>` → open the popup on that widget (a
    ///   click on a desktop widget).
    /// - `barshelf://accessibility` → the Accessibility drag-in helper.
    /// - anything else (`barshelf://install?url=…`, bare URLs) → install.
    func handleDeepLink(_ url: URL) {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let route = (components?.host ?? url.host
            ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
            .lowercased()
        if route == "show" {
            let widgetID = components?.queryItems?.first { $0.name == "widget" }?.value
            if let widgetID, !widgetID.isEmpty {
                onReveal?(widgetID)
            } else {
                onOpenPopup?()
            }
            return
        }
        if route == "dock" {
            onDockRequest?(components?.queryItems ?? [])
            return
        }
        if route == "accessibility" {
            onAccessibilityRequest?()
            return
        }
        if route == "refresh" {
            let widgetID = components?.queryItems?
                .first { $0.name == "widget" }?
                .value?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            onRefreshRequest?(widgetID?.isEmpty == true ? nil : widgetID)
            return
        }
        install(input: url.absoluteString)
    }

    /// `onInstalledOne`, when given, takes over the single-widget reveal:
    /// the Gallery keeps the user where they are and says where it went,
    /// instead of jumping to the popup.
    func install(input: String, onInstalledOne: ((String) -> Void)? = nil, completion: (() -> Void)? = nil) {
        let panel = DownloadProgressPanel()
        panel.show()
        let task = Task { @MainActor in
            do {
                let prepared = try await WidgetInstallFlow.prepare(input: input) {
                    received, expected in
                    DispatchQueue.main.async {
                        panel.update(received: received, expected: expected)
                    }
                }
                panel.close()
                defer { try? FileManager.default.removeItem(at: prepared.stagingRoot) }
                if self.processCandidates(prepared, onInstalledOne: onInstalledOne) {
                    completion?()
                }
            } catch is CancellationError {
                panel.close()
            } catch {
                panel.close()
                self.showError(error)
            }
        }
        panel.onCancel = { task.cancel() }
    }

    func install(registryEntry entry: RegistryWidgetEntry, onInstalledOne: ((String) -> Void)? = nil, completion: (() -> Void)? = nil) {
        if let bundled = entry.install.bundled,
           let directory = WidgetInstallFlow.bundledWidgetDirectory(named: bundled) {
            installBundledWidget(at: directory, onInstalledOne: onInstalledOne, completion: completion)
            return
        }
        install(input: entry.install.url, onInstalledOne: onInstalledOne, completion: completion)
    }

    /// Installs a registry pack: one confirmation for the set, then each
    /// widget in turn, then one summary. Only the widget each entry names is
    /// taken from its source (a repository with several widgets adds just
    /// that one). Nothing is approved here: every widget still asks for its
    /// permissions on its card, as when installed alone.
    func installPack(name: String, entries: [RegistryWidgetEntry], completion: (() -> Void)? = nil) {
        // One pack at a time: two overlapping packs could both decide a shared
        // widget is missing.
        guard !packInFlight, !entries.isEmpty, confirmPack(name: name, entries: entries) else { return }
        packInFlight = true
        let panel = DownloadProgressPanel(
            title: String(localized: "Installing \(name)", comment: "Progress panel title while a widget pack installs"),
            message: String(localized: "Getting widgets…")
        )
        panel.show()
        let task = Task { @MainActor in
            var installed: [String] = []
            var failed: [String] = []
            var done: Set<String> = []
            for entry in entries {
                // Let Cancel be handled between widgets, bundled ones included.
                await Task.yield()
                if Task.isCancelled { break }
                panel.setMessage(String(localized: "Installing \(entry.name)…", comment: "Progress while one widget of a pack installs"))
                do {
                    let discovery: WidgetDiscovery.Result
                    var staging: URL?
                    if let bundled = entry.install.bundled,
                       let directory = WidgetInstallFlow.bundledWidgetDirectory(named: bundled) {
                        discovery = try WidgetInstallFlow.discoverBundledWidget(at: directory)
                    } else {
                        let prepared = try await WidgetInstallFlow.prepare(input: entry.install.url) { _, _ in }
                        discovery = prepared.discovery
                        staging = prepared.stagingRoot
                    }
                    defer { if let staging { try? FileManager.default.removeItem(at: staging) } }
                    guard let candidate = discovery.candidates.first(where: { $0.manifest.id == entry.id }) else {
                        failed.append("\(entry.name): \(String(localized: "It wasn’t found where the gallery says it is. Try again later."))")
                        done.insert(entry.id)
                        continue
                    }
                    // Checked again at the last moment: a pack adds, it never
                    // replaces. Something else (the CLI, a scan that had not
                    // caught up) may have installed it meanwhile.
                    try Task.checkCancellation()
                    if WidgetInstallFlow.isInstalled(id: entry.id) {
                        done.insert(entry.id)
                        continue
                    }
                    try WidgetInstallFlow.install(candidate: candidate)
                    done.insert(entry.id)
                    installed.append(String(localized: "Installed \(WidgetInstallFlow.describe(candidate))", comment: "A widget install finished; the argument names the widget."))
                } catch is CancellationError {
                    break
                } catch {
                    NSLog("barshelf: pack install of %@ failed: %@", entry.id, String(describing: error))
                    failed.append("\(entry.name): \(WidgetInstallFlow.userFacingDescription(of: error))")
                    done.insert(entry.id)
                }
            }
            let cancelled = entries.filter { !done.contains($0.id) }
            if !cancelled.isEmpty {
                failed.append(String(localized: "Cancelled: \(cancelled.map(\.name).joined(separator: ", "))",
                                     comment: "Pack install summary: widgets not installed because the install was cancelled"))
            }
            self.packInFlight = false
            panel.close()
            if !installed.isEmpty {
                self.onInstalled?()
                completion?()
            }
            self.showSummary(installed: installed, failed: failed)
            if !installed.isEmpty { self.onOpenPopup?() }
        }
        panel.onCancel = { task.cancel() }
    }

    /// One confirmation for a pack: what it adds, and what each widget says
    /// it will ask for (the registry's summary, display-only: the installed
    /// manifest is what each widget's card asks about).
    private func confirmPack(name: String, entries: [RegistryWidgetEntry]) -> Bool {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = String(localized: "Install the \(name) pack?", comment: "Confirmation title for installing a widget pack")
        var lines: [String] = [
            entries.count == 1
                ? String(localized: "Adds 1 widget:")
                : String(localized: "Adds \(entries.count) widgets:"),
        ]
        for entry in entries {
            var line = "• \(entry.name)"
            if let requires = entry.requires, !requires.isEmpty {
                line += " — " + String(localized: "needs \(requires)", comment: "Pack confirmation: an external tool a widget needs")
            }
            lines.append(line)
            let asks = Self.permissionPhrases(entry.permissions)
            if !asks.isEmpty {
                lines.append("   " + String(localized: "Will ask to: \(asks.joined(separator: ", "))",
                                            comment: "Pack confirmation: what a widget declares it will ask for"))
            }
        }
        lines.append("")
        lines.append(String(localized: "Installing grants no new permissions. A widget that needs one asks on its card before it runs."))
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: String(localized: "Install"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    private var packInFlight = false

    /// The registry's display-only permission summary as short phrases.
    static func permissionPhrases(_ permissions: RegistryWidgetEntry.PermissionsSummary?) -> [String] {
        guard let permissions else { return [] }
        var phrases: [String] = []
        if let exec = permissions.exec, !exec.isEmpty {
            phrases.append(String(localized: "run \(exec.joined(separator: ", "))", comment: "Pack confirmation: commands"))
        }
        if let hosts = permissions.network, !hosts.isEmpty {
            phrases.append(String(localized: "connect to \(hosts.joined(separator: ", "))", comment: "Pack confirmation: hosts"))
        }
        if let paths = permissions.readPaths, !paths.isEmpty {
            phrases.append(String(localized: "read \(paths.joined(separator: ", "))", comment: "Pack confirmation: paths"))
        }
        if permissions.notifications == true { phrases.append(String(localized: "send notifications", comment: "Pack confirmation")) }
        if permissions.keychain == true { phrases.append(String(localized: "use Keychain secrets", comment: "Pack confirmation")) }
        return phrases
    }

    // MARK: internals (main thread)

    private func installBundledWidget(at directory: URL, onInstalledOne: ((String) -> Void)?, completion: (() -> Void)?) {
        do {
            let discovery = try WidgetInstallFlow.discoverBundledWidget(at: directory)
            if processDiscovery(discovery, onInstalledOne: onInstalledOne) {
                completion?()
            }
        } catch {
            showError(error)
        }
    }

    @discardableResult
    private func processCandidates(_ prepared: WidgetInstallFlow.Prepared, onInstalledOne: ((String) -> Void)? = nil) -> Bool {
        processDiscovery(prepared.discovery, onInstalledOne: onInstalledOne)
    }

    @discardableResult
    private func processDiscovery(_ discovery: WidgetDiscovery.Result, onInstalledOne: ((String) -> Void)? = nil) -> Bool {
        guard !discovery.candidates.isEmpty else {
            showError(WidgetInstallFlowError.noWidgetsFound(
                details: discovery.failures.map { "\($0.relativePath): \($0.reason)" }
            ))
            return false
        }

        var installed: [String] = []
        var installedIDs: [String] = []
        var failed: [String] = discovery.failures.map(WidgetInstallFlow.describeSkipped)

        for candidate in discovery.candidates {
            let isUpdate = WidgetInstallFlow.isInstalled(id: candidate.manifest.id)
            guard confirmInstall(candidate, isUpdate: isUpdate) else { continue }
            do {
                try WidgetInstallFlow.install(candidate: candidate)
                let description = WidgetInstallFlow.describe(candidate)
                installed.append(
                    isUpdate
                        ? String(localized: "Updated \(description)", comment: "A widget update finished; the argument names the widget.")
                        : String(localized: "Installed \(description)", comment: "A widget install finished; the argument names the widget.")
                )
                installedIDs.append(candidate.manifest.id)
            } catch {
                NSLog("barshelf: install of %@ failed: %@", candidate.manifest.id, String(describing: error))
                failed.append(
                    "\(candidate.manifest.name): \(WidgetInstallFlow.userFacingDescription(of: error))"
                )
            }
        }

        if !installed.isEmpty {
            onInstalled?()
        }

        // Post-install reveal: a clean single-widget install skips the summary
        // alert and jumps straight to the new widget in the popup. Anything
        // else (multiple widgets, or partial failures) keeps the summary and
        // then opens the popup so the result is visible.
        if installedIDs.count == 1, failed.isEmpty {
            if let onInstalledOne {
                onInstalledOne(installedIDs[0])
            } else {
                onReveal?(installedIDs[0])
            }
        } else {
            showSummary(installed: installed, failed: failed)
            if !installed.isEmpty {
                onOpenPopup?()
            }
        }
        return !installed.isEmpty
    }

    /// Per-widget confirmation: name, version, permission summary (exec /
    /// keychain / notifications), install-vs-update wording.
    private func confirmInstall(
        _ candidate: WidgetDiscovery.Candidate, isUpdate: Bool
    ) -> Bool {
        NSApp.activate()

        let alert = NSAlert()
        alert.messageText = isUpdate
            ? String(localized: "Update widget \"\(candidate.manifest.name)\"?")
            : String(localized: "Install widget \"\(candidate.manifest.name)\"?")

        var info: [String] = []
        if let version = candidate.displayVersion {
            info.append(String(localized: "Version \(version)"))
        }
        let permissions = WidgetPermissionSummary.lines(
            for: candidate.manifest, workflow: InstallCandidate.loadWorkflow(for: candidate)
        ).map(\.text)
        if permissions.isEmpty {
            info.append(String(localized: "Requested permissions: none"))
        } else {
            info.append(String(localized: "Requested permissions:"))
            info.append(contentsOf: permissions.map { "• \($0)" })
            info.append(String(localized: "Nothing runs automatically — each permission still requires your approval on the widget's first run."))
        }
        if isUpdate {
            info.append(String(localized: "An existing install will be replaced. Changed permissions must be approved again before they take effect."))
        }
        alert.informativeText = info.joined(separator: "\n")
        alert.addButton(withTitle: isUpdate ? String(localized: "Update") : String(localized: "Install"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func showSummary(installed: [String], failed: [String]) {
        guard !installed.isEmpty || !failed.isEmpty else { return }
        let alert = NSAlert()
        alert.alertStyle = failed.isEmpty ? .informational : .warning
        alert.messageText = installed.isEmpty
            ? String(localized: "No widgets installed")
            : installed.count == 1
                ? String(localized: "Installed 1 widget")
                : String(localized: "Installed \(installed.count) widgets")
        var lines = installed
        if !failed.isEmpty {
            lines.append(String(localized: "Failed:"))
            lines.append(contentsOf: failed.map { "• \($0)" })
        }
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: String(localized: "OK"))
        alert.runModal()
    }

    private func showError(_ error: Error) {
        let failure = WidgetInstallFlow.explainFailure(error)
        NSLog("barshelf: widget install failed: %@", failure.detail ?? String(describing: error))
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Couldn’t install the widget")
        alert.informativeText = failure.message
        alert.addButton(withTitle: String(localized: "OK"))
        if failure.detail != nil {
            alert.addButton(withTitle: String(localized: "Copy Details"))
        }
        if alert.runModal() == .alertSecondButtonReturn, let detail = failure.detail {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(detail, forType: .string)
        }
    }
}

// MARK: - Download progress panel

/// Small non-modal floating panel shown during a URL install's download.
/// Determinate when the server reports Content-Length, indeterminate
/// otherwise; the Cancel button aborts the in-flight download.
/// All access happens on the main thread (creation, updates dispatched to
/// main, cancel from the button); `@unchecked Sendable` lets the progress
/// callback capture it across the download's concurrency domain.
final class DownloadProgressPanel: NSObject, @unchecked Sendable {
    /// Invoked on the main thread when the user presses Cancel.
    var onCancel: (() -> Void)?

    private var panel: NSPanel?
    private let indicator = NSProgressIndicator()
    private let label: NSTextField
    private let title: String

    /// The app update reuses this panel, so the wording is a parameter — the
    /// determinate bar and the working Cancel are the point of sharing it.
    init(
        title: String = String(localized: "Installing Widget"),
        message: String = String(localized: "Downloading widget…")
    ) {
        self.title = title
        self.label = NSTextField(labelWithString: message)
        super.init()
    }

    /// Switches the panel to a phase that has no byte count (verifying,
    /// installing), returning the bar to its indeterminate state.
    func setMessage(_ message: String) {
        guard let panel, panel.isVisible else { return }
        label.stringValue = message
        if !indicator.isIndeterminate {
            indicator.isIndeterminate = true
        }
        indicator.startAnimation(nil)
    }

    func show() {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 104))

        label.frame = NSRect(x: 20, y: 66, width: 300, height: 18)
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingTail
        content.addSubview(label)

        indicator.frame = NSRect(x: 20, y: 44, width: 300, height: 16)
        indicator.style = .bar
        indicator.isIndeterminate = true
        indicator.startAnimation(nil)
        content.addSubview(indicator)

        let cancel = NSButton(
            title: String(localized: "Cancel"), target: self, action: #selector(cancelClicked)
        )
        cancel.bezelStyle = .rounded
        cancel.frame = NSRect(x: 232, y: 8, width: 88, height: 28)
        content.addSubview(cancel)

        let panel = NSPanel(
            contentRect: content.frame,
            styleMask: [.titled, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = title
        panel.contentView = content
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.center()
        self.panel = panel

        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    func update(received: Int64, expected: Int64) {
        guard let panel, panel.isVisible else { return }
        if expected > 0 {
            if indicator.isIndeterminate {
                indicator.stopAnimation(nil)
                indicator.isIndeterminate = false
            }
            indicator.minValue = 0
            indicator.maxValue = Double(expected)
            indicator.doubleValue = Double(min(received, expected))
            label.stringValue =
                String(localized: "Downloading… \(Self.megabytes(received)) / \(Self.megabytes(expected))")
        } else {
            if !indicator.isIndeterminate {
                indicator.isIndeterminate = true
                indicator.startAnimation(nil)
            }
            label.stringValue = String(localized: "Downloading… \(Self.megabytes(received))")
        }
    }

    func close() {
        indicator.stopAnimation(nil)
        panel?.orderOut(nil)
        panel = nil
    }

    @objc private func cancelClicked() {
        onCancel?()
        close()
    }

    private static func megabytes(_ bytes: Int64) -> String {
        String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
    }
}

// MARK: - App-binary headless mode (`barshelf-app install <url>`)

/// Headless install used by `BarShelf.app/Contents/MacOS/barshelf-app install
/// <url>` — no dialogs; the permission summary is printed to stdout instead.
/// Exit code 0 on success, 1 on any failure.
enum WidgetInstallCLI {
    static func run(arguments: [String]) -> Int32 {
        guard arguments.count == 1, let input = arguments.first, !input.isEmpty else {
            printError("usage: barshelf-app install <url>")
            printError("  <url>: GitHub repo URL, .zip/.mbw archive URL, or barshelf://install?url=…")
            return 1
        }

        final class ExitCodeBox: @unchecked Sendable { var value: Int32 = 1 }
        let box = ExitCodeBox()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            box.value = await performInstall(input: input)
            semaphore.signal()
        }
        semaphore.wait()
        return box.value
    }

    private static func performInstall(input: String) async -> Int32 {
        do {
            let prepared = try await WidgetInstallFlow.prepare(input: input)
            defer { try? FileManager.default.removeItem(at: prepared.stagingRoot) }

            print("source: \(prepared.source.displayName)")
            let discovery = prepared.discovery
            for failure in discovery.failures {
                printError("skipped \(failure.relativePath): \(failure.reason)")
            }
            guard !discovery.candidates.isEmpty else {
                printError(WidgetInstallFlowError.noWidgetsFound(details: [])
                    .localizedDescription)
                return 1
            }

            var installedCount = 0
            var failureCount = discovery.failures.count
            for candidate in discovery.candidates {
                print("widget: \(WidgetInstallFlow.describe(candidate))")
                let permissions = InstallCandidate(candidate).permissionSummary
                if permissions.isEmpty {
                    print("  permissions: none")
                } else {
                    for line in permissions {
                        print("  permission: \(line)")
                    }
                    print("  note: permissions require approval on the widget's first run")
                }
                do {
                    let wasUpdate = try WidgetInstallFlow.install(candidate: candidate)
                    // An update replaces the copy in place, which need not be
                    // named after the id (seeded starters live in `today/`).
                    let destination = (HeadlessInstaller.installedPackages(
                        in: WidgetInstallFlow.widgetsInstallDirectory
                    )[candidate.manifest.id]?.directory
                        ?? WidgetInstallFlow.widgetsInstallDirectory.appendingPathComponent(candidate.manifest.id)).path
                    print("  \(wasUpdate ? "updated" : "installed") → \(destination)")
                    installedCount += 1
                } catch {
                    printError("  failed: \(error.localizedDescription)")
                    failureCount += 1
                }
            }

            print("done: \(installedCount) installed, \(failureCount) failed")
            return (installedCount > 0 && failureCount == 0) ? 0 : 1
        } catch {
            printError("error: \(error.localizedDescription)")
            return 1
        }
    }

    private static func printError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
