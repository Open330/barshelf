import AppKit
import XCTest
@testable import MenubucketApp
import MenubucketCore

/// The chips' look as it lands in the menu bar, measured on pixels: where a
/// glyph is in its chip folded apart and stacked, how large, in which set
/// and colours.
///
/// A glyph's middle here is its optical one, as the renderer places it:
/// halfway between the middle of its bounding box and its centre of mass
/// (`GlyphCache`).
@MainActor
final class ChipAppearanceTests: XCTestCase {
    private static let scale = 8
    private static let height = 24
    /// The disc is drawn in a blue no glyph has, so the two tell apart.
    private static let disc = NSColor(red: 0.1, green: 0.1, blue: 0.6, alpha: 1)

    override func setUp() async throws {
        // Glyphs are cached for the density the test draws at, whatever
        // screen this Mac has.
        GlyphCache.shared.scalesForTesting = [CGFloat(Self.scale)]
    }

    override func tearDown() async throws {
        GlyphCache.shared.scalesForTesting = nil
    }

    /// What is white in a span of columns: its box, and its centre of mass.
    private struct Ink {
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        var sumX = 0.0, sumY = 0.0, weight = 0.0
        var count = 0
        var scale = ChipAppearanceTests.scale

        mutating func add(_ x: Int, _ y: Int, _ light: Double) {
            minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
            sumX += light * (Double(x) + 0.5); sumY += light * (Double(y) + 0.5); weight += light
            count += 1
        }

        var width: Double { count == 0 ? 0 : Double(maxX - minX + 1) / Double(scale) }
        var height: Double { count == 0 ? 0 : Double(maxY - minY + 1) / Double(scale) }
        var left: Double { Double(minX) / Double(scale) }
        var right: Double { Double(maxX + 1) / Double(scale) }
        /// Halfway between the box's middle and the centre of mass.
        var midX: Double { (Double(minX + maxX + 1) / 2 + sumX / weight) / 2 / Double(scale) }
        var midY: Double { (Double(minY + maxY + 1) / 2 + sumY / weight) / 2 / Double(scale) }
    }

    private func chips(_ symbols: [String]) -> [ClusterChip] {
        symbols.enumerated().map { ClusterChip(widgetID: "w\($0)", name: $1, symbol: $1, initial: "X") }
    }

    private func bitmap(_ image: NSImage, scale: Int = ChipAppearanceTests.scale) throws -> NSBitmapImageRep {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(ceil(image.size.width)) * scale, pixelsHigh: Int(ceil(image.size.height)) * scale,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        rep.size = NSSize(width: ceil(image.size.width), height: ceil(image.size.height))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: image.size), from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    /// The folded cluster, eight times life size. Rows run top to bottom.
    private func render(
        _ chips: [ClusterChip], look: ChipAppearance, color: NSColor = ChipAppearanceTests.disc,
        appearance: NSAppearance.Name = .darkAqua
    ) throws -> NSBitmapImageRep {
        try bitmap(MenuBarController.clusterImage(
            chips, mark: NSImage(size: NSSize(width: 1, height: 1)), badged: false,
            color: { _ in color }, look: look, appearance: try XCTUnwrap(NSAppearance(named: appearance)),
            height: CGFloat(Self.height)
        ))
    }

    /// The glyph pixels (white on the blue disc) between two x, in points.
    private func ink(_ rep: NSBitmapImageRep, from: Double, to: Double) -> Ink {
        var ink = Ink()
        let first = max(Int((from * Double(Self.scale)).rounded()), 0)
        let last = min(Int((to * Double(Self.scale)).rounded()), rep.pixelsWide)
        guard first < last else { return ink }
        for y in 0..<rep.pixelsHigh {
            for x in first..<last {
                guard let color = rep.colorAt(x: x, y: y), color.alphaComponent > 0.5,
                      color.redComponent > 0.55, color.greenComponent > 0.55 else { continue }
                ink.add(x, y, Double(color.redComponent))
            }
        }
        return ink
    }

    private static let trios = [
        ["cpu", "thermometer.medium", "bolt.fill"],
        ["battery.75percent", "arrow.down", "memorychip"],
        ["fan", "network", "lock.shield.fill"],
        ["internaldrive", "cup.and.saucer.fill", "arrow.left.arrow.right"],
    ]

    private func center(_ index: Int, _ geometry: ClusterGeometry) -> Double {
        geometry.collapsedX(index) + ClusterGeometry.slot / 2
    }

    // MARK: - Spacing and centring

