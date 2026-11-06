import XCTest
@testable import MenubucketCore

final class MenuBarClusterTests: XCTestCase {
    // MARK: - Geometry

    func testFoldedStackOverlapsAndLeavesRoomForTheIcon() {
        let geometry = ClusterGeometry(count: 5)
        XCTAssertEqual(geometry.collapsedWidth, 4 * 11 + 26)
        XCTAssertEqual(geometry.itemWidth, 70 + 4 + 22)
        XCTAssertEqual(geometry.collapsedMarkX, 74)
        XCTAssertEqual(ClusterGeometry(count: 0).itemWidth, ClusterGeometry.markWidth)
    }

    func testTheHoveredChipStaysPutWhenTheFanOpens() {
        let geometry = ClusterGeometry(count: 5)
        for anchor in 0..<5 {
            XCTAssertEqual(geometry.expandedX(anchor, anchor: anchor), geometry.collapsedX(anchor))
        }
        // Chips before the anchor move left, chips after it move right.
        XCTAssertLessThan(geometry.expandedX(0, anchor: 2), geometry.collapsedX(0))
        XCTAssertGreaterThan(geometry.expandedX(4, anchor: 2), geometry.collapsedX(4))
        XCTAssertEqual(geometry.expandedX(3, anchor: 2) - geometry.expandedX(2, anchor: 2), ClusterGeometry.expandedStep)
    }

    func testOutOfRangeAnchorsClamp() {
        let geometry = ClusterGeometry(count: 3)
        XCTAssertEqual(geometry.expandedX(0, anchor: -4), geometry.expandedX(0, anchor: 0))
        XCTAssertEqual(geometry.expandedX(0, anchor: 9), geometry.expandedX(0, anchor: 2))
    }

    func testFoldedHitTestPicksTheChipOnTop() {
        let geometry = ClusterGeometry(count: 3)
        XCTAssertEqual(geometry.collapsedIndex(at: 5), 0)
        // 12 is inside chip 0 (0...26) and chip 1 (11...37): chip 1 is on top.
        XCTAssertEqual(geometry.collapsedIndex(at: 12), 1)
        XCTAssertEqual(geometry.collapsedIndex(at: 47), 2)
        XCTAssertNil(geometry.collapsedIndex(at: 48))
        XCTAssertNil(geometry.collapsedIndex(at: -1))
        XCTAssertTrue(geometry.isOnMark(collapsedX: geometry.collapsedMarkX + 5))
        XCTAssertFalse(geometry.isOnMark(collapsedX: 20))
    }

    func testFannedOutHitTestHasNoDeadGaps() {
        let geometry = ClusterGeometry(count: 4)
        let anchor = 1
        let first = geometry.expandedX(0, anchor: anchor)
        var x = first
        var seen: [Int] = []
        while x <= geometry.expandedX(3, anchor: anchor) + ClusterGeometry.slot {
            let index = geometry.expandedIndex(at: x, anchor: anchor)
            XCTAssertNotNil(index, "nothing under x=\(x)")
            if let index, seen.last != index { seen.append(index) }
            x += 1
        }
        XCTAssertEqual(seen, [0, 1, 2, 3])
        XCTAssertNil(geometry.expandedIndex(at: first - 20, anchor: anchor))
        XCTAssertTrue(geometry.isOnMark(expandedX: geometry.expandedMarkX(anchor: anchor) + 3, anchor: anchor))
    }

    func testSpanCoversChipsAndIcon() {
        let geometry = ClusterGeometry(count: 3)
        let span = geometry.expandedSpan(anchor: 1)
        XCTAssertEqual(span.lowerBound, geometry.expandedX(0, anchor: 1))
        XCTAssertEqual(span.upperBound, geometry.expandedMarkX(anchor: 1) + ClusterGeometry.markWidth)
    }

    // MARK: - Chips

