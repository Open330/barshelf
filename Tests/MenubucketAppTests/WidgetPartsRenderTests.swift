import AppKit
import SwiftUI
import XCTest
import MenubucketCore
@testable import MenubucketApp

/// Offscreen rendering of the `sparkline` node and stacked `progress`
/// segments, plus the app-side `quitApp` guards.
@MainActor
final class WidgetPartsRenderTests: XCTestCase {
    private func render(_ node: UINode, density: WidgetAppearance.Density? = nil) throws -> CGImage {
        var appearance = WidgetAppearance()
        appearance.density = density
        let view = ViewTreeRenderer(node: node)
            .environment(\.widgetAppearance, appearance)
            .frame(width: 200)
            .padding(Spacing.xs)
            .background(Color.white)
            .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        return try XCTUnwrap(renderer.cgImage)
    }

    /// Share of pixels that are not the white background.
    private func inkCoverage(_ image: CGImage, colouredOnly: Bool = false) -> Double {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var inked = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let channels = pixels[index..<index + 3]
            let ink = colouredOnly
                ? Int(channels.max()!) - Int(channels.min()!) > 40
                : channels.contains { $0 < 240 }
            if ink { inked += 1 }
        }
        return Double(inked) / Double(width * height)
    }

    func testSparklineRendersOffscreen() throws {
        let node = UINode(type: "sparkline", tint: "accent", values: [3, 9, 4, 12, 7, 15])
        let image = try render(node)
        // 34 pt default + padding, at 2×.
        XCTAssertEqual(image.height, Int((ChartMetrics.sparklineHeight + Spacing.xs * 2) * 2))
        XCTAssertGreaterThan(inkCoverage(image), 0.02)
    }

    func testSparklineHonoursHeightAndCompactDensity() throws {
        let node = UINode(type: "sparkline", values: [1, 2, 3], height: 40)
        let regular = try render(node)
        let compact = try render(node, density: .compact)
        XCTAssertEqual(regular.height, Int((40 + Spacing.xs * 2) * 2))
        XCTAssertLessThan(compact.height, regular.height)
        // Untinted (neutral) still draws.
        XCTAssertGreaterThan(inkCoverage(regular), 0.01)
    }

    func testSparklineWithoutDataKeepsItsHeight() throws {
        let image = try render(UINode(type: "sparkline", values: []))
        XCTAssertEqual(image.height, Int((ChartMetrics.sparklineHeight + Spacing.xs * 2) * 2))
    }

    func testSparklineAccessibilitySummary() {
        XCTAssertEqual(
            SparklineView.summary([12, 9, 40, 31]),
            "Trend from 12 to 31, low 9, high 40"
        )
    }

    func testSparklinePointsStayInsideTheFrame() {
        let rect = SparklineView.plotRect(CGSize(width: 100, height: 34))
        let points = SparklineView.points([0, 50, 100, 200], domain: 0...100, in: rect)
        XCTAssertEqual(points.first?.y, rect.maxY)
        XCTAssertEqual(points[2].y, rect.minY)
        XCTAssertEqual(points[3].y, rect.minY) // above an explicit max: on the edge
        XCTAssertEqual(points.last?.x ?? 0, rect.maxX, accuracy: 0.001)
        XCTAssertEqual(SparklineView.points([5], domain: 0...10, in: rect).count, 2)
    }

    func testSegmentedProgressRendersOffscreen() throws {
        let segmented = UINode(type: "progress", segments: [
            .init(value: 0.4, tint: "accent", label: "User"),
            .init(value: 0.3, tint: "warning", label: "System"),
        ])
        let empty = UINode(type: "progress", value: 0)
        let filled = inkCoverage(try render(segmented), colouredOnly: true)
        XCTAssertGreaterThan(filled, inkCoverage(try render(empty), colouredOnly: true) + 0.05)
    }

    func testSegmentsAccessibilityValueListsEachPart() {
        let value = SegmentedMeter.accessibilityValue(for: [
            .init(value: 0.32, label: "User"),
            .init(value: 0.12, label: "System"),
            .init(value: 0.05),
        ])
        XCTAssertTrue(value.contains("User 32%"), value)
        XCTAssertTrue(value.contains("System 12%"), value)
        XCTAssertTrue(value.contains("5%"), value)
    }

    func testQuitAppNeverTargetsBarShelfOrNonApps() {
        let own = ProcessInfo.processInfo.processIdentifier
        XCTAssertTrue(WidgetRuntime.quittableApps(for: .pid(own)).isEmpty)
        XCTAssertTrue(WidgetRuntime.quittableApps(for: .pid(1)).isEmpty) // launchd
        XCTAssertTrue(WidgetRuntime.quittableApps(for: .bundleID("dev.barshelf.not-running")).isEmpty)
    }
}