    /// Apart, every chip is whole: its glyph is the one it has drawn alone,
    /// in the middle of its own disc.
    func testApartEveryGlyphIsWholeAndInTheMiddleOfItsDisc() throws {
        var worstX = 0.0, worstY = 0.0, worstBox = 0.0
        for set in ChipAppearance.GlyphSet.allCases {
            let look = ChipAppearance(glyphSet: set, spacing: .apart)
            let geometry = ClusterGeometry(count: 3, spacing: .apart)
            XCTAssertGreaterThanOrEqual(geometry.collapsedStep, ClusterGeometry.disc, "the discs do not overlap")
            for trio in Self.trios {
                let rep = try render(chips(trio), look: look)
                for (index, symbol) in trio.enumerated() {
                    let middle = center(index, geometry)
                    let half = geometry.collapsedStep / 2
                    let folded = ink(rep, from: middle - half, to: middle + half)
                    let alone = ink(try render(chips([symbol]), look: look), from: 0, to: ClusterGeometry.slot)
                    XCTAssertGreaterThan(folded.count, 0, "\(symbol) drew nothing")
                    XCTAssertEqual(folded.width, alone.width, accuracy: 0.3, "\(symbol) (\(set)) is cut")
                    XCTAssertEqual(folded.height, alone.height, accuracy: 0.3, "\(symbol) (\(set)) is cut")
                    XCTAssertEqual(folded.midX, middle, accuracy: 0.3, "\(symbol) (\(set)) is off centre sideways")
                    XCTAssertEqual(folded.midY, Double(Self.height) / 2, accuracy: 0.3, "\(symbol) (\(set)) is off centre up or down")
                    worstX = max(worstX, abs(folded.midX - middle))
                    worstY = max(worstY, abs(folded.midY - Double(Self.height) / 2))
                    // The box alone never strays past the optical limit.
                    let box = abs((folded.left + folded.right) / 2 - middle)
                    XCTAssertLessThanOrEqual(box, Double(MenuBarController.ChipMetrics.opticalLimit) + 0.15, symbol)
                    worstBox = max(worstBox, box)
                }
            }
        }
        print(String(format: "CHIP-CENTRING apart: worst optical offset x %.3f pt, y %.3f pt; worst box offset x %.3f pt", worstX, worstY, worstBox))
    }

    /// Stacked, a chip lies over the one to its right. The covered chip's
    /// glyph is whole, inside the part of the chip in view and in the
    /// middle of it; the chip on top is as it is alone.
    func testStackedACoveredGlyphIsWholeInTheMiddleOfWhatShows() throws {
        let m = MenuBarController.ChipMetrics.self
        var worst = 0.0
        for set in ChipAppearance.GlyphSet.allCases {
            let look = ChipAppearance(glyphSet: set, spacing: .stacked)
            let geometry = ClusterGeometry(count: 3, spacing: .stacked)
            XCTAssertLessThan(geometry.collapsedStep, ClusterGeometry.disc, "the discs overlap")
            for trio in Self.trios {
                let rep = try render(chips(trio), look: look)
                let face = Double(m.face)
                // The chip on top.
                let top = ink(rep, from: center(0, geometry) - face / 2, to: center(0, geometry) + face / 2)
                let alone = ink(try render(chips([trio[0]]), look: look), from: 0, to: ClusterGeometry.slot)
                XCTAssertEqual(top.width, alone.width, accuracy: 0.3, "\(trio[0]) on top changed")
                XCTAssertEqual(top.height, alone.height, accuracy: 0.3, "\(trio[0]) on top changed")
                XCTAssertEqual(top.midX, center(0, geometry), accuracy: 0.3, "\(trio[0]) on top moved")
                for index in 1..<trio.count {
                    let symbol = trio[index]
                    let middle = center(index, geometry)
                    let neighbourEdge = center(index - 1, geometry) + face / 2
                    let visibleLeft = max(middle - face / 2, neighbourEdge + Double(m.cutout))
                    let visibleRight = middle + face / 2
                    XCTAssertEqual(visibleRight - visibleLeft, 11.5, accuracy: 0.01)
                    // Nothing of a glyph at the neighbour's edge or in the
                    // cutout: the neighbour's own glyph ends well before.
                    let hidden = ink(rep, from: neighbourEdge - 1, to: visibleLeft)
                    XCTAssertEqual(hidden.count, 0, "\(symbol) (\(set)) shows under the chip over it")
                    let shown = ink(rep, from: visibleLeft, to: visibleRight)
                    XCTAssertGreaterThan(shown.count, 0, "\(symbol) drew nothing")
                    XCTAssertGreaterThan(shown.left, visibleLeft + 0.2, "\(symbol) (\(set)) touches the cutout")
                    XCTAssertLessThan(shown.right, visibleRight - 0.2, "\(symbol) (\(set)) touches the rim")
                    XCTAssertEqual(shown.midX, (visibleLeft + visibleRight) / 2, accuracy: 0.4, "\(symbol) (\(set)) is not in the middle of what shows")
                    XCTAssertEqual(shown.midY, Double(Self.height) / 2, accuracy: 0.4, symbol)
                    worst = max(worst, abs(shown.midX - (visibleLeft + visibleRight) / 2))
                    // Whole: the shape it has alone, only smaller.
                    let whole = ink(try render(chips([symbol]), look: look), from: 0, to: ClusterGeometry.slot)
                    XCTAssertEqual(shown.width / shown.height, whole.width / whole.height, accuracy: 0.12, "\(symbol) (\(set)) is cut")
                    XCTAssertLessThan(shown.width, whole.width, "\(symbol) is drawn smaller to fit")
                    XCTAssertGreaterThan(max(shown.width, shown.height), 5, "\(symbol) is still a glyph")
                }
            }
        }
        print(String(format: "CHIP-CENTRING stacked: worst offset in the visible part %.3f pt", worst))
    }

