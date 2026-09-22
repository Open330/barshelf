import AppKit
import CryptoKit
import ImageIO

extension Notification.Name {
    /// Posted after a user-driven retry clears temporary remote-image failures.
    static let barshelfRemoteImageRetry = Notification.Name("dev.barshelf.remoteImageRetry")
}

/// A bounded, cached loader for remote raster images.
final class RemoteImageService: @unchecked Sendable {
    static let shared = RemoteImageService()
    static let memoryCountLimit = 200
    static let memoryCostLimitBytes = 16 * 1024 * 1024
    static let diskLimitBytes = 20 * 1024 * 1024
    static let maxResponseBytes = 2 * 1024 * 1024
    static let maxPixelDimension = 512
    static let timeoutSec: TimeInterval = 8
    /// Keep a screen full of distinct remote-image nodes from creating an
    /// unbounded number of URL sessions and TCP connections.
    static let maximumConcurrentDownloads = 6
    static let maximumQueuedDownloads = 128
    static let maximumCallbacksPerDownload = 256
    static let maximumFailureEntries = 512

    private let cache = NSCache<NSString, NSImage>()
    private let diskDirectory: URL
    private let queue = DispatchQueue(label: "dev.barshelf.remote-images", qos: .utility)
    private let lock = NSLock()
    private let now: () -> Date
    private let sessionConfiguration: URLSessionConfiguration
    private let maximumConcurrentDownloads: Int
    private var inFlight: [String: [(NSImage?) -> Void]] = [:]
    private var pendingKeys: [String] = []
    private var activeDownloads = 0
    private var loadStartScheduled = false
    private var failures: [String: (attempts: Int, retryAt: Date)] = [:]
    private var pruneScheduled = false

