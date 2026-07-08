import Foundation
import UserNotifications
import CopilotProjectsCore

extension StatusNotificationKind {
    var title: String {
        switch self {
        case .elicitation: return "Copilot has a question"
        case .permission: return "Copilot needs permission"
        case .completed: return "Copilot finished a task"
        }
    }
}

/// Thin wrapper over UNUserNotificationCenter. Posts banners and routes taps back
/// to the app via `onActivate(projectId, sessionId)`.
@MainActor
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    var onActivate: ((String?, String?) -> Void)?

    func requestAuth() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error = error {
                NSLog("copilot-projects: notification auth error \(error)")
            } else {
                NSLog("copilot-projects: notification auth granted=\(granted)")
            }
        }
    }

    func post(
        title: String,
        subtitle: String?,
        body: String?,
        projectId: String?,
        sessionId: String?
    ) {
        let content = UNMutableNotificationContent()
        content.title = title
        if let subtitle, !subtitle.isEmpty { content.subtitle = subtitle }
        if let body = body, !body.isEmpty { content.body = body }
        content.sound = .default
        var info: [String: String] = [:]
        if let projectId = projectId { info["projectId"] = projectId }
        if let sessionId = sessionId { info["sessionId"] = sessionId }
        content.userInfo = info
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                NSLog("copilot-projects: failed to post notification \(error)")
            }
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        let projectId = info["projectId"] as? String
        let sessionId = info["sessionId"] as? String
        Task { @MainActor in
            self.onActivate?(projectId, sessionId)
        }
        completionHandler()
    }
}