    /// A covered chip's glyph follows the chips as they fan out: halfway
    /// uncovered it is larger than folded and smaller than whole, and whole
    /// once nothing covers it.
    func testACoveredGlyphGrowsAsItsChipIsUncovered() throws {
        let look = ChipAppearance(spacing: .stacked)
        let pair = chips(["cpu", "cpu"])
        func second(gap: CGFloat) throws -> Ink {
            let rep = try bitmap(MenuBarController.clusterImage(
                pair, positions: [0, gap], mark: NSImage(size: NSSize(width: 1, height: 1)), badged: false,
                color: { _ in Self.disc }, look: look, appearance: try XCTUnwrap(NSAppearance(named: .darkAqua)),
                height: CGFloat(Self.height)
            ))
            // From where chip 0 (on top, ending at 22) and its cutout end.
            return ink(rep, from: max(Double(gap) + 4 - 0.5, 23.5), to: Double(gap) + 22.5)
        }
        let widths = try [13, 15, 17, 19, 21].map { try second(gap: $0).width }
        XCTAssertEqual(widths, widths.sorted(), "the glyph only grows: \(widths)")
        XCTAssertLessThan(widths[0], widths[2])
        XCTAssertLessThan(widths[2], widths[4])
        let alone = ink(try render(chips(["cpu"]), look: look), from: 0, to: ClusterGeometry.slot)
        XCTAssertEqual(widths[4], alone.width, accuracy: 0.3, "uncovered, it is whole")
        XCTAssertEqual(try second(gap: 21).midX, 21 + 13, accuracy: 0.3, "and back in the middle of its disc")
    }

    /// The chip in focus is on top of both neighbours: its glyph is whole.
    func testTheFocusedChipsGlyphIsNotCovered() throws {
        let look = ChipAppearance(spacing: .stacked)
        let lone = [ClusterChip(widgetID: "a", name: "A", symbol: "cpu", initial: "A", value: "")]
        // No pill (no value, a one-letter name would still fit: use the disc width).
        let trio = [lone[0], ClusterChip(widgetID: "b", name: "B", symbol: "cpu", initial: "B", value: ""), lone[0]]
        let rep = try bitmap(MenuBarController.clusterImage(
            trio, focus: 1, pill: CGFloat(ClusterGeometry.disc), mark: NSImage(size: NSSize(width: 1, height: 1)), badged: false,
            color: { _ in Self.disc }, look: look, appearance: try XCTUnwrap(NSAppearance(named: .darkAqua)),
            height: CGFloat(Self.height)
        ))
        let geometry = ClusterGeometry(count: 3, spacing: .stacked)
        let middle = center(1, geometry)
        let focused = ink(rep, from: middle - 8, to: middle + 8)
        XCTAssertEqual(focused.midX, middle, accuracy: 0.3)
        XCTAssertGreaterThan(focused.width, 9, "whole, and a little larger")
    }

    // MARK: - Sizes

