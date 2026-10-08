import Foundation

public enum RemotePullRequestsContract {
    public static let capability = "pull-request-overview-v1"
    public static let overviewPath = "/pull-requests"
    public static let sessionPath = "/pull-requests/session"
    public static let version = 1
    public static let maximumKeys = 100
    public static let maximumResponseBytes = 2 * 1_024 * 1_024
    /// Client retries expire before the host's seven-day creation ledger.
    public static let retryLifetime: TimeInterval = 24 * 60 * 60

    public static func canonicalKey(_ value: String) -> String? {
        let parts = value.split(separator: "#", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let repository = parts[0].split(separator: "/", omittingEmptySubsequences: false)
        guard repository.count == 2, let number = Int(parts[1]), number > 0,
              let target = PullRequestReviewTarget.parse(
                "https://github.com/\(repository[0])/\(repository[1])/pull/\(number)"
              ),
              target.owner == repository[0], target.repository == repository[1] else { return nil }
        return "\(target.owner.lowercased())/\(target.repository.lowercased())#\(number)"
    }

    public static func pullRequestURL(for key: String) -> String? {
        guard let key = canonicalKey(key), let hash = key.lastIndex(of: "#") else { return nil }
        return "https://github.com/\(key[..<hash])/pull/\(key[key.index(after: hash)...])"
    }

    /// An external link must identify the same PR as the displayed row.
    public static func validatedURL(_ value: String, key: String) -> URL? {
        guard let target = PullRequestReviewTarget.parse(value),
              canonicalKey("\(target.owner)/\(target.repository)#\(target.number)") == canonicalKey(key),
              let canonical = pullRequestURL(for: key) else { return nil }
        return URL(string: canonical)
    }
}

/// Cached GitHub facts regrouped against the current Mac workspace. Status and
/// phase are strings so an unfamiliar future value need not discard the rows.
public struct RemotePullRequestsOverview: Codable, Equatable, Sendable {
    public let version: Int
    /// loading, loaded, or failed. A failed refresh may still have cached goals.
    public let phase: String
    public let updatedAtMilliseconds: Int64?
    public let isRefreshing: Bool
    public let sessionsKnown: Bool
    public let owners: [String]
    public let warning: String?
    public let omitted: Int
    public let openCount: Int
    public let needsYouCount: Int
    public let goals: [RemotePullRequestGoal]

    public init(
        version: Int = RemotePullRequestsContract.version, phase: String, updatedAtMilliseconds: Int64? = nil,
        isRefreshing: Bool = false, sessionsKnown: Bool = false, owners: [String] = [],
        warning: String? = nil, omitted: Int = 0, openCount: Int, needsYouCount: Int,
        goals: [RemotePullRequestGoal]
    ) {
        self.version = version
        self.phase = phase
        self.updatedAtMilliseconds = updatedAtMilliseconds
        self.isRefreshing = isRefreshing
        self.sessionsKnown = sessionsKnown
        self.owners = owners
        self.warning = warning
        self.omitted = omitted
        self.openCount = openCount
        self.needsYouCount = needsYouCount
        self.goals = goals
    }
}

public struct RemotePullRequestSession: Codable, Equatable, Sendable {
    public let id: String
    public let projectId: String
    public let projectName: String
    public let title: String
    /// running, waiting, idle, or finished; nil when unknown.
    public let status: String?

    public init(id: String, projectId: String, projectName: String, title: String, status: String?) {
        self.id = id
        self.projectId = projectId
        self.projectName = projectName
        self.title = title
        self.status = status
    }
}

public struct RemotePullRequestPreviousSession: Codable, Equatable, Sendable {
    public let copilotSessionId: String
    public let name: String
    public let lastActiveAtMilliseconds: Int64
    /// Only these PRs were verified for this session, not necessarily the whole goal.
    public let pullRequestKeys: [String]

    public init(copilotSessionId: String, name: String, lastActiveAtMilliseconds: Int64, pullRequestKeys: [String]) {
        self.copilotSessionId = copilotSessionId
        self.name = name
        self.lastActiveAtMilliseconds = lastActiveAtMilliseconds
        self.pullRequestKeys = pullRequestKeys
    }
}

public struct RemotePullRequestReason: Codable, Equatable, Sendable {
    public let kind: String
    public let label: String
    public let symbol: String
    public let isNudge: Bool

    public init(kind: String, label: String, symbol: String, isNudge: Bool = false) {
        self.kind = kind
        self.label = label
        self.symbol = symbol
        self.isNudge = isNudge
    }
}

public struct RemotePullRequestItem: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let repository: String
    public let number: Int
    public let title: String
    public let url: String
    public let stage: String
    public let status: String
    public let reasons: [RemotePullRequestReason]
    public let needsYou: Bool
    public let isPartial: Bool
    public let updatedAtMilliseconds: Int64
    public let session: RemotePullRequestSession?

