import Foundation

/// How a page (a widget's `bucket.group`) is named on screen.
///
/// The stored name is a key — layout prefs, page order and moves all use it —
/// so it never changes. Only its label follows the app's language: the pages
/// bundled widgets start on ("General", "Demo", "Files", …) are shown in the
/// gallery's words for them. These conventional group keys share one label;
/// other names retain their exact spelling, case and whitespace.
enum PageName {
    static func label(_ group: String) -> String {
        switch group {
        case "General": return String(localized: "General")
        case "Demo", "Everyday", "Developer", "System", "Productivity", "Files", "Media", "Security":
            return GalleryEntryText.categoryLabel(group)
        default: return group
        }
    }
}
