import Foundation
import MenubucketCore

/// What a widget's commands do, in the words a permission request uses.
///
/// A request used to print command lines ("pmset -g batt", a shell script cut
/// off mid-word), which says how and not what. A command's `purpose` from the
/// manifest says what; without one the request names only the tool, never
/// its arguments. The exact command lines stay available behind "Details".
enum ExecPermissionText {
    struct Summary: Equatable {
        /// What the commands do, one phrase each, without repeats, in the
        /// order the manifest lists them.
        let phrases: [String]
        /// Every allowed command line exactly, for "Details".
        let commandLines: [String]
        /// The programs involved, by name: the declared commands and, for a
        /// shell script, the commands it calls.
        let tools: [String]
    }

    /// Nil when the manifest declares no commands.
    static func summary(for manifest: Manifest, localization: WidgetLocalization?) -> Summary? {
        let entries = manifest.permissions?.exec ?? []
        guard !entries.isEmpty else { return nil }
        var phrases = OrderedSet()
        var lines: [String] = []
        var tools = OrderedSet()
        for entry in entries {
            let patterns: [[String]]? = entry.allowedArgs.map { $0.isEmpty ? [[]] : $0 }
            let purpose = entry.purpose?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !purpose.isEmpty {
                phrases.append(localization?.text(purpose) ?? purpose)
            }
            tools.append(friendlyCommandName(entry.command))
            guard let patterns else {
                if purpose.isEmpty {
                    phrases.append(String(localized: "Run \(friendlyCommandName(entry.command)) with any arguments", comment: "Permission request: a command allowed with any arguments"))
                }
                lines.append(commandLine(entry.command, ["…"]))
                continue
            }
            for args in patterns {
                lines.append(commandLine(entry.command, args))
                if let script = shellScript(command: entry.command, args: args) {
                    tools.append(contentsOf: ShellScriptCommands.analyze(script).commands)
                }
                if purpose.isEmpty { phrases.append(describe(command: entry.command, args: args)) }
            }
        }
        return Summary(phrases: phrases.items, commandLines: lines, tools: tools.items)
    }

    /// One allowed command line in words, for a command with no `purpose`:
    /// the tool's name, never its arguments.
    static func describe(command: String, args: [String]) -> String {
        let name = friendlyCommandName(command)
        // The date widgets only read a formatted date. This is not said of
        // date-setting arguments or of an unrelated program named date.
        if command == "/bin/date", args.isEmpty || (args.count == 1 && args[0].hasPrefix("+")) {
            return String(localized: "Read the current date and time", comment: "Permission request: a widget that runs /bin/date to read the time")
        }
        if let script = shellScript(command: command, args: args) {
            let found = ShellScriptCommands.analyze(script)
            guard !found.commands.isEmpty else { return String(localized: "Run a shell script", comment: "Permission request") }
            let shown = Array(found.commands.prefix(5))
            if found.isComplete, shown.count == found.commands.count {
                return String(localized: "Run a shell script that uses \(shown.formatted(.list(type: .and)))", comment: "Permission request: the commands a shell script calls, as a list")
            }
            // Some commands are found only when the script runs ("$d" ps), so
            // the list must not read as the whole of it.
            return String(localized: "Run a shell script that uses \(shown.joined(separator: ", ")) and others", comment: "Permission request: some of the commands a shell script calls; it may call more")
        }
        return String(localized: "Run \(name)", comment: "Permission request: a command, by name only")
    }

    /// The script of `sh -c "<script>"` (any common shell), else nil.
    static func shellScript(command: String, args: [String]) -> String? {
        let shells: Set<String> = ["sh", "bash", "zsh", "dash", "ksh"]
        guard shells.contains(friendlyCommandName(command).lowercased()),
              let flag = args.firstIndex(of: "-c"), flag + 1 < args.count else { return nil }
        return args[flag + 1]
    }

    /// The basename of an executable path (`/usr/bin/top` → `top`).
    static func friendlyCommandName(_ command: String) -> String {
        let name = (command as NSString).lastPathComponent
        return name.isEmpty ? command : name
    }

    /// A command line as a shell would read it. `*` in a pattern stands for
    /// any one argument and is shown as it is.
    static func commandLine(_ command: String, _ args: [String]) -> String {
        ([command] + args).map(quoted).joined(separator: " ")
    }

