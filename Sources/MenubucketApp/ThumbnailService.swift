import AppKit
import CryptoKit
import MenubucketCore
import QuickLookThumbnailing

/// File thumbnails for `fileThumbnail` image nodes — file-stack's layered
/// design: NSCache → disk cache (keyed by path hash + mtime) → QuickLook
/// generation, with in-flight coalescing so a grid of identical paths costs
/// one generation.
final class ThumbnailService: @unchecked Sendable {
    static let shared = ThumbnailService()

    static let memoryCountLimit = 200
    /// Byte budget for the in-memory cache (R05 perf): count alone lets 200
    /// large thumbnails hold tens of MB; NSCache evicts by cost first.
    static let memoryCostLimitBytes = 32 * 1024 * 1024
    static let diskLimitBytes = 200 * 1024 * 1024
    /// Quick Look can consume substantial CPU and memory while rendering a
    /// preview. Bound outstanding work when a large file grid appears.
    static let maximumConcurrentGenerations = 4
    static let maximumQueuedGenerations = 128
    static let maximumCallbacksPerGeneration = 256
    static let generationTimeout: TimeInterval = 15
    static let failureRetryDelay: TimeInterval = 15
    static let maximumFailureEntries = 512
    typealias Generator = (String, CGFloat, @escaping (NSImage?) -> Void) -> (() -> Void)

    private let cache = NSCache<NSString, NSImage>()
    private let diskDirectory: URL
    private let queue = DispatchQueue(label: "dev.barshelf.thumbnails", qos: .userInitiated)
    private let lock = NSLock()
    private var inFlight: [String: [(NSImage?) -> Void]] = [:]
    private var pendingRequests: [(key: String, path: String, pointSize: CGFloat)] = []
    private var activeGenerations = 0
    private var generationStartScheduled = false
    private var failures: [String: TimeInterval] = [:]
    private let now: () -> TimeInterval
    private let generator: Generator
    private let generationTimeout: TimeInterval
    private struct Generation {
        let id: UUID
        let deadline: DispatchSourceTimer
        var cancel: (() -> Void)?
    }
    /// Owned by the serial queue. IDs reject late callbacks after cancellation.
    private var generations: [String: Generation] = [:]
    /// Writes are often bursty while a grid appears. Coalesce maintenance so
    /// long-running sessions are bounded without scanning the directory per tile.
    private var pruneScheduled = false

    init(diskDirectory: URL? = nil, now: @escaping () -> TimeInterval = SleepAwareClock.now,
         generationTimeout: TimeInterval = ThumbnailService.generationTimeout,
         generator: Generator? = nil) {
        self.now = now
        self.generator = generator ?? Self.generate
        self.generationTimeout = generationTimeout.isFinite
            ? min(Self.generationTimeout, max(0.001, generationTimeout)) : Self.generationTimeout
        cache.countLimit = Self.memoryCountLimit
        cache.totalCostLimit = Self.memoryCostLimitBytes
        self.diskDirectory = diskDirectory ?? FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BarShelf/thumbnails")
        try? FileManager.default.createDirectory(at: self.diskDirectory, withIntermediateDirectories: true)
        queue.async { [weak self] in self?.pruneDiskCache() }
    }

    deinit {
        for generation in generations.values {
            generation.deadline.cancel()
            generation.cancel?()
        }
    }

    func icon(forPath path: String) -> NSImage {
        DockActions.fileIcon(at: path)
    }

    /// Completion always lands on the main queue. Returns the cached image
    /// synchronously when it is already in memory (avoids placeholder flash).
    @discardableResult
    func thumbnail(
        path: String,
        modifiedAt: Double?,
        pointSize: CGFloat,
        completion: @escaping (NSImage?) -> Void
    ) -> NSImage? {
        let boundedPointSize = Self.boundedPointSize(pointSize)
        let key = Self.cacheKey(path: path, modifiedAt: modifiedAt, pointSize: boundedPointSize)
        if let hit = cache.object(forKey: key as NSString) {
            return hit
        }

        lock.lock()
        if let retryAt = failures[key] {
            if now() < retryAt {
                lock.unlock()
                DispatchQueue.main.async { completion(nil) }
                return nil
            }
            failures.removeValue(forKey: key)
        }
        if var callbacks = inFlight[key] {
            if callbacks.count < Self.maximumCallbacksPerGeneration {
                callbacks.append(completion)
                inFlight[key] = callbacks
            } else {
                DispatchQueue.main.async { completion(nil) }
            }
            lock.unlock()
            return nil
        }
        guard pendingRequests.count < Self.maximumQueuedGenerations else {
            lock.unlock()
            DispatchQueue.main.async { completion(nil) }
            return nil
        }
        inFlight[key] = [completion]
        pendingRequests.append((key, path, boundedPointSize))
        lock.unlock()
        schedulePendingGenerations()
        return nil
    }

    // MARK: - Internals

    /// Sanitizes externally supplied layout values before they participate in
    /// both cache identity and Quick Look generation.
    static func boundedPointSize(_ pointSize: CGFloat) -> CGFloat {
        guard pointSize.isFinite else { return 1 }
        return min(max(pointSize, 1), 512)
    }

    /// `Double`'s bit pattern retains sub-second mtimes and has defined
    /// behavior for non-finite values, unlike conversion to `Int`.
    static func cacheKey(path: String, modifiedAt: Double?, pointSize: CGFloat) -> String {
        let digest = SHA256.hash(data: Data(path.utf8))
            .map { String(format: "%02x", $0) }.joined().prefix(32)
        let mtime = modifiedAt.map { String($0.bitPattern, radix: 16) } ?? "none"
        let size = Double(boundedPointSize(pointSize)).bitPattern
        return "\(digest)-\(mtime)-\(String(size, radix: 16))"
    }

