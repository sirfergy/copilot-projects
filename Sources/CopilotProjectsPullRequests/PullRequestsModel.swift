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

    @Published private(set) var pullRequests: [PullRequestSnapshot] = []
    @Published private(set) var links: [PullRequestKey: String] = [:]
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var isRefreshing = false
    /// Whether transcripts have been matched to pull requests yet.
    @Published private(set) var sessionsMatched = false
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var warning: String?
    @Published private(set) var omitted = 0
    @Published private(set) var overrides: PullRequestGoalOverrides
    @Published private(set) var workspace: WorkspaceState = .connecting
    /// Goals whose Start Session request is on its way to Copilot Projects.
    @Published private(set) var startingGoals: Set<String> = []
    /// Comma- or space-separated GitHub owners. Only pull requests they own are
    /// shown; empty means every owner.
    @Published var owners: String {
        didSet {
            defaults.set(owners, forKey: Self.ownersKey)
            pullRequests = Self.inScope(pullRequests, owners: ownerList)
        }
    }

    /// Why Owners can't be shared with Copilot Projects, when it can't.
    let settingsNote: String?
    /// Why this copy saves nothing, when it can't.
    let storageNote: String?

    private let defaults: UserDefaults
    private let service: PullRequestService
    private let index: PullRequestTranscriptIndex
    private let overridesURL: URL?
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

    private struct PendingStart {
        let requestId: UUID
        let projectId: String
        let prompt: String
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
        owners = defaults.string(forKey: Self.ownersKey) ?? ""
        index = PullRequestTranscriptIndex(storeURL: stateDirectory?.appendingPathComponent("transcript-index.json"))
        overridesURL = stateDirectory?.appendingPathComponent("goals.json")
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
    var sessionsKnown: Bool { sessionsMatched && isConnected && !matchedWithoutSessions }

    func goals(now: Date = Date()) -> [PullRequestGoal] {
        PullRequestGrouping.goals(
            pullRequests: pullRequests, links: links, sessions: liveSessions,
            overrides: overrides, now: now, sessionsKnown: sessionsKnown
        )
    }

    /// Reads the workspace when the window opens, then every two seconds while
    /// it is visible. Each read finishes, or times out, before the next starts.
    func runWorkspaceLoop() async {
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

    private func apply(_ fetch: WorkspaceFetch) {
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
        // Copilot Projects came back after pull requests were matched without
        // its sessions: match them once more, not on every poll.
        // A refresh still running queues this one behind it.
        if !wasConnected, isConnected, matchedWithoutSessions { refresh() }
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
        host.open?()
    }

    // MARK: Refreshing

    /// Shows pull requests fetched elsewhere, as a completed refresh. Used by
    /// captures and tests, which must not reach GitHub.
    func show(_ prs: [PullRequestSnapshot], links: [PullRequestKey: String], updated: Date = Date()) {
        pullRequests = prs
        self.links = links
        sessionsMatched = true
        lastUpdated = updated
        lastAttempt = updated
        phase = .loaded
    }

    func refresh() {
        guard refreshTask == nil else {
            refreshAgain = true
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
        if lastAttempt.map({ Date().timeIntervalSince($0) >= Self.reopenFreshness }) ?? true { refresh() }
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard !Task.isCancelled else { break }
            if let lastAttempt, Date().timeIntervalSince(lastAttempt) >= Self.refreshInterval { refresh() }
        }
    }

    private func performRefresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        lastAttempt = Date()
        let firstLoad = lastUpdated == nil
        if pullRequests.isEmpty, !isFailed { phase = .loading }
        do {
            let accounts = try await loadAccounts()
            let owners = ownerList
            let fetch = try await service.search(accounts: accounts, owners: owners)
            if firstLoad {
                pullRequests = Self.inScope(fetch.pullRequests, owners: ownerList)
                phase = .loaded
            }

            await waitForFirstWorkspaceAnswer()
            let matchedLive = isConnected
            let newLinks: [PullRequestKey: String]
            if matchedLive || lastGoodSnapshot != nil {
                let sources = transcriptSources()
                let branches = Set(fetch.pullRequests.map(\.headRefName).filter(PullRequestLinker.isDistinctiveBranch))
                let evidence = await index.evidence(for: sources, branches: branches)
                newLinks = PullRequestLinker.links(pullRequests: fetch.pullRequests, evidence: evidence)
            } else {
                // No sessions known yet: matching against none would empty the
                // on-disk index, and every session would be read from the start
                // again once Copilot Projects answers.
                newLinks = links
            }
            matchedWithoutSessions = !matchedLive
            if firstLoad {
                pullRequests = Self.inScope(fetch.pullRequests, owners: ownerList)
                links = newLinks
                sessionsMatched = true
            }

            let enriched = await service.enrich(fetch.pullRequests, tokens: fetch.tokens)
            // Owners may have changed while this ran; a later refresh fills in the rest.
            apply(Self.inScope(enriched, owners: ownerList), links: newLinks, animated: !firstLoad)
            omitted = fetch.omitted
            warning = fetch.warnings.first
            lastUpdated = Date()
            phase = .loaded
        } catch {
            let failure = (error as? PullRequestFetchError) ?? .failed(error.localizedDescription)
            if pullRequests.isEmpty {
                phase = .failed(failure)
            } else {
                warning = failure.message
            }
        }
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
        if animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            withAnimation(.easeOut(duration: 0.2), update)
        } else {
            update()
        }
    }

    private func transcriptSources() -> [PullRequestTranscriptIndex.Source] {
        liveSessions.values.sorted { $0.id < $1.id }.compactMap { session in
            guard let copilotId = session.copilotSessionId,
                  let path = PullRequestTranscriptIndex.transcriptPath(copilotSessionId: copilotId) else { return nil }
            return PullRequestTranscriptIndex.Source(sessionId: session.id, path: path)
        }
    }

    // MARK: Actions

    /// Brings Copilot Projects forward on the session. While it can't be
    /// reached, opens it instead.
    func goToSession(_ session: PullRequestSession) {
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
        NSWorkspace.shared.open(pr.url)
    }

    func copyLink(_ pr: PullRequestSnapshot) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(pr.url.absoluteString, forType: .string)
    }

    func move(_ key: PullRequestKey, toGoal goalId: String?) {
        overrides.assign(key, to: goalId)
        saveOverrides()
    }

    func moveToNewGoal(_ key: PullRequestKey, named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let goalId = "manual:\(UUID().uuidString)"
        overrides.names[goalId] = trimmed
        overrides.assign(key, to: goalId)
        saveOverrides()
    }

    nonisolated static func startingPrompt(for pullRequests: [PullRequestSnapshot]) -> String {
        let subject = pullRequests.count == 1 ? "this pull request" : "these pull requests"
        let list = pullRequests.map { "- \($0.url.absoluteString)" }.joined(separator: "\n")
        return """
        Help me move \(subject) forward:

        \(list)

        Check CI, unresolved review threads, and merge state, then tell me what needs to happen next.
        """
    }

    /// Starts a Copilot session for a goal no session is working on, links the
    /// goal's pull requests to it, and shows it in Copilot Projects.
    func startSession(for goal: PullRequestGoal, projectId: String) {
        guard isConnected, !startingGoals.contains(goal.id) else { return }
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

    private func saveOverrides() {
        guard let overridesURL, let data = try? JSONEncoder().encode(overrides) else { return }
        try? FileManager.default.createDirectory(
            at: overridesURL.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? data.write(to: overridesURL, options: [.atomic])
    }
}
