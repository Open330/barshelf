import AppKit
@testable import MenubucketApp
import MenubucketCore
import XCTest

final class ClusterHoverTests: XCTestCase {
    private let item = NSRect(x: 1000, y: 876, width: 80, height: 24)

    func testOnTheItemIncludesTheBarsTopEdge() {
        XCTAssertEqual(ClusterHoverPolicy.zone(of: NSPoint(x: 1010, y: 880), item: item), .on(x: 10))
        XCTAssertEqual(ClusterHoverPolicy.zone(of: NSPoint(x: 1010, y: 901), item: item), .on(x: 10))
    }

    func testAPointerThatDriftsJustBelowOrPastTheItemIsInTheMargin() {
        XCTAssertEqual(ClusterHoverPolicy.zone(of: NSPoint(x: 1040, y: 868), item: item), .margin)
        XCTAssertEqual(ClusterHoverPolicy.zone(of: NSPoint(x: 997, y: 880), item: item), .margin)
        XCTAssertEqual(ClusterHoverPolicy.zone(of: NSPoint(x: 1082, y: 880), item: item), .margin)
    }

    func testFurtherAwayIsAway() {
        XCTAssertEqual(ClusterHoverPolicy.zone(of: NSPoint(x: 1040, y: 860), item: item), .away)
        XCTAssertEqual(ClusterHoverPolicy.zone(of: NSPoint(x: 990, y: 880), item: item), .away)
    }

    func testHeadingDownToThePeekGetsLongerThanLeavingSideways() {
        let peek = NSRect(x: 990, y: 790, width: 120, height: 80)
        XCTAssertEqual(ClusterHoverPolicy.grace(leavingAt: NSPoint(x: 1040, y: 840), item: item, peek: peek),
                       ClusterHoverPolicy.peekGrace)
        XCTAssertEqual(ClusterHoverPolicy.grace(leavingAt: NSPoint(x: 1200, y: 880), item: item, peek: peek),
                       ClusterHoverPolicy.leaveGrace)
        XCTAssertEqual(ClusterHoverPolicy.grace(leavingAt: NSPoint(x: 1040, y: 840), item: item, peek: nil),
                       ClusterHoverPolicy.leaveGrace)
    }

    func testFoldingWaitsBrieflyAndLongerTowardsThePeek() {
        XCTAssertEqual(ClusterHoverPolicy.leaveGrace, 0.2)
        XCTAssertGreaterThan(ClusterHoverPolicy.peekGrace, ClusterHoverPolicy.leaveGrace)
        XCTAssertGreaterThan(MenuBarController.foldDuration, MenuBarController.focusDuration)
    }
}

final class ClusterPixelsTests: XCTestCase {
    private func chips(cpu: String = "23%", alert: Bool = false, stale: Bool = false) -> [ClusterChip] {
        [
            ClusterChip(widgetID: "a", name: "CPU", symbol: "cpu", initial: "C", isStale: stale, value: cpu),
            ClusterChip(widgetID: "b", name: "Memory", symbol: "memorychip", initial: "M", alert: alert, value: "61%"),
        ]
    }

    private func pixels(_ chips: [ClusterChip], focus: Int? = nil, color: NSColor = .systemPurple) -> ClusterPixels {
        ClusterPixels(
            chips: chips, focus: focus, color: { _ in color }, appearance: NSAppearance(named: .darkAqua)!,
            positions: [0, 10], pill: 20, lead: 0, markAlpha: 1, lifts: [], growth: 0.3,
            mark: "barshelf.logo", badged: false, height: 24, scales: [2]
        )
    }

    func testAFoldedChipsNewReadingDoesNotRedraw() {
        XCTAssertEqual(pixels(chips(cpu: "23%")), pixels(chips(cpu: "41%")))
    }

    func testTheFocusedChipsReadingRedraws() {
        XCTAssertNotEqual(pixels(chips(cpu: "23%"), focus: 0), pixels(chips(cpu: "41%"), focus: 0))
    }

    func testWhatTheFoldedChipsShowRedraws() {
        XCTAssertNotEqual(pixels(chips()), pixels(chips(alert: true)))
        XCTAssertNotEqual(pixels(chips()), pixels(chips(stale: true)))
        XCTAssertNotEqual(pixels(chips()), pixels(chips(), color: .systemTeal))
    }

    /// The bitmap the menu bar gets looks like the drawn image it replaces.
    func testTheRasterizedClusterMatchesTheDrawnOne() throws {
        let drawn = MenuBarController.clusterImage(
            chips(alert: true), focus: 1, pill: 60,
            mark: NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: nil)!,
            badged: false, color: { _ in .systemPink }, appearance: NSAppearance(named: .darkAqua)!, height: 24
        )
        let raster = MenuBarController.rasterized(drawn, scales: [2])
        XCTAssertEqual(raster.size, drawn.size)
        XCTAssertTrue(raster.representations.allSatisfy { $0 is NSBitmapImageRep })
        func pixels(_ image: NSImage) throws -> [UInt8] {
            let width = Int(image.size.width * 2), height = Int(image.size.height * 2)
            let rep = try XCTUnwrap(NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .calibratedRGB,
                bytesPerRow: width * 4, bitsPerPixel: 32
            ))
            rep.size = image.size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            image.draw(in: NSRect(origin: .zero, size: image.size))
            NSGraphicsContext.restoreGraphicsState()
            return Array(UnsafeBufferPointer(start: rep.bitmapData, count: width * height * 4))
        }
        let a = try pixels(drawn), b = try pixels(raster)
        if let dir = ProcessInfo.processInfo.environment["CLUSTER_RENDER_DIR"] {
            for (name, image) in [("drawn", drawn), ("raster", raster)] {
                let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
                try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
            }
        }
        let off = zip(a, b).filter { abs(Int($0) - Int($1)) > 2 }.count
        XCTAssertLessThan(Double(off) / Double(a.count), 0.001, "\(off) of \(a.count) bytes differ")
        XCTAssertGreaterThan(a.filter { $0 > 0 }.count, 100, "something was drawn")
    }
}
