import Foundation
import CopilotProjectsCore

/// `owner/repo#number`, lowercased: GitHub treats owner and repository names
/// case-insensitively, and transcripts spell them however the user typed them.
struct PullRequestKey: Hashable, Comparable, CustomStringConvertible, Sendable {
    let owner: String
    let repo: String
    let number: Int

    init(owner: String, repo: String, number: Int) {
        self.owner = owner.lowercased()
        self.repo = repo.lowercased()
        self.number = number
    }

    /// From a `owner/repo` name and a number.
    init?(repository: String, number: Int) {
        let parts = repository.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty, number > 0 else { return nil }
        self.init(owner: String(parts[0]), repo: String(parts[1]), number: number)
    }

    /// From its own `owner/repo#number` description.
    init?(_ text: String) {
        guard let hash = text.lastIndex(of: "#"), let number = Int(text[text.index(after: hash)...]) else {
            return nil
        }
        self.init(repository: String(text[..<hash]), number: number)
    }

    var repository: String { "\(owner)/\(repo)" }
    var description: String { "\(owner)/\(repo)#\(number)" }

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.owner, lhs.repo, lhs.number) < (rhs.owner, rhs.repo, rhs.number)
    }
}

/// One open pull request as GitHub last reported it.
struct PullRequestSnapshot: Identifiable, Equatable, Sendable {
    enum Mergeable: String, Sendable { case mergeable = "MERGEABLE", conflicting = "CONFLICTING", unknown = "UNKNOWN" }

    enum MergeState: String, Sendable {
        case behind = "BEHIND", blocked = "BLOCKED", clean = "CLEAN", dirty = "DIRTY"
        case draft = "DRAFT", hasHooks = "HAS_HOOKS", unknown = "UNKNOWN", unstable = "UNSTABLE"
    }

    enum ReviewDecision: String, Sendable {
        case approved = "APPROVED", changesRequested = "CHANGES_REQUESTED", reviewRequired = "REVIEW_REQUIRED"
    }

    enum CheckState: String, Sendable {
        case success = "SUCCESS", pending = "PENDING", expected = "EXPECTED", failure = "FAILURE", error = "ERROR"
    }

    let key: PullRequestKey
    let nodeId: String
    /// `owner/repo` as GitHub spells it.
    let repository: String
    let title: String
    let url: URL
    let author: String
    let isDraft: Bool
    let createdAt: Date
    let updatedAt: Date
    let headRefName: String
    var mergeable: Mergeable = .unknown
    var mergeState: MergeState = .unknown
    /// Part of what GitHub reported about it couldn't be read, so it is never called ready.
    var isIncomplete = false
    /// Nil when the base branch requires no review.
    let reviewDecision: ReviewDecision?
    /// The head commit's combined check and status state, nil when it has none.
    let checks: CheckState?
    /// Failing checks the base branch requires; nil until known.
    var failingRequiredChecks: [String]? = nil
    /// Open, current threads whose latest comment is someone else's.
    var unresolvedThreads: Int
    /// The part of `unresolvedThreads` that Copilot code review started.
    var unresolvedCopilotThreads: Int
    /// Where older review threads that went uncounted start; nil once all are counted.
    var uncountedThreadsCursor: String? = nil
    let inMergeQueue: Bool
    let autoMergeEnabled: Bool
    /// The base branch merges through a merge queue, which keeps branches current itself.
    var isMergeQueueEnabled = false
    /// Whether the account that read it can merge it (write access or more).
    var viewerCanMerge = true

    var id: PullRequestKey { key }

    /// `repo#number`; the owner is in the tooltip.
    var shortName: String { "\(repositoryName)#\(key.number)" }

    var repositoryName: String { repository.split(separator: "/").last.map(String.init) ?? repository }

    var checksFailing: Bool { checks == .failure || checks == .error }
    var checksRunning: Bool { checks == .pending || checks == .expected }
}

/// Where a pull request is in its life, left to right.
enum PullRequestStage: Int, CaseIterable, Identifiable, Comparable, Sendable {
    case draft, checks, review, ready

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .draft: return "Draft"
        case .checks: return "Checks"
        case .review: return "Review"
        case .ready: return "Ready"
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Why a pull request needs you, in the order you should deal with them.
enum PullRequestAttention: Hashable, Sendable {
    case sessionWaiting
    case conflicts
    case failingRequiredChecks(Int)
    /// Checks fail and which of them are required could not be read.
    case failingChecks
    case changesRequested
    case unresolvedThreads(Int, copilot: Int)
    case readyToMerge
    case behindBase
    case noSession
    case stale(days: Int)

