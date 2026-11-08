import Foundation

/// Rules for the `quitApp` action, kept free of AppKit so they are testable:
/// what the action names, and whether the widget may use it at all. The app
/// layer asks the user and does the quitting.
///
///     { "type": "quitApp", "value": "com.apple.TextEdit" }
///     { "type": "quitApp", "value": "${row.pid}" }
public enum QuitAppAction {
    public enum Target: Equatable, Sendable {
        case pid(Int32)
        case bundleID(String)
    }

    public enum Decision: Equatable, Sendable {
        case allowed(Target)
        case blocked(reason: String)
    }

    /// A positive decimal number is a pid; anything else is taken as a
    /// bundle identifier. Nil for a missing or blank value.
    public static func target(of action: NodeAction) -> Target? {
        guard action.type == "quitApp",
              let raw = action.value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else { return nil }
        if raw.allSatisfy(\.isASCII), raw.allSatisfy(\.isNumber) {
            guard let pid = Int32(raw), pid > 0 else { return nil }
            return .pid(pid)
        }
        guard !raw.contains("/"), !raw.contains(" ") else { return nil }
        return .bundleID(raw)
    }

    /// Whether this widget may quit the target, before the user is asked.
    /// Needs an approved permission set that declares `permissions.quitApps`.
    public static func evaluate(
        _ action: NodeAction,
        manifest: Manifest,
        status: PermissionStore.Status
    ) -> Decision {
        guard PermissionStore.manifestDeclares(.quitApps, in: manifest) else {
            return .blocked(reason: "permissions.quitApps is not declared")
        }
        guard status == .approved else {
            return .blocked(reason: "permissions are not approved")
        }
        guard let target = target(of: action) else {
            return .blocked(reason: "value is not a bundle id or pid")
        }
        return .allowed(target)
    }
}
