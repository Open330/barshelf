import AppKit
import CryptoKit
import XCTest
@testable import MenubucketApp

/// A delayed, in-process image endpoint. It lets the service's URLSession
/// delegate path be tested without touching the network.
private final class RemoteImageURLProtocol: URLProtocol {
    nonisolated(unsafe) static var statusCode = 200
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var delay: TimeInterval = 0.03
    nonisolated(unsafe) static var advertisedContentLength: Int?
    nonisolated(unsafe) static var requests: [URL] = []
    nonisolated(unsafe) static var activeRequests = 0
    nonisolated(unsafe) static var peakActiveRequests = 0
    nonisolated(unsafe) static var stoppedRequests = 0
    private static let stateLock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url ?? URL(string: "https://images.example.test/missing")!
        Self.stateLock.lock()
        Self.requests.append(url)
        Self.activeRequests += 1
        Self.peakActiveRequests = max(Self.peakActiveRequests, Self.activeRequests)
        let statusCode = Self.statusCode
        let body = Self.body
        let delay = Self.delay
        let advertisedContentLength = Self.advertisedContentLength ?? body.count
        Self.stateLock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            let response = HTTPURLResponse(
                url: url, statusCode: statusCode, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Length": "\(advertisedContentLength)"]
            )!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: body)
            self.client?.urlProtocolDidFinishLoading(self)
            Self.stateLock.lock()
            Self.activeRequests -= 1
            Self.stateLock.unlock()
        }
    }

    override func stopLoading() {
        Self.stateLock.lock()
        Self.stoppedRequests += 1
        Self.stateLock.unlock()
    }

    static func reset(body: Data) {
        stateLock.lock()
        statusCode = 200
        self.body = body
        delay = 0.03
        advertisedContentLength = nil
        requests = []
        activeRequests = 0
        peakActiveRequests = 0
        stoppedRequests = 0
        stateLock.unlock()
    }
}

