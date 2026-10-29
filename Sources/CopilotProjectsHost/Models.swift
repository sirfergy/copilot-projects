import Foundation
import CopilotProjectsCore
import CopilotProjectsProtocol

/// A terminal session inside a project. Value type; the live terminal NSView lives
/// elsewhere (AppModel.controllers) and is keyed by `id`.
struct Session: Identifiable, Codable, Equatable {
    var id: String
    var title: String
    var cwd: String
    var hostId: String?
    var creationFingerprint: String?
    var pullRequestKeys: [String]?
    var parentSessionId: String?
    /// Persisted only while set, so unmarked sessions keep their saved shape.
    private var manuallyMarkedUnread: Bool?

    /// "Mark as Unread": a reminder to come back to this session. Unlike `hasUnread`,
    /// it survives relaunch, viewing other tabs in the project, and reactivating the
    /// app. Only navigating to the session or marking it read clears it.
    var markedUnread: Bool {
        get { manuallyMarkedUnread == true }
        set { manuallyMarkedUnread = newValue ? true : nil }
    }

    /// Either an unseen notification or a manual mark. Drives the unread dot,
    /// project bell, Dock count, and the `unread` flag mirrored to remotes.
    var isUnread: Bool { hasUnread || markedUnread }

    /// A session showing an unread or finished indicator offers Mark as Read;
    /// any other offers Mark as Unread.
    var offersMarkAsRead: Bool { isUnread || finishedUnseen }

    // Transient (not persisted): reset on load.
    var status: SessionStatus = .idle
    var statusIsRuntimeDerived = false
    var statusText: String? = nil
    var hasUnread: Bool = false
    /// The agent went active → idle while you weren't looking at this session, so it
    /// has finished and is waiting for you to come back. Cleared when you view it.
    var finishedUnseen: Bool = false
    var turnCompleted: Bool = false
    /// copilot is waiting on its own background agents (it reports this via a
    /// "Copilot: Waiting for background agents" terminal title). Surfaced as a tab/
    /// sidebar indicator instead of letting that title clobber the tab's real name.
    var backgroundAgentsActive: Bool = false
    var scheduledTurnActive: Bool = false
    var agentActivity: AgentActivitySnapshot?
    var memoryUsageBytes: Int64? = nil

    var activeSubagentCount: Int { agentActivity?.activeSubagents.count ?? 0 }
    var schedules: [TrackedSchedule] { agentActivity?.schedules ?? [] }
    var hasBackgroundWork: Bool {
        backgroundAgentsActive || scheduledTurnActive || activeSubagentCount > 0
    }
    /// A pending structured `ask_user` or schema `elicitation` awaiting an answer.
    /// These are answered via their own card, so a free-form remote prompt must
    /// never be injected over one even when the terminal footer reads idle.
    var hasPendingQuestions: Bool {
        (agentActivity?.trackedUserInputs?.isEmpty == false)
            || (agentActivity?.trackedElicitations?.isEmpty == false)
    }
    var hasPendingInput: Bool { agentActivity?.hasPendingInput == true }

    /// Activity hooks can report running while a question is still unanswered.
    /// Keep that lifecycle state separate from the attention shown to the user.
    var displayStatus: SessionStatus { hasPendingInput ? .waiting : status }

    /// The latest request failed and the session has been idle since.
    var failedRequest: TranscriptTurnError? {
        displayStatus == .idle ? agentActivity?.remoteLastError() : nil
    }

    var requiresEndConfirmation: Bool {
        status != .idle || hasBackgroundWork || !schedules.isEmpty || hasPendingInput
    }

    /// The attention state shown beside a session's name.
    var attentionLabel: String {
        switch displayStatus {
        case .running: return "Running"
        case .waiting: return "Waiting for input"
        case .idle:
            if failedRequest != nil { return "Request failed" }
            return finishedUnseen ? "Finished" : "Idle"
        }
    }

