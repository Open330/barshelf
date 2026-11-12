import Foundation

/// xbar / SwiftBar plugin compatibility: `source.output = "xbar"`.
///
/// A plugin is an executable that prints the xbar text format. Lines before
/// the first `---` are the menu bar title (the first is the reading BarShelf
/// shows); lines after it are the dropdown, which becomes the widget's card.
/// Each line is `text | key=value key2="quoted value"`; a leading `--` per
/// level nests it under the line above. Parsing is pure and never throws:
/// anything malformed renders as inert text.
///
/// Enforcement is not done here. A `bash=` line becomes an ordinary `run`
/// action that `permissions.exec` still has to allow; the only rewrite is a
/// verified call of the plugin to itself (see `Context.selfCommand`).
public enum XbarPlugin {
    // MARK: - Limits

    public static let maxLines = 400
    public static let maxDepth = 4
    /// `param0` … `param32`; a higher index is dropped, never padded to.
    public static let maxParamIndex = 32

    // MARK: - Parsing

    public struct Line: Equatable, Sendable {
        public var text: String
        /// Keys lowercased; a repeated key keeps its last value.
        public var params: [String: String]
        public var depth: Int
        public var isSeparator: Bool
        /// The parameter part could not be read (an unclosed quote): the line
        /// shows its text and does nothing.
        public var malformed: Bool

        public init(text: String, params: [String: String] = [:], depth: Int = 0,
                    isSeparator: Bool = false, malformed: Bool = false) {
            self.text = text
            self.params = params
            self.depth = depth
            self.isSeparator = isSeparator
            self.malformed = malformed
        }
    }

    public struct Output: Equatable, Sendable {
        public var titles: [Line]
        public var items: [Line]
    }

