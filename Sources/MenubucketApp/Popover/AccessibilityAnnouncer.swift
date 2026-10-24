import AppKit

/// Something that can speak a short message to VoiceOver. Injected so tests
/// can observe what would be announced without VoiceOver running.
@MainActor
protocol AccessibilityAnnouncing: AnyObject {
    func announce(_ message: String)
}

/// Posts `announcementRequested` — the way to tell VoiceOver about a change
/// that happened away from its cursor (a toast, a search count, the selected
/// search result while focus stays in the field). Does nothing unless
/// VoiceOver is running, so sighted users pay nothing for it.
@MainActor
final class AccessibilityAnnouncer: AccessibilityAnnouncing {
    static let shared = AccessibilityAnnouncer()

    private let isVoiceOverRunning: @MainActor () -> Bool
    private let post: @MainActor (String) -> Void

    init(
        isVoiceOverRunning: @escaping @MainActor () -> Bool = { NSWorkspace.shared.isVoiceOverEnabled },
        post: (@MainActor (String) -> Void)? = nil
    ) {
        self.isVoiceOverRunning = isVoiceOverRunning
        self.post = post ?? { AccessibilityAnnouncer.postToVoiceOver($0) }
    }

    func announce(_ message: String) {
        guard !message.isEmpty, isVoiceOverRunning() else { return }
        post(message)
    }

    static func postToVoiceOver(_ message: String) {
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }
}

/// Coalesces a burst of announcements (typing, holding an arrow key) into the
/// last one. A single cancellable sleep per burst — no repeating timer, so it
/// costs nothing while idle.
@MainActor
final class AnnouncementDebouncer {
    private let announcer: AccessibilityAnnouncing
    private let delay: Duration
    private var pending: Task<Void, Never>?

    init(announcer: AccessibilityAnnouncing, delay: Duration) {
        self.announcer = announcer
        self.delay = delay
    }

    func schedule(_ message: String) {
        pending?.cancel()
        pending = Task { [weak self, delay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.pending = nil
            self.announcer.announce(message)
        }
    }

    func cancel() {
        pending?.cancel()
        pending = nil
    }
}

/// The sentences VoiceOver hears. Kept apart from the views so they can be
/// checked against what is actually selected.
enum AccessibilityMessages {
    /// One search result as the selection: what it is, which widget, where.
    static func searchSelection(text: String, widgetName: String, index: Int, count: Int) -> String {
        String(localized: "\(text), \(widgetName), \(index + 1) of \(count)",
               comment: "VoiceOver: the selected search result, its widget, and its position")
    }

    /// The result count after the query changed, followed by the result that
    /// Return would now activate (the first).
    static func searchResults(
        count: Int, firstText: String?, firstWidgetName: String?
    ) -> String {
        guard count > 0, let firstText, let firstWidgetName else {
            return String(localized: "No matches")
        }
        let selection = searchSelection(text: firstText, widgetName: firstWidgetName, index: 0, count: count)
        return String(localized: "\(count) results. \(selection)",
                      comment: "VoiceOver: number of search results, then the selected one")
    }

    /// The outcome of a refresh someone asked for from a card.
    static func refreshOutcome(widgetName: String, error: String?) -> String {
        if let error, !error.isEmpty {
            return String(localized: "\(widgetName) couldn't refresh. \(error)",
                          comment: "VoiceOver: a manual refresh failed; the error follows")
        }
        return String(localized: "\(widgetName) refreshed",
                      comment: "VoiceOver: a manual refresh finished")
    }
}
