import CoreServices
import Foundation
import MenubucketCore

/// FSEvents watcher (file-stack `DirectoryWatcher` pattern), extended for
/// multiple paths and a trailing debounce (default 250 ms). The handler is
/// always invoked on the main queue.
@MainActor
final class DirectoryWatcher {
    enum WatcherError: Error {
        case failedToCreateStream
        case failedToStartStream
    }

    private let eventHandler: () -> Void
    private let debounceInterval: TimeInterval
    private var cancelled = false
    private let fsQueue = DispatchQueue(label: "dev.barshelf.directorywatcher")
    private let resources = Resources()

    /// What has to be undone: the stream or the descriptor source, and a
    /// debounced callback still waiting. A main-actor `deinit` cannot reach
    /// these itself; this is released with the watcher and undoes them at
    /// the same moment, as `cancel()` does earlier.
    private final class Resources {
        var stream: FSEventStreamRef?
        var descriptorSource: DispatchSourceFileSystemObject?
        var pendingWork: DispatchWorkItem?

        func tearDown() {
            pendingWork?.cancel()
            pendingWork = nil
            descriptorSource?.cancel()
            descriptorSource = nil
            guard let stream else { return }
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }

        deinit { tearDown() }
    }

    /// Handed to FSEvents, whose callback runs on `fsQueue` and only carries
    /// it to the main queue.
    private final class WeakBox: Sendable {
        weak let watcher: DirectoryWatcher?
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

        resources.stream = stream
        FSEventStreamSetDispatchQueue(stream, fsQueue)
        if !FSEventStreamStart(stream) {
            cancel()
            throw WatcherError.failedToStartStream
        }
    }

    /// Watches the exact directory object that was authorized and listed.
    /// This avoids reopening a manifest-controlled path after the permission
    /// check, where a symlink substitution could otherwise retarget the watch.
    init(
        directory: FileSource.AuthorizedDirectory,
        debounce: TimeInterval = 0.25,
        eventHandler: @escaping () -> Void
    ) throws {
        self.eventHandler = eventHandler
        self.debounceInterval = debounce

        let descriptor = try directory.duplicateFileDescriptor()
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .attrib, .extend, .link, .revoke],
            queue: fsQueue
        )
        source.setEventHandler { [weak self] in
            DispatchQueue.main.async { [weak self] in
                self?.fireDebounced()
            }
        }
        source.setCancelHandler {
            close(descriptor)
        }
        resources.descriptorSource = source
        source.resume()
    }

    /// Coalesces bursts of FSEvents into a single trailing-edge callback.
    func fireDebounced() {
        guard !cancelled else { return }
        resources.pendingWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.cancelled else { return }
            self.eventHandler()
        }
        resources.pendingWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }

    func cancel() {
        cancelled = true
        resources.tearDown()
    }
}
