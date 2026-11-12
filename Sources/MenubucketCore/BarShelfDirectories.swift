import Foundation

/// Where BarShelf keeps its own files. One definition, so the app and the
/// feature targets beside it (Automation, Dock) cannot drift apart.
public enum BarShelfDirectories {
    /// `~/Library/Application Support/barshelf`
    public static var applicationSupport: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("barshelf", isDirectory: true)
    }
}
