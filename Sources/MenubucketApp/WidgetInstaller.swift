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

    struct Prepared {
        let source: WidgetInstallSource
        /// Temporary extraction root — caller removes it when done.
        let stagingRoot: URL
        let discovery: WidgetDiscovery.Result
    }

    /// Parses the input, downloads the archive (20 MB cap), extracts it
    /// safely (50 MB cap) and discovers widget candidates.
    static func prepare(input: String) async throws -> Prepared {
        let session = try await HeadlessInstaller.fetchSession(input: input)
        return Prepared(
            source: session.source,
            stagingRoot: session.stagingRoot,
            discovery: session.discovery
        )
    }

    /// Tries each download candidate in order; HTTP 404 falls through to the
    /// next one (GitHub main → master fallback).
    static func download(source: WidgetInstallSource) async throws -> Data {
        try await HeadlessInstaller.download(source: source)
    }

    static func download(from url: URL) async throws -> Data {
        try await HeadlessInstaller.download(from: url)
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

// MARK: - GUI installer (menu item + menubucket:// deep link)

/// Interactive install: URL prompt → per-widget confirmation dialog (name /
/// version / permission summary) → completion summary. Installed files are
/// picked up by WidgetRuntime hot reload; `onInstalled` additionally asks the
/// runtime to rescan for the first-install case where the watch directory did
/// not exist at launch.
final class WidgetInstaller {
    static let shared = WidgetInstaller()

    /// Called on the main thread after at least one widget was installed.
    var onInstalled: (() -> Void)?

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

    /// Deep link entry point: `menubucket://install?url=…`.
    func handleDeepLink(_ url: URL) {
        install(input: url.absoluteString)
    }

    func install(input: String) {
        Task { @MainActor in
            do {
                let prepared = try await WidgetInstallFlow.prepare(input: input)
                defer { try? FileManager.default.removeItem(at: prepared.stagingRoot) }
                self.processCandidates(prepared)
            } catch {
                self.showError(error)
            }
        }
    }

    // MARK: internals (main thread)

    private func processCandidates(_ prepared: WidgetInstallFlow.Prepared) {
        let discovery = prepared.discovery
        guard !discovery.candidates.isEmpty else {
            showError(WidgetInstallFlowError.noWidgetsFound(
                details: discovery.failures.map { "\($0.relativePath): \($0.reason)" }
            ))
            return
        }

        var installed: [String] = []
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
            } catch {
                failed.append(
                    "\(candidate.manifest.id): \(error.localizedDescription)"
                )
            }
        }

        if !installed.isEmpty {
            onInstalled?()
        }
        showSummary(installed: installed, failed: failed)
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

// MARK: - CLI mode (`menubucket install <url>`)

/// Headless install used by `MenuBucket.app/Contents/MacOS/menubucket install
/// <url>` — no dialogs; the permission summary is printed to stdout instead.
/// Exit code 0 on success, 1 on any failure.
enum WidgetInstallCLI {
    static func run(arguments: [String]) -> Int32 {
        guard arguments.count == 1, let input = arguments.first, !input.isEmpty else {
            printError("usage: menubucket install <url>")
            printError("  <url>: GitHub repo URL, .zip/.mbw archive URL, or menubucket://install?url=…")
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
