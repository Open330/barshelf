import CoreServices
import Foundation

/// FSEvents watcher (file-stack `DirectoryWatcher` pattern), extended for
/// multiple paths and a trailing debounce (default 250 ms). The handler is
/// always invoked on the main queue.
final class DirectoryWatcher {
    enum WatcherError: Error {
        case failedToCreateStream
        case failedToStartStream
    }

    private var stream: FSEventStreamRef?
    private let eventHandler: () -> Void
    private let debounceInterval: TimeInterval
    private var pendingWork: DispatchWorkItem?
    private let fsQueue = DispatchQueue(label: "dev.barshelf.directorywatcher")

    private class WeakBox {
        weak var watcher: DirectoryWatcher?
        init(_ watcher: DirectoryWatcher) {
            self.watcher = watcher
        }
    }

    init(paths: [String], debounce: TimeInterval = 0.25, eventHandler: @escaping () -> Void) throws {
        self.eventHandler = eventHandler
        self.debounceInterval = debounce

        let weakBox = WeakBox(self)
        var context = FSEventStreamContext(version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
        context.info = Unmanaged.passRetained(weakBox).toOpaque()
        context.release = { ptr in
            guard let ptr = ptr else { return }
            Unmanaged<WeakBox>.fromOpaque(ptr).release()
        }

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info = info else { return }
            let box = Unmanaged<WeakBox>.fromOpaque(info).takeUnretainedValue()
            DispatchQueue.main.async {
                box.watcher?.fireDebounced()
            }
        }

        let expandedPaths = paths.map { ($0 as NSString).expandingTildeInPath }
        guard !expandedPaths.isEmpty,
              let stream = FSEventStreamCreate(
                  nil,
                  callback,
                  &context,
                  expandedPaths as CFArray,
                  FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                  0.1,
                  FSEventStreamCreateFlags(
                      kFSEventStreamCreateFlagFileEvents
                          | kFSEventStreamCreateFlagWatchRoot
                          | kFSEventStreamCreateFlagNoDefer
                  )
              )
        else {
            if let info = context.info {
                Unmanaged<WeakBox>.fromOpaque(info).release()
            }
            throw WatcherError.failedToCreateStream
        }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, fsQueue)
        if !FSEventStreamStart(stream) {
            cancel()
            throw WatcherError.failedToStartStream
        }
    }

    /// Coalesces bursts of FSEvents into a single trailing-edge callback.
    private func fireDebounced() {
        pendingWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.eventHandler()
        }
        pendingWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }

    func cancel() {
        pendingWork?.cancel()
        pendingWork = nil
        guard let stream = stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit {
        cancel()
    }
}
