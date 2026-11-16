import Foundation
import MenubucketCore

/// A live watch on one directory; `cancel` ends it for good.
protocol WorkflowWatch: AnyObject {
    func cancel()
}

extension DirectoryWatcher: WorkflowWatch {}

/// The runtime's side of the registry: whether a change in a watched
/// directory refreshes its widget now, and the refresh itself.
@MainActor
protocol WorkflowWatchRegistryHost: AnyObject {
    /// Whether a change seen now is worth a refresh: the widget's card is
    /// on the open shelf.
    func workflowWatchMayRefresh(widgetID: String) -> Bool
    /// An automatic refresh of the widget, as any other trigger asks for one.
    func refreshForWorkflowWatch(widgetID: String)
}

/// The `fs.directory` sources with `watch: true`: owns one watch per widget
/// and turns a change in the watched directory into a refresh request.
///
/// A widget's watch lives until the next one for the same widget replaces
/// it, or the registry goes away.
///
/// Main-actor isolated, like the runtime it reports to; the watches call
/// back on the main queue.
@MainActor
final class WorkflowWatchRegistry {
    /// Starts watching `directory`; `onChange` runs on the main queue after
    /// each (debounced) change.
    typealias WatchFactory = (
        _ directory: FileSource.AuthorizedDirectory, _ onChange: @escaping () -> Void
    ) throws -> WorkflowWatch

    /// The runtime. Weak: the runtime owns the registry. With none, a
    /// change refreshes nothing.
    weak var host: WorkflowWatchRegistryHost?

    private var watches: [String: WorkflowWatch] = [:]
    private let makeWatch: WatchFactory

    /// - Parameter makeWatch: Nil is a `DirectoryWatcher` on the authorized
    ///   descriptor, debounced like the scheduler's own watches.
    init(makeWatch: WatchFactory? = nil) {
        if let makeWatch {
            self.makeWatch = makeWatch
        } else {
            self.makeWatch = { directory, onChange in
                try DirectoryWatcher(
                    directory: directory,
                    debounce: Scheduler.watchDebounceSec,
                    eventHandler: onChange
                )
            }
        }
    }

    /// Watches `directory` for the widget, in place of the directory it
    /// watched before. When the new watch cannot start, the old one is
    /// already cancelled and nothing is watched.
    func watch(_ directory: FileSource.AuthorizedDirectory, widgetID: String) {
        // Re-arm from every successful listing so the watcher retains the
        // exact descriptor-authorized object, not a subsequently reopened path.
        watches[widgetID]?.cancel()
        do {
            watches[widgetID] = try makeWatch(directory) { [weak self] in
                guard let host = self?.host,
                      host.workflowWatchMayRefresh(widgetID: widgetID)
                else { return }
                host.refreshForWorkflowWatch(widgetID: widgetID)
            }
        } catch {
            NSLog("barshelf: workflow watch unavailable for \(directory.path): \(error)")
        }
    }
}