    var priority: Int {
        switch self {
        case .sessionWaiting: return 0
        case .conflicts: return 1
        case .failingRequiredChecks: return 2
        case .failingChecks: return 3
        case .changesRequested: return 4
        case .unresolvedThreads: return 5
        case .readyToMerge: return 6
        case .behindBase: return 7
        case .noSession: return 8
        case .stale: return 9
        }
    }

    var label: String {
        switch self {
        case .sessionWaiting: return "Session needs your input"
        case .conflicts: return "Merge conflicts"
        case .failingRequiredChecks(let count):
            return count == 1 ? "1 required check failing" : "\(count) required checks failing"
        case .failingChecks: return "Checks failing"
        case .changesRequested: return "Changes requested"
        case .unresolvedThreads(let count, let copilot):
            let noun = count == 1 ? "thread" : "threads"
            return copilot == count ? "\(count) Copilot \(noun) open" : "\(count) unresolved \(noun)"
        case .readyToMerge: return "Ready to merge"
        case .behindBase: return "Behind its base branch"
        case .noSession: return "No session on it"
        case .stale(let days): return days == 1 ? "Quiet for a day" : "Quiet for \(days) days"
        }
    }

    /// For narrow lanes.
    var shortLabel: String {
        switch self {
        case .sessionWaiting: return "Needs input"
        case .conflicts: return "Conflicts"
        case .failingRequiredChecks, .failingChecks: return "Checks failing"
        case .changesRequested: return "Changes"
        case .unresolvedThreads(let count, _): return count == 1 ? "1 thread" : "\(count) threads"
        case .readyToMerge: return "Ready"
        case .behindBase: return "Behind"
        case .noSession: return "No session"
        case .stale(let days): return "Quiet \(days)d"
        }
    }

    var symbol: String {
        switch self {
        case .sessionWaiting: return "exclamationmark.bubble.fill"
        case .conflicts: return "arrow.triangle.merge"
        case .failingRequiredChecks, .failingChecks: return "xmark.octagon.fill"
        case .changesRequested: return "arrow.uturn.backward.circle.fill"
        case .unresolvedThreads: return "text.bubble.fill"
        case .readyToMerge: return "checkmark.circle.fill"
        case .behindBase: return "arrow.down.circle.fill"
        case .noSession: return "terminal"
        case .stale: return "moon.zzz"
        }
    }

    /// Worth knowing, but nothing is broken: the PR has no session, or has gone quiet.
    var isNudge: Bool {
        switch self {
        case .noSession, .stale: return true
        default: return false
        }
    }
}

/// What a pull request needs, and what it is waiting on otherwise.
struct PullRequestAssessment: Equatable, Sendable {
    let stage: PullRequestStage
    /// Most urgent first; empty when nothing needs you.
    let reasons: [PullRequestAttention]
    /// What the pull request is doing, for when nothing needs you.
    let status: String

    var primary: PullRequestAttention? { reasons.first }
    /// Any reason at all, nudges included: the user chose every one of them.
    var needsYou: Bool { !reasons.isEmpty }
    var needsAction: Bool { reasons.contains { !$0.isNudge } }
    var isNudgeOnly: Bool { !reasons.isEmpty && !needsAction }
    /// Lower is more urgent.
    var urgency: Int { primary?.priority ?? Int.max }
}

enum PullRequestTriage {
    static let staleInterval: TimeInterval = 3 * 86_400