    private static func quoted(_ word: String) -> String {
        if word == "*" || word == "…" { return word }
        let plain = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-+=:,@%")
        if !word.isEmpty, word.allSatisfy({ plain.contains($0) }) { return word }
        return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Insertion-ordered, without repeats.
    private struct OrderedSet {
        private(set) var items: [String] = []
        private var seen = Set<String>()

        mutating func append(_ item: String) {
            if seen.insert(item).inserted { items.append(item) }
        }

        mutating func append(contentsOf items: [String]) {
            for item in items { append(item) }
        }
    }
}

/// The commands a shell script calls, read well enough to describe it: by
/// absolute path (`/usr/bin/top`), by bare name (`awk`), or looked up with
/// `command -v`. A command run from a variable (`"$d" ps`) is only known when
/// the script runs, so the list is then marked incomplete.
///
/// A reading aid for the permission request, not a security boundary: what
/// runs is decided by the allowlist, which matches the script exactly.
enum ShellScriptCommands {
    struct Result: Equatable {
        let commands: [String]
        /// False when the script runs something it finds at run time.
        let isComplete: Bool
    }

    /// Shell keywords and builtins: control flow and plumbing, not tools.
    static let builtins: Set<String> = [
        "if", "then", "else", "elif", "fi", "for", "in", "do", "done", "while", "until",
        "case", "esac", "function", "select", "time", "!", "{", "}", "[", "[[", "]]", "]",
        "echo", "printf", "test", "true", "false", "exit", "break", "continue", "read",
        "local", "return", "shift", "set", "unset", "export", "readonly", "cd", "pwd",
        "wait", "trap", ":", ".", "source", "type", "alias", "unalias", "getopts", "umask",
        "let", "declare", "typeset", "hash", "shopt", "builtin",
    ]

    static func analyze(_ script: String) -> Result {
        var commands: [String] = []
        var seen = Set<String>()
        var complete = true
        func add(_ name: String) {
            if seen.insert(name).inserted { commands.append(name) }
        }
        scan(script, add: add, dynamic: { complete = false })
        // Programs named only by path elsewhere (a `for b in /opt/…/brew`
        // list, a path in quotes) are still the script's tools.
        for name in absoluteTools(in: script) { add(name) }
        return Result(commands: commands, isComplete: complete)
    }

    // MARK: Lexing

    private enum Piece {
        case word(String, quoted: Bool)
        case separator
    }

    /// Walks the script command by command; `$( … )` is read as a script of
    /// its own where it appears.
    private static func scan(_ script: String, add: (String) -> Void, dynamic: () -> Void) {
        var pieces: [Piece] = []
        var word = ""
        var quoted = false
        var hasWord = false
        func endWord() {
            if hasWord { pieces.append(.word(word, quoted: quoted)) }
            word = ""; quoted = false; hasWord = false
        }
        let chars = Array(script)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            switch c {
            case "\\":
                if i + 1 < chars.count { word.append(chars[i + 1]); hasWord = true }
                i += 2
                continue
            case "'":
                // Data: a printf format, an awk program, AppleScript.
                var j = i + 1
                while j < chars.count, chars[j] != "'" { j += 1 }
                word += String(chars[min(i + 1, chars.count)..<min(j, chars.count)])
                quoted = true; hasWord = true
                i = j + 1
                continue
            case "\"":
                var j = i + 1
                var content = ""
                while j < chars.count, chars[j] != "\"" {
                    if chars[j] == "\\", j + 1 < chars.count {
                        content.append(chars[j + 1]); j += 2; continue
                    }
                    if chars[j] == "$", j + 1 < chars.count, chars[j + 1] == "(" {
                        let (inner, end) = substitution(chars, from: j + 2)
                        scan(inner, add: add, dynamic: dynamic)
                        content += "$_"
                        j = end + 1
                        continue
                    }
                    content.append(chars[j]); j += 1
                }
                word += content
                quoted = true; hasWord = true
                i = j + 1
                continue
            case "$" where i + 1 < chars.count && chars[i + 1] == "(":
                let (inner, end) = substitution(chars, from: i + 2)
                scan(inner, add: add, dynamic: dynamic)
                word += "$_"; hasWord = true
                i = end + 1
                continue
            case "`":
                var j = i + 1
                while j < chars.count, chars[j] != "`" { j += 1 }
                scan(String(chars[min(i + 1, chars.count)..<min(j, chars.count)]), add: add, dynamic: dynamic)
                word += "$_"; hasWord = true
                i = j + 1
                continue
            case ";", "|", "&", "(", ")", "\n":
                endWord()
                pieces.append(.separator)
            case " ", "\t":
                endWord()
            default:
                word.append(c); hasWord = true
            }
            i += 1
        }
        endWord()

