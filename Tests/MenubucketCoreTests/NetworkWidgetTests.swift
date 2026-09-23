import XCTest
@testable import MenubucketCore

final class NetworkWidgetTests: XCTestCase {
    private func definition() throws -> WorkflowDefinition {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try WorkflowDefinition.decode(
            from: try Data(contentsOf: root.appendingPathComponent("widgets/network/workflow.json"))
        )
    }

    private func render(
        available: Bool = true,
        interface: JSONValue = .string("en0"),
        address: JSONValue = .string("192.168.0.8"),
        download: JSONValue,
        upload: JSONValue,
        display: String
    ) throws -> WorkflowEngine.Output {
        try WorkflowEngine.evaluate(
            try definition(),
            sources: ["data": .object(["network": .object([
                "available": .bool(available),
                "interface": interface,
                "address": address,
                "download": download,
                "upload": upload,
                "received": .number(8_000_000),
                "sent": .number(2_000_000),
            ])])],
            settings: .object(["menuBarDisplay": .string(display), "interface": .string("all")])
        )
    }

    private func text(_ node: UINode) -> String {
        (node.text ?? "") + ((node.children ?? []) + (node.items ?? [])).map(text).joined(separator: "\n")
    }

    func testActivityDefaultsToDotsWithAccessibleRates() throws {
        let output = try render(download: .number(1_250_000), upload: .number(500), display: "activity")
        XCTAssertEqual((output.statusMetrics ?? []).map(\.label), ["", ""])
        XCTAssertEqual((output.statusMetrics ?? []).map(\.value), ["", ""])
        XCTAssertEqual((output.statusMetrics ?? []).map(\.active), [true, true])
        XCTAssertEqual((output.statusMetrics ?? []).map(\.accessibilityLabel), ["Download 1.3 MB/s", "Upload 500 B/s"])
    }

    func testSpeedShowsBothFormattedRatesIncludingGigabytes() throws {
        let output = try render(download: .number(1_250_000), upload: .number(2_500_000_000), display: "speed")
        XCTAssertEqual((output.statusMetrics ?? []).map(\.label), ["↓", "↑"])
        XCTAssertEqual((output.statusMetrics ?? []).map(\.value), ["1.3 MB/s", "2.5 GB/s"])
        XCTAssertTrue(output.statusTooltip?.contains("1.3 MB/s") == true)
        XCTAssertTrue(output.statusTooltip?.contains("2.5 GB/s") == true)
    }

    func testFirstRateIsShownAsUnavailableInsteadOfZero() throws {
        let output = try render(download: .null, upload: .null, display: "speed")
        XCTAssertEqual((output.statusMetrics ?? []).map(\.value), ["—", "—"])
        XCTAssertEqual((output.statusMetrics ?? []).map(\.active), [false, false])
        XCTAssertTrue(text(output.viewTree).contains("—"))
    }

    func testOfflineKeepsTheCardAndAccessibleStateUseful() throws {
        let output = try render(
            available: false, interface: .null, address: .null,
            download: .null, upload: .null, display: "activity"
        )
        XCTAssertTrue(text(output.viewTree).contains("Offline"))
        XCTAssertTrue(text(output.viewTree).contains("No local address"))
        XCTAssertEqual((output.statusMetrics ?? []).map(\.accessibilityLabel), ["Download unavailable", "Upload unavailable"])
    }
}
