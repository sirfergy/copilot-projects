import Foundation
import CopilotProjectsCore
import CopilotProjectsProtocol

/// The session finder's index, kept between remote searches so typing stays
/// cheap: each search reads again only the transcripts whose files changed.
/// Every file read and match runs here, off the main actor.
actor SessionSearchIndex {
    /// The files `TranscriptController.loadRemoteSnapshot` reads. The same stamp
    /// means the same conversation, except as `emptyRetryInterval` describes.
    struct Stamp: Equatable, Sendable {
        let transcript: FileSignature?
        let owner: FileSignature?
        let quarantine: FileSignature?

        /// When the transcript last changed, as the Mac finder orders sessions.
        var lastActivity: Date? {
            transcript.map { Date(timeIntervalSinceReferenceDate: $0.modifiedAt) }
        }

        static func current(sessionId: String) -> Stamp {
            Stamp(
                transcript: signature(Paths.transcriptSnapshotPath(sessionId: sessionId)),
                owner: signature(Paths.transcriptOwnerPath(sessionId: sessionId)),
                quarantine: signature(Paths.transcriptQuarantinePath(sessionId: sessionId))
            )
        }

        private static func signature(_ path: String) -> FileSignature? {
            (try? FileManager.default.attributesOfItem(atPath: path)).map(FileSignature.init(attributes:))
        }
    }

    private struct Cached {
        /// The session as listed, without its activity time.
        let source: SessionFinderSource
        let stamp: Stamp
        let entry: SessionFinderEntry
        let loadedAt: Date
    }

    /// A transcript that read as no conversation is read again after this long
    /// even when its files are unchanged: an owner check can turn on whether
    /// another process is still running.
    static let emptyRetryInterval: TimeInterval = 30
    /// Conversations are dropped from memory after this long without a search.
    static let defaultIdleLifetime: TimeInterval = 600

    private let stamp: @Sendable (String) -> Stamp
    private let loadTranscript: @Sendable (String) -> TranscriptSnapshot?
    private let idleLifetime: TimeInterval
    private let now: @Sendable () -> Date
    private var cache: [String: Cached] = [:]
    private var useCount = 0
    private var expiry: Task<Void, Never>?

    init(
        stamp: @escaping @Sendable (String) -> Stamp = { Stamp.current(sessionId: $0) },
        loadTranscript: @escaping @Sendable (String) -> TranscriptSnapshot? = {
            TranscriptController.loadRemoteSnapshot(sessionId: $0)
        },
        idleLifetime: TimeInterval = SessionSearchIndex.defaultIdleLifetime,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.stamp = stamp
        self.loadTranscript = loadTranscript
        self.idleLifetime = idleLifetime
        self.now = now
    }

    deinit { expiry?.cancel() }

    var cachedSessionIds: Set<String> { Set(cache.keys) }

    /// Entries for `sources`, in their order. Nil once the calling task is
    /// cancelled; transcripts read before then stay cached for the next search.
    func entries(for sources: [SessionFinderSource]) -> [SessionFinderEntry]? {
        scheduleExpiry()
        let now = now()
        var refreshed: [String: Cached] = [:]
        var entries: [SessionFinderEntry] = []
        for source in sources where refreshed[source.sessionId] == nil {
            if Task.isCancelled {
                cache.merge(refreshed) { _, fresh in fresh }
                return nil
            }
            let stamp = stamp(source.sessionId)
            var dated = source
            dated.lastActivity = stamp.lastActivity
            let cached: Cached
            if let previous = cache[source.sessionId], previous.stamp == stamp,
               !needsRetry(previous, now: now) {
                cached = Cached(
                    source: source, stamp: stamp,
                    entry: previous.source == source ? previous.entry : previous.entry.rebound(to: dated),
                    loadedAt: previous.loadedAt
                )
            } else {
                // Stamped before reading, so a write during the read shows as a change next time.
                cached = Cached(
                    source: source, stamp: stamp,
                    entry: SessionFinderEntry(source: dated, transcript: loadTranscript(source.sessionId)),
                    loadedAt: now
                )
            }
            refreshed[source.sessionId] = cached
            entries.append(cached.entry)
        }
        cache = refreshed
        return entries
    }

    /// The sessions as the finder lists recent ones, dated by their transcript
    /// files alone: no transcript is read and the cache is left as it is. Nil
    /// once the calling task is cancelled.
    func recent(_ sources: [SessionFinderSource]) -> [SessionFinderEntry]? {
        var seen = Set<String>()
        var entries: [SessionFinderEntry] = []
        for source in sources where seen.insert(source.sessionId).inserted {
            if Task.isCancelled { return nil }
            var dated = source
            dated.lastActivity = stamp(source.sessionId).lastActivity
            entries.append(SessionFinderEntry(source: dated))
        }
        return SessionFinderSearch.recent(entries)
    }

    /// `SessionFinderSearch.localMatches` over the live sessions, or nil once cancelled.
    func instantMatches(
        for query: String,
        in sources: [SessionFinderSource],
        limit: Int
    ) -> [SessionFinderSearch.LocalMatch]? {
        guard let entries = entries(for: sources) else { return nil }
        let matches = SessionFinderSearch.localMatches(for: query, in: entries, limit: limit)
        return Task.isCancelled ? nil : matches
    }

    private func needsRetry(_ cached: Cached, now: Date) -> Bool {
        cached.stamp.transcript != nil
            && cached.entry.requests.isEmpty && cached.entry.replies.isEmpty
            && now.timeIntervalSince(cached.loadedAt) >= Self.emptyRetryInterval
    }

    private func scheduleExpiry() {
        useCount &+= 1
        let use = useCount
        let lifetime = idleLifetime
        expiry?.cancel()
        expiry = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, lifetime) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.expire(after: use)
        }
    }

    private func expire(after use: Int) {
        guard use == useCount else { return }
        cache.removeAll()
        expiry = nil
    }
}

