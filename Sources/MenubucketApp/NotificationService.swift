import Foundation
import UserNotifications

/// `host.notify.show` sink backed by UNUserNotificationCenter.
///
/// Requires a real app bundle — `swift build` dev binaries have no bundle
/// identifier, so notifications degrade to a thrown error (surfaced to the
/// script as an RPC error) instead of crashing the process.
final class NotificationService: @unchecked Sendable {
    enum NotificationError: Error, LocalizedError {
        case unavailable
        case denied

        var errorDescription: String? {
            switch self {
            case .unavailable:
                return "Notifications only work in the installed BarShelf app, not a development build."
            case .denied:
                return "BarShelf isn't allowed to show notifications. Turn them on in System Settings ▸ Notifications ▸ BarShelf."
            }
        }
    }

    /// Asks macOS once, at the moment the user allows a widget that sends
    /// notifications — so the system prompt follows their own decision
    /// instead of appearing out of nowhere the first time a widget fires.
    static func requestAuthorization() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        Task {
            _ = try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
        }
    }

    func show(title: String, body: String?) async throws {
        guard Bundle.main.bundleIdentifier != nil else {
            throw NotificationError.unavailable
        }
        let center = UNUserNotificationCenter.current()
        let granted = try await center.requestAuthorization(options: [.alert, .sound])
        guard granted else { throw NotificationError.denied }

        let content = UNMutableNotificationContent()
        content.title = title
        if let body { content.body = body }
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil
        )
        try await center.add(request)
    }
}
