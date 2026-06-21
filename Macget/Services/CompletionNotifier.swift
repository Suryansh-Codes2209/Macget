import Foundation
import UserNotifications

/// Posts a local notification when a download finishes. Gated by the
/// `completionNotificationsEnabled` setting at the call site. Authorization is
/// requested lazily on first use; if the user declines, posting is a silent no-op.
@MainActor
enum CompletionNotifier {
    static func downloadCompleted(filename: String) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Download complete"
            content.body = filename
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            )
            // Fetch the center inside the closure so nothing non-Sendable is captured.
            UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
        }
    }
}
