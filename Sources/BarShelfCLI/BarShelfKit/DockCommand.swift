import Foundation
import MenubucketCore

/// `barshelf dock …` — the BarShelf Dock's profiles from Terminal (R15).
///
/// `list` reads `dock.json`; `use` asks the running app through its URL
/// scheme (the app owns the switch); `restore-apple-dock` works with the app
/// not running at all, which is the point of it.
public enum DockCommand {
    public static let usage = """
        usage:
          barshelf dock list                  List dock profiles (* = active).
          barshelf dock use <profile>         Switch profile by name, id, or number.
          barshelf dock next | previous       Switch to the next or previous profile.
          barshelf dock restore-apple-dock    Bring back the Apple Dock if BarShelf
                                         left it hidden.
        """

    public static var configurationURL: URL {
        HeadlessInstaller.defaultWidgetsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("dock.json")
    }

    public static func run(
        arguments: [String],
        configurationURL: URL = DockCommand.configurationURL,
        openURL: (URL) -> Bool = DockCommand.openInApp,
        appleDock: () -> AppleDock = { AppleDock() }
    ) -> Int32 {
        guard let subcommand = arguments.first else {
            BarShelfMain.printError(usage)
            return 1
        }
        let rest = Array(arguments.dropFirst())
        switch subcommand {
        case "list", "ls":
            let config = DockConfiguration.load(from: configurationURL)
            print(list(config))
            return 0
        case "use", "switch":
            let query = rest.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            guard !query.isEmpty else {
                BarShelfMain.printError("usage: barshelf dock use <profile>")
                return 1
            }
            let config = DockConfiguration.load(from: configurationURL)
            guard let profile = config.profile(matching: query) else {
                BarShelfMain.printError("barshelf: no dock profile matches \"\(query)\"")
                BarShelfMain.printError(list(config))
                return 1
            }
            return send(query: "profile=\(encode(profile.id))", openURL: openURL)
        case "next":
            return send(query: "next", openURL: openURL)
        case "previous", "prev":
            return send(query: "previous", openURL: openURL)
        case "restore-apple-dock":
            let dock = appleDock()
            var config = DockConfiguration.load(from: configurationURL)
            if let backup = config.appleDockBackup {
                dock.restore(backup)
                config.appleDockBackup = nil
                // "Instead of the Apple Dock" would hide it again at launch.
                if config.mode == .replace { config.mode = .alongside }
                try? config.save(to: configurationURL)
                print("restored the Apple Dock's own settings")
            } else if dock.isHidden {
                dock.unhideWithoutBackup()
                print("the Apple Dock shows again")
            } else {
                print("the Apple Dock is not hidden")
            }
            return 0
        default:
            BarShelfMain.printError("barshelf: unknown dock command \"\(subcommand)\"")
            BarShelfMain.printError(usage)
            return 1
        }
    }

    static func list(_ config: DockConfiguration) -> String {
        config.profiles.enumerated().map { index, profile in
            let marker = profile.id == config.activeProfileID ? "*" : " "
            var line = "\(marker) \(index + 1). \(profile.name)  [\(profile.id)]  \(profile.items.count) item(s)"
            if profile.appleDock != nil { line += ", Apple Dock layout" }
            return line
        }.joined(separator: "\n")
    }

    private static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+"))) ?? value
    }

    private static func send(query: String, openURL: (URL) -> Bool) -> Int32 {
        guard let url = URL(string: "barshelf://dock?\(query)") else { return 1 }
        guard openURL(url) else {
            BarShelfMain.printError("barshelf: couldn't reach BarShelf (is it installed?)")
            return 1
        }
        return 0
    }

    /// `open -g` hands the URL to BarShelf without bringing anything forward.
    public static func openInApp(_ url: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-g", url.absoluteString]
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