    static func assess(
        _ pr: PullRequestSnapshot, session: PullRequestSession?, now: Date, sessionsKnown: Bool = true
    ) -> PullRequestAssessment {
        var reasons: [PullRequestAttention] = []
        if session?.status == .waiting { reasons.append(.sessionWaiting) }
        if pr.mergeable == .conflicting || pr.mergeState == .dirty { reasons.append(.conflicts) }
        if pr.checksFailing {
            if let required = pr.failingRequiredChecks {
                if !required.isEmpty { reasons.append(.failingRequiredChecks(required.count)) }
            } else {
                reasons.append(.failingChecks)
            }
        }
        if pr.reviewDecision == .changesRequested { reasons.append(.changesRequested) }
        if pr.unresolvedThreads > 0 {
            reasons.append(.unresolvedThreads(pr.unresolvedThreads, copilot: pr.unresolvedCopilotThreads))
        }
        let isMerging = pr.inMergeQueue || pr.autoMergeEnabled
        let blocked = reasons.contains { $0 != .sessionWaiting }
        if !blocked, !isMerging, isReady(pr) { reasons.append(.readyToMerge) }
        // Behind matters once only an update stands between you and merging;
        // a merge queue keeps branches current on its own.
        let reviewed = pr.reviewDecision == .approved || pr.reviewDecision == nil
        if pr.mergeState == .behind, !isMerging, !pr.isMergeQueueEnabled, pr.viewerCanMerge, reviewed, !pr.isDraft {
            reasons.append(.behindBase)
        }
        if session == nil, sessionsKnown { reasons.append(.noSession) }
        let quiet = now.timeIntervalSince(pr.updatedAt)
        if quiet >= staleInterval { reasons.append(.stale(days: Int(quiet / 86_400))) }
        return PullRequestAssessment(stage: stage(pr), reasons: reasons, status: status(pr))
    }

    /// Approved (or needing no review), mergeable by you, with no required
    /// check failing or pending, and everything about it read.
    static func isReady(_ pr: PullRequestSnapshot) -> Bool {
        guard !pr.isDraft, pr.viewerCanMerge, pr.mergeable != .conflicting,
              !pr.isIncomplete, pr.uncountedThreadsCursor == nil else { return false }
        guard pr.reviewDecision == .approved || pr.reviewDecision == nil else { return false }
        switch pr.mergeState {
        case .clean, .hasHooks, .unstable:
            return true
        case .unknown:
            // GitHub is still computing; trust the checks we can see.
            return pr.checks == nil || pr.checks == .success
                || (pr.checksFailing && pr.failingRequiredChecks?.isEmpty == true)
        case .behind, .blocked, .dirty, .draft:
            return false
        }
    }

    static func stage(_ pr: PullRequestSnapshot) -> PullRequestStage {
        if pr.isDraft { return .draft }
        if pr.inMergeQueue || isReady(pr) { return .ready }
        let requiredFailing = pr.checksFailing && pr.failingRequiredChecks?.isEmpty != true
        if requiredFailing || pr.checksRunning { return .checks }
        if pr.reviewDecision == .approved { return .ready }
        return .review
    }

    static func status(_ pr: PullRequestSnapshot) -> String {
        if pr.isDraft { return "Draft" }
        if pr.inMergeQueue { return "In the merge queue" }
        let base: String
        if pr.checksRunning {
            base = "Checks running"
        } else {
            switch pr.reviewDecision {
            case .reviewRequired: base = "Awaiting review"
            case .approved: base = pr.viewerCanMerge ? "Approved" : "Approved · maintainers merge"
            case .changesRequested: base = "Changes requested"
            case nil: base = pr.viewerCanMerge ? "Open" : "Awaiting maintainers"
            }
        }
        return pr.autoMergeEnabled ? "\(base) · auto-merge on" : base
    }
}

/// How often each live session's transcript mentions what identifies a pull request.
struct TranscriptEvidence: Equatable, Sendable {
    /// Head branch name → mentions.
    var branchMentions: [String: Int] = [:]
    /// `owner/repo#number` → mentions of its URL.
    var urlMentions: [PullRequestKey: Int] = [:]
    var lastModified: Date? = nil
}

enum PullRequestLinker {
    /// Mentions of a head branch that tie a session to the pull request. Sessions
    /// that only review or list a PR rarely name its branch; the session that
    /// builds it names it every push.
    static let branchThreshold = 3
    /// For a non-distinctive branch name, the URL has to carry the link.
    static let urlThreshold = 5

    private static let commonBranches: Set<String> = [
        "main", "master", "develop", "development", "dev", "trunk", "gh-pages", "staging", "release",
    ]

    /// A branch name specific enough that finding it in a transcript means that
    /// transcript is about this pull request.
    static func isDistinctiveBranch(_ name: String) -> Bool {
        let lower = name.lowercased()
        guard !commonBranches.contains(lower), lower.count >= 8 else { return false }
        if lower.range(of: #"^(patch|fix|update|test|feature)-?\d*$"#, options: .regularExpression) != nil {
            return false
        }
        return lower.contains { $0 == "-" || $0 == "/" || $0 == "_" }
    }

