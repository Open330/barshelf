import AppKit
import CryptoKit

/// Remote images for `url` image nodes (favicons, service logos) — the same
/// layered design as `ThumbnailService`: NSCache → disk cache (keyed by URL
/// hash) → https download, with in-flight coalescing so a list of rows
/// sharing one favicon costs a single fetch.
///
/// Security: https only (the renderer additionally gates loads on the
/// widget's `permissions.network` allowlist before calling in here), GET,
/// 8 s timeout, 2 MB response cap, and the payload must decode as a raster
/// image — SVG/HTML responses are dropped.
final class RemoteImageService: @unchecked Sendable {
    static let shared = RemoteImageService()

    static let memoryCountLimit = 200
    static let memoryCostLimitBytes = 16 * 1024 * 1024
    static let diskLimitBytes = 20 * 1024 * 1024
    static let maxResponseBytes = 2 * 1024 * 1024
    static let timeoutSec: TimeInterval = 8

    private let cache = NSCache<NSString, NSImage>()
    private let diskDirectory: URL
    private let queue = DispatchQueue(label: "dev.barshelf.remote-images", qos: .utility)
    private let lock = NSLock()
    private var inFlight: [String: [(NSImage?) -> Void]] = [:]
    /// URLs that already failed this session — avoids re-hitting a 404 every
    /// time the popup reopens.
    private var failed: Set<String> = []

    init(diskDirectory: URL? = nil) {
        cache.countLimit = Self.memoryCountLimit
        cache.totalCostLimit = Self.memoryCostLimitBytes
        self.diskDirectory = diskDirectory ?? FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BarShelf/remote-images")
        try? FileManager.default.createDirectory(at: self.diskDirectory, withIntermediateDirectories: true)
        queue.async { [weak self] in self?.pruneDiskCache() }
    }

    /// Completion always lands on the main queue. Returns the cached image
    /// synchronously when it is already in memory (avoids placeholder flash).
    @discardableResult
    func image(
        forURL urlString: String,
        completion: @escaping (NSImage?) -> Void
    ) -> NSImage? {
        let key = urlString
        if let hit = cache.object(forKey: key as NSString) {
            return hit
        }

        lock.lock()
        if failed.contains(key) {
            lock.unlock()
            DispatchQueue.main.async { completion(nil) }
            return nil
        }
        if inFlight[key] != nil {
            inFlight[key]?.append(completion)
            lock.unlock()
            return nil
        }
        inFlight[key] = [completion]
        lock.unlock()

        queue.async { [weak self] in self?.load(key: key) }
        return nil
    }

    private func load(key: String) {
        if let data = try? Data(contentsOf: diskFile(for: key)), !data.isEmpty,
           let image = NSImage(data: data) {
            finish(key: key, image: image, cost: data.count)
            return
        }
        guard let url = URL(string: key), url.scheme?.lowercased() == "https" else {
            markFailed(key: key)
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = Self.timeoutSec
        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            guard let self else { return }
            guard let data,
                  let http = response as? HTTPURLResponse, http.statusCode == 200,
                  data.count > 0, data.count <= Self.maxResponseBytes,
                  Self.isRasterImage(data),
                  let image = NSImage(data: data)
            else {
                self.markFailed(key: key)
                return
            }
            self.queue.async {
                try? data.write(to: self.diskFile(for: key), options: .atomic)
            }
            self.finish(key: key, image: image, cost: data.count)
        }
        task.resume()
    }

    private func finish(key: String, image: NSImage, cost: Int) {
        cache.setObject(image, forKey: key as NSString, cost: cost)
        drainCompletions(key: key, image: image)
    }

    private func markFailed(key: String) {
        lock.lock()
        failed.insert(key)
        lock.unlock()
        drainCompletions(key: key, image: nil)
    }

    private func drainCompletions(key: String, image: NSImage?) {
        lock.lock()
        let completions = inFlight.removeValue(forKey: key) ?? []
        lock.unlock()
        DispatchQueue.main.async {
            for completion in completions { completion(image) }
        }
    }

    private func diskFile(for key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return diskDirectory.appendingPathComponent(name + ".img")
    }

    /// Raster magic bytes (PNG/JPEG/GIF/BMP/ICO/WEBP) — rejects SVG/HTML that
    /// NSImage might partially handle or that isn't an image at all.
    static func isRasterImage(_ data: Data) -> Bool {
        guard data.count >= 12 else { return false }
        let b = [UInt8](data.prefix(12))
        if b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47 { return true }          // PNG
        if b[0] == 0xFF, b[1] == 0xD8, b[2] == 0xFF { return true }                        // JPEG
        if b[0] == 0x47, b[1] == 0x49, b[2] == 0x46 { return true }                        // GIF
        if b[0] == 0x42, b[1] == 0x4D { return true }                                      // BMP
        if b[0] == 0x00, b[1] == 0x00, b[2] == 0x01, b[3] == 0x00 { return true }          // ICO
        if b[0] == 0x52, b[1] == 0x49, b[2] == 0x46, b[3] == 0x46,
           b[8] == 0x57, b[9] == 0x45, b[10] == 0x42, b[11] == 0x50 { return true }        // WEBP
        return false
    }

    /// Oldest-first eviction once the disk cache exceeds its budget.
    private func pruneDiskCache() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: diskDirectory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
        ) else { return }
        var entries: [(url: URL, size: Int, modified: Date)] = []
        var total = 0
        for file in files {
            let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = values?.fileSize ?? 0
            entries.append((file, size, values?.contentModificationDate ?? .distantPast))
            total += size
        }
        guard total > Self.diskLimitBytes else { return }
        for entry in entries.sorted(by: { $0.modified < $1.modified }) {
            try? fm.removeItem(at: entry.url)
            total -= entry.size
            if total <= Self.diskLimitBytes { break }
        }
    }
}
