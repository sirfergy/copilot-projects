import Foundation

public struct RemoteWorkspaceSnapshot: Codable, Equatable, Sendable {
    public let projects: [RemoteProjectSnapshot]
    public let selectedProjectId: String?

    public init(projects: [RemoteProjectSnapshot], selectedProjectId: String?) {
        self.projects = projects
        self.selectedProjectId = selectedProjectId
    }
}
public struct RemoteProjectSnapshot: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let selectedSessionId: String?
    public let sessions: [RemoteSessionSnapshot]

    public init(
        id: String,
        name: String,
        selectedSessionId: String?,
        sessions: [RemoteSessionSnapshot]
    ) {
        self.id = id
        self.name = name
        self.selectedSessionId = selectedSessionId
        self.sessions = sessions
    }
}

public struct RemoteSessionSnapshot: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let status: String
    public let statusText: String?
    public let unread: Bool
    public let ready: Bool
    public let background: Bool
    public let scheduled: Bool
    public let promptable: Bool?
    /// Structured `ask_user` questions currently awaiting an answer. Optional (and
    /// omitted when absent) so older clients decode snapshots without this field.
    public let pendingUserInputs: [RemoteUserInputRequest]?

    public init(
        id: String,
        title: String,
        status: String,
        statusText: String?,
        unread: Bool,
        ready: Bool,
        background: Bool,
        scheduled: Bool,
        promptable: Bool? = nil,
        pendingUserInputs: [RemoteUserInputRequest]? = nil
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.statusText = statusText
        self.unread = unread
        self.ready = ready
        self.background = background
        self.scheduled = scheduled
        self.promptable = promptable
        self.pendingUserInputs = pendingUserInputs
    }
}

/// A structured question surfaced by the agent's `ask_user`/`user_input.requested`
/// event, exposed to remote clients so they can answer without the terminal. The
/// `choices` are carried verbatim: a selectable answer must match one exactly.
public struct RemoteUserInputRequest: Codable, Equatable, Sendable, Identifiable {
    public let requestId: String
    public let question: String
    public let choices: [String]
    public let allowFreeform: Bool
    public let requestedAt: Date
    public let agentId: String?

    public var id: String { requestId }

    public init(
        requestId: String,
        question: String,
        choices: [String],
        allowFreeform: Bool,
        requestedAt: Date,
        agentId: String? = nil
    ) {
        self.requestId = requestId
        self.question = question
        self.choices = choices
        self.allowFreeform = allowFreeform
        self.requestedAt = requestedAt
        self.agentId = agentId
    }
}

/// A remote client's answer to a `RemoteUserInputRequest`. `wasFreeform` is only
/// valid when the originating request allowed free-form text; otherwise `answer`
/// must equal one of the request's verbatim choices.
public struct RemoteUserInputAnswer: Codable, Equatable, Sendable {
    public let requestId: String
    public let answer: String
    public let wasFreeform: Bool

    public init(requestId: String, answer: String, wasFreeform: Bool) {
        self.requestId = requestId
        self.answer = answer
        self.wasFreeform = wasFreeform
    }
}

public enum RemoteScrollMode: String, Codable, Equatable, Sendable {
    case history
    case terminal
}

public struct RemoteTerminalScreen: Codable, Equatable, Sendable {
    public let sessionId: String
    public let cols: Int
    public let rows: Int
    public let scrollMode: RemoteScrollMode
    public let historyStartLine: Int
    public let firstLine: Int
    public let liveTopLine: Int
    public let reset: Bool
    public let lines: [String]

    public init(
        sessionId: String,
        cols: Int,
        rows: Int,
        scrollMode: RemoteScrollMode,
        historyStartLine: Int,
        firstLine: Int,
        liveTopLine: Int,
        reset: Bool,
        lines: [String]
    ) {
        self.sessionId = sessionId
        self.cols = cols
        self.rows = rows
        self.scrollMode = scrollMode
        self.historyStartLine = historyStartLine
        self.firstLine = firstLine
        self.liveTopLine = liveTopLine
        self.reset = reset
        self.lines = lines
    }
}

public struct RemoteClientMessage: Codable, Equatable, Sendable {
    public let type: String
    public let clientId: String?
    public let sessionId: String?
    public let data: String?
    public let delta: Int?

    public init(
        type: String,
        clientId: String? = nil,
        sessionId: String? = nil,
        data: String? = nil,
        delta: Int? = nil
    ) {
        self.type = type
        self.clientId = clientId
        self.sessionId = sessionId
        self.data = data
        self.delta = delta
    }
}

public struct RemoteServerMessage<Value: Codable & Sendable>: Codable, Sendable {
    public let type: String
    public let data: Value

    public init(type: String, data: Value) {
        self.type = type
        self.data = data
    }
}