    /// Each pull request's driving session: the one whose transcript names it most.
    static func links(
        pullRequests: [PullRequestSnapshot], evidence: [String: TranscriptEvidence]
    ) -> [PullRequestKey: String] {
        var links: [PullRequestKey: String] = [:]
        let sessions = evidence.sorted { $0.key < $1.key }
        for pr in pullRequests {
            let distinctive = isDistinctiveBranch(pr.headRefName)
            var best: (sessionId: String, score: Int, modified: Date)?
            for (sessionId, evidence) in sessions {
                let score: Int
                if distinctive {
                    score = evidence.branchMentions[pr.headRefName] ?? 0
                    guard score >= branchThreshold else { continue }
                } else {
                    score = evidence.urlMentions[pr.key] ?? 0
                    guard score >= urlThreshold else { continue }
                }
                let modified = evidence.lastModified ?? .distantPast
                if let current = best, (current.score, current.modified) >= (score, modified) { continue }
                best = (sessionId, score, modified)
            }
            if let best { links[pr.key] = best.sessionId }
        }
        return links
    }
}

/// A live workspace session as the Pull Requests window shows it, read from
/// Copilot Projects over its control socket.
struct PullRequestSession: Equatable, Sendable {
    let id: String
    let title: String
    let projectId: String
    let projectName: String
    /// The status the workspace shows, waiting while a question is pending. Nil
    /// when Copilot Projects can't be reached and this is its last known session.
    var status: SessionStatus?
    var finishedUnseen: Bool
    var hasPendingInput: Bool
    /// The Copilot CLI session in this tab, whose event log names its pull requests.
    let copilotSessionId: String?

    init(
        id: String, title: String, projectId: String, projectName: String, status: SessionStatus? = .idle,
        finishedUnseen: Bool = false, hasPendingInput: Bool = false, copilotSessionId: String? = nil
    ) {
        self.id = id
        self.title = title
        self.projectId = projectId
        self.projectName = projectName
        self.status = status
        self.finishedUnseen = finishedUnseen
        self.hasPendingInput = hasPendingInput
        self.copilotSessionId = copilotSessionId
    }

    init(_ session: WorkspaceSnapshot.Session, in project: WorkspaceSnapshot.Project) {
        self.init(
            id: session.id, title: session.title, projectId: project.id, projectName: project.name,
            status: session.status, finishedUnseen: session.finishedUnseen,
            hasPendingInput: session.hasPendingInput, copilotSessionId: session.copilotSessionId
        )
    }

    /// The same session with its state unknown: what is shown while Copilot
    /// Projects can't be reached.
    var withUnknownState: PullRequestSession {
        var session = self
        session.status = nil
        session.finishedUnseen = false
        session.hasPendingInput = false
        return session
    }

    /// The attention state beside the session's project, as the workspace words it.
    var attentionLabel: String {
        switch status {
        case .running: return "Running"
        case .waiting: return "Waiting for input"
        case .idle: return finishedUnseen ? "Finished" : "Idle"
        case nil: return "Status unknown"
        }
    }

    /// Every session in a snapshot by id.
    static func sessions(in snapshot: WorkspaceSnapshot) -> [String: PullRequestSession] {
        var sessions: [String: PullRequestSession] = [:]
        for project in snapshot.projects {
            for session in project.sessions {
                sessions[session.id] = PullRequestSession(session, in: project)
            }
        }
        return sessions
    }
}

struct PullRequestItem: Identifiable, Equatable {
    let pr: PullRequestSnapshot
    let assessment: PullRequestAssessment
    /// The session working on this pull request, when there is one.
    let session: PullRequestSession?
    /// A user-chosen goal rather than an inferred one.
    let isManuallyAssigned: Bool

    var id: PullRequestKey { pr.key }
}

/// Pull requests working toward one outcome.
struct PullRequestGoal: Identifiable, Equatable {
    enum Kind: Equatable {
        /// Inferred from the session that drives these pull requests.
        case session
        /// Pull requests sharing a head branch across repositories.
        case branch
        /// One pull request with nothing to group it by.
        case single
        /// Named by the user.
        case manual
    }

    let id: String
    let kind: Kind
    let name: String
    let session: PullRequestSession?
    /// Most urgent first.
    let items: [PullRequestItem]
    /// An ended Copilot session that worked on these pull requests, offered only
    /// while no live session does.
    var resumable: ResumableSession? = nil

