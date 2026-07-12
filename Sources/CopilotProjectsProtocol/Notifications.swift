import Foundation

public enum StatusNotificationKind: String, Codable, Sendable {
    case elicitation
    case permission
    case completed
}

public enum RemoteNotificationAction: String, Codable, Sendable {
    case show
    case clear
}

public enum NotificationSyncContract {
    public static let categoryIdentifier = "copilot-projects.synced"
    public static let notificationIDKey = "id"
    public static let actionKey = "action"
    public static let dismissPath = "notifications/dismiss"
    public static let appGroupIdentifier = "group.com.sirfergy.copilotprojects"
}

public struct RemoteNotificationPayload: Codable, Equatable, Sendable {
    public let action: RemoteNotificationAction
    public let id: UUID
    public let kind: StatusNotificationKind?
    public let title: String
    public let body: String
    public let projectId: String?
    public let sessionId: String?
    public let sentAt: Date

    public init(
        action: RemoteNotificationAction = .show,
        id: UUID,
        kind: StatusNotificationKind?,
        title: String,
        body: String,
        projectId: String?,
        sessionId: String?,
        sentAt: Date
    ) {
        self.action = action
        self.id = id
        self.kind = kind
        self.title = title
        self.body = body
        self.projectId = projectId
        self.sessionId = sessionId
        self.sentAt = sentAt
    }
}

public struct NotificationDismissRequest: Codable, Equatable, Sendable {
    public let id: UUID
    public let apnsToken: String?
    public let apnsEnvironment: APNsEnvironment?

    public init(
        id: UUID,
        apnsToken: String? = nil,
        apnsEnvironment: APNsEnvironment? = nil
    ) {
        self.id = id
        self.apnsToken = apnsToken
        self.apnsEnvironment = apnsEnvironment
    }
}

public struct NotificationDismissalSnapshot: Codable, Equatable, Sendable {
    public let ids: [UUID]

    public init(ids: [UUID]) {
        self.ids = ids
    }
}

public enum APNsEnvironment: String, Codable, Equatable, Sendable {
    case sandbox
    case production
}

public struct APNsRegistration: Codable, Equatable, Sendable {
    public let token: String
    public let environment: APNsEnvironment
    public let label: String?

    public init(
        token: String,
        environment: APNsEnvironment,
        label: String?
    ) {
        self.token = token
        self.environment = environment
        self.label = label
    }
}
