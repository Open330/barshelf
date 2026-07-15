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
            InstallCandidate(candidate), into: widgetsInstallDirectory
        )
        return isUpdate
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

    /// Menu entry point: "Install Widget from URL…".
    func promptForURL() {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Install Widget from URL"
        alert.informativeText =
            "Enter a GitHub repository URL or a direct .zip/.mbw archive URL."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        field.placeholderString = "https://github.com/user/widget-repo"
        alert.accessoryView = field
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let input = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }
        install(input: input)
    }

    /// Deep link entry point. Routes by host:
    /// - `barshelf://refresh?widget=<id>` → `onRefreshRequest` (no `widget`
    ///   query item → refresh all url-trigger widgets).
    /// - anything else (`barshelf://install?url=…`, bare URLs) → install.
    func handleDeepLink(_ url: URL) {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let route = (components?.host ?? url.host
            ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
            .lowercased()
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

    func install(input: String, completion: (() -> Void)? = nil) {
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
                if self.processCandidates(prepared) {
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

    func install(registryEntry entry: RegistryWidgetEntry, completion: (() -> Void)? = nil) {
        if let bundled = entry.install.bundled,
           let directory = WidgetInstallFlow.bundledWidgetDirectory(named: bundled) {
            installBundledWidget(at: directory, completion: completion)
            return
        }
        install(input: entry.install.url, completion: completion)
    }

    // MARK: internals (main thread)

    private func installBundledWidget(at directory: URL, completion: (() -> Void)?) {
        do {
            let discovery = try WidgetInstallFlow.discoverBundledWidget(at: directory)
            if processDiscovery(discovery) {
                completion?()
            }
        } catch {
            showError(error)
        }
    }

    @discardableResult
    private func processCandidates(_ prepared: WidgetInstallFlow.Prepared) -> Bool {
        processDiscovery(prepared.discovery)
    }

    @discardableResult
    private func processDiscovery(_ discovery: WidgetDiscovery.Result) -> Bool {
        guard !discovery.candidates.isEmpty else {
            showError(WidgetInstallFlowError.noWidgetsFound(
                details: discovery.failures.map { "\($0.relativePath): \($0.reason)" }
            ))
            return false
        }

        var installed: [String] = []
        var installedIDs: [String] = []
        var failed: [String] = discovery.failures.map {
            "\($0.relativePath): \($0.reason)"
        }

        for candidate in discovery.candidates {
            let isUpdate = WidgetInstallFlow.isInstalled(id: candidate.manifest.id)
            guard confirmInstall(candidate, isUpdate: isUpdate) else { continue }
            do {
                try WidgetInstallFlow.install(candidate: candidate)
                installed.append(
                    (isUpdate ? "Updated " : "Installed ")
                        + WidgetInstallFlow.describe(candidate)
                )
                installedIDs.append(candidate.manifest.id)
            } catch {
                failed.append(
                    "\(candidate.manifest.id): \(error.localizedDescription)"
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
            onReveal?(installedIDs[0])
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
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = isUpdate
            ? "Update widget \"\(candidate.manifest.name)\"?"
            : "Install widget \"\(candidate.manifest.name)\"?"

        var info: [String] = ["id: \(candidate.manifest.id)"]
        if let version = candidate.displayVersion {
            info.append("version: \(version)")
        }
        let permissions = WidgetDiscovery.permissionSummary(for: candidate.manifest)
        if permissions.isEmpty {
            info.append("Requested permissions: none")
        } else {
            info.append("Requested permissions:")
            info.append(contentsOf: permissions.map { "• \($0)" })
            info.append("Nothing runs automatically — each permission still "
                + "requires your approval on the widget's first run.")
        }
        if isUpdate {
            info.append("An existing install will be replaced. Changed "
                + "permissions must be approved again before they take effect.")
        }
        alert.informativeText = info.joined(separator: "\n")
        alert.addButton(withTitle: isUpdate ? "Update" : "Install")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func showSummary(installed: [String], failed: [String]) {
        guard !installed.isEmpty || !failed.isEmpty else { return }
        let alert = NSAlert()
        alert.alertStyle = failed.isEmpty ? .informational : .warning
        alert.messageText = installed.isEmpty
            ? "No widgets installed"
            : "Installed \(installed.count) widget\(installed.count == 1 ? "" : "s")"
        var lines = installed
        if !failed.isEmpty {
            lines.append("Failed:")
            lines.append(contentsOf: failed.map { "• \($0)" })
        }
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func showError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Widget install failed"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        alert.runModal()
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
    private let label = NSTextField(labelWithString: "Downloading widget…")

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
            title: "Cancel", target: self, action: #selector(cancelClicked)
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
        panel.title = "Installing Widget"
        panel.contentView = content
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.center()
        self.panel = panel

        NSApp.activate(ignoringOtherApps: true)
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
                "Downloading… \(Self.megabytes(received)) / \(Self.megabytes(expected))"
        } else {
            if !indicator.isIndeterminate {
                indicator.isIndeterminate = true
                indicator.startAnimation(nil)
            }
            label.stringValue = "Downloading… \(Self.megabytes(received))"
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
                let permissions = WidgetDiscovery.permissionSummary(for: candidate.manifest)
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
                    let destination = WidgetInstallFlow.widgetsInstallDirectory
                        .appendingPathComponent(candidate.manifest.id).path
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
