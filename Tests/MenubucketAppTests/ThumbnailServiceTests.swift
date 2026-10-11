import AppKit
import XCTest
@testable import MenubucketApp

final class ThumbnailServiceTests: XCTestCase {
    private static func image(_ size: Int) -> NSImage {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let image = NSImage(size: NSSize(width: size, height: size))
        image.addRepresentation(bitmap)
        return image
    }
    private final class Probe: @unchecked Sendable {
        private let lock = NSLock()
        private var time: TimeInterval = 0
        private var paths: [String] = []
        private var cancellations: [String] = []
        private var completions: [String: [(NSImage?) -> Void]] = [:]

        var now: TimeInterval { lock.withLock { time } }
        var calls: Int { lock.withLock { paths.count } }
        var cancelled: Int { lock.withLock { cancellations.count } }
        func advance() { lock.withLock { time += ThumbnailService.failureRetryDelay + 1 } }
        func record(_ path: String, completion: @escaping (NSImage?) -> Void) {
            lock.withLock {
                paths.append(path)
                completions[path, default: []].append(completion)
            }
        }
        func cancel(_ path: String) { lock.withLock { cancellations.append(path) } }
        func completion(_ path: String, at index: Int) -> ((NSImage?) -> Void)? {
            lock.withLock {
                guard let callbacks = completions[path], callbacks.indices.contains(index) else { return nil }
                return callbacks[index]
            }
        }
    }

    func testFailedThumbnailDoesNotRegenerateUntilMetadataChangesOrRetryDelayExpires() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = Probe()
        let service = ThumbnailService(diskDirectory: directory, now: { probe.now }, generator: { path, _, done in
            probe.record(path, completion: done)
            done(nil)
            return {}
        })
        func request(mtime: Double, count: Int = 1) {
            let completed = expectation(description: "failed thumbnails complete without repeated generation")
            completed.expectedFulfillmentCount = count
            for _ in 0..<count {
                service.thumbnail(path: "/missing.pdf", modifiedAt: mtime, pointSize: 32) { image in
                    XCTAssertNil(image)
                    completed.fulfill()
                }
            }
            wait(for: [completed], timeout: 2)
        }
        request(mtime: 1)
        request(mtime: 1, count: 64)
        XCTAssertEqual(probe.calls, 1)
        request(mtime: 2)
        XCTAssertEqual(probe.calls, 2, "changed file metadata must bypass the previous failure")
        probe.advance()
        request(mtime: 1)
        XCTAssertEqual(probe.calls, 3, "transient failures must remain retryable")
    }

    func testHungGeneratorsReleaseSlotsAndLateCallbackCannotCompleteReplacement() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = Probe()
        let replacementStarted = expectation(description: "replacement generation started")
        let service = ThumbnailService(diskDirectory: directory, now: { probe.now },
            generationTimeout: 0.2, generator: { path, _, done in
                probe.record(path, completion: done)
                if path == "/ready" { done(Self.image(4)) }
                if probe.calls == 6 { replacementStarted.fulfill() }
                return { probe.cancel(path) }
            })
        let timedOut = expectation(description: "all stalled slots complete")
        timedOut.expectedFulfillmentCount = 4
        let ready = expectation(description: "queued healthy thumbnail loads")
        for index in 0..<4 {
            service.thumbnail(path: "/stalled\(index)", modifiedAt: 1, pointSize: 32) { image in
                XCTAssertNil(image)
                timedOut.fulfill()
            }
        }
        service.thumbnail(path: "/ready", modifiedAt: 1, pointSize: 32) { image in
            XCTAssertNotNil(image)
            ready.fulfill()
        }
        wait(for: [timedOut, ready], timeout: 2)
        XCTAssertEqual(probe.cancelled, 4)
        XCTAssertEqual(probe.calls, 5)
        let oldCallback = try XCTUnwrap(probe.completion("/stalled0", at: 0))
        probe.advance()
        let fresh = Self.image(8)
        let replacement = expectation(description: "only fresh generation completes replacement")
        XCTAssertNil(service.thumbnail(path: "/stalled0", modifiedAt: 1, pointSize: 32) { image in
            XCTAssertTrue(image === fresh)
            replacement.fulfill()
        })
        wait(for: [replacementStarted], timeout: 1)
        oldCallback(Self.image(16))
        try XCTUnwrap(probe.completion("/stalled0", at: 1))(fresh)
        wait(for: [replacement], timeout: 1)
    }

    func testCacheKeyRetainsSubsecondModificationIdentity() {
        let early = ThumbnailService.cacheKey(
            path: "/tmp/sample.pdf", modifiedAt: 1_000.125, pointSize: 32)
        let later = ThumbnailService.cacheKey(
            path: "/tmp/sample.pdf", modifiedAt: 1_000.875, pointSize: 32)

        XCTAssertNotEqual(early, later)
    }

    func testCacheKeyAcceptsNonFiniteMetadataAndSanitizesPointSize() {
        XCTAssertNoThrow(ThumbnailService.cacheKey(
            path: "/tmp/sample.pdf", modifiedAt: Double.infinity, pointSize: CGFloat.nan))
        XCTAssertNoThrow(ThumbnailService.cacheKey(
            path: "/tmp/sample.pdf", modifiedAt: Double.nan, pointSize: CGFloat.infinity))

        let negative = ThumbnailService.cacheKey(
            path: "/tmp/sample.pdf", modifiedAt: 10, pointSize: -50)
        let minimum = ThumbnailService.cacheKey(
            path: "/tmp/sample.pdf", modifiedAt: 10, pointSize: 1)
        let oversized = ThumbnailService.cacheKey(
            path: "/tmp/sample.pdf", modifiedAt: 10, pointSize: 9_999)
        let maximum = ThumbnailService.cacheKey(
            path: "/tmp/sample.pdf", modifiedAt: 10, pointSize: 512)

        XCTAssertEqual(negative, minimum)
        XCTAssertEqual(oversized, maximum)
    }
}