    /// Approximate decoded size in bytes (pixels × 4) as the NSCache cost.
    static func cacheCost(of image: NSImage) -> Int {
        let pixels = image.representations
            .map { $0.pixelsWide * $0.pixelsHigh }
            .max() ?? Int(image.size.width * image.size.height)
        return max(pixels, 1) * 4
    }

    private func schedulePendingGenerations() {
        lock.lock()
        guard !generationStartScheduled else {
            lock.unlock()
            return
        }
        generationStartScheduled = true
        lock.unlock()
        queue.async { [weak self] in self?.startPendingGenerations() }
    }

    /// Runs only on `queue`; a Quick Look request retains its slot until its
    /// completion has been cached and all waiting views have been notified.
    private func startPendingGenerations() {
        lock.lock()
        generationStartScheduled = false
        lock.unlock()
        while true {
            lock.lock()
            guard activeGenerations < Self.maximumConcurrentGenerations, !pendingRequests.isEmpty else {
                lock.unlock()
                return
            }
            let request = pendingRequests.removeFirst()
            activeGenerations += 1
            lock.unlock()
            load(request)
        }
    }

    private func load(_ request: (key: String, path: String, pointSize: CGFloat)) {
        if let image = loadFromDisk(key: request.key) {
            completeGeneration(key: request.key, image: image)
            return
        }
        let id = UUID()
        let deadline = DispatchSource.makeTimerSource(queue: queue)
        deadline.schedule(deadline: .now() + generationTimeout)
        deadline.setEventHandler { [weak self] in
            self?.finishGeneration(key: request.key, id: id, image: nil, timedOut: true)
        }
        generations[request.key] = Generation(id: id, deadline: deadline)
        deadline.resume()
        let cancel = generator(request.path, request.pointSize) { [weak self] image in
            guard let self else { return }
            self.queue.async { [weak self] in
                self?.finishGeneration(key: request.key, id: id, image: image, timedOut: false)
            }
        }
        generations[request.key]?.cancel = cancel
    }

    private func finishGeneration(key: String, id: UUID, image: NSImage?, timedOut: Bool) {
        guard let generation = generations[key], generation.id == id else { return }
        generations.removeValue(forKey: key)
        generation.deadline.cancel()
        if timedOut { generation.cancel?() }
        if let image {
            saveToDisk(key: key, image: image)
            scheduleDiskPrune()
        }
        completeGeneration(key: key, image: image)
    }

    /// Runs only on `queue` after disk lookup or Quick Look generation.
    private func completeGeneration(key: String, image: NSImage?) {
        if let image {
            cache.setObject(image, forKey: key as NSString, cost: Self.cacheCost(of: image))
        }
        lock.lock()
        if image == nil {
            if failures[key] == nil, failures.count >= Self.maximumFailureEntries,
               let oldest = failures.min(by: { $0.value < $1.value })?.key {
                failures.removeValue(forKey: oldest)
            }
            failures[key] = now() + Self.failureRetryDelay
        } else {
            failures.removeValue(forKey: key)
        }
        let callbacks = inFlight.removeValue(forKey: key) ?? []
        lock.unlock()
        DispatchQueue.main.async {
            for callback in callbacks { callback(image) }
        }
        lock.lock()
        activeGenerations = max(0, activeGenerations - 1)
        lock.unlock()
        schedulePendingGenerations()
    }

    private static func generate(path: String, pointSize: CGFloat, completion: @escaping (NSImage?) -> Void) -> (() -> Void) {
        let boundedPointSize = Self.boundedPointSize(pointSize)
        let request = QLThumbnailGenerator.Request(
            fileAt: URL(fileURLWithPath: path),
            size: CGSize(width: boundedPointSize, height: boundedPointSize),
            scale: NSScreen.main?.backingScaleFactor ?? 2,
            representationTypes: .thumbnail
        )
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
            completion(representation.map { rep in
                NSImage(cgImage: rep.cgImage, size: CGSize(width: boundedPointSize, height: boundedPointSize))
            })
        }
        return { QLThumbnailGenerator.shared.cancel(request) }
    }

    private func diskURL(key: String) -> URL {
        diskDirectory.appendingPathComponent(key).appendingPathExtension("png")
    }

    private func loadFromDisk(key: String) -> NSImage? {
        NSImage(contentsOf: diskURL(key: key))
    }

    private func saveToDisk(key: String, image: NSImage) {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: diskURL(key: key))
    }

    private func scheduleDiskPrune() {
        guard !pruneScheduled else { return }
        pruneScheduled = true
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.pruneDiskCache()
            self?.pruneScheduled = false
        }
    }

    /// Oldest-first prune to the 200 MB budget (startup housekeeping).
    private func pruneDiskCache() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: diskDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
        ) else { return }
        var entries: [(url: URL, date: Date, size: Int)] = files.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            else { return nil }
            return (url, values.contentModificationDate ?? .distantPast, values.fileSize ?? 0)
        }
        var total = entries.reduce(0) { $0 + $1.size }
        guard total > Self.diskLimitBytes else { return }
        entries.sort { $0.date < $1.date }
        for entry in entries where total > Self.diskLimitBytes {
            if (try? fm.removeItem(at: entry.url)) != nil {
                total -= entry.size
            }
        }
    }
}
