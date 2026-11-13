import Foundation

/// Which page the popup opens on.
///
/// The pager lives as long as the app, so within one run the popup already
/// comes back where it was left. This adds the two things that were missing:
/// a way to say "always start at the first page", and the last page
/// surviving a relaunch. The page is remembered by name, not by position:
/// pages are reordered, renamed and removed.
enum PopupStartPage {
    static let defaultsKey = "popupLastPage"

    /// - Parameters:
    ///   - remembers: the "Reopen on the last page" preference.
    ///   - restoring: the page saved by the previous run, given only for the
    ///     first opening after launch; nil afterwards, when `current` is
    ///     already the page the popup was left on.
    ///   - current: the pager's index now.
    ///   - groups: the pages' names, in order.
    static func index(remembers: Bool, restoring: String?, current: Int, groups: [String]) -> Int {
        guard !groups.isEmpty else { return 0 }
        guard remembers else { return 0 }
        if let restoring, let saved = groups.firstIndex(of: restoring) { return saved }
        return min(max(current, 0), groups.count - 1)
    }

    /// What to save when the pager lands on `index`: the page's name, or nil
    /// (forget) when the preference is off or there is no such page.
    static func nameToSave(remembers: Bool, index: Int, groups: [String]) -> String? {
        guard remembers, groups.indices.contains(index) else { return nil }
        return groups[index]
    }
}
