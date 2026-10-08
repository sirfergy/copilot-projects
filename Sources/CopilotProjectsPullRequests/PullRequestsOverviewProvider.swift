import Foundation
import CopilotProjectsCore
import CopilotProjectsProtocol

/// The helper's PR engine, hosted without windows, actions, timers, or goal writes.
@MainActor
public final class PullRequestsOverviewProvider {
    private let model: PullRequestsModel
    private let workspace: @MainActor () -> WorkspaceSnapshot?
    private let clock: @MainActor () -> Date
    private var sessionsKnown: Bool { model.lastUpdated != nil && model.sessionsKnown }

    public convenience init(
        cacheDirectory: URL, readOnlyGoalsURL: URL, defaults: UserDefaults = .standard,
        workspace: @escaping @MainActor @Sendable () -> WorkspaceSnapshot?
    ) {
        self.init(
            model: PullRequestsModel(
                workspace: ReadOnlyWorkspace(snapshot: workspace), defaults: defaults,
                stateDirectory: cacheDirectory, hostedReadOnly: true, readOnlyGoalsURL: readOnlyGoalsURL,
                isVisible: { false }, presentError: { _, _ in }
            ),
            workspace: workspace
        )
    }

    init(
        model: PullRequestsModel, workspace: @escaping @MainActor () -> WorkspaceSnapshot?,
        clock: @escaping @MainActor () -> Date = Date.init
    ) {
        self.model = model
        self.workspace = workspace
        self.clock = clock
    }

    /// Returns immediately; only GitHub and transcript work runs in background.
    /// Every call groups cached facts against the actual current workspace.
    public func snapshot(refresh: Bool = false) -> RemotePullRequestsOverview {
        model.reloadHostedSettings()
        model.apply(workspace().map(WorkspaceFetch.snapshot) ?? .unreachable)
        model.refreshHosted(manual: refresh)
        model.rematchHostedSessions()
        let goals = model.goals(now: clock()).map { goal in
            RemotePullRequestGoal(
                id: goal.id, name: goal.name, kind: String(describing: goal.kind),
                session: goal.session.map(Self.session),
                resumable: goal.resumable.map { candidate in
                    RemotePullRequestPreviousSession(
                        copilotSessionId: candidate.copilotSessionId, name: candidate.name,
                        lastActiveAtMilliseconds: Self.milliseconds(candidate.lastActive),
                        pullRequestKeys: goal.items.compactMap { item in
                            model.resumable[item.pr.key]?.copilotSessionId.lowercased()
                                == candidate.copilotSessionId.lowercased() ? item.pr.key.description : nil
                        }.sorted()
                    )
                },
                items: goal.items.map { item in
                    RemotePullRequestItem(
                        id: item.pr.key.description, repository: item.pr.repository,
                        number: item.pr.key.number, title: item.pr.title,
                        url: "https://github.com/\(item.pr.key.owner)/\(item.pr.key.repo)/pull/\(item.pr.key.number)",
                        stage: item.assessment.stage.title.lowercased(), status: item.assessment.status,
                        reasons: item.assessment.reasons.map {
                            RemotePullRequestReason(kind: Self.reasonKind($0), label: $0.label,
                                                    symbol: $0.symbol, isNudge: $0.isNudge)
                        },
                        needsYou: item.assessment.needsYou,
                        isPartial: PullRequestsPresentation.hasPartialStatus(item.pr),
                        updatedAtMilliseconds: Self.milliseconds(item.pr.updatedAt),
                        session: item.session.map(Self.session)
                    )
                }
            )
        }
        let phase: String
        var warnings = [model.overridesWarning, model.warning].compactMap { $0 }
        switch model.phase {
        case .idle, .loading: phase = "loading"
        case .loaded: phase = "loaded"
        case .failed(let error):
            phase = "failed"
            warnings.append(error.message)
        }
        return RemotePullRequestsOverview(
            phase: phase, updatedAtMilliseconds: model.lastUpdated.map(Self.milliseconds),
            isRefreshing: model.isRefreshing, sessionsKnown: sessionsKnown, owners: model.ownerList,
            warning: warnings.isEmpty ? nil : warnings.joined(separator: " "), omitted: model.omitted,
            openCount: goals.reduce(0) { $0 + $1.items.count },
            needsYouCount: goals.reduce(0) { $0 + $1.needsYouCount }, goals: goals
        )
    }

