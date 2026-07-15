import Foundation

/// Runtime enforcement of the manifest `permissions.exec` allowlist.
///
/// A command is permitted when some `ExecPermission` matches:
/// - `permission.command` exactly equals the command's argv[0], and
/// - some `allowedArgs` pattern matches the remaining argv element-wise,
///   where the literal `"*"` matches exactly one argument.
///
/// An entry with no `allowedArgs` (nil) allows any arguments for that binary;
/// an empty `allowedArgs` array allows only the bare command.
public enum ExecAllowlist {
    /// Returns the first matching permission, or nil when blocked.
    public static func match(
        command: [String],
        permissions: [Manifest.ExecPermission]?
    ) -> Manifest.ExecPermission? {
        guard let command0 = command.first, !command0.isEmpty else { return nil }
        let args = Array(command.dropFirst())
        for permission in permissions ?? [] {
            guard commandMatches(declared: permission.command, argv0: command0) else { continue }
            guard let patterns = permission.allowedArgs else { return permission }
            if patterns.isEmpty {
                if args.isEmpty { return permission }
                continue
            }
            if patterns.contains(where: { argsMatch(args: args, pattern: $0) }) {
                return permission
            }
        }
        return nil
    }

    public static func permits(
        command: [String],
        permissions: [Manifest.ExecPermission]?
    ) -> Bool {
        match(command: command, permissions: permissions) != nil
    }

    /// Bare names and paths are different executable identities. This keeps a
    /// familiar declared name such as `date` from authorizing `./date` or an
    /// attacker-controlled `/tmp/date`.
    static func commandMatches(declared: String, argv0: String) -> Bool {
        declared == argv0
    }

    /// Element-wise pattern match; `"*"` matches exactly one argument.
    /// Lengths must be equal — a pattern never matches a longer argv.
    static func argsMatch(args: [String], pattern: [String]) -> Bool {
        guard args.count == pattern.count else { return false }
        for (arg, expected) in zip(args, pattern) where expected != "*" && expected != arg {
            return false
        }
        return true
    }
}
