import Foundation

/// A tiny transient-message bus for the popup: `show` publishes a string that a
/// bottom-center capsule in `RootView` renders, then auto-clears after ~1.8s.
///
/// Popup-only by design — there is no toast when the popup is closed, so callers
/// that need feedback in every state (e.g. a copy action) keep their own audible
/// fallback. Successive `show` calls reset the timer so the latest message wins.
@MainActor
final class ToastCenter: ObservableObject {
    static let shared = ToastCenter()

    /// The message currently on screen, or nil when nothing is showing.
    @Published var message: String?

    private var clearTask: Task<Void, Never>?

    private init() {}

    /// Displays `message` and (re)arms the auto-clear timer.
    func show(_ message: String) {
        self.message = message
        clearTask?.cancel()
        clearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            guard !Task.isCancelled else { return }
            self?.message = nil
        }
    }
}
