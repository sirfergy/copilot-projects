import Foundation

public struct RemoteProtocolInfo: Codable, Equatable, Sendable {
    public let revision: Int
    public let capabilities: [String]

    public static let conversationEpochs = "conversation-epochs"
    public static let operationReceipts = "sdk-operation-receipts"
    public static let transcriptWindow = "transcript-window"
    public static let current = RemoteProtocolInfo(
        revision: 1,
        capabilities: [conversationEpochs, operationReceipts, transcriptWindow]
    )

    public init(revision: Int, capabilities: [String]) {
        self.revision = revision
        self.capabilities = capabilities
    }

    public func supports(_ capability: String) -> Bool {
        capabilities.contains(capability)
    }
}

/// Absence means an older host. An updated host explicitly distinguishes an
/// older, live tracker from one whose state is currently unavailable.
public enum RemoteOperationSupport: String, Codable, Equatable, Sendable {
    case legacy
    case receipts
    case unavailable

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: value) ?? .unavailable
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public extension RemoteSessionSnapshot {
    func negotiatedOperationSupport(protocolInfo: RemoteProtocolInfo?) -> RemoteOperationSupport {
        let hostSupportsReceipts = protocolInfo?.supports(RemoteProtocolInfo.operationReceipts) == true
        switch operationSupport {
        case .legacy?:
            return .legacy
        case .unavailable?:
            return .unavailable
        case .receipts?:
            guard hostSupportsReceipts, let conversationEpoch, !conversationEpoch.isEmpty else {
                return .unavailable
            }
            return .receipts
        case nil:
            return hostSupportsReceipts ? .unavailable : .legacy
        }
    }
}

public enum RemoteOperationState: String, Codable, Equatable, Sendable {
    case accepted
    case applied
    case rejected
    case indeterminate

    public var isTerminal: Bool { self != .accepted }

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: value) ?? .indeterminate
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// A tracker outcome, not proof inferred from an HTTP response or a disappearing
/// question. The operation id is distinct from the question's request id.
public struct RemoteOperationReceipt: Codable, Equatable, Sendable, Identifiable {
    public let operationId: String
    public let conversationEpoch: String
    public let kind: String
    public let state: RemoteOperationState
    public let updatedAtMilliseconds: Int64
    public let errorCode: String?

    public var id: String { operationId }

    public init(
        operationId: String,
        conversationEpoch: String,
        kind: String,
        state: RemoteOperationState,
        updatedAtMilliseconds: Int64,
        errorCode: String? = nil
    ) {
        self.operationId = operationId
        self.conversationEpoch = conversationEpoch
        self.kind = kind
        self.state = state
        self.updatedAtMilliseconds = updatedAtMilliseconds
        self.errorCode = errorCode
    }
}