    /// Synchronous with the host's append/launch gate. Manual goal membership
    /// alone never verifies that a previous Copilot session worked on a PR.
    public func validate(
        _ request: RemotePullRequestSessionRequest, workspace: WorkspaceSnapshot,
        existingSessionId: String? = nil
    ) -> RemotePullRequestSessionOutcome? {
        guard let request = request.normalized() else { return .invalid("Invalid pull request session request.") }
        model.reloadHostedSettings()
        model.apply(.snapshot(workspace))
        let keys = Set(request.pullRequestKeys)
        let inScope = keys.isSubset(of: Set(model.pullRequests.map(\.key.description)))
        guard inScope || (request.kind == "resume" && existingSessionId != nil) else {
            return .stale("Refresh pull requests; some requested pull requests are no longer in scope.")
        }
        let items = model.goals(now: clock()).flatMap(\.items)
        if request.kind == "start" {
            let liveKeys = Set(model.liveSessions.values.flatMap(\.pullRequestKeys))
            guard keys.isDisjoint(with: liveKeys),
                  !items.contains(where: { keys.contains($0.pr.key.description) && $0.session != nil }) else {
                return .conflict
            }
            model.rematchHostedSessions()
            guard sessionsKnown else { return .stale("Wait until pull request status and workspace sessions are ready.") }
        } else {
            let verified = keys.allSatisfy { key in
                guard let key = PullRequestKey(key) else { return false }
                if model.resumable[key]?.copilotSessionId.lowercased() == request.copilotSessionId { return true }
                guard let id = existingSessionId, let tab = model.liveSessions[id] else { return false }
                return tab.pullRequestKeys.contains(key.description) || model.links[key] == id
            }
            guard verified else {
                return .stale("These pull requests have not been verified for that previous session.")
            }
        }
        return nil
    }

    public static func startingPrompt(for keys: [String]) -> String? {
        let urls = keys.compactMap(RemotePullRequestsContract.pullRequestURL)
        guard !urls.isEmpty, urls.count == keys.count else { return nil }
        return PullRequestsModel.startingPrompt(urls: urls)
    }

    private static func milliseconds(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 * 1_000) }

    private static func session(_ value: PullRequestSession) -> RemotePullRequestSession {
        RemotePullRequestSession(id: value.id, projectId: value.projectId, projectName: value.projectName,
                                 title: value.title,
                                 status: value.status == .idle && value.finishedUnseen ? "finished" : value.status?.rawValue)
    }

    private static func reasonKind(_ reason: PullRequestAttention) -> String {
        switch reason {
        case .sessionWaiting: return "sessionWaiting"
        case .conflicts: return "conflicts"
        case .failingRequiredChecks: return "failingRequiredChecks"
        case .failingChecks: return "failingChecks"
        case .changesRequested: return "changesRequested"
        case .unresolvedThreads: return "unresolvedThreads"
        case .readyToMerge: return "readyToMerge"
        case .behindBase: return "behindBase"
        case .noSession: return "noSession"
        case .stale: return "stale"
        }
    }
}

private struct ReadOnlyWorkspace: PullRequestsWorkspace {
    let read: @MainActor @Sendable () -> WorkspaceSnapshot?

    init(snapshot: @escaping @MainActor @Sendable () -> WorkspaceSnapshot?) { read = snapshot }

    func snapshot() async -> WorkspaceFetch {
        await read().map(WorkspaceFetch.snapshot) ?? .unreachable
    }

    func revealSession(projectId: String?, sessionId: String) async -> WorkspaceCommandResult {
        .refused(code: "unsupported", message: "Read-only workspace.")
    }

    func startCopilotSession(projectId: String, requestId: UUID, prompt: String) async -> WorkspaceCommandResult {
        .refused(code: "unsupported", message: "Read-only workspace.")
    }

    func resumeCopilotSession(projectId: String, requestId: UUID, copilotSessionId: String) async -> WorkspaceCommandResult {
        .refused(code: "unsupported", message: "Read-only workspace.")
    }
}
