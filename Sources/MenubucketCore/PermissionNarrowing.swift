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
            // Sensitivity is the whole widget's (no logged output, no cached
            // renders) when any command is marked: dropping the one marked
            // command would unmark the rest.
            && (!isSensitive(old) || isSensitive(new))
            && exec(new.exec ?? [], within: old.exec ?? [])
    }

    private static func isSensitive(_ permissions: Manifest.Permissions) -> Bool {
        (permissions.exec ?? []).contains { $0.sensitiveOutput == true }
    }

    /// Exec entries are tried in order and the first match decides the
    /// environment, output limit and redaction a run gets. So the new list
    /// must keep the old entries in their order, each allowing no more than
    /// before; and where an entry was dropped or allows fewer arguments, a
    /// run it used to catch can fall through to a later entry for the same
    /// command, which must then give it no more than the dropped one did.
    private static func exec(_ new: [Manifest.ExecPermission], within old: [Manifest.ExecPermission]) -> Bool {
        // Old index → the entry that replaced it. Earliest fit first, which
        // finds an in-order fit whenever one exists.
        var kept: [Int: Manifest.ExecPermission] = [:]
        var next = 0
        for entry in new {
            guard let index = old[next...].firstIndex(where: { entryWithin(entry, $0) }) else { return false }
            kept[index] = entry
            next = index + 1
        }
        for (index, entry) in old.enumerated() {
            // An entry still catching the same arguments hands nothing on.
            if let now = kept[index], now.allowedArgs == entry.allowedArgs { continue }
            for later in old.indices where later > index {
                guard let laterNow = kept[later], laterNow.command == entry.command else { continue }
                guard attributesWithin(laterNow, entry) else { return false }
            }
        }
        return true
    }

    /// One entry inside another for the same command: the argument
    /// patterns it allows, and what a run it catches gets.
    private static func entryWithin(_ new: Manifest.ExecPermission, _ old: Manifest.ExecPermission) -> Bool {
        guard new.command == old.command else { return false }
        if let oldPatterns = old.allowedArgs {
            // nil allows any arguments, so it is covered only by nil.
            guard let newPatterns = new.allowedArgs else { return false }
            // An empty list allows only the bare command: the empty pattern.
            let newSet = Set(newPatterns.isEmpty ? [[]] : newPatterns)
            let oldSet = Set(oldPatterns.isEmpty ? [[]] : oldPatterns)
            guard newSet.isSubset(of: oldSet) else { return false }
        }
        return attributesWithin(new, old)
    }

    /// What a run caught by `new` gets is no more than `old` gave: the
    /// variables passed, the output allowed, and whether it is hidden.
    private static func attributesWithin(_ new: Manifest.ExecPermission, _ old: Manifest.ExecPermission) -> Bool {
        guard subset(new.env, of: old.env) else { return false }
        switch (new.maxOutputBytes, old.maxOutputBytes) {
        case (nil, nil): break
        case let (newBytes?, oldBytes?) where newBytes <= oldBytes: break
        default: return false
        }
        // Marking output sensitive only hides more; unmarking it shows more.
        return new.sensitiveOutput == old.sensitiveOutput || new.sensitiveOutput == true
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
}
