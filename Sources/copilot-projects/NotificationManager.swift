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

struct NotificationEvent: Codable, Equatable, Sendable {
    let id: UUID
    let kind: StatusNotificationKind?
    let title: String
    let subtitle: String?
    let body: String?
    let projectId: String?
    let sessionId: String?
    let sentAt: Date

    init(
        id: UUID = UUID(),
        kind: StatusNotificationKind?,
        title: String,
        subtitle: String?,
        body: String?,
        projectId: String?,
        sessionId: String?,
        sentAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.projectId = projectId
        self.sessionId = sessionId
        self.sentAt = sentAt
    }

    var displayedBody: String {
        var components: [String] = []
        if let body, !body.isEmpty { components.append(body) }
        components.append("Sent at \(sentAt.formatted(date: .omitted, time: .shortened))")
        return components.joined(separator: "\n")
    }

    var webBody: String {
        var components: [String] = []
        if let subtitle, !subtitle.isEmpty { components.append(subtitle) }
        if let body, !body.isEmpty { components.append(body) }
        return components.joined(separator: "\n")
    }
}

@MainActor
protocol NotificationPosting: AnyObject {
    func post(_ event: NotificationEvent)
}

@MainActor
final class CompositeNotificationPoster: NotificationPosting {
    private let posters: [any NotificationPosting]

    init(_ posters: [any NotificationPosting]) {
        self.posters = posters
    }

    func post(_ event: NotificationEvent) {
        for poster in posters { poster.post(event) }
    }
}

/// Thin wrapper over UNUserNotificationCenter. Posts banners and routes taps back
/// to the app via `onActivate(projectId, sessionId)`.
@MainActor
final class NotificationManager: NSObject, NotificationPosting, UNUserNotificationCenterDelegate {
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

    func post(_ event: NotificationEvent) {
        let content = UNMutableNotificationContent()
        content.title = event.title
        if let subtitle = event.subtitle, !subtitle.isEmpty {
            content.subtitle = subtitle
        }
        content.body = event.displayedBody
        content.sound = .default
        var info: [String: String] = [:]
        if let projectId = event.projectId { info["projectId"] = projectId }
        if let sessionId = event.sessionId { info["sessionId"] = sessionId }
        info["sentAt"] = ISO8601DateFormatter().string(from: event.sentAt)
        content.userInfo = info
        let request = UNNotificationRequest(
            identifier: event.id.uuidString,
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
