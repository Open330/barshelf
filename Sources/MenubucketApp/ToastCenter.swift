import Foundation
import SwiftUI

/// Where a toast is drawn: the window or panel the action came from. Each
/// surface mounts one `ToastOverlay` for its own kind, so a copy in the Dock
/// says "Copied" in the Dock, not in a popup that may not even be open.
enum ToastSurface: Hashable, Sendable {
    /// The shelf popup.
    case popup
    /// A single widget's card under its menu bar item.
    case menuBarCard
    /// The BarShelf Dock panel.
    case dock
    /// The BarShelf window (shelf board, gallery, settings pages).
    case hub
}

private struct ToastSurfaceKey: EnvironmentKey {
    static let defaultValue: ToastSurface = .popup
}

extension EnvironmentValues {
    /// The surface this view is drawn on, so an action taken here can
    /// confirm itself here. Set once at each surface's root.
    var toastSurface: ToastSurface {
        get { self[ToastSurfaceKey.self] }
        set { self[ToastSurfaceKey.self] = newValue }
    }
}

/// One transient message.
struct Toast: Identifiable {
    enum Tone: Equatable {
        /// A confirmation: "Copied", "Moved to Work".
        case neutral
        /// Something the person asked for did not happen.
        case failure
    }

    /// A button on the toast ("Undo"). Only offered for a moment, so it
    /// never stands in for a permanent control.
    struct Action {
        let title: String
        let perform: () -> Void
    }

    let id = UUID()
    let message: String
    /// A second, quieter line: why it failed, what to do.
    var detail: String?
    var tone: Tone = .neutral
    var surface: ToastSurface
    var action: Action?

    /// Long enough to read a second line, or to reach a button.
    var duration: Duration {
        if action != nil { return .seconds(6) }
        if detail != nil || tone == .failure { return .seconds(4) }
        return .milliseconds(1_800)
    }
}

/// A tiny transient-message bus: `show` publishes a toast that the
/// matching surface's `ToastOverlay` renders, then auto-clears.
///
/// Successive `show` calls reset the timer so the latest message wins. A
/// surface that is not on screen shows nothing; VoiceOver still hears every
/// toast, so a copy from a closed popup is not silent for everyone.
@MainActor
final class ToastCenter: ObservableObject {
    static let shared = ToastCenter()

    /// The toast currently on screen, or nil when nothing is showing.
    @Published private(set) var current: Toast?

    /// The message currently on screen, or nil when nothing is showing.
    var message: String? { current?.message }

    /// The surface someone last acted on. A toast that does not name its
    /// surface (one raised by a service, such as the vault) goes here.
    var lastSurface: ToastSurface = .popup

    private var clearTask: Task<Void, Never>?
    private let announcer: AccessibilityAnnouncing

    init(announcer: AccessibilityAnnouncing? = nil) {
        self.announcer = announcer ?? AccessibilityAnnouncer.shared
    }

    /// Displays `message` and (re)arms the auto-clear timer. VoiceOver hears it
    /// once, here: the capsule is never focused, so it cannot be read in place.
    func show(
        _ message: String,
        detail: String? = nil,
        tone: Toast.Tone = .neutral,
        on surface: ToastSurface? = nil,
        action: Toast.Action? = nil
    ) {
        let surface = surface ?? lastSurface
        lastSurface = surface
        let toast = Toast(message: message, detail: detail, tone: tone, surface: surface, action: action)
        current = toast
        announcer.announce([message, detail].compactMap { $0 }.joined(separator: " "))
        clearTask?.cancel()
        clearTask = Task { [weak self] in
            try? await Task.sleep(for: toast.duration)
            guard !Task.isCancelled else { return }
            self?.dismiss(toast.id)
        }
    }

    /// A failed action: what did not happen, then why and what to do.
    func showFailure(_ message: String, explanation: ErrorExplanation?, on surface: ToastSurface? = nil) {
        let detail = explanation.map { "\($0.cause) \($0.fix)" }
        show(message, detail: detail, tone: .failure, on: surface)
    }

    /// Clears `id` if it is still the one showing (a newer toast stays).
    func dismiss(_ id: UUID) {
        guard current?.id == id else { return }
        current = nil
    }

    /// Runs the current toast's button and takes the toast down.
    func performAction(of id: UUID) {
        guard let toast = current, toast.id == id, let action = toast.action else { return }
        current = nil
        clearTask?.cancel()
        action.perform()
    }
}
