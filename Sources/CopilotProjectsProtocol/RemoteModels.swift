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

    public init(
        id: String,
        title: String,
        status: String,
        statusText: String?,
        unread: Bool,
        ready: Bool,
        background: Bool,
        scheduled: Bool
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.statusText = statusText
        self.unread = unread
        self.ready = ready
        self.background = background
        self.scheduled = scheduled
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
