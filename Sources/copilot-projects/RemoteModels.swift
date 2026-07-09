import Foundation

struct RemoteWorkspaceSnapshot: Codable, Equatable {
    let projects: [RemoteProjectSnapshot]
    let selectedProjectId: String?
}

struct RemoteProjectSnapshot: Codable, Equatable {
    let id: String
    let name: String
    let selectedSessionId: String?
    let sessions: [RemoteSessionSnapshot]
}

struct RemoteSessionSnapshot: Codable, Equatable {
    let id: String
    let title: String
    let status: String
    let statusText: String?
    let unread: Bool
    let ready: Bool
    let background: Bool
    let scheduled: Bool
}

struct RemoteTerminalScreen: Codable, Equatable {
    let sessionId: String
    let cols: Int
    let rows: Int
    let lines: [String]
}

struct RemoteClientMessage: Codable {
    let type: String
    let clientId: String?
    let sessionId: String?
    let data: String?
}

struct RemoteServerMessage<T: Codable>: Codable {
    let type: String
    let data: T
}
