@testable import MenubucketApp
import MenubucketCore
import XCTest

final class MenuBarCardTests: XCTestCase {
    private func widget(statusItem: String = #"{"mode": "text"}"#) throws -> LoadedWidget {
        let json = """
        {"schemaVersion": 1, "id": "test.card", "name": "Card", "version": "1.0.0",
         "entry": {"kind": "workflow", "main": "workflow.json"}, "statusItem": \(statusItem)}
        """
        return LoadedWidget(
            manifest: try Manifest.decode(from: Data(json.utf8)),
            directory: FileManager.default.temporaryDirectory
        )
    }

    func testHistoryKeepsTheLatestReadingsAndDropsRemovedWidgets() {
        let history = ReadingHistory()
        for value in 0..<(ReadingHistory.limit + 5) { history.record("a", Double(value)) }
        history.record("b", 1)
        XCTAssertEqual(history.values["a"]?.count, ReadingHistory.limit)
        XCTAssertEqual(history.values["a"]?.last, Double(ReadingHistory.limit + 4))
        history.retain(["a"])
        XCTAssertNil(history.values["b"])
    }

    func testTheReadingIsTheFirstMetricWithANumber() {
        var snapshot = WidgetSnapshot(widgetID: "a")
        snapshot.statusMetrics = [StatusMetric(label: "Load", value: "busy"), StatusMetric(label: "CPU", value: "23%", number: 23)]
        XCTAssertEqual(ReadingHistory.reading(of: snapshot), 23)
    }