    public init(
        id: String, repository: String, number: Int, title: String, url: String, stage: String,
        status: String, reasons: [RemotePullRequestReason], needsYou: Bool, isPartial: Bool = false,
        updatedAtMilliseconds: Int64, session: RemotePullRequestSession? = nil
    ) {
        self.id = id
        self.repository = repository
        self.number = number
        self.title = title
        self.url = url
        self.stage = stage
        self.status = status
        self.reasons = reasons
        self.needsYou = needsYou
        self.isPartial = isPartial
        self.updatedAtMilliseconds = updatedAtMilliseconds
        self.session = session
    }
}

public struct RemotePullRequestGoal: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let kind: String
    public let session: RemotePullRequestSession?
    public let resumable: RemotePullRequestPreviousSession?
    public let items: [RemotePullRequestItem]

    public var needsYouCount: Int { items.filter(\.needsYou).count }

    public init(
        id: String, name: String, kind: String, session: RemotePullRequestSession? = nil,
        resumable: RemotePullRequestPreviousSession? = nil, items: [RemotePullRequestItem]
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.session = session
        self.resumable = resumable
        self.items = items
    }
}

public struct RemotePullRequestSessionRequest: Codable, Equatable, Sendable {
    public let requestId: UUID
    /// start or resume; other kinds must be rejected, never treated as start.
    public let kind: String
    public let projectId: String
    public let pullRequestKeys: [String]
    public let copilotSessionId: String?

    public init(
        requestId: UUID, kind: String, projectId: String, pullRequestKeys: [String],
        copilotSessionId: String? = nil
    ) {
        self.requestId = requestId
        self.kind = kind
        self.projectId = projectId
        self.pullRequestKeys = pullRequestKeys
        self.copilotSessionId = copilotSessionId
    }

    public func normalized() -> Self? {
        guard ["start", "resume"].contains(kind), !projectId.isEmpty, projectId.utf8.count <= 256,
              !pullRequestKeys.isEmpty, pullRequestKeys.count <= RemotePullRequestsContract.maximumKeys else { return nil }
        let keys = pullRequestKeys.compactMap(RemotePullRequestsContract.canonicalKey)
        guard keys.count == pullRequestKeys.count else { return nil }
        let cid: String?
        if kind == "resume" {
            guard let value = copilotSessionId, let uuid = UUID(uuidString: value) else { return nil }
            cid = uuid.uuidString.lowercased()
        } else {
            guard copilotSessionId == nil else { return nil }
            cid = nil
        }
        return Self(requestId: requestId, kind: kind, projectId: projectId,
                    pullRequestKeys: Set(keys).sorted(), copilotSessionId: cid)
    }

    /// Same intent across retries; a different request ID doesn't change the intent.
    public func hasSameIntent(as other: Self) -> Bool {
        guard let lhs = normalized(), let rhs = other.normalized() else { return false }
        return lhs.kind == rhs.kind && lhs.projectId == rhs.projectId
            && lhs.pullRequestKeys == rhs.pullRequestKeys && lhs.copilotSessionId == rhs.copilotSessionId
    }
}

public struct RemotePullRequestSessionResponse: Codable, Equatable, Sendable {
    public let requestId: UUID
    /// Actual owning project, which can differ from the requested destination.
    public let projectId: String
    /// May name an existing tab and need not equal requestId.
    public let sessionId: String

    public init(requestId: UUID, projectId: String, sessionId: String) {
        self.requestId = requestId
        self.projectId = projectId
        self.sessionId = sessionId
    }
}

public struct RemotePullRequestsError: Codable, Equatable, Sendable {
    public let code: String
    public let error: String

    public init(code: String, error: String) {
        self.code = code
        self.error = error
    }
}

public enum RemotePullRequestsOverviewOutcome: Equatable, Sendable {
    case overview(RemotePullRequestsOverview)
    case unsupported
    case unavailable(String)
}

/// Separate from legacy session creation, whose consumers exhaustively switch
/// on its outcomes and whose response has different session-identity semantics.
public enum RemotePullRequestSessionOutcome: Equatable, Sendable {
    case created(RemotePullRequestSessionResponse)
    case existing(RemotePullRequestSessionResponse)
    case invalid(String)
    case unsupported
    case stale(String)
    case conflict
    case gone
    case inUse
    case unknownProject
    case unavailable(String)
    case persistenceUnavailable
}
