import Foundation
import CopilotProjectsCore
import CopilotProjectsProtocol

/// The session finder's index, kept between remote searches so typing stays
/// cheap: each search reads again only the transcripts whose files changed.
/// Every file read and match runs here, off the main actor.
actor SessionSearchIndex {
    /// The files `TranscriptController.loadRemoteSnapshot` reads. The same stamp
    /// means the same conversation.
    struct Stamp: Equatable, Sendable {
        let transcript: FileSignature?
        let owner: FileSignature?
        let live: FileSignature?

        /// When the transcript last changed, as the Mac finder orders sessions:
        /// the later of its sealed file and the live file of the turn in progress.
        var lastActivity: Date? {
            transcript.map {
                Date(timeIntervalSinceReferenceDate: max($0.modifiedAt, live?.modifiedAt ?? 0))
            }
        }

        static func current(sessionId: String) -> Stamp {
            Stamp(
                transcript: signature(Paths.transcriptSnapshotPath(sessionId: sessionId)),
                owner: signature(Paths.transcriptOwnerPath(sessionId: sessionId)),
                live: signature(Paths.transcriptLivePath(sessionId: sessionId))
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
    }

    /// Resumable ended sessions are cached across rapid remote keystrokes for this long.
    static let resumableCacheInterval: TimeInterval = 15
    /// Conversations are dropped from memory after this long without a search.
    static let defaultIdleLifetime: TimeInterval = 600

    private let stamp: @Sendable (String) -> Stamp
    private let loadTranscript: @Sendable (String) -> TranscriptSnapshot?
    private let idleLifetime: TimeInterval
    private var cache: [String: Cached] = [:]
    private var cachedResumable: (entries: [SessionFinderEntry], loadedAt: Date)?
    private var useCount = 0
    private var expiry: Task<Void, Never>?

    init(
        stamp: @escaping @Sendable (String) -> Stamp = { Stamp.current(sessionId: $0) },
        loadTranscript: @escaping @Sendable (String) -> TranscriptSnapshot? = {
            TranscriptController.loadRemoteSnapshot(sessionId: $0)
        },
        idleLifetime: TimeInterval = SessionSearchIndex.defaultIdleLifetime
    ) {
        self.stamp = stamp
        self.loadTranscript = loadTranscript
        self.idleLifetime = idleLifetime
    }

    deinit { expiry?.cancel() }

    var cachedSessionIds: Set<String> { Set(cache.keys) }

    /// Entries for `sources`, in their order. Nil once the calling task is
    /// cancelled; transcripts read before then stay cached for the next search.
    func entries(for sources: [SessionFinderSource]) -> [SessionFinderEntry]? {
        scheduleExpiry()
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
            if let previous = cache[source.sessionId], previous.stamp == stamp {
                cached = Cached(
                    source: source, stamp: stamp,
                    entry: previous.source == source ? previous.entry : previous.entry.rebound(to: dated)
                )
            } else {
                // Stamped before reading, so a write during the read shows as a change next time.
                cached = Cached(
                    source: source, stamp: stamp,
                    entry: SessionFinderEntry(source: dated, transcript: loadTranscript(source.sessionId))
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

    /// `SessionFinderSearch.localMatches` over the live sessions and any additional
    /// resumable entries, or nil once cancelled.
    func instantMatches(
        for query: String,
        in sources: [SessionFinderSource],
        additionalEntries: [SessionFinderEntry] = [],
        limit: Int
    ) -> [SessionFinderSearch.LocalMatch]? {
        guard let entries = entries(for: sources) else { return nil }
        let matches = SessionFinderSearch.localMatches(
            for: query,
            in: entries + additionalEntries,
            limit: limit
        )
        return Task.isCancelled ? nil : matches
    }

    /// Cached recent ended resumable sessions, refreshed after `resumableCacheInterval`
    /// and rebound to the current project targets on each lookup.
    func resumableEntries(
        projects: [SessionFinderProjectTarget],
        selectedProjectId: String?,
        excludedCopilotSessionIds: @Sendable () -> Set<String> = { [] },
        defaultStartupDir: String = Paths.defaultStartupDir,
        load: @Sendable (Set<String>) -> [SessionFinderEntry]
    ) -> [SessionFinderEntry]? {
        scheduleExpiry()
        let current = Date()
        let excluded = excludedCopilotSessionIds()
        if let cached = cachedResumable,
           current.timeIntervalSince(cached.loadedAt) < Self.resumableCacheInterval {
            guard !Task.isCancelled else { return nil }
            return Self.rebindResumableEntries(
                cached.entries,
                projects: projects,
                selectedProjectId: selectedProjectId,
                excludedCopilotSessionIds: excluded,
                defaultStartupDir: defaultStartupDir
            )
        }
        let loaded = load(excluded)
        guard !Task.isCancelled else { return nil }
        cachedResumable = (loaded, current)
        return Self.rebindResumableEntries(
            loaded,
            projects: projects,
            selectedProjectId: selectedProjectId,
            excludedCopilotSessionIds: excluded,
            defaultStartupDir: defaultStartupDir
        )
    }

    private static func rebindResumableEntries(
        _ entries: [SessionFinderEntry],
        projects: [SessionFinderProjectTarget],
        selectedProjectId: String?,
        excludedCopilotSessionIds: Set<String>,
        defaultStartupDir: String
    ) -> [SessionFinderEntry] {
        guard !projects.isEmpty else { return [] }
        return entries.compactMap { entry in
            if let copilotId = entry.source.resumableCopilotSessionId?.lowercased(),
               excludedCopilotSessionIds.contains(copilotId) {
                return nil
            }
            guard let targetProject = SessionFinderSearch.targetProject(
                forCwd: entry.source.cwd,
                repository: entry.source.repository,
                projects: projects,
                selectedProjectId: selectedProjectId,
                defaultStartupDir: defaultStartupDir
            ) else { return nil }
            guard entry.source.projectId != targetProject.id || entry.source.projectName != targetProject.name else {
                return entry
            }
            return entry.rebound(
                to: SessionFinderSource(
                    sessionId: entry.source.sessionId,
                    projectId: targetProject.id,
                    projectName: targetProject.name,
                    title: entry.source.title,
                    cwd: entry.source.cwd,
                    lastActivity: entry.source.lastActivity,
                    resumableCopilotSessionId: entry.source.resumableCopilotSessionId,
                    repository: entry.source.repository
                )
            )
        }
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
        cachedResumable = nil
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
    private let historySearcher: SessionHistorySearching?
    private let copilotSessionStore: (@Sendable () -> CopilotSessionStore)?
    private(set) var activeLunaRuns = 0

    init(
        index: SessionSearchIndex = SessionSearchIndex(),
        ranker: SessionRanking = LunaSessionRanker(),
        historySearcher: SessionHistorySearching? = nil,
        copilotSessionStore: (@Sendable () -> CopilotSessionStore)? = nil
    ) {
        self.index = index
        self.ranker = ranker
        self.historySearcher = historySearcher ?? (ranker as? SessionHistorySearching)
        self.copilotSessionStore = copilotSessionStore
    }

    var capabilities: [String] {
        var list = [
            RemoteSessionSearchContract.capability,
            RemoteSessionSearchContract.recentCapability,
        ]
        if historySearcher != nil {
            list.append(RemoteSessionSearchContract.historyCapability)
        }
        return list
    }

    /// `liveSources` lists the live sessions. It is read again once the search
    /// finishes, so sessions that ended meanwhile are left out and moved ones
    /// report their current project.
    func search(
        _ request: RemoteSessionSearchRequest,
        liveSources: () -> [SessionFinderSource]
    ) async -> RemoteSessionSearchOutcome {
        await search(
            request,
            liveSources: liveSources,
            projects: { [] },
            selectedProjectId: { nil },
            inMemoryActiveCopilotIds: { [] },
            markerDirectory: Paths.sessionsDir,
            defaultStartupDir: Paths.defaultStartupDir
        )
    }

    func search(
        _ request: RemoteSessionSearchRequest,
        liveSources: () -> [SessionFinderSource],
        projects: () -> [SessionFinderProjectTarget],
        selectedProjectId: () -> String?,
        inMemoryActiveCopilotIds: () -> Set<String>,
        markerDirectory: URL = Paths.sessionsDir,
        defaultStartupDir: String = Paths.defaultStartupDir
    ) async -> RemoteSessionSearchOutcome {
        guard let query = RemoteSessionSearchContract.normalizedQuery(request.query, mode: request.mode) else {
            return .invalid(Self.invalidMessage(for: request.query))
        }
        let includeResumable = request.includeResumable == true
        switch request.mode {
        case .instant:
            return await instant(
                query,
                includeResumable: includeResumable,
                liveSources: liveSources,
                projects: projects,
                selectedProjectId: selectedProjectId,
                inMemoryActiveCopilotIds: inMemoryActiveCopilotIds,
                markerDirectory: markerDirectory,
                defaultStartupDir: defaultStartupDir
            )
        case .luna:
            return await luna(
                query,
                includeResumable: includeResumable,
                liveSources: liveSources,
                projects: projects,
                selectedProjectId: selectedProjectId,
                inMemoryActiveCopilotIds: inMemoryActiveCopilotIds,
                markerDirectory: markerDirectory,
                defaultStartupDir: defaultStartupDir
            )
        case .recent:
            return await recent(
                includeResumable: includeResumable,
                liveSources: liveSources,
                projects: projects,
                selectedProjectId: selectedProjectId,
                inMemoryActiveCopilotIds: inMemoryActiveCopilotIds,
                markerDirectory: markerDirectory,
                defaultStartupDir: defaultStartupDir
            )
        case .history:
            return await history(
                query,
                excludedCopilotSessionIds: request.excludedCopilotSessionIds ?? [],
                liveSources: liveSources,
                projects: projects,
                selectedProjectId: selectedProjectId,
                inMemoryActiveCopilotIds: inMemoryActiveCopilotIds,
                markerDirectory: markerDirectory,
                defaultStartupDir: defaultStartupDir
            )
        }
    }

    static func invalidMessage(for query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Enter something to search for."
            : "Searches can be at most \(RemoteSessionSearchContract.maximumQueryLength) characters."
    }

    private func loadResumableEntries(
        includeResumable: Bool = true,
        candidateIds: [String]? = nil,
        projects: [SessionFinderProjectTarget],
        selectedProjectId: String?,
        inMemoryIds: Set<String>,
        liveSessionIds: [String],
        markerDirectory: URL,
        defaultStartupDir: String
    ) async -> [SessionFinderEntry]? {
        guard includeResumable, let storeProvider = copilotSessionStore, !projects.isEmpty else { return [] }
        if let candidateIds, candidateIds.isEmpty { return [] }
        if candidateIds == nil {
            return await index.resumableEntries(
                projects: projects,
                selectedProjectId: selectedProjectId,
                excludedCopilotSessionIds: {
                    let markerIds = AppModel.validatedMarkerCopilotSessionIds(
                        sessionIds: liveSessionIds,
                        directory: markerDirectory
                    )
                    return inMemoryIds.union(markerIds)
                },
                defaultStartupDir: defaultStartupDir
            ) { excluded in
                SessionFinderResumableLoader.load(
                    store: storeProvider(),
                    projects: projects,
                    selectedProjectId: selectedProjectId,
                    liveCopilotSessionIds: excluded,
                    defaultStartupDir: defaultStartupDir
                )
            }
        }
        let ids = candidateIds ?? []
        let task = Task.detached(priority: .userInitiated) {
            let markerIds = AppModel.validatedMarkerCopilotSessionIds(
                sessionIds: liveSessionIds,
                directory: markerDirectory
            )
            return SessionFinderResumableLoader.loadEntries(
                forCopilotSessionIds: ids,
                store: storeProvider(),
                projects: projects,
                selectedProjectId: selectedProjectId,
                liveCopilotSessionIds: inMemoryIds.union(markerIds),
                defaultStartupDir: defaultStartupDir
            )
        }
        let entries = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        return Task.isCancelled ? nil : entries
    }

    private static func makeMatch(
        for entry: SessionFinderEntry,
        liveProjects: [String: String],
        validProjectIds: Set<String>,
        activeCopilotIds: Set<String>,
        snippet: String? = nil,
        reason: String? = nil
    ) -> RemoteSessionSearchMatch? {
        let cleanedReason = reason.flatMap { $0.isEmpty ? nil : $0 }
        if let copilotId = entry.source.resumableCopilotSessionId?.lowercased() {
            guard !activeCopilotIds.contains(copilotId),
                  validProjectIds.contains(entry.source.projectId) else {
                return nil
            }
            let folder = entry.folderName
            return RemoteSessionSearchMatch(
                sessionId: entry.id,
                projectId: entry.source.projectId,
                snippet: snippet,
                reason: cleanedReason,
                lastActivityAt: entry.lastActivity,
                resumableCopilotSessionId: copilotId,
                title: RemoteSessionSearchContract.sanitizedTitle(entry.source.title) ?? "Copilot session",
                folderName: folder.isEmpty || folder == "/" ? nil : folder
            )
        }
        guard let projectId = liveProjects[entry.id] else { return nil }
        return RemoteSessionSearchMatch(
            sessionId: entry.id,
            projectId: projectId,
            snippet: snippet,
            reason: cleanedReason,
            lastActivityAt: entry.lastActivity
        )
    }

    private static func rankedMatches(
        from picks: [LunaMatch],
        entries: [SessionFinderEntry],
        liveProjects: [String: String],
        validProjectIds: Set<String>,
        activeCopilotIds: Set<String>
    ) -> [RemoteSessionSearchMatch] {
        let entriesById = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        let matches = picks.compactMap { pick -> RemoteSessionSearchMatch? in
            guard seen.insert(pick.sessionId).inserted,
                  let entry = entriesById[pick.sessionId] else {
                return nil
            }
            return makeMatch(
                for: entry,
                liveProjects: liveProjects,
                validProjectIds: validProjectIds,
                activeCopilotIds: activeCopilotIds,
                reason: pick.reason
            )
        }
        return Array(matches.prefix(RemoteSessionSearchContract.maximumMatches))
    }

    private func instant(
        _ query: String,
        includeResumable: Bool,
        liveSources: () -> [SessionFinderSource],
        projects: () -> [SessionFinderProjectTarget],
        selectedProjectId: () -> String?,
        inMemoryActiveCopilotIds: () -> Set<String>,
        markerDirectory: URL,
        defaultStartupDir: String
    ) async -> RemoteSessionSearchOutcome {
        let initialSources = liveSources()
        guard let resumable = await loadResumableEntries(
            includeResumable: includeResumable,
            projects: projects(),
            selectedProjectId: selectedProjectId(),
            inMemoryIds: inMemoryActiveCopilotIds(),
            liveSessionIds: initialSources.map(\.sessionId),
            markerDirectory: markerDirectory,
            defaultStartupDir: defaultStartupDir
        ), !Task.isCancelled else {
            return .failed(Self.cancelledMessage)
        }
        guard let found = await index.instantMatches(
            for: query,
            in: initialSources,
            additionalEntries: resumable,
            limit: RemoteSessionSearchContract.maximumMatches
        ), !Task.isCancelled else {
            return .failed(Self.cancelledMessage)
        }
        let liveProjects = Self.projectIds(liveSources())
        let validProjectIds = Set(projects().map(\.id)).union(liveProjects.values)
        let activeCopilotIds = inMemoryActiveCopilotIds()
        let matches = found.compactMap { match in
            Self.makeMatch(
                for: match.entry,
                liveProjects: liveProjects,
                validProjectIds: validProjectIds,
                activeCopilotIds: activeCopilotIds,
                snippet: match.snippet
            )
        }
        return .results(RemoteSessionSearchResponse(mode: .instant, matches: matches))
    }

    private func luna(
        _ query: String,
        includeResumable: Bool,
        liveSources: () -> [SessionFinderSource],
        projects: () -> [SessionFinderProjectTarget],
        selectedProjectId: () -> String?,
        inMemoryActiveCopilotIds: () -> Set<String>,
        markerDirectory: URL,
        defaultStartupDir: String
    ) async -> RemoteSessionSearchOutcome {
        guard activeLunaRuns < Self.maximumConcurrentLunaRuns else { return .busy }
        activeLunaRuns += 1
        defer { activeLunaRuns -= 1 }
        let initialSources = liveSources()
        guard let liveEntries = await index.entries(for: initialSources),
              let resumable = await loadResumableEntries(
                  includeResumable: includeResumable,
                  projects: projects(),
                  selectedProjectId: selectedProjectId(),
                  inMemoryIds: inMemoryActiveCopilotIds(),
                  liveSessionIds: initialSources.map(\.sessionId),
                  markerDirectory: markerDirectory,
                  defaultStartupDir: defaultStartupDir
              ),
              !Task.isCancelled else {
            return .failed(Self.cancelledMessage)
        }
        let entries = liveEntries + resumable
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
        let liveProjects = Self.projectIds(liveSources())
        let validProjectIds = Set(projects().map(\.id)).union(liveProjects.values)
        return .results(RemoteSessionSearchResponse(
            mode: .luna,
            matches: Self.rankedMatches(
                from: picks,
                entries: entries,
                liveProjects: liveProjects,
                validProjectIds: validProjectIds,
                activeCopilotIds: inMemoryActiveCopilotIds()
            )
        ))
    }

    private func history(
        _ query: String,
        excludedCopilotSessionIds: [String],
        liveSources: () -> [SessionFinderSource],
        projects: () -> [SessionFinderProjectTarget],
        selectedProjectId: () -> String?,
        inMemoryActiveCopilotIds: () -> Set<String>,
        markerDirectory: URL,
        defaultStartupDir: String
    ) async -> RemoteSessionSearchOutcome {
        guard let historySearcher else { return .unsupported }
        guard activeLunaRuns < Self.maximumConcurrentLunaRuns else { return .busy }
        activeLunaRuns += 1
        defer { activeLunaRuns -= 1 }

        let liveSessionIds = liveSources().map(\.sessionId)
        let inMemoryIds = inMemoryActiveCopilotIds()
        let markerTask = Task.detached(priority: .userInitiated) {
            AppModel.validatedMarkerCopilotSessionIds(sessionIds: liveSessionIds, directory: markerDirectory)
        }
        let markerIds = await withTaskCancellationHandler {
            await markerTask.value
        } onCancel: {
            markerTask.cancel()
        }
        guard !Task.isCancelled else { return .failed(Self.cancelledMessage) }

        let clientExcluded = Set(
            excludedCopilotSessionIds
                .prefix(RemoteSessionSearchContract.maximumExcludedSessionIds)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter(CopilotSessionStore.isValidSessionId)
        )
        let excluded = inMemoryIds.union(markerIds).union(clientExcluded)

        let picks: [LunaMatch]
        do {
            picks = try await historySearcher.searchHistory(
                query: SessionFinderSearch.collapseWhitespace(query),
                excludedCopilotSessionIds: excluded
            )
        } catch {
            if Task.isCancelled || error is CancellationError { return .failed(Self.cancelledMessage) }
            return .failed((error as? LunaSearchError)?.message ?? error.localizedDescription)
        }
        guard !Task.isCancelled else { return .failed(Self.cancelledMessage) }

        let candidateIds: [String] = picks.compactMap { pick in
            guard pick.sessionId.hasPrefix("resumable:") else { return nil }
            return String(pick.sessionId.dropFirst("resumable:".count))
        }
        guard let loadedEntries = await loadResumableEntries(
            candidateIds: candidateIds,
            projects: projects(),
            selectedProjectId: selectedProjectId(),
            inMemoryIds: inMemoryActiveCopilotIds(),
            liveSessionIds: liveSources().map(\.sessionId),
            markerDirectory: markerDirectory,
            defaultStartupDir: defaultStartupDir
        ), !Task.isCancelled else {
            return .failed(Self.cancelledMessage)
        }

        let liveProjects = Self.projectIds(liveSources())
        let validProjectIds = Set(projects().map(\.id)).union(liveProjects.values)
        return .results(RemoteSessionSearchResponse(
            mode: .history,
            matches: Self.rankedMatches(
                from: picks,
                entries: loadedEntries,
                liveProjects: liveProjects,
                validProjectIds: validProjectIds,
                activeCopilotIds: inMemoryActiveCopilotIds()
            )
        ))
    }

    private func recent(
        includeResumable: Bool,
        liveSources: () -> [SessionFinderSource],
        projects: () -> [SessionFinderProjectTarget],
        selectedProjectId: () -> String?,
        inMemoryActiveCopilotIds: () -> Set<String>,
        markerDirectory: URL,
        defaultStartupDir: String
    ) async -> RemoteSessionSearchOutcome {
        let initialSources = liveSources()
        guard let ordered = await index.recent(initialSources),
              let resumable = await loadResumableEntries(
                  includeResumable: includeResumable,
                  projects: projects(),
                  selectedProjectId: selectedProjectId(),
                  inMemoryIds: inMemoryActiveCopilotIds(),
                  liveSessionIds: initialSources.map(\.sessionId),
                  markerDirectory: markerDirectory,
                  defaultStartupDir: defaultStartupDir
              ),
              !Task.isCancelled else {
            return .failed(Self.cancelledMessage)
        }
        let liveProjects = Self.projectIds(liveSources())
        let validProjectIds = Set(projects().map(\.id)).union(liveProjects.values)
        let activeCopilotIds = inMemoryActiveCopilotIds()
        let liveMatches = ordered.compactMap { entry in
            liveProjects[entry.id].map {
                RemoteSessionSearchMatch(sessionId: entry.id, projectId: $0, lastActivityAt: entry.lastActivity)
            }
        }
        let endedMatches = SessionFinderSearch.recent(resumable)
            .prefix(SessionFinderModel.maximumRecentEndedRows)
            .compactMap { entry in
                Self.makeMatch(
                    for: entry,
                    liveProjects: liveProjects,
                    validProjectIds: validProjectIds,
                    activeCopilotIds: activeCopilotIds
                )
            }
        let combined = Array((liveMatches + endedMatches).prefix(RemoteSessionSearchContract.maximumMatches))
        return .results(RemoteSessionSearchResponse(mode: .recent, matches: combined))
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
        await remoteSessionSearch.search(
            request,
            liveSources: { sessionSearchSources },
            projects: { sessionFinderProjectTargets },
            selectedProjectId: { selectedProjectId },
            inMemoryActiveCopilotIds: { inMemoryActiveCopilotSessionIds() },
            markerDirectory: resumeMarkerDirectory,
            defaultStartupDir: Paths.defaultStartupDir
        )
    }
}