    public static func parse(_ stdout: String) -> Output {
        var titles: [Line] = []
        var items: [Line] = []
        var inBody = false
        var count = 0
        for raw in stdout.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let rawLine = String(raw)
            if rawLine.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            count += 1
            if count > maxLines { break }
            let line = parseLine(rawLine)
            if !inBody {
                if line.isSeparator && line.depth == 0 {
                    inBody = true
                } else {
                    titles.append(line)
                }
                continue
            }
            items.append(line)
        }
        return Output(titles: titles, items: items)
    }

    /// One line. Text ends at the first `|` (as in both xbar and SwiftBar,
    /// so a literal pipe cannot be part of the text); pipes inside quoted
    /// parameter values are kept.
    public static func parseLine(_ raw: String) -> Line {
        let text: Substring
        let paramPart: Substring?
        if let bar = raw.firstIndex(of: "|") {
            text = raw[..<bar]
            paramPart = raw[raw.index(after: bar)...]
        } else {
            text = Substring(raw)
            paramPart = nil
        }
        var body = text.trimmingCharacters(in: .whitespaces)
        // `---` is a separator, `-----` one inside a submenu, and so on.
        if body.count >= 3, body.allSatisfy({ $0 == "-" }), (body.count - 3) % 2 == 0 {
            return Line(text: "", depth: (body.count - 3) / 2, isSeparator: true)
        }
        // One pass over the prefix: copying the rest of the line per level
        // made a line of 100k dashes cost seconds.
        var depth = 0
        var start = body.startIndex
        while body[start...].hasPrefix("--") {
            depth += 1
            start = body.index(start, offsetBy: 2)
        }
        depth = min(depth, maxDepth + 1)
        body = body[start...].trimmingCharacters(in: .whitespaces)
        guard let paramPart else { return Line(text: body, depth: depth) }
        guard let params = tokenize(paramPart) else {
            return Line(text: body, depth: depth, malformed: true)
        }
        return Line(text: body, params: params, depth: depth)
    }

    /// `key=value key2='a b' key3="c | d"`. Inside quotes, a backslash
    /// before the quote character or another backslash makes it literal
    /// (`"say \"hi\""`); other backslashes are kept. nil when a quote
    /// never closes or a closing quote is not followed by a space.
    /// No shell is involved: `$HOME`, `$(…)` and backticks stay literal.
    static func tokenize(_ input: Substring) -> [String: String]? {
        var params: [String: String] = [:]
        var index = input.startIndex
        func skipSpace() {
            while index < input.endIndex, input[index].isWhitespace { index = input.index(after: index) }
        }
        while true {
            skipSpace()
            guard index < input.endIndex else { break }
            var key = ""
            while index < input.endIndex, input[index] != "=", !input[index].isWhitespace {
                key.append(input[index])
                index = input.index(after: index)
            }
            guard index < input.endIndex, input[index] == "=" else { continue } // a bare word: ignored
            index = input.index(after: index)
            var value = ""
            if index < input.endIndex, input[index] == "\"" || input[index] == "'" {
                let quote = input[index]
                index = input.index(after: index)
                var closed = false
                while index < input.endIndex {
                    let char = input[index]
                    if char == "\\" {
                        let next = input.index(after: index)
                        if next < input.endIndex, input[next] == quote || input[next] == "\\" {
                            value.append(input[next])
                            index = input.index(after: next)
                            continue
                        }
                    }
                    if char == quote {
                        closed = true
                        index = input.index(after: index)
                        break
                    }
                    value.append(char)
                    index = input.index(after: index)
                }
                guard closed else { return nil }
                // `"a"b` is not two things glued together; it is a mistake.
                if index < input.endIndex, !input[index].isWhitespace { return nil }
            } else {
                while index < input.endIndex, !input[index].isWhitespace {
                    value.append(input[index])
                    index = input.index(after: index)
                }
            }
            if !key.isEmpty { params[key.lowercased()] = value }
        }
        return params
    }

    // MARK: - Rendering

    public struct Context: Sendable {
        /// The command the manifest declares for the plugin (`./name.5m.sh`).
        public var selfCommand: String
        /// The plugin file itself; a `bash=` naming it by an absolute path
        /// (what `$0` expands to) is rewritten to `selfCommand`, so the
        /// declared permission matches. Nothing else is rewritten.
        public var pluginFile: URL?
        public var darkMode: Bool

        public init(selfCommand: String, pluginFile: URL? = nil, darkMode: Bool = false) {
            self.selfCommand = selfCommand
            self.pluginFile = pluginFile
            self.darkMode = darkMode
        }
    }

    public struct Rendered: Equatable, Sendable {
        public var tree: UINode
        public var statusLabel: String?
        public var statusIcon: String?
        public var statusTint: String?
    }

    public static func render(_ output: Output, context: Context) -> Rendered {
        let first = output.titles.first
        let label = first.map { cleanText($0) }.flatMap { $0.isEmpty ? nil : $0 }
        let icon = first?.params["sfimage"].flatMap { $0.isEmpty ? nil : $0 }
        let statusTint = first?.params["color"].flatMap { Self.tint(for: $0, dark: context.darkMode) }

        var children: [UINode] = []
        for (index, title) in output.titles.enumerated() {
            children.append(row(title, id: "title-\(index)", role: index == 0 ? "title" : "caption", context: context))
        }
        let body = buildTree(output.items)
        if !body.isEmpty {
            if !children.isEmpty { children.append(UINode(type: "divider")) }
            children.append(contentsOf: nodes(for: body, path: "item", context: context))
        }
        if children.isEmpty {
            children.append(UINode(type: "empty", title: "No output", subtitle: "The plugin printed nothing.", icon: "text.alignleft"))
        }
        let tree = UINode(id: "xbar", type: "vstack", children: children, spacing: 6)
        return Rendered(tree: tree, statusLabel: label, statusIcon: icon, statusTint: statusTint)
    }

    /// Lines with their submenu children. Depth jumps (a line two levels
    /// below its parent) are pulled up to one level below it; depth is
    /// capped at `maxDepth`.
    struct TreeItem: Equatable {
        var line: Line
        var children: [TreeItem] = []
    }

    static func buildTree(_ lines: [Line]) -> [TreeItem] {
        var roots: [TreeItem] = []
        // Path of indices from the roots to the last line at each depth.
        var path: [Int] = []
        func insert(_ item: TreeItem, at depth: Int) {
            if depth == 0 {
                roots.append(item)
                path = [roots.count - 1]
                return
            }
            var parentPath = Array(path.prefix(depth))
            func append(_ list: inout [TreeItem], _ remaining: ArraySlice<Int>) -> Int {
                guard let head = remaining.first else {
                    list.append(item)
                    return list.count - 1
                }
                return append(&list[head].children, remaining.dropFirst())
            }
            let newIndex = append(&roots, parentPath[...])
            parentPath.append(newIndex)
            path = parentPath
        }
        for line in lines {
            let depth = min(line.depth, maxDepth, path.count)
            // A separator never becomes the parent of the lines after it.
            let before = path
            insert(TreeItem(line: line), at: depth)
            if line.isSeparator { path = depth == 0 ? [] : Array(before.prefix(depth)) }
        }
        return roots
    }

    static func nodes(for items: [TreeItem], path: String, context: Context) -> [UINode] {
        var out: [UINode] = []
        for (index, item) in items.enumerated() {
            let id = "\(path)-\(index)"
            if item.line.isSeparator {
                out.append(UINode(id: id, type: "divider"))
                continue
            }
            out.append(row(item.line, id: id, role: "body", context: context))
            if !item.children.isEmpty {
                out.append(UINode(
                    id: id + "-sub", type: "card", children: nodes(for: item.children, path: id, context: context),
                    spacing: 4, tone: "neutral"
                ))
            }
        }
        return out
    }

    /// One line as a text row, or a button when it does something.
    static func row(_ line: Line, id: String, role: String, context: Context) -> UINode {
        let text = cleanText(line)
        let rowTint = line.params["color"].flatMap { Self.tint(for: $0, dark: context.darkMode) }
        let icon = line.params["sfimage"].flatMap { $0.isEmpty ? nil : $0 }
        let help = line.params["tooltip"].flatMap { $0.isEmpty ? nil : $0 }
        switch action(for: line, context: context) {
        case let .some(.action(action)):
            var node = UINode(id: id, type: "button", title: text, tint: rowTint, icon: icon, action: action)
            node.help = help
            return node
        case .some(.terminal):
            var label = UINode(id: id, type: "text", text: text, role: role, foreground: "secondary")
            label.help = help
            return UINode(id: id + "-row", type: "hstack", children: [
                icon.map { UINode(type: "image", source: .init(kind: "sfSymbol", name: $0), size: 14, tint: "secondary") },
                label,
                UINode(type: "spacer"),
                UINode(type: "text", text: "Opens Terminal — not supported", role: "caption", foreground: "tertiary"),
            ].compactMap { $0 }, spacing: 6)
        case .none:
            var label = UINode(id: id, type: "text", text: text, role: role, tint: rowTint)
            label.help = help
            guard let icon else { return label }
            return UINode(id: id + "-row", type: "hstack", children: [
                UINode(type: "image", source: .init(kind: "sfSymbol", name: icon), size: 14, tint: rowTint),
                label,
            ], spacing: 6)
        }
    }

    enum LineAction: Equatable {
        case action(NodeAction)
        /// `terminal=true`: shown, not run.
        case terminal
    }

    /// What a line does. `bash=`/`shell=` wins over `href=`; `refresh=true`
    /// alone refreshes. Only http and https links open. A malformed line
    /// does nothing.
    static func action(for line: Line, context: Context) -> LineAction? {
        guard !line.malformed, !line.isSeparator else { return nil }
        let p = line.params
        let refresh = p["refresh"]?.lowercased() == "true"
        if let bash = (p["bash"] ?? p["shell"]), !bash.isEmpty {
            if p["terminal"]?.lowercased() == "true" { return .terminal }
            let command = [resolveSelf(bash, context: context)] + params(of: p)
            return .action(NodeAction(type: "run", command: command, thenRefresh: refresh ? true : nil))
        }
        if let href = p["href"], let url = URL(string: href),
           let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" {
            return .action(NodeAction(type: "openURL", url: href))
        }
        if refresh { return .action(NodeAction(type: "refresh")) }
        return nil
    }

    /// `param0`…`param32` in numeric order (SwiftBar starts at 0, xbar at
    /// 1; both are read). Gaps are skipped, not filled.
    static func params(of p: [String: String]) -> [String] {
        p.compactMap { key, value -> (Int, String)? in
            guard key.hasPrefix("param"), let n = Int(key.dropFirst(5)), n >= 0, n <= maxParamIndex,
                  String(n) == key.dropFirst(5) else { return nil }
            return (n, value)
        }
        .sorted { $0.0 < $1.0 }
        .map(\.1)
    }

    /// The plugin calling itself by an absolute path (`$0`) becomes the
    /// declared command. A different file with the same name, a relative
    /// spelling other than the declared one, or a path through `..` that
    /// lands elsewhere is left alone (and blocked unless declared).
    static func resolveSelf(_ bash: String, context: Context) -> String {
        guard bash != context.selfCommand, bash.hasPrefix("/"), let plugin = context.pluginFile else { return bash }
        let candidate = URL(fileURLWithPath: bash).standardizedFileURL.resolvingSymlinksInPath().path
        let own = plugin.standardizedFileURL.resolvingSymlinksInPath().path
        return candidate == own ? context.selfCommand : bash
    }

    /// The line's text: ANSI escapes removed, `:shortcode:` emoji filled in
    /// unless `emojize=false`.
    static func cleanText(_ line: Line) -> String {
        var text = stripANSI(line.text)
        if line.params["emojize"]?.lowercased() != "false" { text = emojize(text) }
        return text.trimmingCharacters(in: .whitespaces)
    }

    static func stripANSI(_ text: String) -> String {
        guard text.contains("\u{1B}") else { return text }
        return text.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
    }

    /// The handful of shortcodes plugins commonly print. Unknown ones stay
    /// as written.
    static let emoji: [String: String] = [
        "sunny": "☀️", "cloud": "☁️", "umbrella": "☔", "snowflake": "❄️", "zap": "⚡", "fire": "🔥",
        "white_check_mark": "✅", "heavy_check_mark": "✔️", "x": "❌", "warning": "⚠️", "rotating_light": "🚨",
        "red_circle": "🔴", "large_blue_circle": "🔵", "green_circle": "🟢", "yellow_circle": "🟡",
        "star": "⭐", "rocket": "🚀", "bell": "🔔", "battery": "🔋", "computer": "💻", "calendar": "📅",
        "clock1": "🕐", "hourglass": "⌛", "moneybag": "💰", "chart_with_upwards_trend": "📈",
        "chart_with_downwards_trend": "📉", "email": "📧", "envelope": "✉️", "lock": "🔒", "unlock": "🔓",
        "bulb": "💡", "coffee": "☕", "musical_note": "🎵", "thumbsup": "👍", "+1": "👍", "thumbsdown": "👎",
        "-1": "👎", "eyes": "👀", "gear": "⚙️", "hammer": "🔨", "wrench": "🔧", "package": "📦",
        "globe_with_meridians": "🌐", "house": "🏠", "heart": "❤️", "tada": "🎉", "sparkles": "✨",
        "arrow_up": "⬆️", "arrow_down": "⬇️", "arrows_counterclockwise": "🔄", "octocat": "🐙", "cat": "🐱",
    ]

    static func emojize(_ text: String) -> String {
        guard text.contains(":") else { return text }
        var out = ""
        var rest = Substring(text)
        while let open = rest.firstIndex(of: ":") {
            out += rest[..<open]
            let after = rest[rest.index(after: open)...]
            if let close = after.firstIndex(of: ":"), let value = emoji[String(after[..<close])] {
                out += value
                rest = after[after.index(after: close)...]
            } else {
                out += ":"
                rest = after
            }
        }
        return out + rest
    }

    /// An xbar colour (a name, `#rgb`/`#rrggbb`, or SwiftBar's
    /// `light,dark` pair) as the nearest BarShelf tint word.
    public static func tint(for color: String, dark: Bool) -> String? {
        let parts = color.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard let chosen = (dark && parts.count > 1 ? parts[1] : parts.first), !chosen.isEmpty else { return nil }
        switch chosen {
        case "red", "crimson", "firebrick", "darkred", "tomato": return "danger"
        case "orange", "darkorange", "yellow", "gold", "amber", "goldenrod": return "warning"
        case "green", "lime", "limegreen", "forestgreen", "seagreen", "darkgreen", "mediumseagreen": return "good"
        case "blue", "dodgerblue", "royalblue", "deepskyblue", "steelblue", "navy", "purple", "violet",
             "magenta", "indigo", "teal", "cyan", "aqua": return "accent"
        case "gray", "grey", "darkgray", "darkgrey", "lightgray", "lightgrey", "silver", "dimgray": return "secondary"
        case "black", "white": return nil
        default: break
        }
        guard chosen.hasPrefix("#"), let rgb = hexRGB(String(chosen.dropFirst())) else { return nil }
        return hueTint(rgb)
    }

    static func hexRGB(_ hex: String) -> (Double, Double, Double)? {
        var digits = hex
        if digits.count == 3 { digits = digits.map { "\($0)\($0)" }.joined() }
        if digits.count == 8 { digits = String(digits.prefix(6)) }
        guard digits.count == 6, let value = Int(digits, radix: 16) else { return nil }
        return (Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255)
    }

    static func hueTint(_ rgb: (Double, Double, Double)) -> String? {
        let (r, g, b) = rgb
        let maxC = Swift.max(r, g, b), minC = Swift.min(r, g, b)
        let delta = maxC - minC
        if delta < 0.15 { return maxC < 0.2 || maxC > 0.9 ? nil : "secondary" }
        var hue: Double
        if maxC == r { hue = 60 * ((g - b) / delta).truncatingRemainder(dividingBy: 6) }
        else if maxC == g { hue = 60 * ((b - r) / delta + 2) }
        else { hue = 60 * ((r - g) / delta + 4) }
        if hue < 0 { hue += 360 }
        switch hue {
        case ..<20, 330...: return "danger"
        case 20..<70: return "warning"
        case 70..<170: return "good"
        default: return "accent"
        }
    }

    // MARK: - File name and header

    /// The segment before the extension when it is an interval token
    /// (`5m`, `-5m`, `500ms`); nil for a name like `my.weather.sh`.
    static func intervalToken(fileName: String) -> (number: Double, scale: Double)? {
        let parts = fileName.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return nil }
        var segment = Substring(parts[parts.count - 2].lowercased())
        let negative = segment.hasPrefix("-")
        if negative || segment.hasPrefix("+") { segment = segment.dropFirst() }
        let units: [(String, Double)] = [("ms", 0.001), ("s", 1), ("m", 60), ("h", 3600), ("d", 86400)]
        for (suffix, scale) in units where segment.hasSuffix(suffix) {
            let number = segment.dropLast(suffix.count)
            guard !number.isEmpty, number.count <= 12, number.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let value = Double(number) else { continue }
            return (negative ? -value : value, scale)
        }
        return nil
    }

    /// The refresh interval in a plugin's file name, in seconds:
    /// `battery.5m.sh` → 300. Units `ms`, `s`, `m`, `h`, `d`. A name with no
    /// interval refreshes every minute, as in xbar. nil for an interval that
    /// is zero, negative or too large to mean anything (over a year).
    public static func refreshInterval(fileName: String) -> Double? {
        guard let token = intervalToken(fileName: fileName) else { return 60 }
        let seconds = token.number * token.scale
        guard seconds > 0, seconds <= 366 * 86400 else { return nil }
        return seconds
    }

    /// The name without the interval and extension: `battery.5m.sh` →
    /// `battery`, `my.weather.sh` → `my.weather`.
    public static func baseName(fileName: String) -> String {
        let parts = fileName.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2 else { return fileName }
        let drop = intervalToken(fileName: fileName) == nil ? 1 : 2
        return parts.dropLast(drop).joined(separator: ".")
    }

    /// `<xbar.title>…</xbar.title>`-style metadata from the plugin's text
    /// (read, never run). Keys without the prefix: `title`, `desc`,
    /// `version`, `author`, `dependencies`; SwiftBar's `swiftbar.*` keys too
    /// (`type`, `schedule`, …), prefixed `swiftbar.`.
    public static func metadata(script: String) -> [String: String] {
        var out: [String: String] = [:]
        let pattern = #"<(xbar|bitbar|swiftbar)\.([A-Za-z.]+)>(.*?)</\1\.\2>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return out }
        let ns = script as NSString
        for match in regex.matches(in: script, range: NSRange(location: 0, length: min(ns.length, 64 * 1024))) {
            let family = ns.substring(with: match.range(at: 1))
            let key = ns.substring(with: match.range(at: 2))
            let value = ns.substring(with: match.range(at: 3)).trimmingCharacters(in: .whitespaces)
            let name = family == "swiftbar" ? "swiftbar." + key : key
            if out[name] == nil { out[name] = value }
        }
        return out
    }

    /// What the plugin process sees besides the usual: BarShelf says who it
    /// is and gives the appearance markers both hosts set. Not `SWIFTBAR=1`:
    /// plugins branch on it to use features BarShelf does not have.
    public static func environment(darkMode: Bool) -> [String: String] {
        [
            "BARSHELF": "1",
            "XBARDarkMode": darkMode ? "true" : "false",
            "OS_APPEARANCE": darkMode ? "Dark" : "Light",
        ]
    }
}