    func testChipsCarrySymbolRingTintAndAlert() {
        let entries = [
            MenuBarEntry(
                widgetID: "battery", name: "Battery", symbol: "battery.100",
                metrics: [StatusMetric(label: "", value: "80%", number: 80, unit: "%", tint: "good")]
            ),
            MenuBarEntry(
                widgetID: "aas", name: "aas usage", tint: .danger, label: "6% left"
            ),
            MenuBarEntry(widgetID: "k8s", name: "k8s pods", iconOverride: "🚢", label: "3 pods"),
        ]
        let chips = MenuBarClusterPolicy.chips(from: entries) { !$0.unicodeScalars.contains { $0.properties.isEmoji && $0.value > 0x2000 } }
        XCTAssertEqual(chips.map(\.widgetID), ["battery", "aas", "k8s"])

        XCTAssertEqual(chips[0].symbol, "battery.100")
        XCTAssertEqual(chips[0].fraction ?? -1, 0.8, accuracy: 0.0001)
        XCTAssertEqual(chips[0].tint, .good)
        XCTAssertFalse(chips[0].alert)

        XCTAssertNil(chips[1].symbol)
        XCTAssertEqual(chips[1].initial, "A")
        XCTAssertNil(chips[1].fraction, "\"6% left\" is not a bare percentage")
        XCTAssertTrue(chips[1].alert)

        XCTAssertNil(chips[2].symbol)
        XCTAssertEqual(chips[2].initial, "🚢")
        XCTAssertTrue(chips[2].spoken.hasPrefix("k8s pods"))
    }

    func testLabelPercentFillsTheRingAndClamps() {
        let chips = MenuBarClusterPolicy.chips(from: [
            MenuBarEntry(widgetID: "a", name: "CPU", label: "42%"),
            MenuBarEntry(widgetID: "b", name: "Disk", metrics: [StatusMetric(value: "130%", number: 130, unit: "%")]),
        ])
        XCTAssertEqual(chips[0].fraction ?? -1, 0.42, accuracy: 0.0001)
        XCTAssertEqual(chips[1].fraction, 1)
    }

    func testChipCountIsCapped() {
        let entries = (0..<20).map { MenuBarEntry(widgetID: "w\($0)", name: "W\($0)", label: "\($0)") }
        XCTAssertLessThanOrEqual(MenuBarClusterPolicy.chips(from: entries).count, MenuBarClusterPolicy.maxChips)
    }

    func testInitialSkipsPunctuation() {
        XCTAssertEqual(MenuBarClusterPolicy.initial(of: "(beta) clock"), "B")
        XCTAssertEqual(MenuBarClusterPolicy.initial(of: "…"), "•")
    }

    // MARK: - Preference