    /// Urgency tier for jumping to the next session that needs the user's attention.
    var attentionTier: SessionAttentionTier? {
        if displayStatus == .waiting { return .waiting }
        if failedRequest != nil { return .failed }
        if finishedUnseen || isUnread { return .unread }
        return nil
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, cwd, hostId, creationFingerprint, pullRequestKeys, parentSessionId
        case manuallyMarkedUnread = "markedUnread"
    }

    init(
        id: String = UUID().uuidString,
        title: String,
        cwd: String,
        hostId: String? = nil,
        creationFingerprint: String? = nil,
        pullRequestKeys: [String]? = nil,
        parentSessionId: String? = nil,
        memoryUsageBytes: Int64? = nil
    ) {
        self.id = id
        self.title = title
        self.cwd = cwd
        self.hostId = hostId
        self.creationFingerprint = creationFingerprint
        self.pullRequestKeys = pullRequestKeys
        self.parentSessionId = parentSessionId
        self.memoryUsageBytes = memoryUsageBytes
    }
}

/// Rollup of a parent session's child sessions for sidebar disclosure UI.
struct SessionChildSummary: Equatable, Sendable {
    var totalCount: Int
    var runningCount: Int = 0
    var waitingCount: Int = 0
    var failedCount: Int = 0

    init(children: [Session]) {
        self.totalCount = children.count
        self.runningCount = children.filter { $0.displayStatus == .running }.count
        self.waitingCount = children.filter { $0.displayStatus == .waiting }.count
        self.failedCount = children.filter { $0.failedRequest != nil }.count
    }

    var label: String {
        let base = "\(totalCount) child\(totalCount == 1 ? "" : "ren")"
        var details: [String] = []
        if runningCount > 0 { details.append("\(runningCount) running") }
        if waitingCount > 0 { details.append("\(waitingCount) waiting") }
        if failedCount > 0 { details.append("\(failedCount) failed") }
        return details.isEmpty ? base : "\(base) · \(details.joined(separator: ", "))"
    }
}

/// A visible row in `SessionList`, after applying single-level parent/child
/// grouping, disclosure state, and auto-peek rules.
struct SessionDisplayItem: Equatable, Identifiable {
    let session: Session
    let effectiveParentSessionId: String?
    let childSummary: SessionChildSummary?
    let isExpanded: Bool

    var id: String { session.id }
    var isChild: Bool { effectiveParentSessionId != nil }
}

/// A project groups sessions and owns a default working directory.
struct Project: Identifiable, Codable, Equatable {
    var id: String
    var name: String
    var cwd: String
    var defaultHostId: String?
    var sessions: [Session]
    var selectedSessionId: String?
    var creationFingerprint: String?

    private enum CodingKeys: String, CodingKey {
        case id, name, cwd, defaultHostId, sessions, selectedSessionId, creationFingerprint
    }

    init(id: String = UUID().uuidString,
         name: String,
         cwd: String,
         defaultHostId: String? = nil,
         sessions: [Session] = [],
         selectedSessionId: String? = nil,
         creationFingerprint: String? = nil) {
        self.id = id
        self.name = name
        self.cwd = cwd
        self.defaultHostId = defaultHostId
        self.sessions = sessions
        self.selectedSessionId = selectedSessionId
        self.creationFingerprint = creationFingerprint
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.cwd = try container.decode(String.self, forKey: .cwd)
        self.defaultHostId = try container.decodeIfPresent(String.self, forKey: .defaultHostId)
        self.sessions = try container.decode([Session].self, forKey: .sessions)
        self.selectedSessionId = try container.decodeIfPresent(String.self, forKey: .selectedSessionId)
        self.creationFingerprint = try container.decodeIfPresent(String.self, forKey: .creationFingerprint)
        normalizeParentSessions()
    }
}

