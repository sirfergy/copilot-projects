import Foundation

public enum StatusNotificationKind: String, Codable, Sendable {
    case elicitation
    case permission
    case completed
}

public struct RemoteNotificationPayload: Codable, Equatable, Sendable {
    public let id: UUID
    public let kind: StatusNotificationKind?
    public let title: String
    public let body: String
    public let projectId: String?
    public let sessionId: String?
    public let sentAt: Date

    public init(
        id: UUID,
        kind: StatusNotificationKind?,
        title: String,
        body: String,
        projectId: String?,
        sessionId: String?,
        sentAt: Date
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.body = body
        self.projectId = projectId
        self.sessionId = sessionId
        self.sentAt = sentAt
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