    var actionCount: Int { items.filter { $0.assessment.needsAction }.count }
    var needsYouCount: Int { items.filter { $0.assessment.needsYou }.count }
    var urgency: Int { items.map(\.assessment.urgency).min() ?? Int.max }
    var lastUpdated: Date { items.map(\.pr.updatedAt).max() ?? .distantPast }

    /// Work with a live session that needs you comes first, then goals no session
    /// is driving, then quiet nudges, then goals that need nothing.
    var focusRank: Int {
        if actionCount > 0 {
            return session != nil || items.contains { $0.session != nil } ? 0 : 1
        }
        return items.contains { !$0.assessment.reasons.isEmpty } ? 2 : 3
    }

    func items(in stage: PullRequestStage) -> [PullRequestItem] {
        items.filter { $0.assessment.stage == stage }
    }
}

/// Goals the user named, and pull requests they placed by hand.
struct PullRequestGoalOverrides: Codable, Equatable, Sendable {
    /// `owner/repo#number` → goal id: `session:<id>` or `manual:<id>`.
    var assignments: [String: String] = [:]
    /// `manual:<id>` → name.
    var names: [String: String] = [:]
    /// `owner/repo#number` → the session started for it from the Pull Requests window.
    var sessionLinks: [String: String] = [:]

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        assignments = try values.decodeIfPresent([String: String].self, forKey: .assignments) ?? [:]
        names = try values.decodeIfPresent([String: String].self, forKey: .names) ?? [:]
        sessionLinks = try values.decodeIfPresent([String: String].self, forKey: .sessionLinks) ?? [:]
    }

    func goalId(for key: PullRequestKey) -> String? { assignments[key.description] }

    mutating func assign(_ key: PullRequestKey, to goalId: String?) {
        assignments[key.description] = goalId
        let used = Set(assignments.values)
        names = names.filter { used.contains($0.key) }
    }
}

enum PullRequestGrouping {
    static func sessionGoalId(_ sessionId: String) -> String { "session:\(sessionId)" }

