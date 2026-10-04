import XCTest
@testable import MenubucketCore

/// The summaries are what desktop widgets draw; these trees are the shapes
/// the bundled widgets actually produce.
final class SharedShelfSummaryTests: XCTestCase {
    private func text(_ value: String, role: String? = nil, size: Double? = nil, foreground: String? = nil) -> UINode {
        UINode(type: "text", text: value, role: role, size: size, foreground: foreground)
    }

    /// aas account card: name, email, plan badge, and a reading per window.
    func testAUsageCardKeepsItsAccountAndEachWindow() {
        func window(_ label: String, _ reset: String, _ value: String, _ fraction: Double) -> UINode {
            UINode(type: "vstack", children: [
                UINode(type: "hstack", children: [text(label, role: "caption"), text(reset, role: "caption")]),
                text(value, role: "title", size: 19, foreground: "good"),
                UINode(type: "progress", tint: "good", value: fraction),
            ])
        }
        let card = UINode(type: "card", children: [
            UINode(type: "hstack", children: [
                UINode(type: "vstack", children: [text("work@codex", role: "body"), text("work@example.com", role: "caption")]),
                UINode(type: "badge", text: "pro"),
            ]),
            UINode(type: "grid", items: [window("5h", "reset 4.1h", "97% left", 0.03), window("7d", "reset 6.5d", "99% left", 0.01)]),
        ], tone: "good")
        let summary = SharedShelf.summarize(card)
        XCTAssertEqual(summary.title, "work@codex")
        XCTAssertEqual(summary.subtitle, "work@example.com")
        XCTAssertEqual(summary.status, "pro")
        XCTAssertEqual(summary.value, "97% left")
        XCTAssertEqual(summary.detail, "5h · reset 4.1h")
        XCTAssertEqual(summary.metrics.map(\.value), ["97% left", "99% left"])
        // The bar shows what is left, like the number.
        XCTAssertEqual(summary.fraction ?? -1, 0.97, accuracy: 0.0001)
    }

    /// System row: the number is the value even when neither text has a size.
    func testAMeterRowPutsTheNumberAsTheValue() {
        let row = UINode(type: "vstack", children: [
            UINode(type: "hstack", children: [text("CPU"), UINode(type: "spacer"), text("6%")]),
            UINode(type: "progress", tint: "good", value: 0.06),
        ])
        let summary = SharedShelf.summarize(row)
        XCTAssertEqual(summary.title, "CPU")
        XCTAssertEqual(summary.value, "6%")
        XCTAssertEqual(SharedShelf.automaticTemplate(for: [summary, summary]), .meters)
    }

    /// Sensors row with no bar and no number yet.
    func testARowWithoutABarIsStillAReading() {
        let summary = SharedShelf.summarize(UINode(type: "hstack", children: [text("GPU"), UINode(type: "spacer"), text("—")]))
        XCTAssertEqual(summary.title, "GPU")
        XCTAssertEqual(summary.value, "—")
        XCTAssertNil(summary.fraction)
    }

    /// Codex Reset: one reading for the whole widget, named by its question.
    func testAWholeWidgetReadingIsNamedByItsFirstText() {
        let tree = UINode(type: "vstack", children: [
            UINode(type: "hstack", children: [text("Will Codex reset?", role: "caption"), text("48H", role: "caption")]),
            text("18%", role: "title", size: 32),
            UINode(type: "progress", value: 0.18),
            text("Last reset 820h ago", role: "caption"),
        ])
        let summary = SharedShelf.summarize(tree)
        XCTAssertEqual(summary.title, "Will Codex reset?")
        XCTAssertEqual(summary.value, "18%")
        XCTAssertEqual(summary.detail, "48H · Last reset 820h ago")
        XCTAssertEqual(SharedShelf.automaticTemplate(for: []), .bigValue)
    }

    /// muxa agent: status dot, name, time, runtime.
    func testAnAgentRowHasADotAStatusAndASubtitle() {
        let row = UINode(type: "hstack", children: [
            UINode(type: "image", source: ImageSource(kind: "sfSymbol", name: "circle.fill"), size: 8, tint: "good"),
            UINode(type: "vstack", children: [
                UINode(type: "hstack", children: [text("barshelf", role: "body"), text("42s", role: "caption")]),
                text("Claude Code", role: "caption"),
            ]),
        ])
        let summary = SharedShelf.summarize(row)
        XCTAssertEqual(summary.title, "barshelf")
        XCTAssertEqual(summary.status, "42s")
        XCTAssertEqual(summary.subtitle, "Claude Code")
        XCTAssertEqual(summary.dotTone, "good")
        XCTAssertEqual(SharedShelf.automaticTemplate(for: [summary]), .list)
    }

    /// A file tile: its thumbnail and name; files make a grid.
    func testAFileTileMakesAGrid() {
        let tile = UINode(type: "vstack", children: [
            UINode(type: "image", source: ImageSource(kind: "fileThumbnail", path: "/tmp/a.png"), size: 52),
            text("a.png", role: "caption"),
        ])
        let summary = SharedShelf.summarize(tile)
        XCTAssertEqual(summary.title, "a.png")
        XCTAssertEqual(summary.imagePath, "/tmp/a.png")
        XCTAssertEqual(SharedShelf.automaticTemplate(for: [summary]), .grid)
    }

    func testABarAgreesWithThePercentNextToIt() {
        // aas draws what is used while saying what is left.
        XCTAssertEqual(SharedShelf.matchingBar(0.03, value: "97% left"), 0.97, accuracy: 0.001)
        XCTAssertEqual(SharedShelf.matchingBar(0.46, value: "46%"), 0.46, accuracy: 0.001)
        XCTAssertEqual(SharedShelf.matchingBar(0.5, value: "41°"), 0.5, accuracy: 0.001)
        // Unrelated numbers are left alone.
        XCTAssertEqual(SharedShelf.matchingBar(0.2, value: "35%"), 0.2, accuracy: 0.001)
    }
}