    func testLayoutDefaultsToItemsAndDecodesLeniently() throws {
        XCTAssertEqual(AppPreferences().menuBarLayout, .items)
        let cluster = try JSONDecoder().decode(AppPreferences.self, from: Data(#"{"menuBarLayout":"cluster"}"#.utf8))
        XCTAssertEqual(cluster.menuBarLayout, .cluster)
        let unknown = try JSONDecoder().decode(AppPreferences.self, from: Data(#"{"menuBarLayout":"orbit"}"#.utf8))
        XCTAssertEqual(unknown.menuBarLayout, .items)
        var prefs = AppPreferences()
        prefs.menuBarLayout = .cluster
        let roundTrip = try JSONDecoder().decode(AppPreferences.self, from: JSONEncoder().encode(prefs))
        XCTAssertEqual(roundTrip.menuBarLayout, .cluster)
    }
}

final class MenuBarClusterProfileTests: XCTestCase {
    func testProfilesSplitIntoOneChipEach() {
        let readings = [
            StatusMetric(id: "work", label: "work-01", value: "36%", number: 36, unit: "%", tint: "good"),
            StatusMetric(id: "personal", label: "personal", value: "18%", number: 18, unit: "%", tint: "warning"),
            StatusMetric(label: "team-x", value: "6%", number: 6, unit: "%", tint: "danger"),
        ]
        var entry = MenuBarEntry(widgetID: "aas", name: "aas usage", style: .metrics, metrics: readings)
        entry.profiles = true
        entry.profileMetrics = MenuBarPolicy.normalizedMetrics(readings, limit: 8)
        XCTAssertEqual(entry.metrics.count, MenuBarPolicy.maxMetrics, "the item itself still draws two")
        let chips = MenuBarClusterPolicy.chips(from: [entry, MenuBarEntry(widgetID: "b", name: "Battery", label: "80%")])
        XCTAssertEqual(chips.map(\.id), ["aas#work", "aas#personal", "aas#2", "b"])
        XCTAssertEqual(Set(chips.prefix(3).map(\.widgetID)), ["aas"])
        XCTAssertEqual(chips[0].name, "work-01")
        XCTAssertEqual(chips[0].initial, "W")
        XCTAssertEqual(chips[1].fraction ?? -1, 0.18, accuracy: 0.0001)
        XCTAssertEqual(chips[1].tint, .warning)
        XCTAssertTrue(chips[2].alert)
        XCTAssertEqual(chips[2].reading, "6%")
        XCTAssertTrue(chips[0].spoken.hasPrefix("aas usage"))
    }

    func testProfilesFlagIgnoredForASingleMetric() {
        var entry = MenuBarEntry(widgetID: "aas", name: "aas", metrics: [StatusMetric(label: "a", value: "1")])
        entry.profiles = true
        XCTAssertEqual(MenuBarClusterPolicy.chips(from: [entry]).map(\.id), ["aas"])
    }

    func testManifestDecodesProfiles() throws {
        let item = try JSONDecoder().decode(
            Manifest.StatusItem.self, from: Data(#"{"mode":"text","style":"metrics","profiles":true}"#.utf8)
        )
        XCTAssertEqual(item.profiles, true)
    }
}

final class MenuBarClusterFocusTests: XCTestCase {
    func testFocusOpensOneGapBehindTheFocusedChip() {
        for count in 2...MenuBarClusterPolicy.maxChips {
            let g = ClusterGeometry(count: count)
            XCTAssertFalse(g.hidesMark(focus: nil))
            for focus in 0..<count {
                XCTAssertTrue(g.hidesMark(focus: focus))
                for index in 0..<count {
                    let moved = g.focusedX(index, focus: focus) - g.collapsedX(index)
                    // Up to the focused chip nothing moves; after it, all
                    // step aside together.
                    XCTAssertEqual(moved, index > focus ? ClusterGeometry.focusShift : 0, accuracy: 0.0001)
                }
                if focus < count - 1 {
                    XCTAssertEqual(g.focusedX(focus + 1, focus: focus) - g.focusedX(focus, focus: focus), ClusterGeometry.revealStep, accuracy: 0.0001)
                }
                XCTAssertLessThanOrEqual(g.focusedX(count - 1, focus: focus) + ClusterGeometry.slot, g.itemWidth, "stays inside the item")
            }
        }
        XCTAssertFalse(ClusterGeometry(count: 1).hidesMark(focus: 0), "a lone chip keeps the icon")
    }

    func testFocusStaysPutUnderAStillPointer() {
        for count in 2...MenuBarClusterPolicy.maxChips {
            let g = ClusterGeometry(count: count)
            var x = 0.0
            while x < g.collapsedWidth {
                // Folded, the pointer picks a chip; laid out for it, the
                // pointer is still on it.
                if let first = g.focusedIndex(at: x, focus: nil) {
                    XCTAssertEqual(g.focusedIndex(at: x, focus: first), first, "count \(count) x \(x)")
                }
                x += 0.5
            }
        }
    }

    func testTheIconStaysClickableWhileFolded() {
        let g = ClusterGeometry(count: 4)
        XCTAssertNil(g.focusedIndex(at: g.collapsedMarkX + 5, focus: nil))
    }

    func testEveryChipIsReachableSweepingAcrossFourChips() {
        let g = ClusterGeometry(count: 4)
        for direction in [1.0, -1.0] {
            // Right from the left edge folded; back left from the last chip.
            var focus: Int? = direction > 0 ? nil : 3
            var seen = Set<Int>()
            var x = direction > 0 ? 0 : g.collapsedWidth - 0.25
            while x >= 0, x < g.itemWidth {
                if let index = g.focusedIndex(at: x, focus: focus) {
                    focus = index
                    seen.insert(index)
                }
                x += 0.25 * direction
            }
            XCTAssertEqual(seen, [0, 1, 2, 3], "sweep \(direction)")
        }
    }
}
