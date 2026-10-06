import Foundation

/// Searches the host's live sessions: instant name, project, folder, and
/// conversation matches, or Luna's meaning-based picks. Hosts advertise the
/// capability only through the gateway that serves `path`.
public enum RemoteSessionSearchContract {
    public static let capability = "session-search-v1"
    /// Gateway route, POST JSON.
    public static let path = "/search"
    /// Swift `Character`s (grapheme clusters) after trimming. A client that keeps
    /// queries within this many UTF-16 code units never exceeds it.
    public static let maximumQueryLength = 300
    public static let maximumMatches = 50

    /// The query trimmed of surrounding whitespace, or nil when that leaves it
    /// empty or longer than `maximumQueryLength`.
    public static func normalizedQuery(_ value: String) -> String? {
        let query = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.count <= maximumQueryLength else { return nil }
        return query
    }
}

public enum RemoteSessionSearchMode: String, Codable, Sendable {
    case instant, luna
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

    public init(sessionId: String, projectId: String, snippet: String? = nil, reason: String? = nil) {
        self.sessionId = sessionId
        self.projectId = projectId
        self.snippet = snippet
        self.reason = reason
    }
}

public struct RemoteSessionSearchResponse: Codable, Equatable, Sendable {
    public let mode: RemoteSessionSearchMode
    /// Ranked, best first.
    public let matches: [RemoteSessionSearchMatch]

    public init(mode: RemoteSessionSearchMode, matches: [RemoteSessionSearchMatch]) {
        self.mode = mode
        self.matches = matches
    }
}

public enum RemoteSessionSearchOutcome: Equatable, Sendable {
    case results(RemoteSessionSearchResponse)
    /// Empty or oversized query → HTTP 400.
    case invalid(String)
    /// The host can't search → HTTP 404.
    case unsupported
    /// Too many concurrent Luna runs → HTTP 429.
    case busy
    /// Luna error (user-facing message) → HTTP 502 `{"error": message}`.
    case failed(String)
}
