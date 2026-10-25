import AppKit
import SwiftUI
import XCTest
@testable import MenubucketApp
import MenubucketCore

@MainActor
private final class AnnouncementSpy: AccessibilityAnnouncing {
    var messages: [String] = []
    func announce(_ message: String) { messages.append(message) }
}

@MainActor
final class AccessibilityAnnouncementTests: XCTestCase {
    func testAnnouncerSpeaksOnlyWhileVoiceOverRuns() {
        var voiceOver = false
        var posted: [String] = []
        let announcer = AccessibilityAnnouncer(
            isVoiceOverRunning: { voiceOver },
            post: { posted.append($0) }
        )
        announcer.announce("Copied")
        XCTAssertEqual(posted, [], "no announcement work without VoiceOver")
        voiceOver = true
        announcer.announce("")
        announcer.announce("Copied")
        XCTAssertEqual(posted, ["Copied"])
    }

    func testEachToastIsAnnouncedExactlyOnce() async throws {
        let spy = AnnouncementSpy()
        let toasts = ToastCenter(announcer: spy)
        toasts.show("Copied")
        toasts.show("Moved to Work")
        XCTAssertEqual(spy.messages, ["Copied", "Moved to Work"])
        // Auto-clear must not speak again.
        try await Task.sleep(for: .seconds(2))
        XCTAssertNil(toasts.message)
        XCTAssertEqual(spy.messages, ["Copied", "Moved to Work"])
    }

    /// A delay is a lower bound, not a deadline: a busy CI runner fires it
    /// late. Wait until `count` messages arrive (or 2 s pass), then a little
    /// longer so an extra, wrong announcement would still be caught.
    private func waitForMessages(_ spy: AnnouncementSpy, count: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while spy.messages.count < count, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try await Task.sleep(for: .milliseconds(150))
    }

    func testDebouncerSpeaksOnlyTheLastOfABurst() async throws {
        let spy = AnnouncementSpy()
        let debouncer = AnnouncementDebouncer(announcer: spy, delay: .milliseconds(50))
        debouncer.schedule("1 results")
        debouncer.schedule("2 results")
        debouncer.schedule("3 results")
        try await waitForMessages(spy, count: 1)
        XCTAssertEqual(spy.messages, ["3 results"])

        debouncer.schedule("stale")
        debouncer.cancel()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(spy.messages, ["3 results"], "cancel drops the pending announcement")
    }

    func testSearchMessagesDescribeTheSelectedResult() {
        XCTAssertEqual(
            AccessibilityMessages.searchSelection(text: "Disk 82%", widgetName: "System", index: 1, count: 5),
            "Disk 82%, System, 2 of 5"
        )
        XCTAssertEqual(
            AccessibilityMessages.searchResults(count: 3, firstText: "Rain", firstWidgetName: "Weather"),
            "3 results. Rain, Weather, 1 of 3",
            "a new query selects the first row, which is what Return activates"
        )
        XCTAssertEqual(
            AccessibilityMessages.searchResults(count: 0, firstText: nil, firstWidgetName: nil),
            "No matches"
        )
    }

    func testRefreshOutcomeSaysWhetherItWorked() {
        XCTAssertEqual(AccessibilityMessages.refreshOutcome(widgetName: "Weather", error: nil), "Weather refreshed")
        XCTAssertEqual(
            AccessibilityMessages.refreshOutcome(widgetName: "Weather", error: "Network is offline"),
            "Weather couldn't refresh. Network is offline"
        )
    }

