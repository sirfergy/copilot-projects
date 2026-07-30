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
    /// Schema-form `elicitation.requested` questions awaiting an answer. Optional
    /// (omitted when absent) for backward-compatible decoding.
    public let pendingElicitations: [RemoteElicitationRequest]?
    /// The session's effective model (name + reasoning effort + context tier).
    /// Optional (omitted when absent) so older clients decode without this field.
    public let model: RemoteModelInfo?
    /// Models the session can switch to, ordered with the preferred default first.
    /// Optional (omitted when absent) so older clients decode without this field
    /// and so a session that hasn't reported its catalog yet simply has no picker.
    public let availableModels: [RemoteAvailableModel]?

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
        pendingUserInputs: [RemoteUserInputRequest]? = nil,
        pendingElicitations: [RemoteElicitationRequest]? = nil,
        model: RemoteModelInfo? = nil,
        availableModels: [RemoteAvailableModel]? = nil
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
        self.pendingElicitations = pendingElicitations
        self.model = model
        self.availableModels = availableModels
    }
}

/// The effective model for a session, surfaced so remote clients can display it.
/// `reasoningEffort` and `contextTier` are optional — omitted when the agent
/// doesn't report them (non-reasoning models, default context tier).
public struct RemoteModelInfo: Codable, Equatable, Sendable {
    public let name: String
    public let reasoningEffort: String?
    public let contextTier: String?

    public init(name: String, reasoningEffort: String? = nil, contextTier: String? = nil) {
        self.name = name
        self.reasoningEffort = reasoningEffort
        self.contextTier = contextTier
    }
}

/// One model the session can switch to, mirrored from the CLI's own model catalog
/// (`session.rpc.model.list()`) so a remote client can render a native picker
/// instead of driving the terminal `/model` TUI. `id` is the switch identifier
/// (a bare CAPI id like `gpt-5.4`, or a provider-qualified BYOK id like
/// `acme/model`); `name` is the display label. The reasoning-effort fields are
/// present only for models that support it, so the picker can offer exactly the
/// levels the CLI would accept. `disabled` reflects policy state (shown greyed,
/// not selectable). `longContextAvailable` gates offering the long-context tier.
public struct RemoteAvailableModel: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let supportedReasoningEfforts: [String]?
    public let defaultReasoningEffort: String?
    public let longContextAvailable: Bool?
    public let disabled: Bool?
    public let category: String?

    public init(
        id: String,
        name: String,
        supportedReasoningEfforts: [String]? = nil,
        defaultReasoningEffort: String? = nil,
        longContextAvailable: Bool? = nil,
        disabled: Bool? = nil,
        category: String? = nil
    ) {
        self.id = id
        self.name = name
        self.supportedReasoningEfforts = supportedReasoningEfforts
        self.defaultReasoningEffort = defaultReasoningEffort
        self.longContextAvailable = longContextAvailable
        self.disabled = disabled
        self.category = category
    }
}

/// A remote request to switch the session's model, carried in the `data` of a
/// `set-model` control message. `modelId` must be one advertised in the session's
/// `availableModels`; `reasoningEffort` (when set) must be one of that model's
/// `supportedReasoningEfforts`; `contextTier` is `default` or `long_context`.
public struct RemoteModelSelection: Codable, Equatable, Sendable {
    public let modelId: String
    public let reasoningEffort: String?
    public let contextTier: String?

    public init(modelId: String, reasoningEffort: String? = nil, contextTier: String? = nil) {
        self.modelId = modelId
        self.reasoningEffort = reasoningEffort
        self.contextTier = contextTier
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

/// A minimal JSON value used to carry an elicitation's `requestedSchema` and a
/// client's answer `content` verbatim across the wire, so the client renders
/// exactly what the agent asked and the host forwards exactly what the user gave.
public enum RemoteJSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([RemoteJSONValue])
    case object([String: RemoteJSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([RemoteJSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: RemoteJSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Unsupported JSON value"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

/// The action a remote client took on an elicitation, matching the SDK's
/// `UIElicitationResponseAction`.
public enum RemoteElicitationAction: String, Codable, Equatable, Sendable {
    case accept
    case decline
    case cancel
}

/// A schema-form (or url-mode) question surfaced by the agent's
/// `elicitation.requested` event. `schema` is the verbatim `requestedSchema` the
/// client renders as a form; `url` is set for url-mode requests instead.
public struct RemoteElicitationRequest: Codable, Equatable, Sendable, Identifiable {
    public let requestId: String
    public let message: String
    public let mode: String?
    public let url: String?
    public let schema: RemoteJSONValue?
    public let elicitationSource: String?
    public let requestedAt: Date
    public let agentId: String?

    public var id: String { requestId }

    public init(
        requestId: String,
        message: String,
        mode: String? = nil,
        url: String? = nil,
        schema: RemoteJSONValue? = nil,
        elicitationSource: String? = nil,
        requestedAt: Date,
        agentId: String? = nil
    ) {
        self.requestId = requestId
        self.message = message
        self.mode = mode
        self.url = url
        self.schema = schema
        self.elicitationSource = elicitationSource
        self.requestedAt = requestedAt
        self.agentId = agentId
    }
}

/// A remote client's answer to a `RemoteElicitationRequest`. `content` carries the
/// submitted form values (keyed by field name) and is only meaningful for the
/// `accept` action.
public struct RemoteElicitationAnswer: Codable, Equatable, Sendable {
    public let requestId: String
    public let action: RemoteElicitationAction
    public let content: [String: RemoteJSONValue]?

    public init(
        requestId: String,
        action: RemoteElicitationAction,
        content: [String: RemoteJSONValue]? = nil
    ) {
        self.requestId = requestId
        self.action = action
        self.content = content
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
    /// Kitty Unicode-placeholder images visible in `lines`, keyed to the exact
    /// bytes fetchable via `RemoteTerminalImageContract.path`. Optional only
    /// so older clients can decode screens encoded before this field existed
    /// — but a host that scans the full retained history (every host as of
    /// this writing) always encodes a *present* array here, `[]` included
    /// when nothing is currently placed. `nil` therefore means specifically
    /// "an older host that never scanned for images at all" (nothing can be
    /// concluded about what's actually on screen), while a present array —
    /// even empty — is the definitive, authoritative current set: a client
    /// can safely drop any previously-shown placement that isn't in it,
    /// rather than assuming it might still be there.
    public let images: [RemoteTerminalImagePlacement]?

    public init(
        sessionId: String,
        cols: Int,
        rows: Int,
        scrollMode: RemoteScrollMode,
        historyStartLine: Int,
        firstLine: Int,
        liveTopLine: Int,
        reset: Bool,
        lines: [String],
        images: [RemoteTerminalImagePlacement]? = nil
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
        self.images = images
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
