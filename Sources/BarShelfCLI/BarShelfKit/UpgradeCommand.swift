import Foundation
import MenubucketCore

/// `barshelf upgrade` — brings the CLI and BarShelf.app up to the latest
/// published release.
///
/// The CLI and the app are versioned together and released together, so they
/// are upgraded together: a machine that updated one and forgot the other is
/// how `release.sh` came to need a version-drift check in the first place.
///
/// It reuses the app's updater wholesale (`ReleaseFeed`, `CodeSignature`,
/// `UpdateInstaller`), so a terminal upgrade and **Check for Updates…** accept
/// and refuse exactly the same builds. Each component is anchored to its *own*
/// current signature: the replacement has to be a Developer ID build from the
/// team that signed the copy being replaced, whether or not that is the team
/// that signed the `barshelf` running this command.
enum UpgradeCommand {
    static let usage = """
        usage: barshelf upgrade [--check] [--yes] [--restart] [--app <path>]

          --check          Report what is available and exit without changing anything.
          --yes, -y        Do not ask for confirmation.
          --restart        Quit and reopen BarShelf.app after updating it.
          --app <path>     The BarShelf.app to update (default: /Applications,
                           then ~/Applications).
        """

    /// Where an installed BarShelf.app is looked for, in order.
    static let appSearchPaths = [
        "/Applications/BarShelf.app",
        "~/Applications/BarShelf.app",
    ]

    struct Options {
        var checkOnly = false
        var assumeYes = false
        var restart = false
        var appPath: String?
    }