/// Answers remote session searches with the Mac finder's instant ranking, Luna,
/// and recent order. One per host, so its Luna limit is host-wide.
@MainActor
final class RemoteSessionSearch {
    static let maximumConcurrentLunaRuns = 2
    static let cancelledMessage = "The search was cancelled."

    private let index: SessionSearchIndex
    private let ranker: SessionRanking
    private(set) var activeLunaRuns = 0

    init(index: SessionSearchIndex = SessionSearchIndex(), ranker: SessionRanking = LunaSessionRanker()) {
        self.index = index
        self.ranker = ranker
    }

    /// `liveSources` lists the live sessions. It is read again once the search
    /// finishes, so sessions that ended meanwhile are left out and moved ones
    /// report their current project.
    func search(
        _ request: RemoteSessionSearchRequest,
        liveSources: () -> [SessionFinderSource]
    ) async -> RemoteSessionSearchOutcome {
        guard let query = RemoteSessionSearchContract.normalizedQuery(request.query, mode: request.mode) else {
            return .invalid(Self.invalidMessage(for: request.query))
        }
        switch request.mode {
        case .instant: return await instant(query, liveSources: liveSources)
        case .luna: return await luna(query, liveSources: liveSources)
        case .recent: return await recent(liveSources: liveSources)
        }
    }

    static func invalidMessage(for query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Enter something to search for."
            : "Searches can be at most \(RemoteSessionSearchContract.maximumQueryLength) characters."
    }

    private func instant(
        _ query: String,
        liveSources: () -> [SessionFinderSource]
    ) async -> RemoteSessionSearchOutcome {
        guard let found = await index.instantMatches(
            for: query, in: liveSources(), limit: RemoteSessionSearchContract.maximumMatches
        ), !Task.isCancelled else {
            return .failed(Self.cancelledMessage)
        }
        let projects = Self.projectIds(liveSources())
        let matches = found.compactMap { match in
            projects[match.entry.id].map {
                RemoteSessionSearchMatch(
                    sessionId: match.entry.id, projectId: $0, snippet: match.snippet,
                    lastActivityAt: match.entry.lastActivity
                )
            }
        }
        return .results(RemoteSessionSearchResponse(mode: .instant, matches: matches))
    }

    private func luna(
        _ query: String,
        liveSources: () -> [SessionFinderSource]
    ) async -> RemoteSessionSearchOutcome {
        guard activeLunaRuns < Self.maximumConcurrentLunaRuns else { return .busy }
        activeLunaRuns += 1
        defer { activeLunaRuns -= 1 }
        guard let entries = await index.entries(for: liveSources()), !Task.isCancelled else {
            return .failed(Self.cancelledMessage)
        }
        guard !entries.isEmpty else {
            return .results(RemoteSessionSearchResponse(mode: .luna, matches: []))
        }
        let picks: [LunaMatch]
        do {
            picks = try await ranker.rank(
                query: SessionFinderSearch.collapseWhitespace(query), entries: entries
            )
        } catch {
            if Task.isCancelled || error is CancellationError { return .failed(Self.cancelledMessage) }
            return .failed((error as? LunaSearchError)?.message ?? error.localizedDescription)
        }
        guard !Task.isCancelled else { return .failed(Self.cancelledMessage) }
        let projects = Self.projectIds(liveSources())
        let activity = Dictionary(
            entries.compactMap { entry in entry.lastActivity.map { (entry.id, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
        var seen = Set<String>()
        let matches = picks.compactMap { pick -> RemoteSessionSearchMatch? in
            guard let projectId = projects[pick.sessionId], seen.insert(pick.sessionId).inserted else {
                return nil
            }
            return RemoteSessionSearchMatch(
                sessionId: pick.sessionId, projectId: projectId,
                reason: pick.reason.isEmpty ? nil : pick.reason,
                lastActivityAt: activity[pick.sessionId]
            )
        }
        return .results(RemoteSessionSearchResponse(
            mode: .luna, matches: Array(matches.prefix(RemoteSessionSearchContract.maximumMatches))
        ))
    }

    private func recent(liveSources: () -> [SessionFinderSource]) async -> RemoteSessionSearchOutcome {
        guard let ordered = await index.recent(liveSources()), !Task.isCancelled else {
            return .failed(Self.cancelledMessage)
        }
        let projects = Self.projectIds(liveSources())
        let matches = ordered.lazy.compactMap { entry in
            projects[entry.id].map {
                RemoteSessionSearchMatch(sessionId: entry.id, projectId: $0, lastActivityAt: entry.lastActivity)
            }
        }.prefix(RemoteSessionSearchContract.maximumMatches)
        return .results(RemoteSessionSearchResponse(mode: .recent, matches: Array(matches)))
    }

    private static func projectIds(_ sources: [SessionFinderSource]) -> [String: String] {
        Dictionary(sources.map { ($0.sessionId, $0.projectId) }, uniquingKeysWith: { first, _ in first })
    }
}

extension AppModel {
    /// Live sessions as remote search lists them. Their transcript times are read
    /// with the transcripts, off the main actor.
    var sessionSearchSources: [SessionFinderSource] {
        projects.flatMap { project in
            project.sessions.map {
                SessionFinderSource(
                    sessionId: $0.id, projectId: project.id, projectName: project.name,
                    title: $0.title, cwd: $0.cwd
                )
            }
        }
    }

    func searchRemoteSessions(_ request: RemoteSessionSearchRequest) async -> RemoteSessionSearchOutcome {
        await remoteSessionSearch.search(request) { sessionSearchSources }
    }
}
