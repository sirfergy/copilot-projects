import AppKit
import Combine
import SwiftUI
import CopilotProjectsCore

/// Open pull requests for the Pull Requests window, refreshed while it is open.
@MainActor
final class PullRequestsModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case loading
        case loaded
        case failed(PullRequestFetchError)
    }

    static let ownersKey = "pullRequests.owners"
    static let refreshInterval: TimeInterval = 300
    /// Data younger than this is fresh enough to show when the window reopens.
    static let reopenFreshness: TimeInterval = 60

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
    /// Comma- or space-separated GitHub owners. Only pull requests they own are
    /// shown; empty means every owner.
    @Published var owners: String {
        didSet { defaults.set(owners, forKey: Self.ownersKey) }
    }

    private weak var appModel: AppModel?
    private let defaults: UserDefaults
    private let service: PullRequestService
    private let index: PullRequestTranscriptIndex
    private let overridesURL: URL?
    private let loadAccounts: @Sendable () async throws -> [GitHubAccount]
    private let copilotSessionId: (String) -> String?
    private let sessionSource: () -> [String: PullRequestSessionRef]
    private let projectSource: () -> [(id: String, name: String)]
    private var refreshTask: Task<Void, Never>?
    /// A refresh asked for while one runs, for example after changing owners.
    private var refreshAgain = false
    /// When the last refresh started, successful or not.
    private var lastAttempt: Date?
    private var workspaceChanges: AnyCancellable?

    init(
        appModel: AppModel?,
        defaults: UserDefaults = .standard,
        stateDirectory: URL? = Paths.stateDir.appendingPathComponent("pull-requests", isDirectory: true),
        service: PullRequestService = PullRequestService(),
        loadAccounts: @escaping @Sendable () async throws -> [GitHubAccount] = PullRequestsModel.signedInAccounts,
        copilotSessionId: @escaping (String) -> String? = PullRequestsModel.copilotSessionId(forSession:),
        sessions: (() -> [String: PullRequestSessionRef])? = nil,
        projects: (() -> [(id: String, name: String)])? = nil
    ) {
        self.appModel = appModel
        self.defaults = defaults
        self.service = service
        self.loadAccounts = loadAccounts
        self.copilotSessionId = copilotSessionId
        sessionSource = sessions ?? { [weak appModel] in Self.sessions(in: appModel?.projects ?? []) }
        projectSource = projects ?? { [weak appModel] in (appModel?.projects ?? []).map { ($0.id, $0.name) } }
        owners = defaults.string(forKey: Self.ownersKey) ?? ""
        index = PullRequestTranscriptIndex(storeURL: stateDirectory?.appendingPathComponent("transcript-index.json"))
        overridesURL = stateDirectory?.appendingPathComponent("goals.json")
        overrides = overridesURL
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode(PullRequestGoalOverrides.self, from: $0) }
            ?? PullRequestGoalOverrides()
        // Session states (waiting, running) change the lanes between fetches.
        workspaceChanges = appModel?.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    nonisolated static func signedInAccounts() async throws -> [GitHubAccount] {
        guard let gh = GitHubCLI.executable() else { throw PullRequestFetchError.cliUnavailable }
        let accounts = try await GitHubCLI.accounts(executable: gh)
        guard !accounts.isEmpty else { throw PullRequestFetchError.notSignedIn }
        return accounts
    }

    nonisolated static func copilotSessionId(forSession sessionId: String) -> String? {
        let path = Paths.copilotSessionMarkerPath(sessionId: sessionId)
        return (try? String(contentsOfFile: path, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static func ownerList(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.split(whereSeparator: { $0 == "," || $0.isWhitespace })
            .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "@")) }
            .filter { PullRequestService.isValidOwner($0) && seen.insert($0.lowercased()).inserted }
    }

    var ownerList: [String] { Self.ownerList(owners) }

    static func sessions(in projects: [Project]) -> [String: PullRequestSessionRef] {
        var sessions: [String: PullRequestSessionRef] = [:]
        for project in projects {
            for session in project.sessions {
                sessions[session.id] = PullRequestSessionRef(
                    session: session, projectId: project.id, projectName: project.name
                )
            }
        }
        return sessions
    }

    var liveSessions: [String: PullRequestSessionRef] { sessionSource() }

    var projects: [(id: String, name: String)] { projectSource() }

    /// The project new sessions land in unless the user picks another.
    var defaultProjectId: String? { appModel?.selectedProjectId ?? projects.first?.id }

    func goals(now: Date = Date()) -> [PullRequestGoal] {
        PullRequestGrouping.goals(
            pullRequests: pullRequests, links: links, sessions: liveSessions,
            overrides: overrides, now: now, sessionsKnown: sessionsMatched
        )
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
                pullRequests = fetch.pullRequests
                phase = .loaded
            }

            let sources = transcriptSources()
            let branches = Set(fetch.pullRequests.map(\.headRefName).filter(PullRequestLinker.isDistinctiveBranch))
            let evidence = await index.evidence(for: sources, branches: branches)
            let newLinks = PullRequestLinker.links(pullRequests: fetch.pullRequests, evidence: evidence)
            if firstLoad {
                pullRequests = fetch.pullRequests
                links = newLinks
                sessionsMatched = true
            }

            let enriched = await service.enrich(fetch.pullRequests, tokens: fetch.tokens)
            apply(enriched, links: newLinks, animated: !firstLoad)
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
        liveSessions.keys.sorted().compactMap { sessionId in
            guard let copilotId = copilotSessionId(sessionId),
                  let path = PullRequestTranscriptIndex.transcriptPath(copilotSessionId: copilotId) else { return nil }
            return PullRequestTranscriptIndex.Source(sessionId: sessionId, path: path)
        }
    }

    // MARK: Actions

    func goToSession(_ session: PullRequestSessionRef) {
        appModel?.focus(projectId: session.projectId, sessionId: session.sessionId)
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

    /// Starts a Copilot session for a goal no session is working on, and links
    /// the goal's pull requests to it.
    func startSession(for goal: PullRequestGoal, projectId: String) {
        guard let appModel else { return }
        do {
            let sessionId = try appModel.addCopilotSession(
                toProjectId: projectId, initialPrompt: Self.startingPrompt(for: goal.items.map(\.pr))
            )
            let live = Set(liveSessions.keys)
            overrides.sessionLinks = overrides.sessionLinks.filter { live.contains($0.value) }
            for item in goal.items { overrides.sessionLinks[item.pr.key.description] = sessionId }
            saveOverrides()
            appModel.focus(projectId: projectId, sessionId: sessionId)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could Not Start Copilot"
            alert.informativeText = error.localizedDescription
            alert.runModal()
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