extension Project {
    /// Project-level rollup for the CLI/status text (idle | running | waiting).
    var aggregateStatus: SessionStatus {
        if sessions.contains(where: { $0.displayStatus == .waiting }) { return .waiting }
        if sessions.contains(where: { $0.displayStatus == .running }) { return .running }
        return .idle
    }

    var runningCount: Int { sessions.filter { $0.displayStatus == .running }.count }
    var waitingCount: Int { sessions.filter { $0.displayStatus == .waiting }.count }
    var backgroundWorkCount: Int { sessions.filter(\.hasBackgroundWork).count }
    var scheduledCount: Int { sessions.filter { !$0.schedules.isEmpty }.count }
    var failedCount: Int { sessions.filter { $0.failedRequest != nil }.count }
    var hasUnread: Bool { sessions.contains { $0.isUnread } }
    var hasBackgroundWork: Bool { backgroundWorkCount > 0 }

    /// Resolves `candidateParentId` to a root (top-level) session ID within this
    /// project's `sessions`, walking up any multi-hop chain so the hierarchy is
    /// strictly single-level. Returns `nil` when `candidateParentId` is missing
    /// from this project, equals `sessionId`, or participates in a cycle.
    func resolvedParentSessionId(
        for candidateParentId: String?,
        excluding sessionId: String? = nil
    ) -> String? {
        guard let candidate = candidateParentId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !candidate.isEmpty,
              candidate != sessionId else {
            return nil
        }
        let sessionsById = Dictionary(
            sessions.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return Self.resolveParentSessionId(
            candidate,
            excluding: sessionId,
            sessionsById: sessionsById
        )
    }

    private static func resolveParentSessionId(
        _ candidate: String,
        excluding sessionId: String?,
        sessionsById: [String: Session]
    ) -> String? {
        guard sessionsById[candidate] != nil else { return nil }
        var currentId = candidate
        var visited: Set<String> = [currentId]
        if let sessionId { visited.insert(sessionId) }
        while let rawNext = sessionsById[currentId]?.parentSessionId?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !rawNext.isEmpty {
            if !visited.insert(rawNext).inserted {
                return nil
            }
            guard sessionsById[rawNext] != nil else { break }
            currentId = rawNext
        }
        return currentId
    }

    /// Effective root parent session ID for `sessionId` within this project, or
    /// `nil` if `sessionId` is a top-level session.
    func effectiveParentSessionId(for sessionId: String) -> String? {
        guard let session = sessions.first(where: { $0.id == sessionId }),
              let rawParent = session.parentSessionId else { return nil }
        return resolvedParentSessionId(for: rawParent, excluding: sessionId)
    }

    /// Map of session ID to effective root parent session ID for all child
    /// sessions in this project, computed with a single lookup table.
    func effectiveParentSessionIdsBySessionId() -> [String: String] {
        guard sessions.contains(where: { $0.parentSessionId != nil }) else { return [:] }
        let sessionsById = Dictionary(
            sessions.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var result: [String: String] = [:]
        for session in sessions {
            guard let candidate = session.parentSessionId?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !candidate.isEmpty,
                  candidate != session.id,
                  let rootId = Self.resolveParentSessionId(
                      candidate,
                      excluding: session.id,
                      sessionsById: sessionsById
                  ) else { continue }
            result[session.id] = rootId
        }
        return result
    }

    mutating func normalizeParentSessions(removingParentId removedId: String? = nil) {
        let effectiveParents = effectiveParentSessionIdsBySessionId()
        for index in sessions.indices {
            let root = effectiveParents[sessions[index].id]
            sessions[index].parentSessionId = (root == removedId) ? nil : root
        }
    }

    /// Whether a child session should auto-peek while its parent is collapsed.
    func shouldAutoPeekChild(_ child: Session) -> Bool {
        child.id == selectedSessionId || child.displayStatus == .waiting
    }

    /// Ordered rows to render in `SessionList`: top-level sessions in project order,
    /// each immediately followed by all of its children when expanded or its
    /// auto-peeked children (selected or waiting) when collapsed.
    func sessionDisplayItems(expandedParentIds: Set<String>) -> [SessionDisplayItem] {
        let effectiveParents = effectiveParentSessionIdsBySessionId()
        var childrenByParentId: [String: [Session]] = [:]
        var topLevelSessions: [Session] = []
        for session in sessions {
            if let parentId = effectiveParents[session.id] {
                childrenByParentId[parentId, default: []].append(session)
            } else {
                topLevelSessions.append(session)
            }
        }
        var items: [SessionDisplayItem] = []
        for session in topLevelSessions {
            let children = childrenByParentId[session.id] ?? []
            let summary = children.isEmpty ? nil : SessionChildSummary(children: children)
            let isExpanded = !children.isEmpty && expandedParentIds.contains(session.id)
            items.append(SessionDisplayItem(
                session: session,
                effectiveParentSessionId: nil,
                childSummary: summary,
                isExpanded: isExpanded
            ))
            let visibleChildren = isExpanded ? children : children.filter(shouldAutoPeekChild)
            for child in visibleChildren {
                items.append(SessionDisplayItem(
                    session: child,
                    effectiveParentSessionId: session.id,
                    childSummary: nil,
                    isExpanded: false
                ))
            }
        }
        return items
    }
}

/// On-disk shape of the app state.
struct PersistedState: Codable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var projects: [Project]
    var selectedProjectId: String?

    init(projects: [Project], selectedProjectId: String?) {
        self.schemaVersion = Self.currentSchemaVersion
        self.projects = projects
        self.selectedProjectId = selectedProjectId
    }
}

/// Urgency order when cycling through sessions that need attention (`⇧⌘A`).
enum SessionAttentionTier: Int, Comparable, Sendable {
    case waiting = 0
    case failed = 1
    case unread = 2

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Interactive categories in `FleetStatusBar`.
enum FleetActivityKind: String, CaseIterable, Equatable, Sendable {
    case running
    case background
    case scheduled
    case waiting
    case failed
    case ready

