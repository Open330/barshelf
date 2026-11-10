import Foundation

/// Whether a widget's new permissions ask for nothing the user has not
/// already approved: every grant in `new` is covered by `approved`.
///
/// An update that only drops grants (Keep Awake 0.2.0 removed one osascript
/// command) used to put the widget back behind Allow / Deny, because the
/// approval was a hash of the exact set. Asking again for less teaches people
/// to click Allow without reading. Asking again for anything more is still
/// the rule.
///
/// The comparison is deliberately literal: a grant is covered only by the
/// same grant, or by one that plainly contains it. No pattern reasoning —
/// `["a", "*"]` does not cover `["a", "b"]` here even though it matches
/// it at run time — so a doubtful case asks again rather than guessing.
public enum PermissionNarrowing {
    public static func isCovered(_ new: Manifest.Permissions?, by approved: Manifest.Permissions?) -> Bool {
        let new = new ?? Manifest.Permissions()
        let old = approved ?? Manifest.Permissions()
        return subset(new.network, of: old.network)
            && subset(new.readPaths, of: old.readPaths)
            && subset(new.env, of: old.env)
            && subset(new.system, of: old.system)
            && flag(new.keychain, within: old.keychain)
            && flag(new.notifications, within: old.notifications)
            && flag(new.quitApps, within: old.quitApps)
            && storage(new.storage, within: old.storage)
            && (new.exec ?? []).allSatisfy { entry in
                (old.exec ?? []).contains { exec(entry, within: $0) }
            }
    }

    private static func subset(_ new: [String]?, of old: [String]?) -> Bool {
        Set(new ?? []).isSubset(of: Set(old ?? []))
    }

    /// A capability turned on needs it to have been on.
    private static func flag(_ new: Bool?, within old: Bool?) -> Bool {
        new != true || old == true
    }

    private static func storage(_ new: Manifest.StoragePermission?, within old: Manifest.StoragePermission?) -> Bool {
        guard let new, new.granted else { return true }
        guard let old, old.granted else { return false }
        // nil is the host's default quota, which is neither more nor less
        // than a number as far as this check can tell.
        switch (new.maxBytes, old.maxBytes) {
        case (nil, nil): return true
        case let (newBytes?, oldBytes?): return newBytes <= oldBytes
        default: return false
        }
    }

    /// One exec entry inside another for the same command: the argument
    /// patterns it allows, the variables it passes, and how much output it
    /// may return are all within the approved entry's.
    private static func exec(_ new: Manifest.ExecPermission, within old: Manifest.ExecPermission) -> Bool {
        guard new.command == old.command else { return false }
        if let oldPatterns = old.allowedArgs {
            // nil allows any arguments, so it is covered only by nil.
            guard let newPatterns = new.allowedArgs else { return false }
            // An empty list allows only the bare command: the empty pattern.
            let newSet = Set(newPatterns.isEmpty ? [[]] : newPatterns)
            let oldSet = Set(oldPatterns.isEmpty ? [[]] : oldPatterns)
            guard newSet.isSubset(of: oldSet) else { return false }
        }
        guard subset(new.env, of: old.env) else { return false }
        switch (new.maxOutputBytes, old.maxOutputBytes) {
        case (nil, nil): break
        case let (newBytes?, oldBytes?) where newBytes <= oldBytes: break
        default: return false
        }
        // Marking output sensitive only hides more; unmarking it shows more.
        return new.sensitiveOutput == old.sensitiveOutput || new.sensitiveOutput == true
    }
}
