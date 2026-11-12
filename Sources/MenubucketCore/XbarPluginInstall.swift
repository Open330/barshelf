import Foundation

/// `barshelf install ./battery.5m.sh`: an xbar/SwiftBar plugin file becomes
/// a widget folder (the plugin plus a `widget.json` around it), which then
/// goes through the ordinary install and the ordinary declare → approve →
/// enforce path. The plugin's text is read for its metadata; it is never
/// run before the person allows it.
public enum XbarPluginInstall {
    /// Bigger than any real plugin; a file this large is something else.
    public static let maxPluginBytes = 1_048_576
    public static let idPrefix = "xbar."

    public enum InstallError: Error, LocalizedError, Equatable {
        case tooLarge(String)
        case notText(String)
        case streamable(String)
        case badInterval(String)

        public var errorDescription: String? {
            switch self {
            case let .tooLarge(name): return "\(name) is larger than \(maxPluginBytes / 1024) KB; that is not a plugin."
            case let .notText(name): return "\(name) is not a text script."
            case let .streamable(name): return "\(name) is a streaming SwiftBar plugin; BarShelf runs plugins that print and exit."
            case let .badInterval(name): return "\(name) has a refresh interval BarShelf can't use (zero, or over a year)."
            }
        }
    }

    /// An existing local file (bare path or `file://`) that looks like a
    /// plugin: a regular file, not an archive or JSON, and executable or
    /// starting with `#!`.
    public static func localPluginFile(for input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let url: URL
        if trimmed.lowercased().hasPrefix("file://") {
            guard let parsed = URL(string: trimmed), parsed.isFileURL else { return nil }
            url = parsed
        } else if !trimmed.contains("://") {
            url = URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath)
        } else {
            return nil
        }
        guard ["zip", "mbw", "json"].contains(url.pathExtension.lowercased()) == false else { return nil }
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { return nil }
        if fm.isExecutableFile(atPath: url.path) { return url.standardizedFileURL }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 2)) ?? Data()
        return head == Data("#!".utf8) ? url.standardizedFileURL : nil
    }

    /// `battery-level` from `Battery Level!`: what the widget id is built on.
    public static func slug(_ name: String) -> String {
        var out = ""
        var lastDash = false
        for scalar in name.lowercased().unicodeScalars {
            if (scalar >= "a" && scalar <= "z") || (scalar >= "0" && scalar <= "9") {
                out.unicodeScalars.append(scalar)
                lastDash = false
            } else if !lastDash, !out.isEmpty {
                out.append("-")
                lastDash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return String((out.isEmpty ? "plugin" : out).prefix(60))
    }

    public struct Scaffold: Equatable {
        public var directory: URL
        public var manifest: [String: Any]
        /// Commands the plugin's text names in `bash=`/`shell=` that are not
        /// the plugin itself: those actions stay blocked until declared.
        /// Only a hint — the plugin can run anything once allowed.
        public var undeclaredCommands: [String]

        public static func == (lhs: Scaffold, rhs: Scaffold) -> Bool {
            lhs.directory == rhs.directory && lhs.undeclaredCommands == rhs.undeclaredCommands
                && NSDictionary(dictionary: lhs.manifest).isEqual(to: rhs.manifest)
        }
    }

    /// Builds `<staging>/xbar.<slug>/` holding the plugin (original name,
    /// executable) and its `widget.json`.
    public static func scaffold(pluginFile: URL, into staging: URL) throws -> Scaffold {
        let fileName = pluginFile.lastPathComponent
        let attributes = try FileManager.default.attributesOfItem(atPath: pluginFile.path)
        if let size = attributes[.size] as? Int, size > maxPluginBytes { throw InstallError.tooLarge(fileName) }
        let data = try Data(contentsOf: pluginFile)
        guard let script = String(data: data, encoding: .utf8) else { throw InstallError.notText(fileName) }
        let meta = XbarPlugin.metadata(script: script)
        if meta["swiftbar.type"]?.lowercased() == "streamable" { throw InstallError.streamable(fileName) }
        guard let interval = XbarPlugin.refreshInterval(fileName: fileName) else { throw InstallError.badInterval(fileName) }

        let base = XbarPlugin.baseName(fileName: fileName)
        let id = idPrefix + slug(base)
        let title = meta["title"].flatMap { $0.isEmpty ? nil : $0 } ?? base
        let command = "./" + fileName

        let directory = staging.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let pluginCopy = directory.appendingPathComponent(fileName)
        try data.write(to: pluginCopy)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: pluginCopy.path)

        var manifest: [String: Any] = [
            "$schema": "https://barshelf.jiun.dev/schema/widget-0.1.json",
            "schemaVersion": 1,
            "id": id,
            "name": title,
            "version": version(meta["version"]),
            // `output: "xbar"` arrived in 0.7.35; an older app must refuse it.
            "minHostVersion": "0.7.35",
            "icon": "puzzlepiece.extension",
            "bucket": ["group": "Plugins", "size": "M"],
            "entry": ["kind": "exec"],
            "source": [
                "kind": "exec",
                "command": [command],
                // Plugins often call a network API; xbar gives them no limit.
                "timeoutMs": 30_000,
                "output": "xbar",
            ] as [String: Any],
            "refresh": [
                "onOpen": true,
                "interval": interval,
                "runInBackground": true,
            ] as [String: Any],
            "statusItem": ["mode": "dynamic"],
            "permissions": [
                "exec": [[
                    "command": command,
                    "purpose": "Run the \(title) plugin. Once allowed it runs with your access, like any program you run.",
                ]],
            ],
        ]
        let json = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try json.write(to: directory.appendingPathComponent("widget.json"))
        manifest.removeValue(forKey: "$schema")
        return Scaffold(directory: directory, manifest: manifest, undeclaredCommands: undeclaredCommands(script: script, fileName: fileName))
    }

    /// `x.y.z` from the plugin's `<xbar.version>` (`v1.2` → `1.2.0`), else `0.0.0`.
    static func version(_ raw: String?) -> String {
        let digits = (raw ?? "").trimmingCharacters(in: .whitespaces).drop { $0 == "v" || $0 == "V" }
        let parts = digits.split(separator: ".").prefix(3).map(String.init)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return "0.0.0" }
        return (parts + Array(repeating: "0", count: 3 - parts.count)).joined(separator: ".")
    }

    /// Literal `bash=`/`shell=` values in the script other than the plugin
    /// itself (`$0`, its own name). Advisory: commands built at run time
    /// are invisible here.
    static func undeclaredCommands(script: String, fileName: String) -> [String] {
        let pattern = #"(?:bash|shell)=(?:"([^"]*)"|'([^']*)'|([^\s|"']+))"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = script as NSString
        var found: [String] = []
        for match in regex.matches(in: script, range: NSRange(location: 0, length: ns.length)) {
            let value = (1...3).compactMap { i -> String? in
                let r = match.range(at: i)
                return r.location == NSNotFound ? nil : ns.substring(with: r)
            }.first ?? ""
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.contains("$"), !trimmed.contains("`"),
                  (trimmed as NSString).lastPathComponent != fileName,
                  !found.contains(trimmed) else { continue }
            found.append(trimmed)
        }
        return found
    }
}