    func testHeroLeadsWithTheMenuBarReadingUnlessTheWidgetOptsOut() throws {
        var snapshot = WidgetSnapshot(widgetID: "test.card")
        snapshot.statusMetrics = [StatusMetric(label: "CPU", value: "23%", number: 23, format: "percent", tint: "warning")]
        let hero = try XCTUnwrap(MenuBarCardHero.Content(widget: try widget(), snapshot: snapshot, history: [1, 2, 3]))
        XCTAssertEqual(hero.label, "CPU")
        XCTAssertEqual(hero.value, "23%")
        XCTAssertEqual(hero.tint, "warning")
        XCTAssertTrue(hero.isPercent)

        let optedOut = try widget(statusItem: #"{"mode": "text", "popoverHero": false}"#)
        XCTAssertNil(MenuBarCardHero.Content(widget: optedOut, snapshot: snapshot, history: []))

        XCTAssertNil(MenuBarCardHero.Content(widget: try widget(), snapshot: WidgetSnapshot(widgetID: "x"), history: []),
                     "nothing for the menu bar, nothing to lead with")

        var labelOnly = WidgetSnapshot(widgetID: "test.card")
        labelOnly.statusLabel = "1:42"
        XCTAssertEqual(MenuBarCardHero.Content(widget: try widget(), snapshot: labelOnly, history: [])?.value, "1:42")
    }

    func testTheCardsHiddenActionGetsANamedButtonOnlyWhenItsNameIsClear() {
        XCTAssertNotNil(PrimaryActionTitle.title(for: NodeAction(type: "openURL", url: "https://example.com")))
        XCTAssertNotNil(PrimaryActionTitle.title(for: NodeAction(type: "revealFile", path: "/tmp")))
        XCTAssertNil(PrimaryActionTitle.title(for: NodeAction(type: "copyText", value: "x")))
        XCTAssertNil(PrimaryActionTitle.title(for: NodeAction(type: "run")))
        XCTAssertEqual(PrimaryActionTitle.appName("Some App"), "Some App")
    }

    func testAPromotableWidgetKeepsAPlaceholderHeroUntilItHasAReading() throws {
        let empty = WidgetSnapshot(widgetID: "test.card")
        XCTAssertNil(MenuBarCardHero.Content(widget: try widget(), snapshot: empty, history: []))
        let placeholder = try XCTUnwrap(MenuBarCardHero.Content.placeholder(
            widget: try widget(statusItem: #"{"mode": "text", "label": "CPU"}"#), snapshot: empty
        ))
        XCTAssertEqual(placeholder.value, "—")
        XCTAssertEqual(placeholder.label, "CPU")
        XCTAssertTrue(placeholder.isPlaceholder)
        XCTAssertTrue(placeholder.history.isEmpty, "no trend for a reading that does not exist")

        var refreshed = empty
        refreshed.updatedAt = Date()
        XCTAssertNil(MenuBarCardHero.Content.placeholder(widget: try widget(), snapshot: refreshed),
                     "refreshed and showing nothing: no placeholder")
        refreshed.isLoading = true
        XCTAssertNotNil(MenuBarCardHero.Content.placeholder(widget: try widget(), snapshot: refreshed),
                        "a reading on its way keeps the place")

        var dash = WidgetSnapshot(widgetID: "test.card")
        dash.statusLabel = "—"
        let real = try XCTUnwrap(MenuBarCardHero.Content(widget: try widget(), snapshot: dash, history: []))
        XCTAssertFalse(real.isPlaceholder, "a widget's own \"—\" is a reading, not a placeholder")

        XCTAssertNil(MenuBarCardHero.Content.placeholder(
            widget: try widget(statusItem: #"{"mode": "none"}"#), snapshot: empty
        ), "a widget with nothing for the menu bar has no hero to hold")
        XCTAssertNil(MenuBarCardHero.Content.placeholder(
            widget: try widget(statusItem: #"{"mode": "text", "popoverHero": false}"#), snapshot: empty
        ))
    }
}

@MainActor
final class CardPolishTests: XCTestCase {
    func testCompactDensityKeepsTheCardInset() {
        XCTAssertEqual(WidgetCardView.contentInset(for: WidgetAppearance(density: .compact)), Spacing.cardInset)
        XCTAssertEqual(WidgetCardView.contentInset(for: WidgetAppearance(density: .regular)), Spacing.cardInset)
        XCTAssertEqual(WidgetCardView.contentInset(for: WidgetAppearance()), Spacing.cardInset)
    }

    func testEmptyCardSaysWhatToDoOrWhatItWaitsFor() {
        XCTAssertEqual(CardEmptyView.message(hint: "Write your first note", hasRefreshed: false), "Write your first note")
        XCTAssertEqual(CardEmptyView.message(hint: nil, hasRefreshed: false),
                       String(localized: "Waiting for the first refresh"))
        XCTAssertEqual(CardEmptyView.message(hint: "", hasRefreshed: true),
                       String(localized: "Nothing to show right now"))
    }

    func testTheEmptyCardCountdownEndsWhenItsTimeHasPassed() {
        let now = Date()
        XCTAssertTrue(CardEmptyView.showsCountdown(to: now.addingTimeInterval(30), now: now))
        XCTAssertFalse(CardEmptyView.showsCountdown(to: now.addingTimeInterval(-5), now: now))
    }

    func testPageCountShowsOnlyWhenTheDotsDoNotFit() {
        XCTAssertFalse(RootView.showsPageCount(pageCount: 1))
        XCTAssertFalse(RootView.showsPageCount(pageCount: 8))
        XCTAssertTrue(RootView.showsPageCount(pageCount: 12))
    }

    func testOnlyAnOverflowingPageFades() {
        XCTAssertFalse(RootView.pageOverflows(content: nil, visible: 400))
        XCTAssertFalse(RootView.pageOverflows(content: 400, visible: 400))
        XCTAssertTrue(RootView.pageOverflows(content: 600, visible: 400))
    }

    func testOnboardingListsMenuBarWidgetsThatCanRunFirst() throws {
        func widget(_ id: String) throws -> LoadedWidget {
            let json = #"{"schemaVersion": 1, "id": "\#(id)", "name": "\#(id)", "entry": {"kind": "workflow"}}"#
            return LoadedWidget(manifest: try Manifest.decode(from: Data(json.utf8)),
                                directory: FileManager.default.temporaryDirectory)
        }
        let widgets = try ["a", "b", "c", "d"].map(widget)
        let ordered = OnboardingView.menuBarOrder(widgets) { $0.id == "b" || $0.id == "d" }
        XCTAssertEqual(ordered.map(\.id), ["b", "d", "a", "c"])
    }

    func testOnboardingShowsADashWhereAReadingWillBe() {
        XCTAssertEqual(OnboardingView.placeholderReading(label: nil), "—")
        XCTAssertEqual(OnboardingView.placeholderReading(label: ""), "—")
        XCTAssertEqual(OnboardingView.placeholderReading(label: "CPU"), "CPU —")
    }
}