    func testGlyphSizesAreSmallMediumLarge() throws {
        for symbol in ["cpu", "battery.75percent", "thermometer.medium", "lock.shield.fill"] {
            for set in ChipAppearance.GlyphSet.allCases {
                let sides = try ChipAppearance.GlyphSize.allCases.map { size -> Double in
                    let look = ChipAppearance(glyphSet: set, glyphSize: size)
                    let drawn = ink(try render(chips([symbol]), look: look), from: 0, to: ClusterGeometry.slot)
                    XCTAssertLessThanOrEqual(max(drawn.width, drawn.height), Double(look.glyphSide) + 0.3, "\(symbol) \(size)")
                    XCTAssertLessThan(
                        (drawn.width * drawn.width + drawn.height * drawn.height).squareRoot(),
                        Double(MenuBarController.ChipMetrics.face) - 1.5, "\(symbol) \(size) reaches the rim"
                    )
                    return max(drawn.width, drawn.height)
                }
                XCTAssertLessThan(sides[0], sides[1] - 0.3, "\(symbol) (\(set)): small is smaller than medium, \(sides)")
                XCTAssertLessThan(sides[1], sides[2] - 0.1, "\(symbol) (\(set)): medium is smaller than large, \(sides)")
            }
        }
        XCTAssertEqual(ChipAppearance(glyphSize: .small).glyphSide, 11)
        XCTAssertEqual(ChipAppearance(glyphSize: .medium).glyphSide, 13)
        XCTAssertEqual(ChipAppearance(glyphSize: .large).glyphSide, 14.5)
        XCTAssertEqual(ChipAppearance(glyphSize: .small).glyphCircle, 13.5)
        XCTAssertEqual(ChipAppearance(glyphSize: .medium).glyphCircle, 15.5)
        XCTAssertEqual(ChipAppearance(glyphSize: .large).glyphCircle, 16, "never past 16")
        XCTAssertEqual(ChipAppearance.GlyphSize.allCases.map { ChipAppearance(glyphSize: $0).initialPointSize }, [11, 12, 13])
    }

    /// The initial of a chip with no symbol grows with the size too.
    func testTheInitialScalesWithTheGlyphSize() throws {
        let chip = [ClusterChip(widgetID: "a", name: "Alpha", initial: "A")]
        let heights = try ChipAppearance.GlyphSize.allCases.map {
            ink(try render(chip, look: ChipAppearance(glyphSize: $0)), from: 0, to: ClusterGeometry.slot).height
        }
        XCTAssertLessThan(heights[0], heights[1])
        XCTAssertLessThan(heights[1], heights[2])
    }

    // MARK: - Glyph sets

    func testEveryMappedSymbolHasASimpleGlyphThatLoads() throws {
        let mapped: [(String, ChipGlyph)] = [
            ("cpu", .cpu), ("cpu.fill", .cpu), ("memorychip", .memory), ("memorychip.fill", .memory),
            ("bolt", .lightning), ("bolt.fill", .lightning), ("thermometer.medium", .thermometerSimple),
            ("thermometer.sun", .thermometerSimple), ("battery.75percent", .battery), ("battery.100", .battery),
            ("fan", .fan), ("fan.fill", .fan), ("internaldrive", .hardDrive), ("externaldrive.fill", .hardDrive),
            ("network", .globeSimple), ("globe", .globeSimple), ("globe.americas.fill", .globeSimple),
            ("arrow.down", .arrowDown), ("arrow.down.to.line", .arrowDown),
            ("arrow.up", .arrowUp), ("arrow.up.to.line", .arrowUp),
            ("square.grid.3x3", .gpu), ("square.grid.3x3.fill", .gpu), ("arrow.left.arrow.right", .arrowsLeftRight),
        ]
        for (symbol, glyph) in mapped {
            XCTAssertEqual(ChipGlyph.replacing(symbol), glyph, symbol)
            let source = try XCTUnwrap(GlyphCache.shared.source(symbol, set: .simple), symbol)
            XCTAssertTrue(source.isSimple, "\(symbol) uses the simple glyph")
            XCTAssertNotNil(GlyphCache.shared.glyph(symbol, look: ChipAppearance(glyphSet: .simple)), symbol)
        }
        for glyph in ChipGlyph.allCases {
            let image = try XCTUnwrap(glyph.image(), "\(glyph) does not load")
            XCTAssertEqual(image.size.width, image.size.height, "\(glyph) is a square drawing")
            XCTAssertNotNil(GlyphCache.shared.ink(of: Self.symbol(for: glyph), set: .simple), "\(glyph) is empty")
        }
        // Every reading BarShelf names itself has a simple glyph.
        for symbol in ["cpu", "square.grid.3x3.fill", "memorychip", "arrow.left.arrow.right", "bolt.fill",
                       "battery.75percent", "thermometer.medium", "fan", "internaldrive", "network", "arrow.down", "arrow.up"] {
            XCTAssertNotNil(ChipGlyph.replacing(symbol), symbol)
        }
    }

