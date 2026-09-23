import XCTest
@testable import MenubucketCore

final class NetworkMetricsTests: XCTestCase {
    private func interface(
        _ name: String,
        received: UInt64,
        sent: UInt64,
        up: Bool = true,
        loopback: Bool = false,
        tunnel: Bool = false,
        address: String? = nil
    ) -> NetworkMetrics.InterfaceSample {
        NetworkMetrics.InterfaceSample(
            name: name,
            counters: .init(received: received, sent: sent),
            isUp: up,
            isLoopback: loopback,
            isTunnel: tunnel,
            address: address
        )
    }

    func testAggregateStartsWithoutRatesThenReportsPerSecondDeltas() throws {
        let sampler = NetworkMetrics.Sampler()
        let first = sampler.sample(interfaces: [
            interface("en0", received: 1_000, sent: 500),
            interface("en1", received: 2_000, sent: 1_000),
        ], now: 10)
        XCTAssertTrue(first.available)
        XCTAssertEqual(first.interface, "all")
        XCTAssertNil(first.download)
        XCTAssertNil(first.upload)
        XCTAssertEqual(first.received, 3_000)
        XCTAssertEqual(first.sent, 1_500)

        let second = sampler.sample(interfaces: [
            interface("en0", received: 1_300, sent: 650),
            interface("en1", received: 2_500, sent: 1_100),
        ], now: 12)
        XCTAssertEqual(try XCTUnwrap(second.download), 400, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(second.upload), 125, accuracy: 0.0001)
    }

    func testNewOrResetInterfaceDoesNotCreateASpike() throws {
        let sampler = NetworkMetrics.Sampler()
        _ = sampler.sample(interfaces: [interface("en0", received: 1_000, sent: 1_000)], now: 1)

        let withNew = sampler.sample(interfaces: [
            interface("en0", received: 1_100, sent: 1_050),
            interface("en1", received: 99_000_000, sent: 88_000_000),
        ], now: 2)
        XCTAssertEqual(try XCTUnwrap(withNew.download), 100, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(withNew.upload), 50, accuracy: 0.0001)

        let reset = sampler.sample(interfaces: [
            interface("en0", received: 5, sent: 7),
            interface("en1", received: 99_000_500, sent: 88_000_200),
        ], now: 3)
        XCTAssertEqual(try XCTUnwrap(reset.download), 500, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(reset.upload), 200, accuracy: 0.0001)
    }

    func testLargeCountersRemainMonotonicAndACompatibilityWrapResetsTheRate() throws {
        let sampler = NetworkMetrics.Sampler()
        let aboveFourGiB = UInt64(UInt32.max) + 100
        _ = sampler.sample(interfaces: [
            interface("en0", received: aboveFourGiB, sent: aboveFourGiB),
        ], now: 1)
        let largeDelta = sampler.sample(interfaces: [
            interface("en0", received: aboveFourGiB + 600, sent: aboveFourGiB + 200),
        ], now: 2)
        XCTAssertEqual(try XCTUnwrap(largeDelta.download), 600, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(largeDelta.upload), 200, accuracy: 0.0001)

        let wrapped = sampler.sample(interfaces: [
            interface("en0", received: 300, sent: 100),
        ], now: 3)
        XCTAssertNil(wrapped.download)
        XCTAssertNil(wrapped.upload)
    }

    func testDisappearedInterfaceAndLongGapNeedAFreshBaseline() {
        let sampler = NetworkMetrics.Sampler()
        _ = sampler.sample(interfaces: [interface("en0", received: 100, sent: 100)], now: 0)
        _ = sampler.sample(interfaces: [], now: 1)
        let returned = sampler.sample(
            interfaces: [interface("en0", received: 9_000, sent: 8_000)], now: 2
        )
        XCTAssertNil(returned.download)
        XCTAssertNil(returned.upload)

        let afterSleep = sampler.sample(
            interfaces: [interface("en0", received: 12_000, sent: 10_000)], now: 40
        )
        XCTAssertNil(afterSleep.download)
        XCTAssertNil(afterSleep.upload)
    }

