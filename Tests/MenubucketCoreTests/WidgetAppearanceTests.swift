import XCTest
@testable import MenubucketCore

/// R12: WidgetAppearance merge precedence + lenient manifest decoding.
final class WidgetAppearanceTests: XCTestCase {
    // MARK: - merged(over:)

    func testMergePrefersSelfFieldWise() {
        let base = WidgetAppearance(
            accent: "blue", density: .regular, cardStyle: .plain, showHeader: true
        )
        let top = WidgetAppearance(
            accent: "red", density: nil, cardStyle: .tinted, showHeader: nil
        )

        let merged = top.merged(over: base)
        XCTAssertEqual(merged.accent, "red")        // self wins
        XCTAssertEqual(merged.density, .regular)     // falls through to base
        XCTAssertEqual(merged.cardStyle, .tinted)    // self wins
        XCTAssertEqual(merged.showHeader, true)      // falls through to base
    }

    func testMergeNeutralOverNeutralIsNeutral() {
        XCTAssertEqual(
            WidgetAppearance().merged(over: WidgetAppearance()),
            WidgetAppearance()
        )
    }

    func testMergeFullyPopulatedSelfIgnoresBase() {
        let base = WidgetAppearance(accent: "blue", density: .regular)
        let top = WidgetAppearance(
            accent: "green", density: .compact, cardStyle: .tinted, showHeader: false
        )
        XCTAssertEqual(top.merged(over: base), top)
    }

    // MARK: - Manifest lenient decode

    private func manifest(appearanceJSON: String) throws -> Manifest {
        let json = """
        {"schemaVersion":1,"id":"x","name":"X","entry":{"kind":"exec"},
         "appearance":\(appearanceJSON)}
        """
        return try Manifest.decode(from: Data(json.utf8))
    }

    func testValidAppearanceDecodes() throws {
        let m = try manifest(appearanceJSON:
            ##"{"accent":"#FF0000","density":"compact","cardStyle":"tinted","showHeader":false}"##)
        let a: WidgetAppearance = try XCTUnwrap(m.appearance)
        XCTAssertEqual(a.accent, "#FF0000")
        XCTAssertEqual(a.density, .compact)
        XCTAssertEqual(a.cardStyle, .tinted)
        XCTAssertEqual(a.showHeader, false)
    }

    func testInvalidFieldsDecodeToNilNotFailure() throws {
        // Bad enum values and a wrong-typed showHeader must not throw; each bad
        // field decodes to nil while good fields survive.
        let m = try manifest(appearanceJSON:
            #"{"accent":"blue","density":"huge","cardStyle":"nope","showHeader":"yes"}"#)
        let a: WidgetAppearance = try XCTUnwrap(m.appearance)
        XCTAssertEqual(a.accent, "blue")
        XCTAssertNil(a.density)
        XCTAssertNil(a.cardStyle)
        XCTAssertNil(a.showHeader)
    }

    func testNonObjectAppearanceDecodesToNeutral() throws {
        // A completely wrong-typed appearance block yields an all-nil (neutral)
        // appearance rather than failing the manifest decode.
        let m = try manifest(appearanceJSON: #""bright""#)
        let a: WidgetAppearance = try XCTUnwrap(m.appearance)
        XCTAssertEqual(a, WidgetAppearance())
    }

    func testAbsentAppearanceIsNil() throws {
        let json = #"{"schemaVersion":1,"id":"x","name":"X","entry":{"kind":"exec"}}"#
        let m = try Manifest.decode(from: Data(json.utf8))
        XCTAssertNil(m.appearance)
    }

    func testWrongTypedAccentDecodesToNil() throws {
        let m = try manifest(appearanceJSON: #"{"accent":42,"density":"regular"}"#)
        let a: WidgetAppearance = try XCTUnwrap(m.appearance)
        XCTAssertNil(a.accent)
        XCTAssertEqual(a.density, .regular)
    }
}
