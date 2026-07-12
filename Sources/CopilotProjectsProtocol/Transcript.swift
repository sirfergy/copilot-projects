import Foundation

public struct TranscriptSnapshot: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let updatedAt: Date
    public let copilotSessionId: String
    public let turns: [TranscriptTurn]

    public init(
        schemaVersion: Int,
        updatedAt: Date,
        copilotSessionId: String,
        turns: [TranscriptTurn]
    ) {
        self.schemaVersion = schemaVersion
        self.updatedAt = updatedAt
        self.copilotSessionId = copilotSessionId
        self.turns = turns
    }
}

public struct TranscriptTurn: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let startedAt: Date
    public let endedAt: Date?
    public let kind: String
    public let userContent: String
    public let assistantMessages: [TranscriptAssistantMessage]
    public let tools: [TranscriptTool]
    public let isAborted: Bool

    public init(
        id: String,
        startedAt: Date,
        endedAt: Date?,
        kind: String,
        userContent: String,
        assistantMessages: [TranscriptAssistantMessage],
        tools: [TranscriptTool],
        isAborted: Bool
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.kind = kind
        self.userContent = userContent
        self.assistantMessages = assistantMessages
        self.tools = tools
        self.isAborted = isAborted
    }
}

public struct TranscriptAssistantMessage: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let timestamp: Date
    public let content: String

    public init(id: String, timestamp: Date, content: String) {
        self.id = id
        self.timestamp = timestamp
        self.content = content
    }
}

public struct TranscriptTool: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let title: String
    public let success: Bool?

    public init(id: String, name: String, title: String, success: Bool?) {
        self.id = id
        self.name = name
        self.title = title
        self.success = success
    }
}

public struct RemoteTranscriptRevision: Codable, Equatable, Sendable {
    public let sessionId: String
    public let generation: String

    public init(sessionId: String, generation: String) {
        self.sessionId = sessionId
        self.generation = generation
    }
}