    /// The name a session's terminal title gives its goal: Copilot titles read
    /// "<name> - <state> - GitHub Copilot".
    static func goalName(sessionTitle: String) -> String {
        let trimmed = sessionTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = trimmed.range(of: " - ") else { return trimmed }
        let name = trimmed[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? trimmed : name
    }

    /// A pull request title read as a goal name: `fix the thing` → `Fix the thing`.
    static func sentenceCase(_ title: String) -> String {
        guard let first = title.first, first.isLowercase else { return title }
        return first.uppercased() + title.dropFirst()
    }

    static func goals(
        pullRequests: [PullRequestSnapshot],
        links: [PullRequestKey: String],
        sessions: [String: PullRequestSession],
        overrides: PullRequestGoalOverrides,
        now: Date,
        sessionsKnown: Bool = true,
        resumable: [PullRequestKey: ResumableSession] = [:]
    ) -> [PullRequestGoal] {
        struct Placement { var goalId: String; var kind: PullRequestGoal.Kind; var manual: Bool }

        func liveSession(fromGoal goalId: String?) -> String? {
            guard let goalId, goalId.hasPrefix("session:") else { return nil }
            let sessionId = String(goalId.dropFirst("session:".count))
            return sessions[sessionId] == nil ? nil : sessionId
        }

        var sessionOf: [PullRequestKey: String] = [:]
        var placements: [PullRequestKey: Placement] = [:]
        for pr in pullRequests {
            let override = overrides.goalId(for: pr.key)
            if let sessionId = liveSession(fromGoal: override) {
                sessionOf[pr.key] = sessionId
                placements[pr.key] = Placement(goalId: sessionGoalId(sessionId), kind: .session, manual: true)
                continue
            }
            let started = overrides.sessionLinks[pr.key.description].flatMap { sessions[$0] == nil ? nil : $0 }
            if let sessionId = started ?? links[pr.key], sessions[sessionId] != nil { sessionOf[pr.key] = sessionId }
            if let override, override.hasPrefix("manual:"), overrides.names[override] != nil {
                placements[pr.key] = Placement(goalId: override, kind: .manual, manual: true)
            } else if let sessionId = sessionOf[pr.key] {
                placements[pr.key] = Placement(goalId: sessionGoalId(sessionId), kind: .session, manual: false)
            }
        }

        // A pull request with no session joins whatever shares its head branch:
        // the same change landing in several repositories is one goal.
        var branchGoal: [String: String] = [:]
        for pr in pullRequests where PullRequestLinker.isDistinctiveBranch(pr.headRefName) {
            guard let placement = placements[pr.key], placement.kind == .session, !placement.manual else { continue }
            branchGoal[pr.headRefName] = branchGoal[pr.headRefName] ?? placement.goalId
        }
        let unplaced = pullRequests.filter { placements[$0.key] == nil }
        let branchCounts = Dictionary(grouping: unplaced, by: \.headRefName).mapValues(\.count)
        for pr in unplaced {
            if let goalId = branchGoal[pr.headRefName] {
                placements[pr.key] = Placement(goalId: goalId, kind: .session, manual: false)
                sessionOf[pr.key] = String(goalId.dropFirst("session:".count))
            } else if PullRequestLinker.isDistinctiveBranch(pr.headRefName), branchCounts[pr.headRefName, default: 0] > 1 {
                placements[pr.key] = Placement(goalId: "branch:\(pr.headRefName)", kind: .branch, manual: false)
            } else {
                placements[pr.key] = Placement(goalId: "pr:\(pr.key)", kind: .single, manual: false)
            }
        }

        var members: [String: [PullRequestSnapshot]] = [:]
        var kinds: [String: PullRequestGoal.Kind] = [:]
        for pr in pullRequests {
            guard let placement = placements[pr.key] else { continue }
            members[placement.goalId, default: []].append(pr)
            kinds[placement.goalId] = placement.kind
        }

        let goals = members.map { goalId, prs -> PullRequestGoal in
            let kind = kinds[goalId] ?? .single
            let goalSession = kind == .session ? liveSession(fromGoal: goalId).flatMap { sessions[$0] } : nil
            let items = prs.map { pr -> PullRequestItem in
                let session = sessionOf[pr.key].flatMap { sessions[$0] }
                return PullRequestItem(
                    pr: pr,
                    assessment: PullRequestTriage.assess(
                        pr, session: session, now: now, sessionsKnown: sessionsKnown
                    ),
                    session: session,
                    isManuallyAssigned: placements[pr.key]?.manual == true
                )
            }
            .sorted(by: itemOrder)
            let name: String
            switch kind {
            case .session:
                name = goalSession.map { goalName(sessionTitle: $0.title) } ?? items[0].pr.title
            case .manual:
                name = overrides.names[goalId] ?? sentenceCase(items[0].pr.title)
            case .branch, .single:
                name = sentenceCase(prs.min { ($0.createdAt, $0.key) < ($1.createdAt, $1.key) }?.title ?? goalId)
            }
            var goal = PullRequestGoal(id: goalId, kind: kind, name: name, session: goalSession, items: items)
            if goalSession == nil, items.allSatisfy({ $0.session == nil }) {
                goal.resumable = previousSession(for: items, in: resumable)
            }
            return goal
        }
        return goals.sorted(by: goalOrder)
    }

    /// The ended session that worked on most of the goal's pull requests, then
    /// the one active most recently.
    private static func previousSession(
        for items: [PullRequestItem], in resumable: [PullRequestKey: ResumableSession]
    ) -> ResumableSession? {
        var counts: [String: (session: ResumableSession, count: Int)] = [:]
        for item in items {
            guard let session = resumable[item.pr.key] else { continue }
            counts[session.copilotSessionId, default: (session, 0)].count += 1
        }
        return counts.values.max {
            ($0.count, $0.session.lastActive, $1.session.copilotSessionId)
                < ($1.count, $1.session.lastActive, $0.session.copilotSessionId)
        }?.session
    }

    private static func itemOrder(_ lhs: PullRequestItem, _ rhs: PullRequestItem) -> Bool {
        if lhs.assessment.urgency != rhs.assessment.urgency {
            return lhs.assessment.urgency < rhs.assessment.urgency
        }
        if lhs.pr.updatedAt != rhs.pr.updatedAt { return lhs.pr.updatedAt > rhs.pr.updatedAt }
        return lhs.pr.key < rhs.pr.key
    }

    private static func goalOrder(_ lhs: PullRequestGoal, _ rhs: PullRequestGoal) -> Bool {
        if lhs.focusRank != rhs.focusRank { return lhs.focusRank < rhs.focusRank }
        if lhs.urgency != rhs.urgency { return lhs.urgency < rhs.urgency }
        if lhs.lastUpdated != rhs.lastUpdated { return lhs.lastUpdated > rhs.lastUpdated }
        return lhs.id < rhs.id
    }
}