final class RemoteImageRetryTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func diskFile(for key: String, in directory: URL) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return directory.appendingPathComponent(digest).appendingPathExtension("img")
    }

    private func rasterData() -> Data {
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 8,
            pixelsHigh: 8,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        return bitmap.representation(using: .png, properties: [:])!
    }

    private func protocolConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RemoteImageURLProtocol.self]
        return configuration
    }

    override func tearDown() {
        RemoteImageURLProtocol.reset(body: Data())
        super.tearDown()
    }

    private func fail(
        _ service: RemoteImageService,
        url: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let completed = expectation(description: "initial invalid URL failure")
        service.image(forURL: url) { image in
            XCTAssertNil(image, file: file, line: line)
            completed.fulfill()
        }
        wait(for: [completed], timeout: 1)
    }

    private func expectDiskHit(
        _ service: RemoteImageService,
        url: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let completed = expectation(description: "disk cache retry")
        service.image(forURL: url) { image in
            XCTAssertNotNil(image, file: file, line: line)
            completed.fulfill()
        }
        wait(for: [completed], timeout: 1)
    }

    func testFailureRetriesAfterTTLAndLoadsDiskCache() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var current = Date(timeIntervalSince1970: 1_000)
        let service = RemoteImageService(diskDirectory: directory, now: { current })
        let url = "http://invalid.example.test/image.png"

        fail(service, url: url)
        try rasterData().write(to: diskFile(for: url, in: directory))

        let blocked = expectation(description: "retry remains suppressed during TTL")
        service.image(forURL: url) { image in
            XCTAssertNil(image)
            blocked.fulfill()
        }
        wait(for: [blocked], timeout: 1)

        current = current.addingTimeInterval(RemoteImageService.failureDelay(attempt: 1) + 1)
        expectDiskHit(service, url: url)
    }

    func testManualRetryClearsFailureTTLAndLoadsDiskCache() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = RemoteImageService(diskDirectory: directory)
        let url = "http://invalid.example.test/manual.png"

        fail(service, url: url)
        try rasterData().write(to: diskFile(for: url, in: directory))
        service.retryFailedImages()
        expectDiskHit(service, url: url)
    }

    func testURLSessionCoalescesRequestsAndCapsConcurrentDownloads() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        RemoteImageURLProtocol.reset(body: rasterData())
        let service = RemoteImageService(
            diskDirectory: directory,
            sessionConfiguration: protocolConfiguration(),
            maximumConcurrentDownloads: 1
        )
        let completed = expectation(description: "all coalesced callbacks")
        completed.expectedFulfillmentCount = 6
        let urls = [
            "https://images.example.test/a.png",
            "https://images.example.test/a.png",
            "https://images.example.test/a.png",
            "https://images.example.test/a.png",
            "https://images.example.test/b.png",
            "https://images.example.test/c.png",
        ]
        for url in urls {
            XCTAssertNil(service.image(forURL: url) { image in
                XCTAssertNotNil(image)
                completed.fulfill()
            })
        }
        wait(for: [completed], timeout: 2)
        XCTAssertLessThanOrEqual(RemoteImageURLProtocol.peakActiveRequests, 1)
        XCTAssertEqual(RemoteImageURLProtocol.requests.count, 3)
    }

    func testManualRetryReopensURLSessionFailureWithoutDuplicateRequests() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        RemoteImageURLProtocol.reset(body: rasterData())
        RemoteImageURLProtocol.statusCode = 503
        let service = RemoteImageService(
            diskDirectory: directory, sessionConfiguration: protocolConfiguration())
        let url = "https://images.example.test/retry.png"
        let failed = expectation(description: "initial HTTP failure")
        XCTAssertNil(service.image(forURL: url) { image in
            XCTAssertNil(image)
            failed.fulfill()
        })
        wait(for: [failed], timeout: 1)
        XCTAssertEqual(RemoteImageURLProtocol.requests.count, 1)

        let suppressed = expectation(description: "backoff avoids duplicate request")
        XCTAssertNil(service.image(forURL: url) { image in
            XCTAssertNil(image)
            suppressed.fulfill()
        })
        wait(for: [suppressed], timeout: 1)
        XCTAssertEqual(RemoteImageURLProtocol.requests.count, 1)

        RemoteImageURLProtocol.statusCode = 200
        let retried = expectation(description: "manual retry downloads image")
        service.retryFailedImages()
        XCTAssertNil(service.image(forURL: url) { image in
            XCTAssertNotNil(image)
            retried.fulfill()
        })
        wait(for: [retried], timeout: 1)
        XCTAssertEqual(RemoteImageURLProtocol.requests.count, 2)
    }

    func testAdvertisedOversizedResponseIsCancelledBeforeItsBodyIsRead() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        RemoteImageURLProtocol.reset(body: rasterData())
        RemoteImageURLProtocol.advertisedContentLength = RemoteImageService.maxResponseBytes + 1
        let service = RemoteImageService(
            diskDirectory: directory, sessionConfiguration: protocolConfiguration())
        let failed = expectation(description: "oversized response fails")
        XCTAssertNil(service.image(forURL: "https://images.example.test/too-large.png") { image in
            XCTAssertNil(image)
            failed.fulfill()
        })
        wait(for: [failed], timeout: 1)
        XCTAssertEqual(RemoteImageURLProtocol.requests.count, 1)
        XCTAssertGreaterThan(RemoteImageURLProtocol.stoppedRequests, 0)
    }

    func testRepeatedFailuresIncreaseBackoffAfterTheFirstRetryWindow() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        RemoteImageURLProtocol.reset(body: rasterData())
        RemoteImageURLProtocol.statusCode = 503
        var current = Date(timeIntervalSince1970: 1_000)
        let service = RemoteImageService(
            diskDirectory: directory,
            now: { current },
            sessionConfiguration: protocolConfiguration()
        )
        let url = "https://images.example.test/intermittent.png"

        let first = expectation(description: "first failure")
        _ = service.image(forURL: url) { image in
            XCTAssertNil(image)
            first.fulfill()
        }
        wait(for: [first], timeout: 1)

        current = current.addingTimeInterval(RemoteImageService.failureDelay(attempt: 1) + 1)
        let second = expectation(description: "second failure")
        _ = service.image(forURL: url) { image in
            XCTAssertNil(image)
            second.fulfill()
        }
        wait(for: [second], timeout: 1)
        XCTAssertEqual(RemoteImageURLProtocol.requests.count, 2)

        // Sixteen seconds clears attempt 1's 15-second delay, but must not
        // clear attempt 2's 30-second delay.
        current = current.addingTimeInterval(16)
        let suppressed = expectation(description: "second delay is retained")
        _ = service.image(forURL: url) { image in
            XCTAssertNil(image)
            suppressed.fulfill()
        }
        wait(for: [suppressed], timeout: 1)
        XCTAssertEqual(RemoteImageURLProtocol.requests.count, 2)
    }
}
