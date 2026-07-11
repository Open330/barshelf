import Foundation
import MenubucketCore

/// barshelf — BarShelf developer CLI (R06 common contract 3).
///
/// Plain-text output, errors on stderr, exit 0 on success / 1 on failure.
public enum BarShelfMain {
    public static let version = "0.1.2"

    public static let usage = """
        barshelf — BarShelf widget developer CLI

        usage:
          barshelf install <src> [--yes]      Install widget(s) from a GitHub repo URL,
                                         a local widget directory, a .zip/.mbw
                                         archive (local path or URL), or a
                                         barshelf://install deep link.
          barshelf new <name> [--kind exec|workflow|script] [--dir <path>]
                                         Scaffold a widget (default: --kind exec,
                                         --dir ./<name>) and validate it.
          barshelf validate <path>            Validate a widget directory or packed
                                         .mbw/.zip archive.
          barshelf pack <dir> [-o <name>.mbw] Pack a widget directory into a .mbw
                                         archive (includes manifest.sha256).
          barshelf list                       List installed widgets.
          barshelf agent-spec                 Print the widget-authoring spec
                                         (docs/AGENTS.md) for LLM agents.
          barshelf --version                  Print the barshelf version.
          barshelf --help                     Show this help.

        exit status: 0 on success, 1 on failure.
        """

    /// Entry point for the executable. `arguments` excludes the binary name.
    public static func run(arguments: [String]) -> Int32 {
        guard let command = arguments.first else {
            printError(usage)
            return 1
        }

        let rest = Array(arguments.dropFirst())
        switch command {
        case "--help", "-h", "help":
            print(usage)
            return 0
        case "--version", "-V", "version":
            print("barshelf \(version)")
            return 0
        case "install":
            return runInstall(arguments: rest)
        case "new":
            return runNew(arguments: rest)
        case "validate":
            return runValidate(arguments: rest)
        case "pack":
            return runPack(arguments: rest)
        case "list":
            return runList(arguments: rest)
        case "agent-spec":
            return runAgentSpec(arguments: rest)
        default:
            printError("barshelf: unknown command \"\(command)\"")
            printError(usage)
            return 1
        }
    }

    // MARK: - barshelf install

    private static func runInstall(arguments: [String]) -> Int32 {
        var input: String?
        var assumeYes = false
        for argument in arguments {
            switch argument {
            case "--yes", "-y":
                assumeYes = true
            default:
                guard input == nil else {
                    printError("usage: barshelf install <url> [--yes]")
                    return 1
                }
                input = argument
            }
        }
        guard let input, !input.isEmpty else {
            printError("usage: barshelf install <src> [--yes]")
            printError("  <src>: GitHub repo URL, a local widget directory,"
                + " a .zip/.mbw archive (path or URL), or barshelf://install?url=…")
            return 1
        }

        let finalAssumeYes = assumeYes
        return runBlocking {
            await performInstall(input: input, assumeYes: finalAssumeYes)
        }
    }