    private final class Download: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate,
        @unchecked Sendable
    {
        let origin: URL
        let limit: Int
        let completed: (Data?, HTTPURLResponse?, Error?) -> Void
        var data = Data()
        var response: HTTPURLResponse?
        var exceededLimit = false
        var session: URLSession?
        init(origin: URL, limit: Int, completed: @escaping (Data?, HTTPURLResponse?, Error?) -> Void) {
            self.origin = origin
            self.limit = limit
            self.completed = completed
        }
        func urlSession(
            _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
            completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
        ) {
            self.response = response as? HTTPURLResponse
            if !RemoteImageService.responseFits(
                limit: limit, expectedContentLength: response.expectedContentLength)
            {
                exceededLimit = true
                completionHandler(.cancel)
            } else {
                completionHandler(.allow)
            }
        }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            guard !exceededLimit else { return }
            guard
                RemoteImageService.responseFits(
                    limit: limit, receivedBytes: self.data.count, nextChunkBytes: data.count)
            else {
                exceededLimit = true
                dataTask.cancel()
                return
            }
            self.data.append(data)
        }
        func urlSession(
            _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
        ) {
            guard let destination = request.url,
                RemoteImageService.redirectAllowed(from: origin, to: destination)
            else {
                completionHandler(nil)
                return
            }
            completionHandler(request)
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            completed(exceededLimit ? nil : data, response, error)
            session.finishTasksAndInvalidate()
            self.session = nil
        }
    }

    init(
        diskDirectory: URL? = nil,
        now: @escaping () -> Date = Date.init,
        sessionConfiguration: URLSessionConfiguration? = nil,
        maximumConcurrentDownloads: Int = 6
    ) {
        cache.countLimit = Self.memoryCountLimit
        cache.totalCostLimit = Self.memoryCostLimitBytes
        self.now = now
        self.sessionConfiguration = (sessionConfiguration?.copy() as? URLSessionConfiguration) ?? .ephemeral
        self.maximumConcurrentDownloads = max(1, maximumConcurrentDownloads)
        let resolvedDirectory =
            diskDirectory
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent(
                "BarShelf/remote-images")
        self.diskDirectory = resolvedDirectory
        try? FileManager.default.createDirectory(at: self.diskDirectory, withIntermediateDirectories: true)
        queue.async { [weak self] in self?.pruneDiskCache() }
    }

    @discardableResult func image(forURL urlString: String, completion: @escaping (NSImage?) -> Void)
        -> NSImage?
    {
        let key = urlString
        if let hit = cache.object(forKey: key as NSString) { return hit }
        lock.lock()
        if let failure = failures[key], failure.retryAt > now() {
            lock.unlock()
            DispatchQueue.main.async { completion(nil) }
            return nil
        }
        if var callbacks = inFlight[key] {
            if callbacks.count < Self.maximumCallbacksPerDownload {
                callbacks.append(completion)
                inFlight[key] = callbacks
            } else {
                DispatchQueue.main.async { completion(nil) }
            }
            lock.unlock()
            return nil
        }
        guard pendingKeys.count < Self.maximumQueuedDownloads else {
            lock.unlock()
            DispatchQueue.main.async { completion(nil) }
            return nil
        }
        inFlight[key] = [completion]
        pendingKeys.append(key)
        lock.unlock()
        schedulePendingLoads()
        return nil
    }

    /// Lets a user-initiated widget refresh immediately retry a previously failed URL.
    func retryFailedImages() {
        lock.lock()
        let hadFailures = !failures.isEmpty
        failures.removeAll()
        lock.unlock()
        guard hadFailures else { return }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .barshelfRemoteImageRetry, object: nil)
        }
    }

    private func schedulePendingLoads() {
        lock.lock()
        guard !loadStartScheduled else {
            lock.unlock()
            return
        }
        loadStartScheduled = true
        lock.unlock()
        queue.async { [weak self] in self?.startPendingLoads() }
    }

    /// Runs only on `queue`. A slot remains occupied for the entire network
    /// request, then the completion schedules the next pending key.
    private func startPendingLoads() {
        lock.lock()
        loadStartScheduled = false
        lock.unlock()
        while true {
            lock.lock()
            guard activeDownloads < maximumConcurrentDownloads, !pendingKeys.isEmpty else {
                lock.unlock()
                return
            }
            let key = pendingKeys.removeFirst()
            activeDownloads += 1
            lock.unlock()
            load(key: key)
        }
    }

    private func load(key: String) {
        let diskURL = diskFile(for: key)
        if let data = try? Data(contentsOf: diskURL),
            !data.isEmpty,
            data.count <= Self.maxResponseBytes,
            Self.isRasterImage(data),
            let image = Self.downsampledImage(data)
        {
            completeLoad(key: key, image: image)
            return
        }
        // Never retain a malformed or oversized cache entry indefinitely.
        try? FileManager.default.removeItem(at: diskURL)
        guard let url = URL(string: key), url.scheme?.lowercased() == "https" else {
            completeLoad(key: key, image: nil)
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = Self.timeoutSec
        let download = Download(origin: url, limit: Self.maxResponseBytes) {
            [weak self] data, response, error in
            guard let self else { return }
            // URLSession delegate callbacks are not a suitable place to decode
            // images or mutate cache bookkeeping.
            self.queue.async {
                guard error == nil, let data, let response, response.statusCode == 200, !data.isEmpty,
                    data.count <= Self.maxResponseBytes, Self.isRasterImage(data),
                    let image = Self.downsampledImage(data)
                else {
                    self.completeLoad(key: key, image: nil)
                    return
                }
                try? data.write(to: self.diskFile(for: key), options: .atomic)
                self.scheduleDiskPrune()
                self.completeLoad(key: key, image: image)
            }
        }
        let session = URLSession(configuration: sessionConfiguration, delegate: download, delegateQueue: nil)
        download.session = session
        session.dataTask(with: request).resume()
    }

    /// Runs only on `queue`, after a disk or network result has been resolved.
    private func completeLoad(key: String, image: NSImage?) {
        if let image {
            finish(key: key, image: image)
        } else {
            markFailed(key: key)
        }
        lock.lock()
        activeDownloads = max(0, activeDownloads - 1)
        lock.unlock()
        schedulePendingLoads()
    }

    static func redirectAllowed(from origin: URL, to destination: URL) -> Bool {
        guard origin.scheme?.lowercased() == "https", destination.scheme?.lowercased() == "https",
            origin.host?.lowercased() == destination.host?.lowercased()
        else { return false }
        return (origin.port ?? 443) == (destination.port ?? 443)
    }

    /// The two checks used by `Download` before allocation and for each body chunk.
    static func responseFits(limit: Int, expectedContentLength: Int64) -> Bool {
        expectedContentLength < 0 || expectedContentLength <= Int64(limit)
    }

    static func responseFits(limit: Int, receivedBytes: Int, nextChunkBytes: Int) -> Bool {
        receivedBytes >= 0 && nextChunkBytes >= 0 && receivedBytes <= limit - nextChunkBytes
    }

    static func evictionURLs(
        entries: [(url: URL, size: Int, modified: Date)],
        limit: Int
    ) -> [URL] {
        var total = entries.reduce(0) { $0 + $1.size }
        return entries.sorted { $0.modified < $1.modified }.compactMap { entry in
            guard total > limit else { return nil }
            total -= entry.size
            return entry.url
        }
    }

    static func downsampledImage(_ data: Data, maxPixelDimension: Int = maxPixelDimension) -> NSImage? {
        guard
            let source = CGImageSourceCreateWithData(
                data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let options: CFDictionary =
            [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelDimension,
                kCGImageSourceShouldCacheImmediately: true,
            ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        // Keep the actual bitmap representation. NSImage(cgImage:size:) can
        // synthesize a higher-resolution representation on Retina displays.
        let representation = NSBitmapImageRep(cgImage: cgImage)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }

    static func cacheCost(of image: NSImage) -> Int {
        let pixels =
            image.representations.map { $0.pixelsWide * $0.pixelsHigh }.max()
            ?? Int(image.size.width * image.size.height)
        return max(1, pixels) * 4
    }
    static func failureDelay(attempt: Int) -> TimeInterval {
        min(300, 15 * pow(2, Double(max(0, attempt - 1))))
    }

    private func finish(key: String, image: NSImage) {
        cache.setObject(image, forKey: key as NSString, cost: Self.cacheCost(of: image))
        lock.lock()
        failures.removeValue(forKey: key)
        lock.unlock()
        drainCompletions(key: key, image: image)
    }
    private func markFailed(key: String) {
        lock.lock()
        let current = now()
        // URLs can be supplied by data-driven widgets, so the backoff map
        // needs its own bound as well as the download queue. Keep
        // expired entries until eviction: their attempt count makes repeated
        // intermittent failures back off instead of restarting at 15 seconds.
        if failures[key] == nil, failures.count >= Self.maximumFailureEntries,
            let oldest = failures.min(by: { $0.value.retryAt < $1.value.retryAt })?.key
        {
            failures.removeValue(forKey: oldest)
        }
        let attempts = (failures[key]?.attempts ?? 0) + 1
        failures[key] = (attempts, current.addingTimeInterval(Self.failureDelay(attempt: attempts)))
        lock.unlock()
        drainCompletions(key: key, image: nil)
    }
    private func drainCompletions(key: String, image: NSImage?) {
        lock.lock()
        let completions = inFlight.removeValue(forKey: key) ?? []
        lock.unlock()
        DispatchQueue.main.async { completions.forEach { $0(image) } }
    }
    private func diskFile(for key: String) -> URL {
        let name = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return diskDirectory.appendingPathComponent(name + ".img")
    }
    static func isRasterImage(_ data: Data) -> Bool {
        guard data.count >= 12 else { return false }
        let b = [UInt8](data.prefix(12))
        if b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47 { return true }
        if b[0] == 0xFF, b[1] == 0xD8, b[2] == 0xFF { return true }
        if b[0] == 0x47, b[1] == 0x49, b[2] == 0x46 { return true }
        if b[0] == 0x42, b[1] == 0x4D { return true }
        if b[0] == 0x00, b[1] == 0x00, b[2] == 0x01, b[3] == 0x00 { return true }
        return b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46 && b[8] == 0x57 && b[9] == 0x45
            && b[10] == 0x42 && b[11] == 0x50
    }
    private func scheduleDiskPrune() {
        guard !pruneScheduled else { return }
        pruneScheduled = true
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.pruneDiskCache()
            self?.pruneScheduled = false
        }
    }
    private func pruneDiskCache() {
        let fm = FileManager.default
        guard
            let files = try? fm.contentsOfDirectory(
                at: diskDirectory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])
        else { return }
        var entries: [(URL, Int, Date)] = []
        for file in files {
            let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = values?.fileSize ?? 0
            entries.append((file, size, values?.contentModificationDate ?? .distantPast))
        }
        let namedEntries = entries.map { (url: $0.0, size: $0.1, modified: $0.2) }
        for url in Self.evictionURLs(entries: namedEntries, limit: Self.diskLimitBytes) {
            try? fm.removeItem(at: url)
        }
    }
}