    func testSearchFieldReportsIMECompositionAndKeepsText() throws {
        var composing = false
        var text = ""
        let coordinator = SearchField.Coordinator(SearchField(
            text: Binding(get: { text }, set: { text = $0 }),
            isComposing: Binding(get: { composing }, set: { composing = $0 })
        ))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 40),
            styleMask: [.titled], backing: .buffered, defer: true
        )
        let field = NSSearchField(frame: NSRect(x: 0, y: 0, width: 200, height: 22))
        window.contentView?.addSubview(field)
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)

        editor.setMarkedText("ㅎ", selectedRange: NSRange(location: 1, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        coordinator.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        XCTAssertTrue(composing)

        editor.unmarkText()
        coordinator.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        XCTAssertFalse(composing)
        XCTAssertEqual(text, field.stringValue)
    }

    /// Korean keeps the last syllable marked until the next key, so a query
    /// can rest mid-composition. Its results are still announced once the
    /// pause is long enough — and a burst of jamo says only its last state.
    func testResultsAreAnnouncedDuringAPausedCompositionOnlyAfterTheBurst() async throws {
        let spy = AnnouncementSpy()
        let search = SearchAnnouncements(
            announcer: spy, settledDelay: .milliseconds(30), composingDelay: .milliseconds(120), selectionDelay: .milliseconds(10)
        )
        let start = ContinuousClock.now
        search.resultsChanged("5 results. ㄴ", isComposing: true)
        search.resultsChanged("3 results. 나", isComposing: true)
        search.resultsChanged("1 results. 날", isComposing: true)
        try await Task.sleep(for: .milliseconds(60))
        // Only meaningful while the composing delay has not yet passed: a busy
        // runner can oversleep past it, and then an announcement is correct.
        if ContinuousClock.now - start < .milliseconds(110) {
            XCTAssertEqual(spy.messages, [], "not mid-burst, and not at the settled pace")
        }
        try await waitForMessages(spy, count: 1)
        XCTAssertEqual(spy.messages, ["1 results. 날"], "the paused composition is announced once")
    }

    func testCommittingReplacesAPendingCompositionAnnouncement() async throws {
        let spy = AnnouncementSpy()
        let search = SearchAnnouncements(
            announcer: spy, settledDelay: .milliseconds(30), composingDelay: .milliseconds(120), selectionDelay: .milliseconds(10)
        )
        search.resultsChanged("2 results. 나", isComposing: true)
        search.resultsChanged("1 results. 날씨", isComposing: false)
        try await waitForMessages(spy, count: 1)
        XCTAssertEqual(spy.messages, ["1 results. 날씨"])

        search.resultsChanged("4 results", isComposing: false)
        search.selectionMoved("Rain, Weather, 2 of 4")
        try await waitForMessages(spy, count: 2)
        XCTAssertEqual(spy.messages, ["1 results. 날씨", "Rain, Weather, 2 of 4"], "a pending count would name the wrong row")

        search.resultsChanged("stale", isComposing: true)
        search.resultsChanged(nil, isComposing: false)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(spy.messages.count, 2, "an emptied query says nothing")
    }

    /// A refresh asked for on the card is announced by its result, and one
    /// that ended without a new reading or an error (stopped by Disable or a
    /// permission change) is not announced as having worked.
    func testRefreshOutcomeFollowsWhatTheLoadProduced() {
        let before = WidgetCardView.RefreshBaseline(updatedAt: Date(timeIntervalSince1970: 100), error: nil)
        var after = WidgetSnapshot(widgetID: "w")
        after.updatedAt = Date(timeIntervalSince1970: 200)
        XCTAssertEqual(
            WidgetCardView.refreshOutcomeAnnouncement(widgetName: "Weather", before: before, after: after),
            "Weather refreshed"
        )
        after.error = "Network is offline"
        after.updatedAt = before.updatedAt
        XCTAssertEqual(
            WidgetCardView.refreshOutcomeAnnouncement(widgetName: "Weather", before: before, after: after),
            "Weather couldn't refresh. Network is offline"
        )
        after.error = nil
        XCTAssertNil(WidgetCardView.refreshOutcomeAnnouncement(widgetName: "Weather", before: before, after: after))
    }

    func testPageDotsAreVisibleAndStrongerWithIncreasedContrast() {
        let normal = RootView.inactivePageDotOpacity(increasedContrast: false)
        let increased = RootView.inactivePageDotOpacity(increasedContrast: true)
        XCTAssertGreaterThan(normal, 0.35, "the old 0.35 dots nearly vanished")
        XCTAssertGreaterThan(increased, normal)
        XCTAssertGreaterThan(
            RootView.pageDotDiameter(isCurrent: true, isDropTarget: false),
            RootView.pageDotDiameter(isCurrent: false, isDropTarget: false)
        )
    }
}
