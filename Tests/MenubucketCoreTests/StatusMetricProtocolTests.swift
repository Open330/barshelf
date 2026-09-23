import XCTest
@testable import MenubucketCore

final class StatusMetricProtocolTests: XCTestCase {
    func testScriptStatusDecodesMetricsAndKeepsLegacyStatusPayloads() throws {
        let decoder = JSONDecoder()
        let rendered = try decoder.decode(RenderStatus.self, from: Data(#"""
        {"label":"legacy", "metrics":[
          {"label":"↓","value":"8 MB/s","active":true,
           "accessibilityLabel":"Download activity"},
          {"active":true,"accessibilityLabel":"Checking connection"}
        ]}
        """#.utf8))
        XCTAssertEqual(rendered.label, "legacy")
        XCTAssertEqual(rendered.metrics?[0].value, "8 MB/s")
        XCTAssertEqual(rendered.metrics?[1], StatusMetric(
            active: true, accessibilityLabel: "Checking connection"
        ))

        let legacy = try decoder.decode(RenderStatus.self, from: Data(#"{"label":"42%"}"#.utf8))
        XCTAssertEqual(legacy.label, "42%")
        XCTAssertNil(legacy.metrics)
    }
}
