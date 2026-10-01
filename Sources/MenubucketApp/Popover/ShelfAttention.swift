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
    }

    @Published private(set) var reasons: Reasons = []

    var needsAttention: Bool { !reasons.isEmpty }

    /// Turns one reason on or off; publishes only when something changed.
    func set(_ reason: Reasons, _ active: Bool) {
        var next = reasons
        if active { next.insert(reason) } else { next.remove(reason) }
        guard next != reasons else { return }
        reasons = next
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
