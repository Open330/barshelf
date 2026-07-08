import AppKit
import CryptoKit
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

    private let cache = NSCache<NSString, NSImage>()
    private let diskDirectory: URL
    private let queue = DispatchQueue(label: "dev.barshelf.thumbnails", qos: .userInitiated)
    private let lock = NSLock()
    private var inFlight: [String: [(NSImage?) -> Void]] = [:]

    init(diskDirectory: URL? = nil) {
        cache.countLimit = Self.memoryCountLimit
        cache.totalCostLimit = Self.memoryCostLimitBytes
        self.diskDirectory = diskDirectory ?? FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BarShelf/thumbnails")
        try? FileManager.default.createDirectory(at: self.diskDirectory, withIntermediateDirectories: true)
        queue.async { [weak self] in self?.pruneDiskCache() }
    }

    func icon(forPath path: String) -> NSImage {
        NSWorkspace.shared.icon(forFile: path)
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
        let key = cacheKey(path: path, modifiedAt: modifiedAt, pointSize: pointSize)
        if let hit = cache.object(forKey: key as NSString) {
            return hit
        }

        lock.lock()
        if inFlight[key] != nil {
            inFlight[key]?.append(completion)
            lock.unlock()
            return nil
        }
        inFlight[key] = [completion]
        lock.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            if let image = self.loadFromDisk(key: key) {
                self.finish(key: key, image: image)
                return
            }
            self.generate(path: path, pointSize: pointSize) { image in
                if let image { self.saveToDisk(key: key, image: image) }
                self.finish(key: key, image: image)
            }
        }
        return nil
    }

    // MARK: - Internals

    private func cacheKey(path: String, modifiedAt: Double?, pointSize: CGFloat) -> String {
        let digest = SHA256.hash(data: Data(path.utf8))
            .map { String(format: "%02x", $0) }.joined().prefix(32)
        return "\(digest)-\(Int(modifiedAt ?? 0))-\(Int(pointSize))"
    }

    /// Approximate decoded size in bytes (pixels × 4) as the NSCache cost.
    static func cacheCost(of image: NSImage) -> Int {
        let pixels = image.representations
            .map { $0.pixelsWide * $0.pixelsHigh }
            .max() ?? Int(image.size.width * image.size.height)
        return max(pixels, 1) * 4
    }

    private func finish(key: String, image: NSImage?) {
        if let image {
            cache.setObject(image, forKey: key as NSString, cost: Self.cacheCost(of: image))
        }
        lock.lock()
        let callbacks = inFlight.removeValue(forKey: key) ?? []
        lock.unlock()
        DispatchQueue.main.async {
            for callback in callbacks { callback(image) }
        }
    }

    private func generate(path: String, pointSize: CGFloat, completion: @escaping (NSImage?) -> Void) {
        let request = QLThumbnailGenerator.Request(
            fileAt: URL(fileURLWithPath: path),
            size: CGSize(width: pointSize, height: pointSize),
            scale: NSScreen.main?.backingScaleFactor ?? 2,
            representationTypes: .thumbnail
        )
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
            completion(representation.map { rep in
                NSImage(cgImage: rep.cgImage, size: CGSize(width: pointSize, height: pointSize))
            })
        }
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
            try? fm.removeItem(at: entry.url)
            total -= entry.size
        }
    }
}