    func matches(_ session: Session) -> Bool {
        switch self {
        case .running: return session.displayStatus == .running
        case .background: return session.hasBackgroundWork
        case .scheduled: return !session.schedules.isEmpty
        case .waiting: return session.displayStatus == .waiting
        case .failed: return session.failedRequest != nil
        case .ready: return session.finishedUnseen
        }
    }
}

/// Which number-key overlay to show while a modifier is held.
enum NumberHint {
    case none      // nothing held
    case projects  // ⌘ held → number badges on projects
    case tabs      // ⌃ held → number badges on session tabs
}

/// Bounded Back/Forward history of visited sessions across all projects.
struct SessionNavigationHistory: Equatable, Sendable {
    static let maxEntries = 100
    static let maxMenuEntries = 10
    private(set) var entries: [String] = []
    private(set) var index: Int? = nil
    private(set) var isCurrentEntryDisplayed = false

    var canGoBack: Bool { backTarget != nil }

    var canGoForward: Bool { forwardTarget != nil }

    var backTarget: String? {
        guard let index, entries.indices.contains(index) else { return nil }
        if isCurrentEntryDisplayed {
            guard index > 0 else { return nil }
            return entries[index - 1]
        }
        return entries[index]
    }

    var forwardTarget: String? {
        guard let index, entries.indices.contains(index + 1) else { return nil }
        return entries[index + 1]
    }

    /// Up to `limit` previous entries in the back stack, most recent first.
    func backEntries(limit: Int = Self.maxMenuEntries) -> [(index: Int, sessionId: String)] {
        guard limit > 0, let index, entries.indices.contains(index) else { return [] }
        let upperBound = isCurrentEntryDisplayed ? index : index + 1
        guard upperBound > 0 else { return [] }
        return (0..<upperBound).reversed().prefix(limit).map { (index: $0, sessionId: entries[$0]) }
    }

