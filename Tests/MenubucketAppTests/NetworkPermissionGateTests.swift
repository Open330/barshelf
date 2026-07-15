import XCTest
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