    func testDownInterfaceDoesNotSeedAConnectedInterfaceRate() throws {
        let sampler = NetworkMetrics.Sampler()
        _ = sampler.sample(
            interfaces: [interface("en0", received: 10, sent: 5, up: false)], now: 1
        )
        let connected = sampler.sample(
            interfaces: [interface("en0", received: 2_000_000, sent: 1_000_000)], now: 2
        )
        XCTAssertNil(connected.download)
        XCTAssertNil(connected.upload)

        let next = sampler.sample(
            interfaces: [interface("en0", received: 2_000_400, sent: 1_000_100)], now: 3
        )
        XCTAssertEqual(try XCTUnwrap(next.download), 400, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(next.upload), 100, accuracy: 0.0001)
    }

    func testAggregateUsesActivePhysicalInterfacesAndExplicitSelectionCanInspectOthers() {
        let sampler = NetworkMetrics.Sampler()
        let all = sampler.sample(interfaces: [
            interface("en0", received: 100, sent: 10),
            interface("bridge0", received: 1_000, sent: 100),
            interface("lo0", received: 2_000, sent: 200, loopback: true),
            interface("utun4", received: 3_000, sent: 300, tunnel: true),
            interface("en1", received: 4_000, sent: 400, up: false),
        ], now: 1)
        XCTAssertEqual(all.received, 100)
        XCTAssertEqual(all.sent, 10)

        let tunnel = sampler.sample(
            interfaces: [interface("utun4", received: 3_200, sent: 350, tunnel: true, address: "fd00::1")],
            interface: "utun4",
            now: 2
        )
        XCTAssertTrue(tunnel.available)
        XCTAssertEqual(tunnel.interface, "utun4")
        XCTAssertEqual(tunnel.address, "fd00::1")
        XCTAssertEqual(tunnel.received, 3_200)

        let down = sampler.sample(
            interfaces: [interface("en1", received: 10, sent: 5, up: false)],
            interface: "en1",
            now: 3
        )
        XCTAssertFalse(down.available)
        XCTAssertEqual(down.interface, "en1")
    }

    func testShortRequestsReuseTheGlobalWindowInsteadOfStealingIt() throws {
        let sampler = NetworkMetrics.Sampler()
        _ = sampler.sample(interfaces: [interface("en0", received: 100, sent: 0)], now: 1)
        let cached = sampler.sample(interfaces: [interface("en0", received: 200, sent: 0)], now: 1.1)
        XCTAssertEqual(cached.received, 100)

        let measured = sampler.sample(interfaces: [interface("en0", received: 300, sent: 0)], now: 1.3)
        XCTAssertEqual(try XCTUnwrap(measured.download), 200 / 0.3, accuracy: 0.0001)
    }

    func testReadingJSONUsesNullForUnavailableRatesAndAddress() {
        let value = NetworkMetrics.Reading(
            available: false, interface: "all", download: nil, upload: nil,
            received: 0, sent: 0, address: nil
        ).json.objectValue
        XCTAssertEqual(value?["available"], .bool(false))
        XCTAssertEqual(value?["interface"], .string("all"))
        XCTAssertEqual(value?["download"], .null)
        XCTAssertEqual(value?["upload"], .null)
        XCTAssertEqual(value?["address"], .null)
    }

    func testEmptyInterfaceSelectionUsesTheAggregate() {
        let sampler = NetworkMetrics.Sampler()
        let reading = sampler.sample(
            interfaces: [interface("en0", received: 1, sent: 1)], interface: "  \n ", now: 1
        )
        XCTAssertEqual(reading.interface, "all")
        XCTAssertTrue(reading.available)
    }

    func testNativeSamplerSmokeWhenExplicitlyEnabled() throws {
        guard ProcessInfo.processInfo.environment["BARSHELF_NETWORK_SMOKE"] == "1" else {
            throw XCTSkip("Set BARSHELF_NETWORK_SMOKE=1 to inspect native interface sampling")
        }
        NetworkMetrics.shared.reset()
        let first = NetworkMetrics.shared.sample()
        Thread.sleep(forTimeInterval: 0.3)
        let second = NetworkMetrics.shared.sample()
        print(
            "network smoke: available=\(second.available), interface=\(second.interface ?? "nil"), "
                + "received=\(second.received), sent=\(second.sent), "
                + "download=\(second.download ?? -1), upload=\(second.upload ?? -1)"
        )
        XCTAssertTrue(first.available)
        XCTAssertTrue(second.available)
        let download = try XCTUnwrap(second.download)
        let upload = try XCTUnwrap(second.upload)
        XCTAssertTrue(download.isFinite)
        XCTAssertTrue(upload.isFinite)
        XCTAssertGreaterThanOrEqual(download, 0)
        XCTAssertGreaterThanOrEqual(upload, 0)
    }
}
