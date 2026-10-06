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
    /// How to answer this notification from its actions. Nil keeps the
    /// tap-to-open behavior every older client already has.
    public let reply: RemoteNotificationReply?

    public init(
        action: RemoteNotificationAction = .show,
        id: UUID,
        kind: StatusNotificationKind?,
        title: String,
        body: String,
        projectId: String?,
        sessionId: String?,
        sentAt: Date,
        reply: RemoteNotificationReply? = nil
    ) {
        self.action = action
        self.id = id
        self.kind = kind
        self.title = title
        self.body = body
        self.projectId = projectId
        self.sessionId = sessionId
        self.sentAt = sentAt
        self.reply = reply
    }

    private enum CodingKeys: String, CodingKey {
        case action
        case id
        case kind
        case title
        case body
        case projectId
        case sessionId
        case sentAt
        case reply
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        action = try container.decodeIfPresent(RemoteNotificationAction.self, forKey: .action)
            ?? .show
        id = try container.decode(UUID.self, forKey: .id)
        kind = try container.decodeIfPresent(StatusNotificationKind.self, forKey: .kind)
        title = try container.decode(String.self, forKey: .title)
        body = try container.decode(String.self, forKey: .body)
        projectId = try container.decodeIfPresent(String.self, forKey: .projectId)
        sessionId = try container.decodeIfPresent(String.self, forKey: .sessionId)
        sentAt = try container.decode(Date.self, forKey: .sentAt)
        // A reply this client can't use is dropped rather than failing the
        // whole notification.
        reply = (try? container.decodeIfPresent(
            RemoteNotificationReply.self, forKey: .reply
        )).flatMap { $0 }
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
    /// Features this device's app understands. Absent on older apps, so the
    /// gateway keeps sending them only what they registered for.
    public let capabilities: [String]?

    public init(
        token: String,
        environment: APNsEnvironment,
        label: String?,
        capabilities: [String]? = nil
    ) {
        self.token = token
        self.environment = environment
        self.label = label
        self.capabilities = capabilities
    }
}