    private static func performInstall(input: String, assumeYes: Bool) async -> Int32 {
        let interactive = isatty(fileno(stdin)) != 0
        do {
            let session = try await HeadlessInstaller.fetchSession(input: input)
            defer { session.cleanup() }

            print("source: \(session.source.displayName)")
            for failure in session.failures {
                printError("skipped \(failure.relativePath): \(failure.reason)")
            }
            let candidates = session.candidates
            guard !candidates.isEmpty else {
                printError(HeadlessInstallError.noWidgetsFound(details: [])
                    .localizedDescription)
                return 1
            }

            let widgetsDir = HeadlessInstaller.defaultWidgetsDirectory
            var installedCount = 0
            var failureCount = session.failures.count
            for candidate in candidates {
                let isUpdate = HeadlessInstaller.isInstalled(
                    id: candidate.manifest.id, in: widgetsDir
                )
                print("widget: \(candidate.displayLine)\(isUpdate ? " [update]" : "")")
                if candidate.permissionSummary.isEmpty {
                    print("  permissions: none")
                } else {
                    for line in candidate.permissionSummary {
                        print("  permission: \(line)")
                    }
                    print("  note: permissions require approval on the widget's first run")
                }

                if !assumeYes {
                    if interactive {
                        guard confirm(
                            "  \(isUpdate ? "Update" : "Install") \(candidate.manifest.name)?"
                        ) else {
                            print("  skipped")
                            continue
                        }
                    } else {
                        print("  (non-interactive input — proceeding; use --yes to silence this note)")
                    }
                }

                do {
                    let destination = try HeadlessInstaller.install(
                        candidate, into: widgetsDir
                    )
                    print("  \(isUpdate ? "updated" : "installed") → \(destination.path)")
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

    private static func confirm(_ question: String) -> Bool {
        print("\(question) [y/N] ", terminator: "")
        guard let answer = readLine()?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        else { return false }
        return answer == "y" || answer == "yes"
    }

    // MARK: - barshelf new

    private static func runNew(arguments: [String]) -> Int32 {
        var name: String?
        var kind = WidgetScaffold.Kind.exec
        var directory: String?

        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--kind":
                guard index + 1 < arguments.count,
                      let parsed = WidgetScaffold.Kind(rawValue: arguments[index + 1])
                else {
                    printError("barshelf new: --kind expects exec | workflow | script")
                    return 1
                }
                kind = parsed
                index += 2
            case "--dir":
                guard index + 1 < arguments.count else {
                    printError("barshelf new: --dir expects a path")
                    return 1
                }
                directory = arguments[index + 1]
                index += 2
            default:
                guard name == nil, !argument.hasPrefix("-") else {
                    printError("usage: barshelf new <name> [--kind exec|workflow|script] [--dir <path>]")
                    return 1
                }
                name = argument
                index += 1
            }
        }
        guard let name else {
            printError("usage: barshelf new <name> [--kind exec|workflow|script] [--dir <path>]")
            return 1
        }

        let target = URL(
            fileURLWithPath: ((directory ?? "./\(name)") as NSString).expandingTildeInPath
        ).standardizedFileURL

        do {
            let files = try WidgetScaffold.create(name: name, kind: kind, at: target)
            print("created \(kind.rawValue) widget \"\(name)\" at \(target.path)")
            for file in files {
                print("  \(file)")
            }
        } catch {
            printError("error: \(error.localizedDescription)")
            return 1
        }

        // Contract: validate right away so the developer starts green.
        let report = WidgetValidator.validate(directory: target)
        guard report.isValid else {
            for issue in report.issues {
                printError("  \(issue.description)")
            }
            printError("error: generated widget failed validation (please report this)")
            return 1
        }
        print("validate: OK — try `barshelf pack \(target.relativePathFromCwd)`")
        return 0
    }

    // MARK: - barshelf validate

    private static func runValidate(arguments: [String]) -> Int32 {
        guard arguments.count == 1, let path = arguments.first else {
            printError("usage: barshelf validate <path>   (widget directory or .mbw/.zip archive)")
            return 1
        }
        let url = URL(
            fileURLWithPath: (path as NSString).expandingTildeInPath
        ).standardizedFileURL

        do {
            let report = try WidgetValidator.validate(path: url)
            for issue in report.issues {
                printError(issue.description)
            }
            guard report.issues.isEmpty else {
                printError("invalid: \(report.issues.count) issue(s)")
                return 1
            }
            guard !report.validatedWidgets.isEmpty else {
                printError("invalid: no widget found at \(url.path)")
                return 1
            }
            let names = report.validatedWidgets.joined(separator: ", ")
            print("valid: \(report.validatedWidgets.count) widget(s) — \(names)")
            return 0
        } catch {
            printError("error: \(error.localizedDescription)")
            return 1
        }
    }

    // MARK: - barshelf pack

    private static func runPack(arguments: [String]) -> Int32 {
        var directory: String?
        var output: String?

        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "-o", "--output":
                guard index + 1 < arguments.count else {
                    printError("barshelf pack: -o expects a file name")
                    return 1
                }
                output = arguments[index + 1]
                index += 2
            default:
                guard directory == nil, !argument.hasPrefix("-") else {
                    printError("usage: barshelf pack <dir> [-o <name>.mbw]")
                    return 1
                }
                directory = argument
                index += 1
            }
        }
        guard let directory else {
            printError("usage: barshelf pack <dir> [-o <name>.mbw]")
            return 1
        }

        let directoryURL = URL(
            fileURLWithPath: (directory as NSString).expandingTildeInPath
        ).standardizedFileURL
        let outputURL = output.map {
            URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)
                .standardizedFileURL
        }

        do {
            let result = try WidgetPacker.pack(directory: directoryURL, output: outputURL)
            print("packed \(result.fileCount) file(s) → \(result.archiveURL.path)")
            print("widget.json sha256: \(result.manifestSHA256)")
            return 0
        } catch {
            printError("error: \(error.localizedDescription)")
            return 1
        }
    }

    // MARK: - barshelf list

    private static func runList(arguments: [String]) -> Int32 {
        guard arguments.isEmpty else {
            printError("usage: barshelf list")
            return 1
        }
        let widgetsDir = HeadlessInstaller.defaultWidgetsDirectory
        return listWidgets(in: widgetsDir)
    }

    /// Split out so tests can point it at a fixture directory.
    public static func listWidgets(in widgetsDir: URL) -> Int32 {
        guard FileManager.default.fileExists(atPath: widgetsDir.path) else {
            print("no widgets installed (\(widgetsDir.path))")
            return 0
        }
        do {
            let discovery = try WidgetDiscovery.discover(under: widgetsDir)
            for failure in discovery.failures {
                printError("skipped \(failure.relativePath): \(failure.reason)")
            }
            guard !discovery.candidates.isEmpty else {
                print("no widgets installed (\(widgetsDir.path))")
                return 0
            }
            let sorted = discovery.candidates.sorted { $0.manifest.id < $1.manifest.id }
            for candidate in sorted {
                let manifest = candidate.manifest
                let version = candidate.displayVersion ?? "-"
                print("\(manifest.id)\t\(manifest.name)\t\(version)\t\(manifest.entry.kind)")
            }
            return 0
        } catch {
            printError("error: \(error.localizedDescription)")
            return 1
        }
    }

    // MARK: - barshelf agent-spec

    private static func runAgentSpec(arguments: [String]) -> Int32 {
        guard arguments.isEmpty else {
            printError("usage: barshelf agent-spec")
            return 1
        }
        print(AgentSpec.render())
        return 0
    }

    // MARK: - Helpers

    /// Bridges the async install flow into the synchronous CLI entry point.
    private static func runBlocking(_ body: @escaping @Sendable () async -> Int32) -> Int32 {
        final class ExitCodeBox: @unchecked Sendable { var value: Int32 = 1 }
        let box = ExitCodeBox()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            box.value = await body()
            semaphore.signal()
        }
        semaphore.wait()
        return box.value
    }

    static func printError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

private extension URL {
    /// Path relative to the current directory when possible (for hints).
    var relativePathFromCwd: String {
        let cwd = FileManager.default.currentDirectoryPath
        if path.hasPrefix(cwd + "/") {
            return String(path.dropFirst(cwd.count + 1))
        }
        return path
    }
}
