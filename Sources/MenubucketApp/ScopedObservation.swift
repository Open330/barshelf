import AppKit

/// An `NSEvent` monitor that is removed when its owner lets go of it.
///
/// A main-actor owner cannot reach its own non-Sendable monitor token from
/// `deinit`; holding one of these instead removes the monitor at the same
/// moment, on the same thread, without the owner's `deinit` touching it.
/// Setting the owner's reference to nil removes the monitor at once.
final class EventMonitor {
    private let token: Any

    init?(_ token: Any?) {
        guard let token else { return nil }
        self.token = token
    }

    deinit { NSEvent.removeMonitor(token) }
}

/// A block-based notification observer that is removed when its owner lets
/// go of it (see `EventMonitor`).
final class NotificationObservation {
    private let center: NotificationCenter
    private let token: NSObjectProtocol

    init(_ token: NSObjectProtocol, in center: NotificationCenter = .default) {
        self.center = center
        self.token = token
    }

    deinit { center.removeObserver(token) }
}
