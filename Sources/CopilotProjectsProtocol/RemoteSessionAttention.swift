/// What a session needs from the user, decided once by the Mac. The Mac's sidebar
/// and Next Session Needing Attention use the same decision it publishes.
public struct RemoteSessionAttention: Codable, Equatable, Sendable {
    public enum Kind: String, Sendable {
        /// A question, a permission request, or a budget request needs an answer.
        case waiting
        /// The latest request failed. Seeing it doesn't clear it; the next request does.
        case failed
        /// Copilot finished while the user was away, and the session is idle.
        case ready
        /// An unseen notification, or the user marked the session unread.
        case unread

        public var rank: Int {
            switch self {
            case .waiting: 0
            case .failed: 1
            case .ready, .unread: 2
            }
        }
    }

    /// A `Kind` raw value. A client that doesn't know the kind still orders it by `rank`.
    public let kind: String
    /// Next Session Needing Attention visits lower ranks first.
    public let rank: Int

    public init(_ kind: Kind) {
        self.kind = kind.rawValue
        self.rank = kind.rank
    }
}

/// Where Next Session Needing Attention last went. Each client keeps its own,
/// because each has its own selection: the user can step through sessions on the
/// Mac, a phone and a browser at once.
public struct RemoteAttentionCursor: Equatable, Sendable {
    public let sessionId: String
    public let rank: Int

    public init(sessionId: String, rank: Int) {
        self.sessionId = sessionId
        self.rank = rank
    }

    /// The session Next goes to from `currentSessionId`. `sessions` lists every
    /// session's id and `attention.rank` in workspace order: projects in order, then
    /// each project's sessions in order. Next visits them by rank, then in that
    /// order, and wraps around. `previous` is what Next returned last time.
    ///
    /// Visiting a session can clear its attention. If the current session is the
    /// one Next went to, it carries on from where that session stood instead of
    /// starting from the top.
    public static func next(
        in sessions: [(id: String, rank: Int?)],
        from currentSessionId: String?,
        previous: RemoteAttentionCursor?
    ) -> RemoteAttentionCursor? {
        let stops = sessions.enumerated()
            .compactMap { position, session in
                session.rank.map { (rank: $0, position: position, id: session.id) }
            }
            .sorted { ($0.rank, $0.position) < ($1.rank, $1.position) }
        guard let first = stops.first else { return nil }
        let current = sessions.firstIndex { $0.id == currentSessionId }
        let currentRank = current.flatMap { sessions[$0].rank }
            ?? (previous?.sessionId == currentSessionId ? previous?.rank : nil)
        guard let current, let currentRank else {
            return RemoteAttentionCursor(sessionId: first.id, rank: first.rank)
        }
        let target = stops.first { ($0.rank, $0.position) > (currentRank, current) } ?? first
        return RemoteAttentionCursor(sessionId: target.id, rank: target.rank)
    }
}
