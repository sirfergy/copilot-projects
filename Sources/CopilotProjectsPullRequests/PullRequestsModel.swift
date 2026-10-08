import AppKit
import Combine
import SwiftUI
import CopilotProjectsCore

/// Open pull requests for the Pull Requests window, refreshed while it is open,
/// matched to the sessions Copilot Projects reports over its control socket.
@MainActor
final class PullRequestsModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case loading
        case loaded
        case failed(PullRequestFetchError)
    }

    nonisolated static let ownersKey = "pullRequests.owners"
    static let refreshInterval: TimeInterval = 300
    /// Data younger than this is fresh enough to show when the window reopens.
    static let reopenFreshness: TimeInterval = 60
    /// How often the workspace's sessions are read while the window is visible.
    static let workspacePollInterval: TimeInterval = 2
    /// How long Resume Session stays busy waiting for the resumed session to report itself.
    static let resumeSettleInterval: TimeInterval = 20
    /// The pause between searches for ended sessions while some are left unread.
    static let resumableSearchPause: TimeInterval = 0.25

    @Published private(set) var pullRequests: [PullRequestSnapshot] = []
    @Published private(set) var links: [PullRequestKey: String] = [:]
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var isRefreshing = false
    @Published private(set) var isMatchingSessions = false
    @Published private(set) var isSearchingPreviousSessions = false
    /// Whether transcripts have been matched to pull requests yet.
    @Published private(set) var sessionsMatched = false
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var warning: String?
    @Published private(set) var omitted = 0
    @Published private(set) var overrides: PullRequestGoalOverrides
    @Published private(set) var workspace: WorkspaceState = .connecting
    /// Goals whose Start Session request is on its way to Copilot Projects.
    @Published private(set) var startingGoals: Set<String> = []
    /// Ended Copilot sessions that worked on pull requests no live session drives.
    @Published private(set) var resumable: [PullRequestKey: ResumableSession] = [:]
    /// Copilot sessions being resumed, until the workspace shows them live.
    @Published private(set) var resumingSessions: Set<String> = []
    /// Comma- or space-separated GitHub owners. Only pull requests they own are
    /// shown; empty means every owner.
    @Published var owners: String {
        didSet {
            if !hostedReadOnly { defaults.set(owners, forKey: Self.ownersKey) }
            pullRequests = Self.inScope(pullRequests, owners: ownerList)
        }
    }

    /// Why Owners can't be shared with Copilot Projects, when it can't.
    let settingsNote: String?
    /// Why this copy saves nothing, when it can't.
    let storageNote: String?

    private let defaults: UserDefaults
    private let service: PullRequestService
    private let index: any PullRequestTranscriptReading
    private let resumableFinder: any ResumableSessionSearching
    private let overridesURL: URL?
    private let hostedReadOnly: Bool
    private let transcriptPath: @Sendable (String) -> String?
    private let clock: @MainActor () -> Date
    private var scopeGeneration = 0
    private var hostedRelink: Task<Void, Never>?
    private var matchedWorkspace: [String]?
    private(set) var overridesWarning: String?
    private let loadAccounts: @Sendable () async throws -> [GitHubAccount]
    private let source: any PullRequestsWorkspace
    private let host: PullRequestsHostApp
    private let isVisible: @MainActor () -> Bool
    private let presentError: @MainActor (_ title: String, _ message: String) -> Void
    private var refreshTask: Task<Void, Never>?
    /// A refresh asked for while one runs, for example after changing owners.
    private var refreshAgain = false
    /// When the last refresh started, successful or not.
    private var lastAttempt: Date?
    /// The last snapshot Copilot Projects sent, kept to group lanes while it's away.
    private var lastGoodSnapshot: WorkspaceSnapshot?
    private var workspacePollInFlight = false
    /// The last refresh matched transcripts without live sessions, so the next
    /// snapshot matches them again.
    private var matchedWithoutSessions = false
    /// Start Session requests that didn't get an answer, by goal, so trying again
    /// reuses the request id and never starts a second session.
    private var pendingStarts: [String: PendingStart] = [:]
    /// Resume Session requests that didn't get an answer, by Copilot session.
    private var pendingResumes: [String: PendingResume] = [:]
    /// Resumed sessions not yet live in the workspace, and when to stop waiting.
    private var resumeDeadlines: [String: Date] = [:]
    /// The search for ended sessions, which keeps going while the byte budget
    /// leaves candidates unread. At most one runs; each refresh replaces it.
    private var resumableSearch: Task<Void, Never>?
    private var resumableSearchGeneration = UUID()
    /// Ended sessions seen live again in a tab, lowercased, whose pull requests
    /// were matched once more to link them there.
    private var relinkedSessions: Set<String> = []

    private struct PendingStart {
        let requestId: UUID
        let projectId: String
        let prompt: String
    }

    private struct PendingResume {
        let requestId: UUID
        let projectId: String
    }

    init(
        workspace: any PullRequestsWorkspace,
        host: PullRequestsHostApp = .none,
        defaults: UserDefaults = .standard,
        settingsNote: String? = nil,
        storageNote: String? = nil,
        stateDirectory: URL? = Paths.pullRequestsStateDir,
        service: PullRequestService = PullRequestService(),
        loadAccounts: @escaping @Sendable () async throws -> [GitHubAccount] = { try await PullRequestsModel.signedInAccounts() },
        resumableFinder: (any ResumableSessionSearching)? = nil,
        transcriptIndex: (any PullRequestTranscriptReading)? = nil,
        hostedReadOnly: Bool = false,
        readOnlyGoalsURL: URL? = nil,
        transcriptPath: @escaping @Sendable (String) -> String? = {
            PullRequestTranscriptIndex.transcriptPath(copilotSessionId: $0)
        },
        clock: @escaping @MainActor () -> Date = Date.init,
        isVisible: @escaping @MainActor () -> Bool = { NSApp?.occlusionState.contains(.visible) ?? true },
        presentError: @escaping @MainActor (_ title: String, _ message: String) -> Void = PullRequestsModel.presentAlert
    ) {
        source = workspace
        self.host = host
        self.defaults = defaults
        self.settingsNote = settingsNote
        self.storageNote = storageNote
        self.service = service
        self.loadAccounts = loadAccounts
        self.isVisible = isVisible
        self.presentError = presentError
        self.hostedReadOnly = hostedReadOnly
        self.transcriptPath = transcriptPath
        self.clock = clock
        owners = defaults.string(forKey: Self.ownersKey) ?? ""
        index = transcriptIndex
            ?? PullRequestTranscriptIndex(storeURL: stateDirectory?.appendingPathComponent("transcript-index.json"))
        self.resumableFinder = resumableFinder ?? ResumableSessionFinder(
            cacheURL: stateDirectory?.appendingPathComponent("resumable-index.json")
        )
        overridesURL = hostedReadOnly ? readOnlyGoalsURL : stateDirectory?.appendingPathComponent("goals.json")
        overrides = overridesURL
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode(PullRequestGoalOverrides.self, from: $0) }
            ?? PullRequestGoalOverrides()
    }

    static func presentAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    nonisolated static func signedInAccounts() async throws -> [GitHubAccount] {
        guard let gh = GitHubCLI.executable() else { throw PullRequestFetchError.cliUnavailable }
        let accounts = try await GitHubCLI.accounts(executable: gh)
        guard !accounts.isEmpty else { throw PullRequestFetchError.notSignedIn }
        return accounts
    }

    nonisolated static func ownerList(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.split(whereSeparator: { $0 == "," || $0.isWhitespace })
            .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "@")) }
            .filter { PullRequestService.isValidOwner($0) && seen.insert($0.lowercased()).inserted }
    }

    var ownerList: [String] { Self.ownerList(owners) }

    /// Only pull requests in `owners`, so rows from an earlier scope never
    /// linger while a refresh runs or after one fails.
    nonisolated static func inScope(_ prs: [PullRequestSnapshot], owners: [String]) -> [PullRequestSnapshot] {
        guard !owners.isEmpty else { return prs }
        let scope = Set(owners.map { $0.lowercased() })
        return prs.filter { scope.contains($0.key.owner) }
    }

    // MARK: Workspace

    var connectedSnapshot: WorkspaceSnapshot? {
        if case .connected(let snapshot) = workspace { return snapshot }
        return nil
    }

    var isConnected: Bool { connectedSnapshot != nil }

    /// Whether this copy can open Copilot Projects: it is bundled inside it.
    var canOpenHost: Bool { host.open != nil }

    /// Live sessions by id. While Copilot Projects is away, its last known
    /// sessions keep their goals, with their states unknown.
    var liveSessions: [String: PullRequestSession] {
        switch workspace {
        case .connected(let snapshot):
            return PullRequestSession.sessions(in: snapshot)
        case .disconnected(let lastGood?):
            return PullRequestSession.sessions(in: lastGood).mapValues(\.withUnknownState)
        case .connecting, .disconnected, .incompatibleHost:
            return [:]
        }
    }

    /// Whether `liveSessions` holds the sessions Copilot Projects reports now or
    /// last reported, rather than nothing because they're unknown.
    private var knowsSessions: Bool {
        switch workspace {
        case .connected, .disconnected(lastGood: _?): return true
        case .connecting, .disconnected, .incompatibleHost: return false
        }
    }

    /// Projects a session can start in; only while Copilot Projects answers.
    var projects: [(id: String, name: String)] {
        connectedSnapshot?.projects.map { ($0.id, $0.name) } ?? []
    }

    /// The project new sessions land in unless the user picks another.
    var defaultProjectId: String? {
        if let snapshot = connectedSnapshot, let selected = snapshot.selectedProjectId,
           snapshot.projects.contains(where: { $0.id == selected }) {
            return selected
        }
        return projects.first?.id
    }

    /// "No session" is only claimed when the sessions are current and were matched.
    var sessionsKnown: Bool {
        sessionsMatched && isConnected && !matchedWithoutSessions && !isMatchingSessions
            && (!hostedReadOnly || (lastUpdated != nil && matchedWorkspace == workspaceIdentity))
    }

    func goals(now: Date = Date()) -> [PullRequestGoal] {
        let sessions = liveSessions
        let (links, offered) = linkingResumed(links, sessions: sessions)
        return PullRequestGrouping.goals(
            pullRequests: pullRequests, links: links, sessions: sessions,
            overrides: overrides, now: now, sessionsKnown: sessionsKnown, resumable: offered
        )
    }

    /// `links`, plus each pull request whose ended session is live again in a
    /// tab, which drives it from there; and the ended sessions still to offer.
    private func linkingResumed(
        _ links: [PullRequestKey: String], sessions: [String: PullRequestSession]
    ) -> (links: [PullRequestKey: String], offered: [PullRequestKey: ResumableSession]) {
        guard !resumable.isEmpty else { return (links, [:]) }
        var links = links
        var offered: [PullRequestKey: ResumableSession] = [:]
        var tabs: [String: String] = [:]
        for session in sessions.values {
            if let copilotId = session.copilotSessionId?.lowercased() { tabs[copilotId] = session.id }
        }
        for (key, candidate) in resumable {
            if let tab = tabs[candidate.copilotSessionId.lowercased()] {
                if links[key].flatMap({ sessions[$0] }) == nil { links[key] = tab }
            } else {
                offered[key] = candidate
            }
        }
        return (links, offered)
    }

    /// Pull requests no live session works on, by link, goal, or shared branch.
    private func pullRequestsWithoutSession(
        _ prs: [PullRequestSnapshot], links: [PullRequestKey: String]
    ) -> [PullRequestSnapshot] {
        let sessions = liveSessions
        let goals = PullRequestGrouping.goals(
            pullRequests: prs, links: linkingResumed(links, sessions: sessions).links, sessions: sessions,
            overrides: overrides, now: Date()
        )
        let sessionless = Set(goals.filter { $0.session == nil }.flatMap(\.items).filter { $0.session == nil }.map(\.pr.key))
        return prs.filter { sessionless.contains($0.key) }
    }

    /// Reads the workspace when the window opens, then every two seconds while
    /// it is visible. Each read finishes, or times out, before the next starts.
    func runWorkspaceLoop() async {
        guard !hostedReadOnly else { return }
        await pollWorkspace()
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(Self.workspacePollInterval * 1_000_000_000))
            guard !Task.isCancelled else { break }
            if isVisible() { await pollWorkspace() }
        }
    }

    /// Reads the workspace now. A read already on its way finishes first, so
    /// reads never overlap and an action's follow-up always sees a fresh answer.
    func pollWorkspace() async {
        while workspacePollInFlight {
            guard !Task.isCancelled else { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        workspacePollInFlight = true
        defer { workspacePollInFlight = false }
        apply(await source.snapshot())
    }

    func apply(_ fetch: WorkspaceFetch) {
        let wasConnected = isConnected
        let state: WorkspaceState
        switch fetch {
        case .snapshot(let snapshot):
            lastGoodSnapshot = snapshot
            state = .connected(snapshot)
        case .unreachable:
            state = .disconnected(lastGood: lastGoodSnapshot)
        case .incompatibleHost:
            state = .incompatibleHost
        }
        if workspace != state { workspace = state }
        if hostedReadOnly, wasConnected, !isConnected { cancelResumableSearch() }
        var rematch = false
        if case .connected(let snapshot) = state {
            settleResumes(in: snapshot)
            rematch = resumedSessionsAppeared(in: snapshot)
        }
        // Copilot Projects came back after pull requests were matched without
        // its sessions: match them once more, not on every poll.
        // A refresh still running queues this one behind it.
        if !wasConnected, isConnected, matchedWithoutSessions { rematch = true }
        if rematch, !hostedReadOnly { refresh() }
    }

    /// Read helper-owned settings without becoming a second writer. A scope
    /// change invalidates even overlapping cached rows and any in-flight result.
    func reloadHostedSettings() {
        guard hostedReadOnly else { return }
        let sharedOwners = defaults.string(forKey: Self.ownersKey) ?? ""
        let changed = Self.ownerList(sharedOwners).map { $0.lowercased() }.sorted()
            != ownerList.map { $0.lowercased() }.sorted()
        owners = sharedOwners
        if changed {
            scopeGeneration += 1
            pullRequests = []
            links = [:]
            resumable = [:]
            sessionsMatched = false
            lastUpdated = nil
            lastAttempt = nil
            matchedWorkspace = nil
            phase = .idle
            warning = nil
            omitted = 0
            cancelResumableSearch()
            hostedRelink?.cancel()
        }
        guard let overridesURL else { return }
        do {
            let data = try Data(contentsOf: overridesURL)
            overrides = try JSONDecoder().decode(PullRequestGoalOverrides.self, from: data)
            overridesWarning = nil
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            overrides = PullRequestGoalOverrides()
            overridesWarning = nil
        } catch {
            overridesWarning = "Could not read saved pull request goals. Showing the last known goals."
        }
    }

    func refreshHosted(manual: Bool) {
        guard hostedReadOnly, refreshTask == nil,
              lastAttempt.map({ clock().timeIntervalSince($0) >= (manual ? 60 : Self.refreshInterval) }) ?? true
        else { return }
        hostedRelink?.cancel()
        lastAttempt = clock()
        isRefreshing = true
        if lastUpdated == nil { phase = .loading }
        refresh()
    }

    /// Workspace changes re-match local evidence, never schedule a GitHub fetch.
    private var workspaceIdentity: [String] {
        liveSessions.values.map { "\($0.id):\($0.copilotSessionId ?? "")" }.sorted()
    }

    func rematchHostedSessions() {
        guard hostedReadOnly, isConnected, lastUpdated != nil,
              refreshTask == nil, hostedRelink == nil else { return }
        let identity = workspaceIdentity
        guard identity != matchedWorkspace else { return }
        let generation = scopeGeneration
        let prs = pullRequests
        let sources = transcriptSources()
        isMatchingSessions = true
        hostedRelink = Task { [weak self] in
            guard let self else { return }
            defer {
                self.hostedRelink = nil
                if !self.isRefreshing { self.isMatchingSessions = false }
            }
            let evidence = await self.index.evidence(
                for: sources, branches: Set(prs.map(\.headRefName).filter(PullRequestLinker.isDistinctiveBranch))
            )
            guard !Task.isCancelled, generation == self.scopeGeneration else { return }
            self.links = PullRequestLinker.links(pullRequests: prs, evidence: evidence)
            self.sessionsMatched = true
            self.matchedWithoutSessions = false
            self.matchedWorkspace = identity
            self.searchResumable()
        }
    }

    /// Whether an ended session just came back live in a tab while one of its
    /// pull requests has no live link: matching transcripts again links them to
    /// it, since its event log still names them. Once per session while it stays live.
    private func resumedSessionsAppeared(in snapshot: WorkspaceSnapshot) -> Bool {
        let sessions = PullRequestSession.sessions(in: snapshot)
        let live = Set(sessions.values.compactMap { $0.copilotSessionId?.lowercased() })
        relinkedSessions.formIntersection(live)
        var appeared = false
        for (key, candidate) in resumable {
            let copilotId = candidate.copilotSessionId.lowercased()
            guard live.contains(copilotId), !relinkedSessions.contains(copilotId),
                  links[key].flatMap({ sessions[$0] }) == nil else { continue }
            relinkedSessions.insert(copilotId)
            appeared = true
        }
        return appeared
    }

    /// Before matching transcripts, find out whether Copilot Projects is there.
    private func waitForFirstWorkspaceAnswer() async {
        guard workspace == .connecting else { return }
        if !workspacePollInFlight {
            await pollWorkspace()
            return
        }
        for _ in 0..<50 where workspace == .connecting {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    func openHost() {
        guard !hostedReadOnly else { return }
        host.open?()
    }

    // MARK: Refreshing

    /// Shows pull requests fetched elsewhere, as a completed refresh. Used by
    /// captures and tests, which must not reach GitHub.
    func show(
        _ prs: [PullRequestSnapshot], links: [PullRequestKey: String],
        resumable: [PullRequestKey: ResumableSession] = [:], updated: Date = Date(),
        warning: String? = nil, sessionsMatched: Bool = true
    ) {
        pullRequests = prs
        self.links = links
        self.resumable = resumable
        self.sessionsMatched = sessionsMatched
        if hostedReadOnly, sessionsMatched { matchedWorkspace = workspaceIdentity }
        self.warning = warning
        lastUpdated = updated
        lastAttempt = clock()
        phase = .loaded
    }

    func refresh() {
        guard refreshTask == nil else {
            if !hostedReadOnly { refreshAgain = true }
            return
        }
        refreshTask = Task { [weak self] in
            await self?.performRefresh()
            guard let self else { return }
            self.refreshTask = nil
            if self.refreshAgain {
                self.refreshAgain = false
                self.refresh()
            }
        }
    }

    /// Refreshes while the window is open: on opening unless the last attempt is
    /// under a minute old, then every five minutes. Failures wait for the next
    /// interval too; Try Again and ⌘R retry at once.
    func runRefreshLoop() async {
        guard !hostedReadOnly else { return }
        if lastAttempt.map({ Date().timeIntervalSince($0) >= Self.reopenFreshness }) ?? true { refresh() }
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard !Task.isCancelled else { break }
            if let lastAttempt, Date().timeIntervalSince(lastAttempt) >= Self.refreshInterval { refresh() }
        }
    }

    private func performRefresh() async {
        isRefreshing = true
        isMatchingSessions = !sessionsKnown
        defer {
            isRefreshing = false
            isMatchingSessions = false
        }
        lastAttempt = clock()
        let generation = scopeGeneration
        let firstLoad = lastUpdated == nil
        if pullRequests.isEmpty, !isFailed { phase = .loading }
        do {
            let accounts = try await loadAccounts()
            guard generation == scopeGeneration, !Task.isCancelled else { return }
            let owners = ownerList
            let fetch = try await service.search(accounts: accounts, owners: owners)
            guard generation == scopeGeneration, !Task.isCancelled else { return }
            if firstLoad {
                pullRequests = Self.inScope(fetch.pullRequests, owners: ownerList).map {
                    var pr = $0
                    pr.isIncomplete = true
                    return pr
                }
                phase = .loaded
            }

            await waitForFirstWorkspaceAnswer()
            let matchedLive = isConnected
            let matchedIdentity = workspaceIdentity
            // Set before matching, so Copilot Projects answering while it runs
            // queues another refresh instead of being missed.
            matchedWithoutSessions = !matchedLive
            let newLinks: [PullRequestKey: String]
            if knowsSessions {
                let sources = transcriptSources()
                let branches = Set(fetch.pullRequests.map(\.headRefName).filter(PullRequestLinker.isDistinctiveBranch))
                let evidence = await index.evidence(for: sources, branches: branches)
                guard generation == scopeGeneration, !Task.isCancelled else { return }
                newLinks = PullRequestLinker.links(pullRequests: fetch.pullRequests, evidence: evidence)
            } else {
                // No sessions known: matching against none would empty the
                // on-disk index, and every session would be read from the start
                // again once Copilot Projects answers.
                newLinks = links
            }
            let fetchedKeys = Set(fetch.pullRequests.map(\.key))
            links = newLinks.merging(links.filter { !fetchedKeys.contains($0.key) }) { new, _ in new }
            sessionsMatched = true
            if hostedReadOnly, matchedLive { matchedWorkspace = matchedIdentity }
            isMatchingSessions = false

            let enriched = await service.enrich(fetch.pullRequests, tokens: fetch.tokens)
            guard generation == scopeGeneration, !Task.isCancelled else { return }
            // Owners may have changed while this ran; a later refresh fills in the rest.
            apply(Self.inScope(enriched, owners: ownerList), links: newLinks, animated: !firstLoad)
            omitted = fetch.omitted
            warning = fetch.warnings.first
            lastUpdated = clock()
            phase = .loaded
            // Ended sessions are looked for only against current live ones;
            // otherwise the last ones found stay.
            if matchedLive { searchResumable() }
        } catch {
            guard generation == scopeGeneration, !Task.isCancelled else { return }
            let failure = (error as? PullRequestFetchError) ?? .failed(error.localizedDescription)
            if pullRequests.isEmpty {
                phase = .failed(failure)
            } else {
                warning = failure.message
            }
        }
    }

    /// Searches for ended sessions in the background, replacing any search
    /// still running, and again while the byte budget leaves candidates unread.
    private func searchResumable() {
        cancelResumableSearch()
        guard isConnected else { return }
        let generation = resumableSearchGeneration
        isSearchingPreviousSessions = true
        resumableSearch = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.resumableSearchGeneration == generation {
                    self.isSearchingPreviousSessions = false
                    self.resumableSearch = nil
                }
            }
            while !Task.isCancelled {
                guard self.isConnected, self.resumableSearchGeneration == generation else { return }
                let needing = self.pullRequestsWithoutSession(self.pullRequests, links: self.links)
                let live = Set(self.liveSessions.values.compactMap(\.copilotSessionId))
                let search = await self.resumableFinder.search(for: needing, liveCopilotSessionIds: live)
                guard !Task.isCancelled, self.isConnected, self.resumableSearchGeneration == generation else { return }
                self.assignResumable(search.sessions)
                guard search.deferred else { return }
                try? await Task.sleep(nanoseconds: UInt64(Self.resumableSearchPause * 1_000_000_000))
            }
        }
    }

    private func cancelResumableSearch() {
        resumableSearchGeneration = UUID()
        resumableSearch?.cancel()
        resumableSearch = nil
        isSearchingPreviousSessions = false
    }

    /// Takes what a search found, keeping each session being resumed, and each
    /// one live again in a tab before its pull requests are linked to it there:
    /// the search skips those, as in use or as driven by that tab.
    private func assignResumable(_ found: [PullRequestKey: ResumableSession]) {
        let sessions = liveSessions
        let live = Set(sessions.values.compactMap { $0.copilotSessionId?.lowercased() })
        let resuming = Set(resumingSessions.map { $0.lowercased() } + resumeDeadlines.keys.map { $0.lowercased() })
        let kept = resumable.filter { key, candidate in
            let copilotId = candidate.copilotSessionId.lowercased()
            return resuming.contains(copilotId)
                || (live.contains(copilotId) && links[key].flatMap { sessions[$0] } == nil)
        }
        let scope = Set(pullRequests.map(\.key))
        resumable = found.merging(kept) { _, kept in kept }.filter { scope.contains($0.key) }
    }

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    private func apply(_ prs: [PullRequestSnapshot], links: [PullRequestKey: String], animated: Bool) {
        let update = {
            self.pullRequests = prs
            self.links = links
            self.sessionsMatched = true
        }
        // Under Reduce Motion lanes change in place rather than sliding.
        if animated, !hostedReadOnly, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            withAnimation(.easeOut(duration: 0.2), update)
        } else {
            update()
        }
    }

    private func transcriptSources() -> [PullRequestTranscriptIndex.Source] {
        liveSessions.values.sorted { $0.id < $1.id }.compactMap { session in
            guard let copilotId = session.copilotSessionId,
                  let path = transcriptPath(copilotId) else { return nil }
            return PullRequestTranscriptIndex.Source(sessionId: session.id, path: path)
        }
    }

    // MARK: Actions

    /// Brings Copilot Projects forward on the session. While it can't be
    /// reached, opens it instead.
    func goToSession(_ session: PullRequestSession) {
        guard !hostedReadOnly else { return }
        guard let snapshot = connectedSnapshot else {
            openHost()
            return
        }
        let pid = snapshot.hostProcessIdentifier
        Task { if await reveal(projectId: session.projectId, sessionId: session.id) { host.activate(pid) } }
    }

    /// Selects the session in Copilot Projects; true when it is now shown. Callers
    /// activate Copilot Projects only afterwards: becoming active marks whatever it
    /// shows as read, which must be this session and not the one it showed before.
    /// This app is still active a moment after the click, so it can still yield.
    private func reveal(projectId: String, sessionId: String) async -> Bool {
        switch await source.revealSession(projectId: projectId, sessionId: sessionId) {
        case .done:
            return true
        case .refused(code: "conflict", _):
            // It moved to another project since the last snapshot; show it there.
            await pollWorkspace()
            if let moved = liveSessions[sessionId], moved.projectId != projectId, isConnected,
               case .done = await source.revealSession(projectId: moved.projectId, sessionId: sessionId) {
                return true
            }
            return false
        case .refused, .unreachable, .incompatibleHost:
            // An ended session drops out of the next snapshot, and with it its button.
            await pollWorkspace()
            return false
        }
    }

    func openOnGitHub(_ pr: PullRequestSnapshot) {
        guard !hostedReadOnly else { return }
        NSWorkspace.shared.open(pr.url)
    }

    func copyLink(_ pr: PullRequestSnapshot) {
        guard !hostedReadOnly else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(pr.url.absoluteString, forType: .string)
    }

    func move(_ key: PullRequestKey, toGoal goalId: String?) {
        guard !hostedReadOnly else { return }
        overrides.assign(key, to: goalId)
        saveOverrides()
    }

    func moveToNewGoal(_ key: PullRequestKey, named name: String) {
        guard !hostedReadOnly else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let goalId = "manual:\(UUID().uuidString)"
        overrides.names[goalId] = trimmed
        overrides.assign(key, to: goalId)
        saveOverrides()
    }

    nonisolated static func startingPrompt(for pullRequests: [PullRequestSnapshot]) -> String {
        startingPrompt(urls: pullRequests.map(\.url.absoluteString))
    }

    nonisolated static func startingPrompt(urls: [String]) -> String {
        let subject = urls.count == 1 ? "this pull request" : "these pull requests"
        let list = urls.map { "- \($0)" }.joined(separator: "\n")
        return """
        Help me move \(subject) forward:

        \(list)

        Check CI, unresolved review threads, and merge state, then tell me what needs to happen next.
        """
    }

    /// Starts a Copilot session for a goal no session is working on, links the
    /// goal's pull requests to it, and shows it in Copilot Projects.
    func startSession(for goal: PullRequestGoal, projectId: String) {
        guard !hostedReadOnly, isConnected, !startingGoals.contains(goal.id) else { return }
        let prompt = Self.startingPrompt(for: goal.items.map(\.pr))
        let start = pendingStarts[goal.id].flatMap { $0.projectId == projectId && $0.prompt == prompt ? $0 : nil }
            ?? PendingStart(requestId: UUID(), projectId: projectId, prompt: prompt)
        pendingStarts[goal.id] = start
        startingGoals.insert(goal.id)
        let keys = goal.items.map(\.pr.key)
        Task {
            await performStart(start, goalId: goal.id, keys: keys)
            startingGoals.remove(goal.id)
        }
    }

    private func performStart(_ start: PendingStart, goalId: String, keys: [PullRequestKey]) async {
        var result = await source.startCopilotSession(
            projectId: start.projectId, requestId: start.requestId, prompt: start.prompt
        )
        if result == .unreachable {
            // The answer may have been lost after the session started; the same
            // request id returns that session instead of starting another.
            result = await source.startCopilotSession(
                projectId: start.projectId, requestId: start.requestId, prompt: start.prompt
            )
        }
        switch result {
        case .done(_, let sessionId?) where !sessionId.isEmpty:
            pendingStarts[goalId] = nil
            await pollWorkspace()
            if isConnected {
                let live = Set(liveSessions.keys).union([sessionId])
                overrides.sessionLinks = overrides.sessionLinks.filter { live.contains($0.value) }
            }
            for key in keys { overrides.sessionLinks[key.description] = sessionId }
            saveOverrides()
            let pid = connectedSnapshot?.hostProcessIdentifier
            if await reveal(projectId: start.projectId, sessionId: sessionId), let pid { host.activate(pid) }
        case .done:
            pendingStarts[goalId] = nil
            presentError("Could Not Start Copilot", "Copilot Projects didn’t say which session it started.")
        case .refused(let code, let message):
            // Copilot Projects couldn't save what it did; only the same request id
            // finds a session that did start.
            if code != "persistence-unavailable" { pendingStarts[goalId] = nil }
            await pollWorkspace()
            presentError("Could Not Start Copilot", message)
        case .unreachable:
            await pollWorkspace()
            presentError(
                "Could Not Start Copilot",
                "Copilot Projects isn’t answering. Try again; a session that did start won’t start twice."
            )
        case .incompatibleHost:
            pendingStarts[goalId] = nil
            await pollWorkspace()
            presentError("Could Not Start Copilot", "Update Copilot Projects to start sessions from here.")
        }
    }

    /// Opens an ended Copilot session in a new tab in `projectId`, in the folder
    /// it worked in, and shows it in Copilot Projects. Its pull requests follow
    /// it once the workspace reports it live.
    func resume(_ candidate: ResumableSession, projectId: String) {
        guard !hostedReadOnly else { return }
        let copilotId = candidate.copilotSessionId
        guard isConnected, !resumingSessions.contains(copilotId) else { return }
        let resume = pendingResumes[copilotId].flatMap { $0.projectId == projectId ? $0 : nil }
            ?? PendingResume(requestId: UUID(), projectId: projectId)
        pendingResumes[copilotId] = resume
        resumingSessions.insert(copilotId)
        Task { await performResume(resume, copilotSessionId: copilotId) }
    }

    private func performResume(_ resume: PendingResume, copilotSessionId copilotId: String) async {
        var result = await source.resumeCopilotSession(
            projectId: resume.projectId, requestId: resume.requestId, copilotSessionId: copilotId
        )
        if result == .unreachable {
            // The answer may have been lost after the session opened; the same
            // request id returns that tab instead of opening another.
            result = await source.resumeCopilotSession(
                projectId: resume.projectId, requestId: resume.requestId, copilotSessionId: copilotId
            )
        }
        let title = "Could Not Resume Session"
        switch result {
        case .done(_, let sessionId?) where !sessionId.isEmpty:
            pendingResumes[copilotId] = nil
            awaitLive(copilotId)
            await pollWorkspace()
            let pid = connectedSnapshot?.hostProcessIdentifier
            // A tab that already had it open may be in another project.
            let projectId = liveSessions[sessionId]?.projectId ?? resume.projectId
            if await reveal(projectId: projectId, sessionId: sessionId), let pid { host.activate(pid) }
        case .done:
            pendingResumes[copilotId] = nil
            resumingSessions.remove(copilotId)
            presentError(title, "Copilot Projects didn’t say which session it opened.")
        case .refused(let code, let message):
            // An unsaved resume keeps its request id, so trying again opens it once.
            if code != "persistence-unavailable" { pendingResumes[copilotId] = nil }
            resumingSessions.remove(copilotId)
            if let code, ["gone", "in-use", "invalid"].contains(code) {
                resumable = resumable.filter { $0.value.copilotSessionId != copilotId }
            }
            await pollWorkspace()
            presentError(title, message)
        case .unreachable:
            resumingSessions.remove(copilotId)
            await pollWorkspace()
            presentError(title, "Copilot Projects isn’t answering. Try again; a session that did resume won’t open twice.")
        case .incompatibleHost:
            pendingResumes[copilotId] = nil
            resumingSessions.remove(copilotId)
            await pollWorkspace()
            presentError(title, "Update Copilot Projects to resume sessions from here.")
        }
    }

    /// Keeps Resume Session busy until the workspace reports the session live,
    /// which happens once Copilot has resumed it, or for twenty seconds.
    private func awaitLive(_ copilotId: String) {
        let deadline = Date().addingTimeInterval(Self.resumeSettleInterval)
        resumeDeadlines[copilotId] = deadline
        if let snapshot = connectedSnapshot { settleResumes(in: snapshot) }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.resumeSettleInterval * 1_000_000_000))
            guard let self, self.resumeDeadlines[copilotId] == deadline else { return }
            self.resumeDeadlines[copilotId] = nil
            self.resumingSessions.remove(copilotId)
        }
    }

    private func settleResumes(in snapshot: WorkspaceSnapshot) {
        guard !resumeDeadlines.isEmpty else { return }
        let live = Set(snapshot.projects.flatMap(\.sessions).compactMap { $0.copilotSessionId?.lowercased() })
        for copilotId in resumeDeadlines.keys where live.contains(copilotId.lowercased()) {
            resumeDeadlines[copilotId] = nil
            resumingSessions.remove(copilotId)
        }
    }

    private func saveOverrides() {
        guard !hostedReadOnly, let overridesURL, let data = try? JSONEncoder().encode(overrides) else { return }
        try? FileManager.default.createDirectory(
            at: overridesURL.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? data.write(to: overridesURL, options: [.atomic])
    }
}