    private static func symbol(for glyph: ChipGlyph) -> String {
        switch glyph {
        case .cpu: return "cpu"
        case .memory: return "memorychip"
        case .lightning: return "bolt.fill"
        case .thermometerSimple: return "thermometer.medium"
        case .battery: return "battery.75percent"
        case .fan: return "fan"
        case .hardDrive: return "internaldrive"
        case .globeSimple: return "network"
        case .arrowDown: return "arrow.down"
        case .arrowUp: return "arrow.up"
        case .gpu: return "square.grid.3x3.fill"
        case .arrowsLeftRight: return "arrow.left.arrow.right"
        }
    }

    func testUnmappedSymbolsAndTheSymbolsSetUseSFSymbols() throws {
        for symbol in ["lock.shield.fill", "cup.and.saucer.fill", "star.fill", "arrow.down.circle", "arrow.up.circle.fill",
                       "arrow.down.left", "wifi", "clock"] {
            XCTAssertNil(ChipGlyph.replacing(symbol), symbol)
            let source = try XCTUnwrap(GlyphCache.shared.source(symbol, set: .simple), symbol)
            XCTAssertFalse(source.isSimple, "\(symbol) falls back to its SF Symbol")
        }
        for glyph in ChipGlyph.allCases {
            let symbol = Self.symbol(for: glyph)
            let source = try XCTUnwrap(GlyphCache.shared.source(symbol, set: .symbols), symbol)
            XCTAssertFalse(source.isSimple, "\(symbol): the SF Symbols set never uses a simple glyph")
        }
        XCTAssertNil(GlyphCache.shared.source("no.such.symbol.anywhere", set: .simple))
        // The two sets are different drawings, cached apart.
        let simple = ink(try render(chips(["cpu"]), look: ChipAppearance(glyphSet: .simple)), from: 0, to: 26)
        let symbols = ink(try render(chips(["cpu"]), look: ChipAppearance(glyphSet: .symbols)), from: 0, to: 26)
        XCTAssertNotEqual(simple.count, symbols.count)
    }

    /// The simple glyphs are the right way up in the flipped cluster image:
    /// a down arrow's head is in its lower half, an up arrow's in its upper.
    func testSimpleGlyphsAreTheRightWayUp() throws {
        for (symbol, headBelow) in [("arrow.down", true), ("arrow.up", false)] {
            let rep = try render(chips([symbol]), look: ChipAppearance(glyphSet: .simple))
            var rows = [Int](repeating: 0, count: rep.pixelsHigh)
            for y in 0..<rep.pixelsHigh {
                for x in 0..<rep.pixelsWide {
                    guard let color = rep.colorAt(x: x, y: y), color.redComponent > 0.55, color.greenComponent > 0.55 else { continue }
                    rows[y] += 1
                }
            }
            let drawn = rows.indices.filter { rows[$0] > 0 }
            let middle = (try XCTUnwrap(drawn.first) + (try XCTUnwrap(drawn.last))) / 2
            let upper = rows[..<middle].max() ?? 0, lower = rows[middle...].max() ?? 0
            XCTAssertEqual(lower > upper, headBelow, "\(symbol) is upside down")
        }
    }

    // MARK: - Optical centring

    /// A glyph's image is an even number of points with its optical middle
    /// at the image's middle, at most a point from the box's middle.
    func testAGlyphIsAnchoredBetweenItsBoxAndItsWeight() throws {
        defer { GlyphCache.shared.scalesForTesting = [CGFloat(Self.scale)] }
        GlyphCache.shared.scalesForTesting = [1, 2]
        for set in ChipAppearance.GlyphSet.allCases {
            for size in ChipAppearance.GlyphSize.allCases {
                for symbol in Self.trios.flatMap({ $0 }) {
                    let look = ChipAppearance(glyphSet: set, glyphSize: size)
                    let image = try XCTUnwrap(GlyphCache.shared.glyph(symbol, look: look))
                    XCTAssertEqual(image.size.width.truncatingRemainder(dividingBy: 2), 0, "\(symbol) \(image.size)")
                    XCTAssertEqual(image.size.height.truncatingRemainder(dividingBy: 2), 0, "\(symbol) \(image.size)")
                }
            }
        }
        // A thermometer's weight is in its bulb: its box sits above the
        // disc's middle, so the bulb is nearer the middle than its box is.
        GlyphCache.shared.scalesForTesting = [CGFloat(Self.scale)]
        let look = ChipAppearance(glyphSet: .symbols)
        let source = try XCTUnwrap(GlyphCache.shared.source("thermometer.medium", set: .symbols))
        let measured = try XCTUnwrap(GlyphCache.shared.ink(of: "thermometer.medium"))
        XCTAssertLessThan(measured.mass.y, measured.frame.midY, "the weight is below the box's middle")
        XCTAssertFalse(source.isSimple)
        let rep = try render(chips(["thermometer.medium"]), look: look)
        let drawn = ink(rep, from: 0, to: 26)
        let boxMiddle = Double(drawn.minY + drawn.maxY + 1) / 2 / Double(Self.scale)
        XCTAssertLessThan(boxMiddle, Double(Self.height) / 2 - 0.05, "the box moved up (rows run downwards)")
        XCTAssertGreaterThan(boxMiddle, Double(Self.height) / 2 - 1.1, "by a point at most")
    }

