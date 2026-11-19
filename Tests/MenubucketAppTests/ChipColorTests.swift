import AppKit
import SwiftUI
import XCTest
@testable import MenubucketApp
import MenubucketCore

/// Chip colours as a palette: one lightness and one strength per tone, the
/// widget's hue kept, everything sRGB can show.
@MainActor
final class ChipColorTests: XCTestCase {
    func testSRGBSurvivesTheTripThroughOKLCH() {
        let steps = stride(from: 0.0, through: 1.0, by: 0.125)
        for r in steps {
            for g in steps {
                for b in steps {
                    let rgb = ChipColor.RGB(r: r, g: g, b: b)
                    let back = ChipColor.srgb(ChipColor.oklch(rgb))
                    XCTAssertEqual(back.r, r, accuracy: 1.0 / 255, "\(rgb)")
                    XCTAssertEqual(back.g, g, accuracy: 1.0 / 255, "\(rgb)")
                    XCTAssertEqual(back.b, b, accuracy: 1.0 / 255, "\(rgb)")
                }
            }
        }
    }

    func testKnownColoursHaveTheirOKLCHValues() {
        let white = ChipColor.oklch(.init(r: 1, g: 1, b: 1))
        XCTAssertEqual(white.l, 1, accuracy: 0.001)
        XCTAssertEqual(white.c, 0, accuracy: 0.001)
        XCTAssertEqual(ChipColor.oklch(.init(r: 0, g: 0, b: 0)).l, 0, accuracy: 0.001)
        // sRGB red, from Ottosson's table: L 0.628, C 0.258, h 29.2°.
        let red = ChipColor.oklch(.init(r: 1, g: 0, b: 0))
        XCTAssertEqual(red.l, 0.628, accuracy: 0.002)
        XCTAssertEqual(red.c, 0.2577, accuracy: 0.002)
        XCTAssertEqual(red.h * 180 / .pi, 29.23, accuracy: 0.2)
        // sRGB blue: L 0.452, C 0.313, h 264.1°.
        let blue = ChipColor.oklch(.init(r: 0, g: 0, b: 1))
        XCTAssertEqual(blue.l, 0.452, accuracy: 0.002)
        XCTAssertEqual(blue.c, 0.3132, accuracy: 0.002)
        XCTAssertEqual((blue.h * 180 / .pi + 360).truncatingRemainder(dividingBy: 360), 264.05, accuracy: 0.2)
    }

    func testAColourOutsideSRGBLosesChromaOnly() {
        // No sRGB yellow is this strong at this lightness.
        let wild = ChipColor.LCH(l: 0.6, c: 0.4, h: 1.9)
        XCTAssertFalse(ChipColor.inGamut(wild))
        let fitted = ChipColor.fitted(wild)
        XCTAssertTrue(ChipColor.inGamut(fitted))
        XCTAssertEqual(fitted.l, wild.l)
        XCTAssertEqual(fitted.h, wild.h)
        XCTAssertLessThan(fitted.c, wild.c)
        XCTAssertGreaterThan(fitted.c, 0.05, "as strong as it can be")
        let tame = ChipColor.LCH(l: 0.6, c: 0.05, h: 1.9)
        XCTAssertEqual(ChipColor.fitted(tame), tame)
    }

    /// The accent colours a widget can take (`AccentPalette`), as chips
    /// resolve them.
    private var accents: [(name: String, color: NSColor)] {
        AccentPalette.swatches.compactMap { swatch in
            guard let value = swatch.value, let color = WidgetAppearance(accent: value).accentColor else { return nil }
            return (value, NSColor(color))
        }
    }

