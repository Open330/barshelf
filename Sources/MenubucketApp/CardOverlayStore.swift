import Foundation
import MenubucketCore

/// A state the host shows *instead of* a widget's own content until it is
/// resolved. `CardOverlayPolicy` decides which one applies; `CardStateViews`
/// draws it.
enum CardOverlay: Equatable {
    /// New or changed permissions waiting for the user's decision.
    case approvalNeeded([PermissionRequest])
    /// The user denied the current permission set; the widget does not run.
    case denied([PermissionRequest])
    /// A script widget kept crashing and was stopped.
    case disabled(reason: String)

    var needsApproval: Bool {
        if case .approvalNeeded = self { return true }
        return false
    }
}

/// One capability a widget asks for, as the approval card lists it.
struct PermissionRequest: Equatable, Hashable {
    let symbol: String
    let description: String
    /// The exact command lines behind the words, for "Details".
    var details: [String] = []
    /// Something that blocks the widget outright rather than a permission
    /// the user can grant.
    var isWarning = false
}

/// Which host-generated card a widget shows once its permissions have been
/// looked at: the facts in, the card out.
enum CardOverlayPolicy {
    /// - Parameters:
    ///   - status: The widget's permission status, as just read.
    ///   - crashLoopReason: Why its script was stopped after it kept
    ///     crashing, if it was and has not been restarted since.
    ///   - requests: What the widget asks for; only called for a card that
    ///     lists it.
    /// - Returns: The card to show; nil is the widget's own content.
    static func card(
        for status: PermissionStore.Status,
        crashLoopReason: String?,
        requests: () -> [PermissionRequest]
    ) -> CardOverlay? {
        switch status {
        case .approved:
            // A stale approval/denied card goes. A widget stopped after a
            // crash loop shows "Restart Widget" until it is restarted:
            // also when a permission card had replaced that one, or the
            // approval card would stay up with nothing left to allow.
            return crashLoopReason.map { .disabled(reason: $0) }
        case .pending:
            return .approvalNeeded(requests())
        case .denied:
            return .denied(requests())
        }
    }
}

/// The runtime's side of the store: whether a card may be written at all,
/// and where a change goes.
@MainActor
protocol CardOverlayStoreHost: AnyObject {
    /// False while a staged preview is showing and is not itself writing:
    /// the cards are then left exactly as staged.
    var acceptsCardOverlayWrites: Bool { get }
    /// The widget's card changed to `overlay` (nil: its own content again).
    /// Called once per change, after the store holds the new value.
    func cardOverlayDidChange(widgetID: String, to overlay: CardOverlay?)
}

/// What settling a widget's permission card leaves for the runtime to act
/// on: the audit entry is the runtime's, not the store's.
struct PermissionCardOutcome: Equatable {
    /// The card the widget shows now.
    var card: CardOverlay?
    /// The widget is not approved and showed no card before: this is the
    /// first time the request is put in front of the user.
    var isNewRequest: Bool
}

/// The host-generated cards: owns which widget shows which, and which
/// script widgets were stopped after a crash loop. Every change goes through
/// one write path, which reports to the host only when the card differs.
///
/// Main-actor isolated, like the runtime it reports to.
@MainActor
final class CardOverlayStore {
    /// The runtime. Weak: the runtime owns the store. With none, writes
    /// land and nobody is told.
    weak var host: CardOverlayStoreHost?

    /// The card each widget shows instead of its content; no entry for a
    /// widget showing its own.
    private(set) var overlays: [String: CardOverlay] = [:]
    /// Why each crash-looping script widget was stopped. Kept apart from
    /// the card: approval does not clear a "Restart Widget" card, and
    /// brings back one a permission card had replaced.
    private var crashLoopReasons: [String: String] = [:]
    private let requests: (LoadedWidget) -> [PermissionRequest]

    /// - Parameter requests: What a widget asks for, as its approval card
    ///   lists it.
    init(requests: @escaping (LoadedWidget) -> [PermissionRequest] = PermissionCardText.requests(for:)) {
        self.requests = requests
    }

    /// Whether the widget's script was stopped after a crash loop and has
    /// not been restarted since.
    func isCrashLoopDisabled(_ widgetID: String) -> Bool {
        crashLoopReasons[widgetID] != nil
    }

    // MARK: - Permission cards

    /// Shows the card that goes with `status` (`CardOverlayPolicy.card`).
    @discardableResult
    func settlePermissionCard(
        for widget: LoadedWidget, status: PermissionStore.Status
    ) -> PermissionCardOutcome {
        let current = overlays[widget.id]
        let card = CardOverlayPolicy.card(
            for: status,
            crashLoopReason: crashLoopReasons[widget.id],
            requests: { requests(widget) }
        )
        set(card, for: widget.id)
        return PermissionCardOutcome(
            card: overlays[widget.id],
            isNewRequest: status != .approved && current == nil
        )
    }

    // MARK: - Crash-loop cards

    /// The widget's script kept crashing and was stopped: shows the
    /// "Restart Widget" card. The reason is kept even when the card cannot
    /// be written.
    func showCrashLoopCard(reason: String, for widgetID: String) {
        crashLoopReasons[widgetID] = reason
        set(.disabled(reason: reason), for: widgetID)
    }

    /// "Restart Widget": the widget shows its own content again, whatever
    /// card it had, and is no longer counted as stopped.
    func clearForRestart(_ widgetID: String) {
        set(nil, for: widgetID)
        crashLoopReasons.removeValue(forKey: widgetID)
    }

    // MARK: - Housekeeping

    /// Takes every card down, one write each. Crash-loop reasons stay.
    func clearAll() {
        for id in Array(overlays.keys) { set(nil, for: id) }
    }

    /// Drops the cards of widgets that are gone. Not a write: the host is
    /// not told, and a staged preview does not hold it back.
    func forgetCards(notIn liveIDs: Set<String>) {
        overlays = overlays.filter { liveIDs.contains($0.key) }
    }

    /// Drops the crash-loop reasons of widgets that are gone.
    func forgetCrashLoops(notIn liveIDs: Set<String>) {
        crashLoopReasons = crashLoopReasons.filter { liveIDs.contains($0.key) }
    }

    /// Single write path for overlay cards (`nil` removes): nothing while
    /// the host refuses writes, and no report when the card is unchanged.
    private func set(_ overlay: CardOverlay?, for id: String) {
        if let host, !host.acceptsCardOverlayWrites { return }
        guard overlays[id] != overlay else { return }
        overlays[id] = overlay
        host?.cardOverlayDidChange(widgetID: id, to: overlay)
    }
}
