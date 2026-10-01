import Foundation
import MenubucketCore

// Plain-language descriptions of what a registry widget asks for and needs.
// Pure functions over registry data, shared by the card (short form) and the
// detail page (full sentences), and unit-tested.

/// One permission a widget declares, as an icon plus a sentence.
struct GalleryPermissionLine: Hashable {
    let symbol: String
    /// Short form for a card tooltip: "Runs: aas".
    let short: String
    /// Full sentence for the detail page.
    let sentence: String
}

enum GalleryPermissionText {
    static func lines(
        for permissions: RegistryWidgetEntry.PermissionsSummary?
    ) -> [GalleryPermissionLine] {
        guard let permissions else { return [] }
        var lines: [GalleryPermissionLine] = []
        let commands = clean(permissions.exec)
        if !commands.isEmpty {
            lines.append(GalleryPermissionLine(
                symbol: "terminal",
                short: String(localized: "Runs: \(list(commands))", comment: "Gallery permission; the list of commands a widget runs"),
                sentence: String(localized: "Runs these commands on your Mac: \(list(commands)).")
            ))
        }
        let hosts = clean(permissions.network)
        if !hosts.isEmpty {
            lines.append(GalleryPermissionLine(
                symbol: "network",
                short: String(localized: "Network: \(list(hosts))"),
                sentence: String(localized: "Connects to these websites: \(list(hosts)).")
            ))
        }
        let paths = clean(permissions.readPaths)
        if !paths.isEmpty {
            lines.append(GalleryPermissionLine(
                symbol: "folder",
                short: String(localized: "Reads files in: \(list(paths))"),
                sentence: String(localized: "Reads files in these folders: \(list(paths)).")
            ))
        }
        let telemetry = clean(permissions.system)
        if !telemetry.isEmpty {
            lines.append(GalleryPermissionLine(
                symbol: "gauge",
                short: String(localized: "Reads system information: \(list(telemetry))"),
                sentence: String(localized: "Reads information about your Mac: \(list(telemetry)).")
            ))
        }
        if permissions.keychain == true {
            lines.append(GalleryPermissionLine(
                symbol: "key",
                short: String(localized: "Reads a Keychain secret"),
                sentence: String(localized: "Reads a password or token you save in your Keychain.")
            ))
        }
        if permissions.notifications == true {
            lines.append(GalleryPermissionLine(
                symbol: "bell",
                short: String(localized: "Posts notifications"),
                sentence: String(localized: "Can show notifications.")
            ))
        }
        return lines
    }

    private static func clean(_ values: [String]?) -> [String] {
        (values ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func list(_ values: [String]) -> String {
        ListFormatter.localizedString(byJoining: values)
    }
}

/// One tool a widget needs on this Mac (`requires`, split on `+`, `&`, `,`).
struct GalleryRequirement: Hashable, Sendable {
    /// As written in the registry: "Deno", "muxa CLI".
    let name: String
    /// The command BarShelf looks for on PATH, when one can be read from it.
    let command: String?
    /// A Terminal command that installs it, for tools with a well-known one.
    let installCommand: String?
}

enum GalleryRequirementText {
    static func requirements(from requires: String?) -> [GalleryRequirement] {
        guard let requires else { return [] }
        return requires
            .components(separatedBy: CharacterSet(charactersIn: "+&,;"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { part in
                let command = RequirementChecker.candidateBinaries(from: part)
                    .last?.lowercased()
                return GalleryRequirement(
                    name: part,
                    command: command,
                    installCommand: command.flatMap { knownInstallCommands[$0] }
                )
            }
    }

    /// Tools with a standard Homebrew formula. Anything else points at the
    /// widget's project page instead of guessing.
    static let knownInstallCommands: [String: String] = [
        "deno": "brew install deno",
        "gh": "brew install gh",
        "jq": "brew install jq",
        "node": "brew install node",
        "python3": "brew install python",
        "ffmpeg": "brew install ffmpeg",
    ]
}
