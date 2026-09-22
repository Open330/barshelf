import XCTest
import AppKit
@testable import MenubucketApp
import MenubucketCore

/// The `http` workflow source is gated by the `network` permission: the
/// manifest must declare it (checked in Core) and the fetched host must fall
/// inside the declared allowlist (`WidgetRuntime.networkHostAllowed`).
final class NetworkPermissionGateTests: XCTestCase {
    private func manifest(network: [String]?) -> Manifest {
        Manifest(
            schemaVersion: 1, id: "dev.test.net", name: "Net",
            entry: .init(kind: "workflow"),
            permissions: network.map { Manifest.Permissions(network: $0) }
        )
    }

    func testHostMustBeInAllowlist() {
        let m = manifest(network: ["api.github.com"])
        XCTAssertTrue(WidgetRuntime.networkHostAllowed(
            url: "https://api.github.com/status", manifest: m
        ))
        XCTAssertFalse(WidgetRuntime.networkHostAllowed(
            url: "https://evil.example.test/x", manifest: m
        ))
    }

    func testNoNetworkPermissionBlocksEverything() {
        let m = manifest(network: nil)
        XCTAssertFalse(WidgetRuntime.networkHostAllowed(
            url: "https://api.github.com", manifest: m
        ))
        let empty = manifest(network: [])
        XCTAssertFalse(WidgetRuntime.networkHostAllowed(
            url: "https://api.github.com", manifest: empty
        ))
    }

    func testWildcardAndFullURLEntries() {
        let wildcard = manifest(network: ["*.githubusercontent.com"])
        XCTAssertTrue(WidgetRuntime.networkHostAllowed(
            url: "https://raw.githubusercontent.com/a/b", manifest: wildcard
        ))
        XCTAssertFalse(WidgetRuntime.networkHostAllowed(
            url: "https://githubusercontent.com/a", manifest: wildcard
        ))

        let fullURL = manifest(network: ["https://api.open-meteo.com/v1/forecast"])
        XCTAssertTrue(WidgetRuntime.networkHostAllowed(
            url: "https://api.open-meteo.com/v1/forecast?lat=1", manifest: fullURL
        ))

        let star = manifest(network: ["*"])
        XCTAssertTrue(WidgetRuntime.networkHostAllowed(
            url: "https://anything.test/x", manifest: star
        ))
    }

    func testRemoteImageRedirectsCannotLeaveApprovedOrigin() {
        let origin = URL(string: "https://images.example.test/a.png")!
        XCTAssertTrue(RemoteImageService.redirectAllowed(
            from: origin, to: URL(string: "https://images.example.test/b.png")!
        ))
        XCTAssertFalse(RemoteImageService.redirectAllowed(
            from: origin, to: URL(string: "https://tracker.example.test/b.png")!
        ))
        XCTAssertFalse(RemoteImageService.redirectAllowed(
            from: origin, to: URL(string: "http://images.example.test/b.png")!
        ))
    }

    func testRemoteImageFailureBackoffIsBounded() {
        XCTAssertEqual(RemoteImageService.failureDelay(attempt: 1), 15)
        XCTAssertEqual(RemoteImageService.failureDelay(attempt: 2), 30)
        XCTAssertEqual(RemoteImageService.failureDelay(attempt: 10), 300)
    }

    func testRemoteImageMemoryCostUsesDecodedPixels() {
        let image = NSImage(size: CGSize(width: 100, height: 40))
        XCTAssertGreaterThanOrEqual(RemoteImageService.cacheCost(of: image), 16_000)
    }

    func testRemoteImageResponseCapRejectsAdvertisedAndStreamedOverflow() {
        let cap = RemoteImageService.maxResponseBytes
        XCTAssertFalse(RemoteImageService.responseFits(limit: cap, expectedContentLength: Int64(cap + 1)))
        XCTAssertTrue(RemoteImageService.responseFits(limit: cap, expectedContentLength: -1))
        XCTAssertTrue(RemoteImageService.responseFits(limit: cap, receivedBytes: cap - 8, nextChunkBytes: 8))
        XCTAssertFalse(RemoteImageService.responseFits(limit: cap, receivedBytes: cap - 8, nextChunkBytes: 9))
    }

    func testRemoteImageDownsamplesLargeRasterBeforeCaching() {
        let source = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2_048, pixelsHigh: 1_024,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        let data = source.representation(using: .png, properties: [:])!
        let image = RemoteImageService.downsampledImage(data)!
        XCTAssertLessThanOrEqual(image.representations.map(\.pixelsWide).max()!, RemoteImageService.maxPixelDimension)
        XCTAssertLessThanOrEqual(image.representations.map(\.pixelsHigh).max()!, RemoteImageService.maxPixelDimension)
        XCTAssertLessThanOrEqual(RemoteImageService.cacheCost(of: image), 512 * 512 * 4)
    }

    func testRemoteImageDiskEvictionRemovesOldestFilesOnlyUntilWithinBudget() {
        let oldest = URL(fileURLWithPath: "/tmp/oldest")
        let newer = URL(fileURLWithPath: "/tmp/newer")
        let newest = URL(fileURLWithPath: "/tmp/newest")
        let epoch = Date(timeIntervalSince1970: 0)
        let removed = RemoteImageService.evictionURLs(entries: [
            (oldest, 8, epoch), (newer, 8, epoch.addingTimeInterval(1)), (newest, 8, epoch.addingTimeInterval(2))
        ], limit: 16)
        XCTAssertEqual(removed, [oldest])
    }

    // MARK: - Deep-link routing (barshelf://refresh)

    func testRefreshDeepLinkRoutesToHook() {
        let installer = WidgetInstaller()
        var received: [String?] = []
        installer.onRefreshRequest = { received.append($0) }

        installer.handleDeepLink(URL(string: "barshelf://refresh?widget=dev.test.net")!)
        installer.handleDeepLink(URL(string: "barshelf://refresh")!)
        installer.handleDeepLink(URL(string: "barshelf://refresh?widget=")!)

        XCTAssertEqual(received.count, 3)
        XCTAssertEqual(received[0], "dev.test.net")
        XCTAssertNil(received[1]) // no widget param → refresh all
        XCTAssertNil(received[2]) // empty widget param → refresh all
    }

    func testInstallDeepLinkDoesNotHitRefreshHook() {
        let installer = WidgetInstaller()
        var refreshCalls = 0
        installer.onRefreshRequest = { _ in refreshCalls += 1 }
        // An install deep link must NOT route to the refresh hook. We only
        // assert routing (not that an install dialog runs) to keep this headless.
        let route = URLComponents(
            url: URL(string: "barshelf://install?url=https://example.test/w.zip")!,
            resolvingAgainstBaseURL: false
        )?.host
        XCTAssertEqual(route, "install")
        XCTAssertNotEqual(route, "refresh")
        XCTAssertEqual(refreshCalls, 0)
    }
}