        var command: [(String, Bool)] = []
        for piece in pieces + [.separator] {
            switch piece {
            case let .word(text, quoted): command.append((text, quoted))
            case .separator:
                if !command.isEmpty { read(command, add: add, dynamic: dynamic) }
                command = []
            }
        }
    }

    /// The text of `$( … )` starting after the parenthesis, and the index of
    /// its closing one; quotes and nested parentheses are respected.
    private static func substitution(_ chars: [Character], from start: Int) -> (String, Int) {
        var depth = 1
        var j = start
        var quote: Character?
        while j < chars.count {
            let c = chars[j]
            if let open = quote {
                if c == open { quote = nil }
            } else if c == "'" || c == "\"" {
                quote = c
            } else if c == "(" {
                depth += 1
            } else if c == ")" {
                depth -= 1
                if depth == 0 { break }
            }
            j += 1
        }
        return (String(chars[start..<min(j, chars.count)]), j)
    }

    /// One simple command: skips assignments and keywords, then names the
    /// program it runs.
    private static func read(_ words: [(String, Bool)], add: (String) -> Void, dynamic: () -> Void) {
        var index = 0
        let leading: Set<String> = ["if", "then", "else", "elif", "do", "while", "until", "!", "{", "}", "time", "exec", "nohup", "env"]
        while index < words.count {
            let (text, quoted) = words[index]
            if !quoted, leading.contains(text) { index += 1; continue }
            if isAssignment(text) { index += 1; continue }
            break
        }
        guard index < words.count else { return }
        let (first, _) = words[index]
        // A word list or a pattern, not a command.
        if ["for", "case", "select", "function", "fi", "done", "esac", ";;"].contains(first) { return }
        if first == "eval" { dynamic(); return }
        if first == "command" {
            let rest = words[(index + 1)...].map(\.0)
            if let flag = rest.firstIndex(where: { $0 == "-v" || $0 == "-V" }) {
                if let name = rest.dropFirst(flag - rest.startIndex + 1).first, isName(name) { add(name) }
                return
            }
            if let name = rest.first(where: { !$0.hasPrefix("-") }) { classify(name, add: add, dynamic: dynamic) }
            return
        }
        classify(first, add: add, dynamic: dynamic)
    }

    private static func classify(_ word: String, add: (String) -> Void, dynamic: () -> Void) {
        if word.contains("$") { dynamic(); return }
        if word.contains("/") {
            let name = (word as NSString).lastPathComponent
            if isName(name) { add(name) }
            return
        }
        guard !builtins.contains(word), isName(word) else { return }
        add(word)
    }

    private static func isAssignment(_ word: String) -> Bool {
        guard let equals = word.firstIndex(of: "="), equals != word.startIndex else { return false }
        let name = word[..<equals]
        return name.allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber } && !(name.first?.isNumber ?? true)
    }

    private static func isName(_ word: String) -> Bool {
        guard let first = word.first, first.isLetter || first.isNumber else { return false }
        return word.allSatisfy { $0.isLetter || $0.isNumber || "._+-".contains($0) }
    }

    /// Executables named by absolute path: anything in a `bin` folder
    /// (`/usr/bin/top`, `/opt/homebrew/bin/brew`, `…/Resources/bin/docker`).
    static func absoluteTools(in script: String) -> [String] {
        let pathChars = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-")
        let binFolders: Set<String> = ["bin", "sbin", "xbin"]
        var tools: [String] = []
        var seen = Set<String>()
        let chars = Array(script)
        var i = 0
        while i < chars.count {
            guard chars[i] == "/" else { i += 1; continue }
            var j = i
            while j < chars.count, pathChars.contains(chars[j]) { j += 1 }
            let token = String(chars[i..<j]) as NSString
            let name = token.lastPathComponent
            let folder = token.deletingLastPathComponent.split(separator: "/").last.map(String.init) ?? ""
            if binFolders.contains(folder), isName(name), seen.insert(name).inserted { tools.append(name) }
            i = j
        }
        return tools
    }
}