    // MARK: - Styles

    private func pixel(_ rep: NSBitmapImageRep, _ x: Double, _ y: Double) throws -> NSColor {
        try XCTUnwrap(rep.colorAt(x: Int(x * Double(Self.scale)), y: Int(y * Double(Self.scale))))
    }

    private static let styleChips = [
        ClusterChip(widgetID: "a", name: "CPU", symbol: "cpu", initial: "C", value: "23%"),
        ClusterChip(widgetID: "b", name: "Power", symbol: "bolt.fill", initial: "P", value: "6W"),
        ClusterChip(widgetID: "c", name: "Named", initial: "N", value: "ok"),
    ]

    private func styled(
        _ look: ChipAppearance, appearance: NSAppearance.Name, focus: Int? = nil, chips: [ClusterChip] = styleChips
    ) throws -> NSBitmapImageRep {
        let faces = MenuBarController.clusterColors(chips, look: look) { $0 == "b" ? .systemOrange : .systemPurple }
        return try bitmap(MenuBarController.clusterImage(
            chips, positions: MenuBarController.clusterTargets(chips, focus: focus, look: look), focus: focus,
            pill: focus == nil ? nil : MenuBarController.pillWidth(chips),
            lead: focus == nil ? 0 : MenuBarController.clusterLead(for: chips, look: look),
            markAlpha: focus == nil ? 1 : 0,
            mark: try XCTUnwrap(NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: nil)),
            badged: false, color: { faces[$0.id] ?? .systemPurple }, look: look,
            appearance: try XCTUnwrap(NSAppearance(named: appearance)), height: CGFloat(Self.height)
        ))
    }

    private func saturation(_ color: NSColor) -> Double {
        let parts = [color.redComponent, color.greenComponent, color.blueComponent].map { Double($0) }
        return (parts.max() ?? 0) - (parts.min() ?? 0)
    }

    /// Mono has no colour anywhere: discs, glyphs, pill and its words.
    func testMonoDrawsNoColour() throws {
        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            for tone in ChipAppearance.Tone.allCases {
                for focus in [nil, 0] as [Int?] {
                    let rep = try styled(ChipAppearance(style: .mono, tone: tone), appearance: appearance, focus: focus)
                    var drawn = 0
                    for y in 0..<rep.pixelsHigh {
                        for x in 0..<rep.pixelsWide {
                            guard let color = rep.colorAt(x: x, y: y), color.alphaComponent > 0.02 else { continue }
                            drawn += 1
                            XCTAssertLessThan(saturation(color), 0.03, "a coloured pixel at \(x),\(y)")
                        }
                    }
                    XCTAssertGreaterThan(drawn, 1000)
                }
            }
        }
        // The tone changes nothing.
        let vivid = try styled(ChipAppearance(style: .mono, tone: .vivid), appearance: .darkAqua)
        let muted = try styled(ChipAppearance(style: .mono, tone: .muted), appearance: .darkAqua)
        XCTAssertEqual(vivid.tiffRepresentation, muted.tiffRepresentation)
    }

    /// A point of a disc that no glyph covers: just inside its rim, at the
    /// left.
    private func discPoint(_ index: Int, _ geometry: ClusterGeometry) -> (x: Double, y: Double) {
        (center(index, geometry) - 7.6, Double(Self.height) / 2)
    }

    func testSoftIsATranslucentWashWithItsGlyphInTheChipsHue() throws {
        let geometry = ClusterGeometry(count: 3)
        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            let look = ChipAppearance(style: .soft)
            let rep = try styled(look, appearance: appearance)
            let point = discPoint(0, geometry)
            let disc = try pixel(rep, point.x, point.y)
            XCTAssertEqual(Double(disc.alphaComponent), Double(MenuBarController.ChipMetrics.softFill), accuracy: 0.04, "the disc is a wash")
            XCTAssertGreaterThan(saturation(disc), 0.1, "in the chip's colour")
            // The glyph: opaque, coloured, light on a dark bar and deep on
            // a light one.
            var best: NSColor?
            for x in stride(from: center(0, geometry) - 6, through: center(0, geometry) + 6, by: 0.25) {
                let color = try pixel(rep, x, Double(Self.height) / 2)
                if color.alphaComponent > (best?.alphaComponent ?? 0.9) { best = color }
            }
            let glyph = try XCTUnwrap(best, "no opaque glyph pixel")
            XCTAssertGreaterThan(saturation(glyph), 0.08, "the glyph has the chip's hue")
            let l = ChipColor.oklch(try XCTUnwrap(ChipColor.rgb(glyph))).l
            XCTAssertEqual(l, appearance == .darkAqua ? ChipColor.inkOnDark : ChipColor.inkOnLight, accuracy: 0.03)
        }
        let solid = try styled(ChipAppearance(style: .solid), appearance: .darkAqua)
        let point = discPoint(0, geometry)
        XCTAssertEqual(try pixel(solid, point.x, point.y).alphaComponent, 1, accuracy: 0.01, "a solid disc is solid")
    }

    /// Solid with SF Symbols is the chip as it was before the options: an
    /// opaque 18 pt disc, a white glyph. (What did change for it: the face
    /// colour comes from the tone, and a lopsided glyph sits up to a point
    /// from its box's middle.)
    func testSolidIsAnOpaqueDiscWithAWhiteGlyph() throws {
        let look = ChipAppearance(style: .solid, glyphSet: .symbols)
        let rep = try render(chips(["cpu"]), look: look)
        var disc = Ink()
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let color = rep.colorAt(x: x, y: y), color.alphaComponent > 0.5 else { continue }
                disc.add(x, y, 1)
            }
        }
        XCTAssertEqual(disc.width, Double(MenuBarController.ChipMetrics.face), accuracy: 0.3)
        XCTAssertEqual(disc.height, Double(MenuBarController.ChipMetrics.face), accuracy: 0.3)
        let glyph = ink(rep, from: 0, to: 26)
        // A symmetric symbol: its box is still in the middle, as before.
        XCTAssertEqual((glyph.left + glyph.right) / 2, 13, accuracy: 0.25)
        XCTAssertEqual(max(glyph.width, glyph.height), 11, accuracy: 2.3)
        XCTAssertGreaterThan(glyph.count, 500, "the glyph is white")
    }

    /// Stale chips fade, the wave makes a chip denser, the alert dot is red
    /// and the stacked cutout is clear, in every style.
    func testEveryStyleKeepsStaleGlowAlertAndCutout() throws {
        let geometry = ClusterGeometry(count: 2, spacing: .stacked)
        for style in ChipAppearance.Style.allCases {
            let look = ChipAppearance(style: style, spacing: .stacked)
            func draw(stale: Bool = false, lifts: [CGFloat] = [], alert: Bool = false) throws -> NSBitmapImageRep {
                let pair = [
                    ClusterChip(widgetID: "a", name: "A", symbol: "cpu", initial: "A", alert: alert, isStale: stale),
                    ClusterChip(widgetID: "b", name: "B", symbol: "cpu", initial: "B", isStale: stale),
                ]
                return try bitmap(MenuBarController.clusterImage(
                    pair, lifts: lifts, growth: 0, mark: NSImage(size: NSSize(width: 1, height: 1)), badged: false,
                    color: { _ in MenuBarController.chipFace(.systemPurple) }, look: look,
                    appearance: try XCTUnwrap(NSAppearance(named: .darkAqua)), height: CGFloat(Self.height)
                ))
            }
            let point = discPoint(0, geometry)
            let plain = try pixel(try draw(), point.x, point.y)
            let stale = try pixel(try draw(stale: true), point.x, point.y)
            XCTAssertLessThan(stale.alphaComponent, plain.alphaComponent * 0.8, "\(style): a stale chip fades")
            let lit = try pixel(try draw(lifts: [1, 0]), point.x, point.y)
            if style == .solid {
                XCTAssertGreaterThan(lit.brightnessComponent, plain.brightnessComponent, "solid: the wave lightens")
            } else {
                XCTAssertGreaterThan(lit.alphaComponent, plain.alphaComponent + 0.1, "\(style): the wave makes the disc denser")
            }
            // The cutout: clear between chip 0's edge and chip 1.
            let gap = try pixel(try draw(), center(0, geometry) + 9.75, Double(Self.height) / 2)
            XCTAssertLessThan(gap.alphaComponent, 0.05, "\(style): the cutout is clear")
            let m = MenuBarController.ChipMetrics.self
            let dot = try pixel(
                try draw(alert: true), center(0, geometry) + Double(m.face / 2 - m.badge / 3),
                Double(Self.height) / 2 - Double(m.face / 2 - m.badge / 3)
            )
            XCTAssertGreaterThan(dot.redComponent, 0.8, "\(style): the alert dot")
            XCTAssertLessThan(dot.greenComponent, 0.45, "\(style): the alert dot is red")
            XCTAssertEqual(dot.alphaComponent, 1, accuracy: 0.01)
        }
    }

    /// The pill takes the style too: Soft's is a wash with words in the
    /// chip's hue, Solid's is filled with white words.
    func testThePillFollowsTheStyle() throws {
        for style in ChipAppearance.Style.allCases {
            let look = ChipAppearance(style: style)
            let rep = try styled(look, appearance: .darkAqua, focus: 0)
            let lead = Double(MenuBarController.clusterLead(for: Self.styleChips, look: look))
            let left = Double(MenuBarController.clusterTargets(Self.styleChips, focus: 0, look: look)[0]) + lead
                + ClusterGeometry.slotInset
            // Inside the pill, at its top edge between the glyph and the words.
            let fill = try pixel(rep, left + 12, Double(Self.height) / 2 - 8.5)
            switch style {
            case .solid: XCTAssertEqual(fill.alphaComponent, 1, accuracy: 0.02)
            case .soft: XCTAssertEqual(Double(fill.alphaComponent), 0.24, accuracy: 0.05)
            case .mono: XCTAssertEqual(Double(fill.alphaComponent), 0.12, accuracy: 0.05)
            }
        }
    }

    /// A look is part of what the status item's image depends on.
    func testAChangedLookRedraws() {
        func pixels(_ look: ChipAppearance) -> ClusterPixels {
            ClusterPixels(
                chips: Self.styleChips, focus: nil, color: { _ in .systemPurple }, chipLook: look,
                appearance: NSAppearance(named: .darkAqua)!, positions: [0, 20, 40], pill: 18, lead: 0, markAlpha: 1,
                lifts: [], growth: 0, mark: "barshelf.logo", badged: false, height: 24, scales: [2]
            )
        }
        XCTAssertEqual(pixels(ChipAppearance()), pixels(ChipAppearance()))
        XCTAssertNotEqual(pixels(ChipAppearance()), pixels(ChipAppearance(style: .soft)))
        XCTAssertNotEqual(pixels(ChipAppearance()), pixels(ChipAppearance(glyphSet: .symbols)))
        XCTAssertNotEqual(pixels(ChipAppearance()), pixels(ChipAppearance(glyphSize: .large)))
        XCTAssertNotEqual(pixels(ChipAppearance()), pixels(ChipAppearance(spacing: .stacked)))
    }

    /// Where the chips rest follows the spacing, folded and with one in
    /// focus.
    func testTheLayoutFollowsTheSpacing() {
        let chips = Self.styleChips
        XCTAssertEqual(MenuBarController.clusterTargets(chips, focus: nil, look: ChipAppearance(spacing: .apart)), [0, 20, 40])
        XCTAssertEqual(MenuBarController.clusterTargets(chips, focus: nil, look: ChipAppearance(spacing: .stacked)), [0, 13, 26])
        XCTAssertEqual(MenuBarController.clusterTargets(chips, focus: nil), [0, 20, 40], "apart unless told")
        for spacing in ChipAppearance.Spacing.allCases {
            let look = ChipAppearance(spacing: spacing)
            let geometry = ClusterGeometry(count: chips.count, spacing: spacing)
            let image = MenuBarController.clusterImage(
                chips, mark: NSImage(size: NSSize(width: 1, height: 1)), badged: false, color: { _ in .systemPurple },
                look: look, appearance: NSAppearance(named: .darkAqua)!, height: 24
            )
            XCTAssertEqual(image.size.width, CGFloat(geometry.itemWidth))
            let targets = MenuBarController.clusterTargets(chips, focus: 1, look: look)
            XCTAssertEqual(targets[1] - targets[0], CGFloat(ClusterGeometry.revealStep), accuracy: 0.001)
        }
    }
}
