import Foundation

/// Searches the host's live sessions: instant name, project, folder, and
/// conversation matches, Luna's meaning-based picks, or the most recently active
/// sessions. Hosts advertise the capabilities only through the gateway that serves `path`.
public enum RemoteSessionSearchContract {
    public static let capability = "session-search-v1"
    /// The `recent` mode and `RemoteSessionSearchMatch.lastActivityAt`.
    public static let recentCapability = "session-search-recent-v1"
    /// Gateway route, POST JSON.
    public static let path = "/search"
    /// Swift `Character`s (grapheme clusters) after trimming. A client that keeps
    /// queries within this many UTF-16 code units never exceeds it.
    public static let maximumQueryLength = 300
    public static let maximumMatches = 50

    /// The query trimmed of surrounding whitespace, or nil when that leaves it
    /// empty or longer than `maximumQueryLength`.
    public static func normalizedQuery(_ value: String) -> String? {
        normalizedQuery(value, mode: .instant)
    }

    /// As `normalizedQuery(_:)`, except that `recent`, which ignores its query,
    /// also accepts an empty one.
    public static func normalizedQuery(_ value: String, mode: RemoteSessionSearchMode) -> String? {
        let query = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count <= maximumQueryLength, !query.isEmpty || mode == .recent else { return nil }
        return query
    }
}

public enum RemoteSessionSearchMode: String, Codable, Sendable {
    case instant, luna
    /// Every live session, most recently active first. Needs `recentCapability`.
    case recent
}

public struct RemoteSessionSearchRequest: Codable, Equatable, Sendable {
    public let query: String
    public let mode: RemoteSessionSearchMode

    public init(query: String, mode: RemoteSessionSearchMode) {
        self.query = query
        self.mode = mode
    }
}

public struct RemoteSessionSearchMatch: Codable, Equatable, Sendable {
    public let sessionId: String
    public let projectId: String
    /// Instant: one-line conversation excerpt when only conversation text matched.
    public let snippet: String?
    /// Luna: short reason.
    public let reason: String?
    /// When the session's transcript last changed, in milliseconds since 1970.
    /// Absent when unknown, such as for a plain terminal, or from an older host.
    public let lastActivityAtMilliseconds: Int64?

    public var lastActivityAt: Date? {
        lastActivityAtMilliseconds.map { Date(timeIntervalSince1970: Double($0) / 1_000) }
    }

    public init(
        sessionId: String,
        projectId: String,
        snippet: String? = nil,
        reason: String? = nil,
        lastActivityAt: Date? = nil
    ) {
        self.sessionId = sessionId
        self.projectId = projectId
        self.snippet = snippet
        self.reason = reason
        lastActivityAtMilliseconds = lastActivityAt.map { Int64(($0.timeIntervalSince1970 * 1_000).rounded()) }
    }
}

public struct RemoteSessionSearchResponse: Codable, Equatable, Sendable {
    public let mode: RemoteSessionSearchMode
    /// Ranked, best first; for `recent`, most recently active first.
    public let matches: [RemoteSessionSearchMatch]

    public init(mode: RemoteSessionSearchMode, matches: [RemoteSessionSearchMatch]) {
        self.mode = mode
        self.matches = matches
    }
}

public enum RemoteSessionSearchOutcome: Equatable, Sendable {
    case results(RemoteSessionSearchResponse)
    /// Oversized query, or an empty one outside `recent` → HTTP 400.
    case invalid(String)
    /// The host can't search → HTTP 404.
    case unsupported
    /// Too many concurrent Luna runs → HTTP 429.
    case busy
    /// Luna error (user-facing message) → HTTP 502 `{"error": message}`.
    case failed(String)
}