    /// Every chip of a row has the tone's lightness, whatever its widget's
    /// colour, in a colour sRGB can show, with its hue kept and white
    /// readable on it.
    func testEveryAccentBecomesOnePalettePerTone() throws {
        XCTAssertEqual(accents.count, 8)
        var report: [String] = []
        for tone in ChipAppearance.Tone.allCases {
            let target = ChipColor.face(tone)
            var lowest = Double.infinity
            for (name, accent) in accents {
                let face = MenuBarController.chipFace(accent, tone: tone)
                let rgb = try XCTUnwrap(ChipColor.rgb(face))
                for part in [rgb.r, rgb.g, rgb.b] {
                    XCTAssertGreaterThanOrEqual(part, 0, "\(name) \(tone)")
                    XCTAssertLessThanOrEqual(part, 1, "\(name) \(tone)")
                }
                let lch = ChipColor.oklch(rgb)
                XCTAssertEqual(lch.l, target.l, accuracy: 0.01, "\(name) \(tone): the tone's lightness")
                XCTAssertTrue(ChipColor.inGamut(ChipColor.retoned(
                    ChipColor.oklch(try XCTUnwrap(ChipColor.rgb(accent))), l: target.l, c: target.c
                )), "\(name) \(tone)")
                XCTAssertLessThanOrEqual(lch.c, target.c + 0.005, "\(name) \(tone): no stronger than the tone")
                let chosen = ChipColor.oklch(try XCTUnwrap(ChipColor.rgb(accent)))
                if chosen.c >= ChipColor.greyChroma {
                    let gap = abs(lch.h - chosen.h)
                    XCTAssertLessThan(min(gap, 2 * .pi - gap), 0.04, "\(name) \(tone): the widget's hue")
                } else {
                    XCTAssertLessThan(lch.c, ChipColor.greyChroma, "\(name) \(tone): grey stays grey")
                }
                let contrast = ChipColor.contrast(rgb, .init(r: 1, g: 1, b: 1))
                XCTAssertGreaterThanOrEqual(contrast, 3, "\(name) \(tone): white on the face")
                lowest = min(lowest, contrast)
            }
            report.append(String(format: "%@ %.2f", tone.rawValue, lowest))
        }
        print("CHIP-CONTRAST lowest white-on-face per tone: \(report.joined(separator: ", "))")
    }

    /// Stronger tones are stronger and lighter.
    func testTonesAreOrdered() {
        let tones = ChipAppearance.Tone.allCases.map(ChipColor.face)
        XCTAssertEqual(ChipAppearance.Tone.allCases, [.vivid, .balanced, .muted])
        XCTAssertGreaterThan(tones[0].c, tones[1].c)
        XCTAssertGreaterThan(tones[1].c, tones[2].c)
        XCTAssertGreaterThan(tones[0].l, tones[1].l)
        XCTAssertGreaterThan(tones[1].l, tones[2].l)
        XCTAssertEqual(tones[1].l, 0.60)
        XCTAssertEqual(tones[1].c, 0.13)
    }

    /// The Soft style's ink reads on its own wash over either bar.
    func testSoftInkReadsOnEitherBar() throws {
        for tone in ChipAppearance.Tone.allCases {
            for (name, accent) in accents {
                let face = MenuBarController.chipFace(accent, tone: tone)
                let rgb = try XCTUnwrap(ChipColor.rgb(face))
                for dark in [true, false] {
                    let ink = try XCTUnwrap(ChipColor.rgb(ChipColor.ink(face: face, tone: tone, dark: dark)))
                    XCTAssertEqual(ChipColor.oklch(ink).l, dark ? ChipColor.inkOnDark : ChipColor.inkOnLight, accuracy: 0.01)
                    // The wash over a typical bar.
                    let bar = dark ? 0.16 : 0.92
                    let wash = Double(MenuBarController.ChipMetrics.softFill)
                    let under = ChipColor.RGB(
                        r: rgb.r * wash + bar * (1 - wash), g: rgb.g * wash + bar * (1 - wash), b: rgb.b * wash + bar * (1 - wash)
                    )
                    XCTAssertGreaterThanOrEqual(ChipColor.contrast(ink, under), 3, "\(name) \(tone) dark \(dark)")
                }
            }
        }
    }

    /// Two chips of a colour whose hue cannot turn (orange, grey) were told
    /// apart by brightness; the tone levels that, so the later one is
    /// deeper.
    func testChipsOfAnUnturnableColourStillTellApart() throws {
        let chips = (0..<3).map { ClusterChip(widgetID: "w\($0)", name: "W", initial: "W") }
        for base in [NSColor.systemOrange, .systemGray] {
            let colors = MenuBarController.clusterColors(chips) { _ in base }
            let lightness = try chips.map { ChipColor.oklch(try XCTUnwrap(ChipColor.rgb(try XCTUnwrap(colors[$0.id])))).l }
            XCTAssertEqual(lightness[0], ChipColor.face(.balanced).l, accuracy: 0.01)
            XCTAssertLessThan(lightness[1], lightness[0] - 0.05)
            XCTAssertLessThan(lightness[2], lightness[1] - 0.05)
        }
        // A colour that turns keeps the tone's lightness: the hue tells them apart.
        let purple = MenuBarController.clusterColors(chips) { _ in .systemPurple }
        let faces = try chips.map { ChipColor.oklch(try XCTUnwrap(ChipColor.rgb(try XCTUnwrap(purple[$0.id])))) }
        for face in faces { XCTAssertEqual(face.l, ChipColor.face(.balanced).l, accuracy: 0.01) }
        XCTAssertGreaterThan(abs(faces[0].h - faces[1].h), 0.2)
    }
}
