import XCTest
@testable import MenubucketCore

final class ChipAppearanceTests: XCTestCase {
    func testDefaults() {
        let look = ChipAppearance()
        XCTAssertEqual(look.style, .solid)
        XCTAssertEqual(look.tone, .balanced)
        XCTAssertEqual(look.glyphSet, .simple)
        XCTAssertEqual(look.glyphSize, .medium)
        XCTAssertEqual(look.spacing, .stacked)
        XCTAssertEqual(AppPreferences().menuBarChips, look)
        XCTAssertEqual(ChipAppearance.Style.allCases.map(\.rawValue), ["solid", "soft", "mono"])
        XCTAssertEqual(ChipAppearance.Tone.allCases.map(\.rawValue), ["vivid", "balanced", "muted"])
        XCTAssertEqual(ChipAppearance.GlyphSet.allCases.map(\.rawValue), ["simple", "symbols"])
        XCTAssertEqual(ChipAppearance.GlyphSize.allCases.map(\.rawValue), ["small", "medium", "large"])
        XCTAssertEqual(ChipAppearance.Spacing.allCases.map(\.rawValue), ["apart", "stacked"])
    }

    private func preferences(_ json: String) throws -> AppPreferences {
        try JSONDecoder().decode(AppPreferences.self, from: Data(json.utf8))
    }

    /// A file an older build wrote has no chips block: everything else
    /// still loads, and the chips are the defaults.
    func testAnOldFileWithoutChipsDecodesToDefaults() throws {
        let old = try preferences(#"{"menuBarSymbol":"star","menuBarLayout":"cluster","menuBarPulse":false}"#)
        XCTAssertEqual(old.menuBarChips, ChipAppearance())
        XCTAssertEqual(old.menuBarSymbol, "star")
        XCTAssertEqual(old.menuBarLayout, .cluster)
        XCTAssertFalse(old.menuBarPulse)
        XCTAssertEqual(try preferences("{}").menuBarChips, ChipAppearance())
    }

    /// A value a newer build wrote costs its own field, not its
    /// neighbours and not the rest of the file.
    func testAnUnknownValueFallsBackFieldByField() throws {
        let mixed = try preferences(#"""
        {"menuBarLayout":"cluster","menuBarChips":{"style":"neon","tone":"muted","glyphSet":"emoji",
         "glyphSize":"large","spacing":7}}
        """#)
        XCTAssertEqual(mixed.menuBarChips, ChipAppearance(style: .solid, tone: .muted, glyphSet: .simple, glyphSize: .large, spacing: .stacked))
        XCTAssertEqual(mixed.menuBarLayout, .cluster)
        let partial = try preferences(#"{"menuBarChips":{"spacing":"stacked"}}"#)
        XCTAssertEqual(partial.menuBarChips, ChipAppearance(spacing: .stacked))
        // Not an object at all: the defaults, and the rest of the file.
        let broken = try preferences(#"{"menuBarChips":"soft","menuBarPulse":false}"#)
        XCTAssertEqual(broken.menuBarChips, ChipAppearance())
        XCTAssertFalse(broken.menuBarPulse)
    }

    func testRoundTrip() throws {
        for style in ChipAppearance.Style.allCases {
            for spacing in ChipAppearance.Spacing.allCases {
                var preferences = AppPreferences()
                preferences.menuBarChips = ChipAppearance(
                    style: style, tone: .vivid, glyphSet: .symbols, glyphSize: .small, spacing: spacing
                )
                let data = try JSONEncoder().encode(preferences)
                XCTAssertEqual(try JSONDecoder().decode(AppPreferences.self, from: data), preferences)
            }
        }
        let json = String(decoding: try JSONEncoder().encode(ChipAppearance(style: .soft)), as: UTF8.self)
        XCTAssertTrue(json.contains(#""style":"soft""#), json)
        XCTAssertTrue(json.contains(#""spacing":"stacked""#), json)
    }

    func testFileRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("chips-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var preferences = AppPreferences()
        preferences.menuBarChips = ChipAppearance(style: .mono, tone: .muted, glyphSet: .symbols, glyphSize: .large, spacing: .stacked)
        try preferences.save(to: url)
        XCTAssertEqual(AppPreferences.load(from: url).menuBarChips, preferences.menuBarChips)
    }
}
