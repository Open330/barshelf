import SwiftUI
import XCTest
@testable import MenubucketApp

final class BrandGlyphTests: XCTestCase {
    func testProviderMapping() {
        XCTAssertEqual(BrandMark.forProvider("claude"), .claude)
        XCTAssertEqual(BrandMark.forProvider("anthropic"), .claude)
        XCTAssertEqual(BrandMark.forProvider("Codex"), .codex)
        XCTAssertEqual(BrandMark.forProvider("openai"), .codex)
        XCTAssertNil(BrandMark.forProvider("google"))
    }

    /// The bundled brand paths must parse into a non-degenerate shape roughly
    /// filling the 24×24 viewBox — a regression guard against a truncated path
    /// string or a parser that silently drops arc/relative commands.
    func testBrandPathsParseToFilledShapes() {
        for mark in [BrandMark.claude, .codex] {
            let path = SVGPathParser.parse(mark.pathData)
            XCTAssertFalse(path.isEmpty, "\(mark) path is empty")
            let box = path.boundingRect
            XCTAssertGreaterThan(box.width, 18, "\(mark) too narrow: \(box)")
            XCTAssertGreaterThan(box.height, 18, "\(mark) too short: \(box)")
            XCTAssertLessThan(box.minX, 6, "\(mark) not left-anchored: \(box)")
            XCTAssertLessThan(box.minY, 6, "\(mark) not top-anchored: \(box)")
            XCTAssertLessThan(box.maxX, 25, "\(mark) overflows viewBox: \(box)")
            XCTAssertLessThan(box.maxY, 25, "\(mark) overflows viewBox: \(box)")
        }
    }

    func testShapeScalesIntoRect() {
        let shape = SVGPathShape(pathData: BrandMark.claude.pathData, viewBox: 24)
        let rendered = shape.path(in: CGRect(x: 0, y: 0, width: 48, height: 48))
        XCTAssertFalse(rendered.isEmpty)
        // 24→48 doubles; the mark should span most of the target rect.
        XCTAssertGreaterThan(rendered.boundingRect.width, 36)
    }
}