    static func parse(_ arguments: [String]) -> Options? {
        var options = Options()
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--check", "-n":
                options.checkOnly = true
                index += 1
            case "--yes", "-y":
                options.assumeYes = true
                index += 1
            case "--restart":
                options.restart = true
                index += 1
            case "--app":
                guard index + 1 < arguments.count else { return nil }
                options.appPath = arguments[index + 1]
                index += 2
            default:
                return nil
            }
        }
        return options
    }

    // MARK: - Entry point

    static func run(arguments: [String]) -> Int32 {
        guard let options = parse(arguments) else {
            BarShelfMain.printError(usage)
            return 1
        }
        return BarShelfMain.runBlocking { await perform(options) }
    }

    private static func perform(_ options: Options) async -> Int32 {
        let release: ReleaseFeed.Release
        do {
            release = try await ReleaseFeed.latest()
        } catch {
            BarShelfMain.printError("error: \(error.localizedDescription)")
            return 1
        }
        let latest = release.version

        var source = ReleaseFeed.repository
        if ReleaseFeed.isOverridden { source += " (overridden)" }
        print("latest release: \(latest)  [\(source)]")

        let cli = inspectCLI(latest: latest)
        let app = inspectApp(latest: latest, explicitPath: options.appPath)
        for component in [cli, app] {
            // The column padding is for alignment, not for trailing blanks.
            print(component.line.replacingOccurrences(
                of: " +$", with: "", options: .regularExpression
            ))
            // A blocker only matters when there is something it is blocking;
            // otherwise "up to date" followed by a warning reads as a problem.
            guard component.needsUpdate || component.paths.isEmpty else { continue }
            for note in component.notes { print("    \(note)") }
        }

        let pending = [cli, app].filter { $0.needsUpdate && $0.blocker == nil }
        let blocked = [cli, app].contains { $0.needsUpdate && $0.blocker != nil }

        // `--check` only reports, so it succeeds whenever the report is
        // accurate — including when the news is "you cannot update from here".
        if options.checkOnly {
            if !pending.isEmpty {
                print("run `barshelf upgrade` to install.")
            } else if blocked {
                print("an update exists but cannot be installed from here — see above.")
            } else {
                print("everything is up to date.")
            }
            return 0
        }

        guard !pending.isEmpty else {
            if blocked {
                print("nothing to do here — see the notes above.")
                return 1
            }
            print("everything is up to date.")
            return 0
        }
        guard confirmed(pending, options: options) else {
            print("cancelled.")
            return 0
        }

        var updated = 0
        var failed = 0
        // The app first: if the CLI swap then fails, the user re-runs this same
        // command and only the CLI is left to do.
        for component in pending.sorted(by: { $0.kind.order < $1.kind.order }) {
            do {
                switch component.kind {
                case .app:
                    try await updateApp(component, release: release, restart: options.restart)
                case .cli:
                    try await updateCLI(component, release: release)
                }
                updated += 1
            } catch {
                BarShelfMain.printError("  failed: \(describe(error))")
                failed += 1
            }
        }
        print("done: \(updated) updated, \(failed) failed"
            + (blocked ? ", 1 skipped" : ""))
        // Exiting 0 with something still out of date would tell a script the
        // machine is current when it is not.
        return (failed == 0 && !blocked) ? 0 : 1
    }

    // MARK: - What is installed

    enum Kind {
        case cli
        case app

        var order: Int { self == .app ? 0 : 1 }
        var label: String { self == .app ? "app" : "cli" }
    }

    struct Component {
        var kind: Kind
        /// Installed paths this component covers. Empty when it is not installed.
        var paths: [URL] = []
        var version: String?
        /// The Developer ID team that signed the installed copy.
        var team: String?
        var bundleID: String?
        var needsUpdate = false
        var blocker: String?
        var notes: [String] = []
        var line = ""
    }

    static func inspectCLI(latest: String) -> Component {
        var component = Component(kind: .cli)
        component.version = BarShelfMain.version
        component.needsUpdate = ReleaseFeed.isNewer(latest, than: BarShelfMain.version)
        component.team = CodeSignature.hostDeveloperIDTeam()

        guard let running = runningToolURL() else {
            component.blocker = "unknown location"
            component.notes.append(
                "This process cannot tell where its own binary lives, so it"
                    + " cannot replace it. Reinstall the CLI from the release."
            )
            component.line = describe(component, latest: latest, location: "unknown location")
            return component
        }

        component.paths = companionTools(of: running)
        guard !component.paths.isEmpty else {
            // The archive is unpacked by member name, so a binary that has been
            // renamed has nothing to be matched against.
            component.blocker = "not named like a release binary"
            component.notes.append(
                "\(running.lastPathComponent) is not "
                    + CommandLineToolInstaller.toolNames.joined(separator: " or ")
                    + ", so it cannot be matched to a release binary."
            )
            component.line = describe(component, latest: latest, location: running.path)
            return component
        }

        // `bsf` ships with `barshelf` and has to move with it, so a sibling
        // left behind counts as out of date even when the release does not.
        if companionsAreStale(
            component.paths, running: running,
            expected: BarShelfMain.version, team: component.team
        ) {
            component.needsUpdate = true
        }

        let directory = running.deletingLastPathComponent()
        if component.team == nil {
            component.blocker = "not a Developer ID build"
            component.notes.append(
                "This barshelf was built locally, so an update cannot be verified"
                    + " against it. Download the release CLI manually."
            )
        } else if !FileManager.default.isWritableFile(atPath: directory.path) {
            component.blocker = "\(directory.path) is not writable"
            component.notes.append(
                "Re-run with sudo, or install the CLI somewhere you own."
            )
        }
        component.line = describe(component, latest: latest, location: listed(component.paths))
        return component
    }

    static func inspectApp(latest: String, explicitPath: String?) -> Component {
        var component = Component(kind: .app)
        guard let app = installedApp(explicitPath: explicitPath) else {
            component.line = "  app  " + pad("not installed", to: 24)
            component.notes.append(
                explicitPath.map { "No application at \($0)." }
                    ?? ("No BarShelf.app in /Applications or ~/Applications."
                        + " Pass --app <path> if it lives elsewhere.")
            )
            return component
        }
        component.paths = [app]
        component.version = UpdateInstaller.installedVersion(of: app)
        component.team = CodeSignature.developerIDTeam(of: app)
        component.bundleID = UpdateInstaller.bundleIdentifier(of: app)
        component.needsUpdate = ReleaseFeed.isNewer(latest, than: component.version ?? "0.0.0")

        // The same eligibility rules the app applies to itself, so the terminal
        // and the menu never disagree about whether a copy may be replaced.
        // `blocker`'s sandbox probe reads *this* process's environment and so
        // never fires here; a Mac App Store build is caught by the check above
        // instead, since it is Apple-signed rather than Developer ID signed.
        if let blocker = UpdateInstaller.blocker(appURL: app, hostTeam: component.team) {
            component.blocker = blocker.message
            switch blocker {
            case .homebrewManaged:
                component.notes.append(blocker.message)
                component.notes.append("Update it the way you installed it: "
                    + UpdateInstaller.homebrewUpgradeCommand)
            default:
                component.notes.append(blocker.message)
            }
        }
        component.line = describe(component, latest: latest, location: app.path)
        return component
    }

    private static func describe(
        _ component: Component, latest: String, location: String
    ) -> String {
        let current = component.version ?? "unknown"
        var state = component.needsUpdate ? "\(current) → \(latest)" : "\(current) up to date"
        if component.needsUpdate, component.blocker != nil { state += " (blocked)" }
        return "  \(component.kind.label)  \(pad(state, to: 24))  \(location)"
    }

    private static func pad(_ text: String, to width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }

    private static func listed(_ paths: [URL]) -> String {
        paths.map(\.path).joined(separator: ", ")
    }

    // MARK: - Locating what to replace

    /// This executable, with symlinks resolved — a `~/.local/bin/barshelf` that
    /// points into a release directory has to replace the real file, not the
    /// link to it.
    static func runningToolURL() -> URL? {
        Bundle.main.executableURL?.resolvingSymlinksInPath().standardizedFileURL
    }

    /// `barshelf` and its `bsf` sibling, deduplicated by resolved path so a
    /// `bsf` symlinked to `barshelf` is not replaced twice.
    static func companionTools(of running: URL) -> [URL] {
        let directory = running.deletingLastPathComponent()
        var found: [URL] = []
        for name in CommandLineToolInstaller.toolNames {
            let candidate = directory.appendingPathComponent(name)
                .resolvingSymlinksInPath().standardizedFileURL
            guard FileManager.default.fileExists(atPath: candidate.path) else { continue }
            // A `bsf` symlinked to `barshelf` resolves to the same file; adding
            // it twice would have the second swap replace what the first
            // installed.
            guard !found.contains(candidate) else { continue }
            found.append(candidate)
        }
        return found
    }

    /// Whether a sibling tool is out of step with this one — the case where the
    /// release says "up to date" but half the CLI is old. `bsf` and `barshelf`
    /// are built and released as a pair, and `release.sh` refuses to package
    /// them at different versions, so they should never disagree on a machine.
    static func companionsAreStale(
        _ paths: [URL], running: URL, expected: String, team: String?
    ) -> Bool {
        paths.contains { path in
            guard path != running else { return false }
            // Nothing to compare against on a locally built CLI, and it cannot
            // be updated in place anyway — do not report a phantom "0.2.1 →
            // 0.2.1" at someone running from `.build`.
            guard let team else { return false }
            // Asking a binary its version means running it. Only ask one that
            // is already a Developer ID build from the same team; anything else
            // is replaced rather than interrogated.
            guard CodeSignature.isSigned(path, by: team) else { return true }
            return toolVersion(at: path) != expected
        }
    }

    /// `<tool> --version` → `"0.2.1"`, or nil when it cannot be asked.
    ///
    /// Only ever pointed at a binary whose Developer ID signature has already
    /// been checked, so a blocking read cannot be wedged by hostile code.
    static func toolVersion(at url: URL) -> String? {
        let process = Process()
        process.executableURL = url
        process.arguments = ["--version"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?
            .split(separator: " ").last?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func installedApp(explicitPath: String?) -> URL? {
        let candidates = explicitPath.map { [$0] } ?? appSearchPaths
        for candidate in candidates {
            let url = URL(fileURLWithPath: (candidate as NSString).expandingTildeInPath)
                .standardizedFileURL
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    // MARK: - Doing the work

    private static func confirmed(_ pending: [Component], options: Options) -> Bool {
        if options.assumeYes { return true }
        let names = pending.map { $0.kind == .app ? "BarShelf.app" : "the barshelf CLI" }
        let question = "Update \(names.joined(separator: " and "))?"
        guard isatty(fileno(stdin)) != 0 else {
            print("\(question) (non-interactive input — proceeding;"
                + " use --yes to silence this note)")
            return true
        }
        print("\(question) [y/N] ", terminator: "")
        let answer = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return answer == "y" || answer == "yes"
    }

    private static func updateApp(
        _ component: Component, release: ReleaseFeed.Release, restart: Bool
    ) async throws {
        let version = release.version
        guard let target = component.paths.first else { return }
        guard let team = component.team else { throw UpdateInstaller.Failure.hostNotSigned }
        let name = ReleaseFeed.appAssetName(version: version)
        guard let asset = release.asset(named: name)?.url else {
            throw CLIUpgradeError.assetMissing(name)
        }

        print("updating BarShelf.app → \(version)")
        let archive = try await downloadReporting(asset, named: name)
        defer { try? FileManager.default.removeItem(at: archive) }
        print("  verifying signature, notarization, and identity…")
        let installed = try UpdateInstaller.install(
            archive: archive,
            replacing: target,
            expectedTeam: team,
            expectedBundleID: component.bundleID
        )
        print("  installed → \(target.path) (\(installed ?? version))")
        if let installed, installed != version {
            BarShelfMain.printError(
                "  warning: the release announced \(version) but the installed"
                    + " build reports \(installed)"
            )
        }
        finishApp(target, restart: restart)
    }

    private static func updateCLI(
        _ component: Component, release: ReleaseFeed.Release
    ) async throws {
        let version = release.version
        guard let team = component.team else { throw UpdateInstaller.Failure.hostNotSigned }
        let name = ReleaseFeed.cliAssetName(version: version)
        guard let asset = release.asset(named: name)?.url else {
            throw CLIUpgradeError.assetMissing(name)
        }

        print("updating the barshelf CLI → \(version)")
        let archive = try await downloadReporting(asset, named: name)
        defer { try? FileManager.default.removeItem(at: archive) }
        print("  verifying signatures…")
        try CommandLineToolInstaller.install(
            archive: archive, replacing: component.paths, expectedTeam: team
        )
        for path in component.paths {
            print("  installed → \(path.path) (\(toolVersion(at: path) ?? version))")
        }
    }

    /// Whether the app is running, and how to get the new build in front of the
    /// user. Replacing the bundle leaves the running process on the old code.
    private static func finishApp(_ app: URL, restart: Bool) {
        guard isRunning(app) else { return }
        guard restart else {
            print("  BarShelf.app is still running the previous build —"
                + " quit and reopen it, or re-run with --restart.")
            return
        }
        print("  restarting BarShelf.app…")
        _ = shell("/usr/bin/pkill", processSelector(for: app))
        for _ in 0..<50 where isRunning(app) {
            Thread.sleep(forTimeInterval: 0.1)
        }
        if shell("/usr/bin/open", ["-a", app.path]) != 0 {
            BarShelfMain.printError("  warning: could not reopen \(app.path)")
        }
    }

    static let appExecutableName = "barshelf-app"

    /// Matches the process launched from *this* bundle, and only this user's.
    ///
    /// Matching the executable name alone would report the copy in
    /// /Applications as "still running the previous build" after `--app`
    /// updated one somewhere else — and `--restart` would then quit the wrong
    /// app and reopen the other. Scoping to the user matters too: on a shared
    /// Mac another login's BarShelf is not ours to signal, and counting it
    /// would leave `--restart` waiting for a process it cannot kill.
    static func processSelector(for app: URL) -> [String] {
        let executable = app.appendingPathComponent("Contents/MacOS/\(appExecutableName)")
        return ["-U", String(getuid()), "-f", executable.path]
    }

    private static func isRunning(_ app: URL) -> Bool {
        shell("/usr/bin/pgrep", processSelector(for: app)) == 0
    }

    @discardableResult
    private static func shell(_ tool: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }

    private static func downloadReporting(_ asset: URL, named name: String) async throws -> URL {
        print("  downloading \(name)…")
        // Only on a terminal: a carriage return redrawing a line is noise in a
        // log or a pipe.
        guard isatty(fileno(stdout)) != 0 else { return try await ReleaseFeed.download(asset) }
        let url = try await ReleaseFeed.download(asset) { received, expected in
            guard expected > 0 else { return }
            let percent = Int(Double(received) / Double(expected) * 100)
            FileHandle.standardOutput.write(Data("\r    \(percent)%   ".utf8))
        }
        print("\r    100%  ")
        return url
    }

    enum CLIUpgradeError: Error, LocalizedError {
        case assetMissing(String)

        var errorDescription: String? {
            switch self {
            case let .assetMissing(name):
                return "This release publishes no \(name)."
            }
        }
    }

    private static func describe(_ error: Error) -> String {
        var text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        if let suggestion = (error as? LocalizedError)?.recoverySuggestion {
            text += " " + suggestion
        }
        // Every other failure happens before anything is swapped, so saying so
        // keeps a refusal from reading as a half-finished install. A failed
        // swap is the one case where that would be a lie.
        return midSwap(error) ? text : text + " Nothing was replaced."
    }

    private static func midSwap(_ error: Error) -> Bool {
        if case .replaceFailed = error as? UpdateInstaller.Failure { return true }
        if case .replaceFailed = error as? CommandLineToolInstaller.Failure { return true }
        return false
    }
}
