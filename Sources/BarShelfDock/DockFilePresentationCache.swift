import AppKit

/// Hover and widget refreshes redraw the Dock frequently. File metadata and
/// icon services need one read per path, not one per SwiftUI body evaluation.
/// Expiry is checked on use; no polling timer or filesystem watcher is needed.
/// Ten minutes: icons and names rarely change, and reloading every icon in
/// the dock each minute was most of the dock's work at rest.
package final class DockFilePresentationCache {
    package struct Presentation {
        package let name: String
        package let icon: NSImage?
    }
    private final class Entry: NSObject {
        package let presentation: Presentation
        package let expiresAt: Date
        package init(_ presentation: Presentation, expiresAt: Date) {
            self.presentation = presentation
            self.expiresAt = expiresAt
        }
    }
    private let entries = NSCache<NSString, Entry>()
    private let load: (String) -> Presentation
    private let lifetime: TimeInterval

    package init(lifetime: TimeInterval = 600, load: @escaping (String) -> Presentation = {
        Presentation(name: FileManager.default.displayName(atPath: $0),
                     icon: NSWorkspace.shared.icon(forFile: $0))
    }) {
        self.lifetime = lifetime
        self.load = load
        entries.countLimit = 256
    }

    /// Drops what is known about `path`: an app that just launched may be a
    /// new version with a new icon.
    package func forget(_ path: String) {
        entries.removeObject(forKey: RunningApps.key(path) as NSString)
    }

    package func presentation(at path: String, now: Date = Date()) -> Presentation {
        let key = RunningApps.key(path) as NSString
        if let entry = entries.object(forKey: key), now < entry.expiresAt { return entry.presentation }
        let presentation = load(key as String)
        entries.setObject(Entry(presentation, expiresAt: now.addingTimeInterval(lifetime)), forKey: key)
        return presentation
    }
}
