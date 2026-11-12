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
        /// False when `tools` may not be all of them: a script runs
        /// something it finds at run time, or a command may be given any
        /// arguments or code.
        let toolsAreComplete: Bool
        /// A command that may be run with any arguments, or a shell or
        /// interpreter that may be handed any code.
        let isOpenEnded: Bool
        /// Variables a command is handed besides the widget's own `env`.
        let environment: [String]
    }

    /// Nil when the manifest declares no commands.
    static func summary(for manifest: Manifest, localization: WidgetLocalization?) -> Summary? {
        let entries = manifest.permissions?.exec ?? []
        guard !entries.isEmpty else { return nil }
        var phrases = OrderedSet()
        var lines: [String] = []
        var tools = OrderedSet()
        var environment = OrderedSet()
        var complete = true
        var openEnded = false
        for entry in entries {
            let name = friendlyCommandName(entry.command)
            let patterns: [[String]]? = entry.allowedArgs.map { $0.isEmpty ? [[]] : $0 }
            let purpose = entry.purpose?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !purpose.isEmpty {
                phrases.append(localization?.text(purpose) ?? purpose)
            }
            tools.append(name)
            environment.append(contentsOf: entry.env ?? [])
            guard let patterns else {
                // Always said, purpose or not: a purpose describes what the
                // widget means to do, not everything the grant allows. The
                // phrase differs from a narrow entry's, so the two are never
                // merged into one line.
                phrases.append(anyArguments(name))
                lines.append(commandLine(entry.command, ["…"]))
                complete = false
                openEnded = true
                continue
            }
            for args in patterns {
                lines.append(commandLine(entry.command, args))
                if takesAnyCode(command: entry.command, args: args) {
                    phrases.append(anyArguments(name))
                    complete = false
                    openEnded = true
                    continue
                }
                if let script = shellScript(command: entry.command, args: args) {
                    let found = ShellScriptCommands.analyze(script)
                    tools.append(contentsOf: found.commands)
                    if !found.isComplete { complete = false }
                }
                if purpose.isEmpty { phrases.append(describe(command: entry.command, args: args)) }
            }
        }
        return Summary(
            phrases: phrases.items, commandLines: lines, tools: tools.items,
            toolsAreComplete: complete, isOpenEnded: openEnded, environment: environment.items
        )
    }

    private static func anyArguments(_ name: String) -> String {
        String(localized: "Run \(name) with any arguments", comment: "Permission request: a command allowed with any arguments")
    }

    /// Programs that run code handed to them on the command line.
    static let interpreters: Set<String> = ["python", "python2", "python3", "perl", "ruby", "node", "deno", "osascript", "php", "lua", "tclsh"]
    static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "ksh", "fish", "csh", "tcsh"]

    static func isInterpreter(_ name: String) -> Bool {
        let name = name.lowercased()
        return interpreters.contains(name) || name.hasPrefix("python") || name.hasPrefix("perl")
    }

    /// A shell or interpreter whose code comes from a wildcard: whatever
    /// the widget passes runs.
    static func takesAnyCode(command: String, args: [String]) -> Bool {
        let name = friendlyCommandName(command).lowercased()
        guard shells.contains(name) || isInterpreter(name) else { return false }
        for (index, arg) in args.enumerated() where ["-c", "-e", "--eval", "-E"].contains(arg) {
            if index + 1 >= args.count || args[index + 1] == "*" { return true }
        }
        // A shell given only wildcards runs a script file someone else chose.
        return !args.isEmpty && args.allSatisfy { $0 == "*" }
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
        "wait", ":", "type", "unalias", "getopts", "umask",
        "let", "declare", "typeset", "hash", "shopt",
    ]

    /// Words that run code the reader cannot see: another file, a string
    /// run later, a command line built from input.
    static let opaque: Set<String> = ["eval", "source", ".", "trap", "builtin", "alias", "xargs", "parallel"]

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
                    if chars[j] == "`" {
                        // A command substitution inside double quotes.
                        var k = j + 1
                        while k < chars.count, chars[k] != "`" { k += 1 }
                        scan(String(chars[(j + 1)..<min(k, chars.count)]), add: add, dynamic: dynamic)
                        content += "$_"
                        j = k + 1
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
            case "&" where i > 0 && (chars[i - 1] == ">" || chars[i - 1] == "<"):
                // `2>&1`: part of a redirection, not a separator.
                word.append(c); hasWord = true
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

    /// One simple command: skips assignments, keywords and wrappers
    /// (`exec`, `nohup`, `time`, `env`, `sudo`), then names the program it
    /// runs. Anything that hides what runs marks the script incomplete.
    private static func read(_ words: [(String, Bool)], add: (String) -> Void, dynamic: () -> Void) {
        let leading: Set<String> = ["if", "then", "else", "elif", "do", "while", "until", "!", "{", "}", "exec", "nohup", "coproc"]
        var rest = ArraySlice(words)
        while let (word, quoted) = rest.first {
            let name = (word as NSString).lastPathComponent
            if !quoted, leading.contains(word) { rest = rest.dropFirst(); continue }
            if isAssignment(word) || isRedirection(word) { rest = rest.dropFirst(); continue }
            if !quoted, word == "time" {
                // Harmless itself, but `time` and `env` are ways to run a
                // command the reader might misjudge; say the list may be short.
                dynamic()
                rest = rest.dropFirst()
                while let option = rest.first?.0, option.hasPrefix("-") { rest = rest.dropFirst() }
                continue
            }
            if name == "env" {
                add("env")
                dynamic()
                rest = rest.dropFirst()
                // Its options and NAME=value pairs; `-S` splits a string
                // into a command line the reader does not see.
                while let option = rest.first?.0, option.hasPrefix("-") || isAssignment(option) {
                    if option.hasPrefix("-S") || option.hasPrefix("--split-string") { dynamic() }
                    rest = rest.dropFirst()
                    if ["-u", "-C", "-P", "--unset", "--chdir"].contains(option) { rest = rest.dropFirst() }
                }
                continue
            }
            if name == "sudo" || name == "doas" {
                // Runs the rest as another user, and its options can take
                // a command of their own.
                add(name)
                dynamic()
                rest = rest.dropFirst()
                while let option = rest.first?.0, option.hasPrefix("-") { rest = rest.dropFirst() }
                continue
            }
            break
        }
        guard let first = rest.first?.0 else { return }
        // A word list or a pattern, not a command.
        if ["for", "case", "select", "function", "fi", "done", "esac", ";;", "in"].contains(first) { return }
        let name = (first as NSString).lastPathComponent
        if opaque.contains(first) || opaque.contains(name) {
            if isName(name) { add(name) }
            dynamic()
            return
        }
        let args = rest.dropFirst().map(\.0)
        if first == "command" {
            if let flag = args.firstIndex(where: { $0 == "-v" || $0 == "-V" }) {
                if flag + 1 < args.count, isName(args[flag + 1]) { add(args[flag + 1]) }
                return
            }
            read(Array(rest.dropFirst().drop { $0.0.hasPrefix("-") }), add: add, dynamic: dynamic)
            return
        }
        if first.contains("$") { dynamic(); return }
        guard isName(name), !builtins.contains(first) else { return }
        add(name)
        let lower = name.lowercased()
        if ExecPermissionText.shells.contains(lower), let flag = args.firstIndex(of: "-c") {
            // A shell inside the script: read its script too, but what it
            // runs may be built from input.
            if flag + 1 < args.count { scan(args[flag + 1], add: add, dynamic: dynamic) }
            dynamic()
        } else if ExecPermissionText.isInterpreter(lower),
                  args.contains(where: { ["-c", "-e", "-E", "--eval"].contains($0) }) {
            // Code on the command line (`python3 -c`, `osascript -e`) can
            // run anything.
            dynamic()
        } else if lower == "find", args.contains(where: { ["-exec", "-execdir", "-ok", "-okdir"].contains($0) }) {
            dynamic()
        } else if ["awk", "gawk", "nawk", "mawk"].contains(lower),
                  args.contains(where: { $0.contains("system(") || $0.contains("|") }) {
            // An awk program that starts commands of its own.
            dynamic()
        }
    }

    private static func isAssignment(_ word: String) -> Bool {
        guard let equals = word.firstIndex(of: "="), equals != word.startIndex else { return false }
        let name = word[..<equals]
        return name.allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber } && !(name.first?.isNumber ?? true)
    }

    /// `2>/dev/null`, `>out`, `3>&1`.
    private static func isRedirection(_ word: String) -> Bool {
        guard let index = word.firstIndex(where: { $0 == ">" || $0 == "<" }) else { return false }
        return word[..<index].allSatisfy(\.isNumber)
    }

    private static func isName(_ word: String) -> Bool {
        guard let first = word.first, first.isLetter || first.isNumber,
              !word.allSatisfy(\.isNumber) else { return false }
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
