import Foundation

/// Whether something in BarShelf is waiting on the user, and why. Drives the
/// dot on the status item, so a widget asking for permission or failing is
/// noticed without opening the page it lives on.
///
/// Each reason is owned by whoever knows about it: the runtime sets the
/// widget reasons from its own state, and later work (the updater) can set
/// `updateAvailable` the same way.
final class ShelfAttention: ObservableObject {
    struct Reasons: OptionSet, Equatable {
        let rawValue: Int
        /// A widget's permissions are waiting for Allow or Deny.
        static let approvalNeeded = Reasons(rawValue: 1 << 0)
        /// A widget's last refresh failed, or it was stopped after crashing.
        static let widgetError = Reasons(rawValue: 1 << 1)
        /// A newer BarShelf is available.
        static let updateAvailable = Reasons(rawValue: 1 << 2)
        /// Dock settings or restoring the Apple Dock need user attention.
        static let dockNeedsAttention = Reasons(rawValue: 1 << 3)
        /// The keyboard extension's last input source switch did not take.
        static let automationNeedsAttention = Reasons(rawValue: 1 << 4)
    }

    @Published private(set) var reasons: Reasons = []

    /// A widget that failed, or says something is wrong, and in what words:
    /// what the dot on the icon is about, so it can say so.
    struct Problem: Equatable, Identifiable {
        let widgetID: String
        let name: String
        let message: String
        var id: String { widgetID }
    }

    /// Enabled widgets with a problem, in shelf order.
    @Published private(set) var problems: [Problem] = []

    func setProblems(_ problems: [Problem]) {
        guard problems != self.problems else { return }
        self.problems = problems
    }

    /// Why the dot is on, one line per thing, for the icon's tooltip and
    /// what VoiceOver says. Empty when nothing is waiting.
    static func summary(reasons: Reasons, problems: [Problem], waitingCount: Int, limit: Int = 3) -> [String] {
        var lines: [String] = []
        if reasons.contains(.widgetError) {
            for problem in problems.prefix(limit) {
                lines.append("\(problem.name): \(problem.message)")
            }
            if problems.count > limit {
                let more = problems.count - limit
                lines.append(String(localized: "and \(more) more widgets with a problem", comment: "Menu bar icon tooltip"))
            }
        }
        if reasons.contains(.approvalNeeded) {
            lines.append(PermissionWaitingBanner.message(count: max(waitingCount, 1)))
        }
        if reasons.contains(.updateAvailable) {
            lines.append(String(localized: "A new version of BarShelf is available", comment: "Menu bar icon tooltip"))
        }
        if reasons.contains(.dockNeedsAttention) {
            lines.append(String(localized: "The Dock needs attention", comment: "Menu bar icon tooltip"))
        }
        if reasons.contains(.automationNeedsAttention) {
            lines.append(String(localized: "Keyboard switching needs attention", comment: "Menu bar icon tooltip"))
        }
        return lines
    }
    /// The enabled widgets waiting for Allow or Deny, in shelf order: the
    /// popup's "N widgets are waiting" banner counts them.
    @Published private(set) var waitingWidgetIDs: [String] = []

    var needsAttention: Bool { !reasons.isEmpty }

    /// Turns one reason on or off; publishes only when something changed.
    func set(_ reason: Reasons, _ active: Bool) {
        var next = reasons
        if active { next.insert(reason) } else { next.remove(reason) }
        guard next != reasons else { return }
        reasons = next
    }

    func setWaitingWidgetIDs(_ ids: [String]) {
        guard ids != waitingWidgetIDs else { return }
        waitingWidgetIDs = ids
    }

    /// Whether the popup shows the waiting banner: when several widgets are
    /// waiting, or one is waiting on a page other than the one shown.
    static func showsWaitingBanner(waitingIDs: [String], currentPageIDs: Set<String>) -> Bool {
        waitingIDs.count > 1 || waitingIDs.contains { !currentPageIDs.contains($0) }
    }

    /// The widget reasons, worked out from per-widget state. Pure, so the rule
    /// is tested without a runtime: disabled widgets never count, and a denied
    /// widget is the user's decision, not something waiting on them.
    static func widgetReasons(
        widgetIDs: [String],
        isDisabled: (String) -> Bool,
        overlay: (String) -> CardOverlay?,
        error: (String) -> String?
    ) -> Reasons {
        var reasons: Reasons = []
        for id in widgetIDs where !isDisabled(id) {
            switch overlay(id) {
            case .approvalNeeded?:
                reasons.insert(.approvalNeeded)
            case .disabled?:
                reasons.insert(.widgetError)
            case .denied?:
                continue
            case nil:
                if error(id) != nil { reasons.insert(.widgetError) }
            }
        }
        return reasons
    }
}
