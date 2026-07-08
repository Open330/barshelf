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
                return "notifications unavailable (no app bundle — run the packaged MenuBucket.app)"
            case .denied:
                return "notification permission denied by the user"
            }
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