    /// Up to `limit` upcoming entries in the forward stack, nearest first.
    func forwardEntries(limit: Int = Self.maxMenuEntries) -> [(index: Int, sessionId: String)] {
        guard limit > 0, let index else { return [] }
        let lowerBound = max(0, index + 1)
        guard lowerBound < entries.count else { return [] }
        return (lowerBound..<entries.count).prefix(limit).map { (index: $0, sessionId: entries[$0]) }
    }

    mutating func prune(validSessionIds: Set<String>) {
        guard !entries.isEmpty else {
            index = nil
            isCurrentEntryDisplayed = false
            return
        }
        let displayedId: String? = if isCurrentEntryDisplayed, let index, entries.indices.contains(index) {
            entries[index]
        } else {
            nil
        }
        let targetIndex = index ?? (entries.count - 1)
        var nextEntries: [String] = []
        var nextIndex: Int? = nil
        for (offset, id) in entries.enumerated() where validSessionIds.contains(id) {
            if nextEntries.last != id {
                nextEntries.append(id)
            }
            if offset <= targetIndex {
                nextIndex = nextEntries.count - 1
            } else if nextIndex == nil {
                nextIndex = -1
            }
        }
        entries = nextEntries
        index = nextEntries.isEmpty ? nil : nextIndex
        if let displayedId, let index, entries.indices.contains(index), entries[index] == displayedId {
            isCurrentEntryDisplayed = true
        } else {
            isCurrentEntryDisplayed = false
        }
    }

    mutating func reconcile(validSessionIds: Set<String>, currentSessionId: String?) {
        prune(validSessionIds: validSessionIds)
        guard let currentSessionId, validSessionIds.contains(currentSessionId) else {
            isCurrentEntryDisplayed = false
            return
        }
        if let index, entries.indices.contains(index), entries[index] == currentSessionId {
            isCurrentEntryDisplayed = true
            return
        }
        if let index, index + 1 < entries.count {
            entries.removeSubrange(max(0, index + 1)...)
        }
        if entries.last != currentSessionId {
            entries.append(currentSessionId)
        }
        if entries.count > Self.maxEntries {
            entries.removeFirst(entries.count - Self.maxEntries)
        }
        index = entries.indices.last
        isCurrentEntryDisplayed = true
    }

    mutating func goBack(validSessionIds: Set<String>) -> String? {
        prune(validSessionIds: validSessionIds)
        guard let current = index, entries.indices.contains(current) else { return nil }
        if isCurrentEntryDisplayed {
            guard current > 0 else { return nil }
            index = current - 1
            return entries[current - 1]
        }
        isCurrentEntryDisplayed = true
        return entries[current]
    }

    mutating func goForward(validSessionIds: Set<String>) -> String? {
        prune(validSessionIds: validSessionIds)
        guard let current = index, entries.indices.contains(current + 1) else { return nil }
        index = current + 1
        isCurrentEntryDisplayed = true
        return entries[current + 1]
    }

    mutating func goTo(index targetIndex: Int, validSessionIds: Set<String>) -> String? {
        guard entries.indices.contains(targetIndex) else {
            prune(validSessionIds: validSessionIds)
            return nil
        }
        let targetId = entries[targetIndex]
        guard validSessionIds.contains(targetId) else {
            prune(validSessionIds: validSessionIds)
            return nil
        }
        index = targetIndex
        isCurrentEntryDisplayed = true
        prune(validSessionIds: validSessionIds)
        return targetId
    }
}

/// One entry in the Back or Forward right-click history menu.
struct SessionHistoryMenuItem: Equatable, Identifiable, Sendable {
    let index: Int
    let projectId: String
    let projectName: String
    let sessionId: String
    let sessionTitle: String

    var id: Int { index }

    var menuTitle: String {
        "\(sessionTitle) — \(projectName)"
    }
}
