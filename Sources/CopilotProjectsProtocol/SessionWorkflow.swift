import Foundation

public enum RemoteSessionActionKind: String, Codable, Sendable, CaseIterable {
    case send = "session-send"
    case abort = "session-abort"
    case setBudget = "set-session-budget"
    case answerBudget = "answer-session-budget"
}

public enum RemotePromptMode: String, Codable, Sendable, CaseIterable {
    case enqueue
    case immediate

    public var title: String {
        switch self {
        case .enqueue: "Run after current task"
        case .immediate: "Steer current task"
        }
    }
}

public struct RemoteWorkflowActionResult: Equatable, Sendable {
    public let state: RemoteOperationState
    public let message: String?
    public let operationId: String?

    public init(state: RemoteOperationState, message: String? = nil, operationId: String? = nil) {
        self.state = state
        self.message = message
        self.operationId = operationId
    }
}

/// A closed set of user actions, not an arbitrary SDK RPC proxy.
public struct RemoteSessionAction: Codable, Equatable, Sendable {
    public let kind: RemoteSessionActionKind
    public var prompt: String?
    public var mode: RemotePromptMode?
    public var maxAiCredits: Double?
    public var requestId: String?
    public var additionalAiCredits: Double?
    public var attachmentIds: [String]?

    public init(
        kind: RemoteSessionActionKind,
        prompt: String? = nil,
        mode: RemotePromptMode? = nil,
        maxAiCredits: Double? = nil,
        requestId: String? = nil,
        additionalAiCredits: Double? = nil,
        attachmentIds: [String]? = nil
    ) {
        self.kind = kind
        self.prompt = prompt
        self.mode = mode
        self.maxAiCredits = maxAiCredits
        self.requestId = requestId
        self.additionalAiCredits = additionalAiCredits
        self.attachmentIds = attachmentIds
    }

    public var isValid: Bool {
        if let attachmentIds {
            guard kind == .send, !attachmentIds.isEmpty,
                  attachmentIds.count <= RemoteAttachmentContract.maxImages,
                  Set(attachmentIds).count == attachmentIds.count,
                  attachmentIds.allSatisfy(RemoteAttachmentContract.validID) else { return false }
        }
        switch kind {
        case .send:
            guard let prompt, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  prompt.utf8.count <= 8_192, mode != nil else { return false }
            return maxAiCredits == nil && requestId == nil && additionalAiCredits == nil
        case .abort:
            return prompt == nil && mode == nil && maxAiCredits == nil
                && requestId == nil && additionalAiCredits == nil
        case .setBudget:
            return prompt == nil && mode == nil && requestId == nil
                && additionalAiCredits == nil
                && (maxAiCredits.map { $0.isFinite && $0 >= 30 } ?? true)
        case .answerBudget:
            guard let requestId, !requestId.isEmpty, requestId.utf8.count <= 200 else { return false }
            return prompt == nil && mode == nil && maxAiCredits == nil
                && (additionalAiCredits.map { $0.isFinite && $0 > 0 } ?? true)
        }
    }
}

public struct RemoteBudgetRequest: Codable, Equatable, Sendable, Identifiable {
    public let requestId: String
    public let maxAiCredits: Double
    public let usedAiCredits: Double
    public var id: String { requestId }

    public init(requestId: String, maxAiCredits: Double, usedAiCredits: Double) {
        self.requestId = requestId
        self.maxAiCredits = maxAiCredits
        self.usedAiCredits = usedAiCredits
    }
}

public struct RemoteWorkflowAgent: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let description: String?

    public init(id: String, name: String, description: String? = nil) {
        self.id = id
        self.name = name
        self.description = description
    }
}

public struct RemoteSessionWorkflow: Codable, Equatable, Sendable {
    public let version: Int
    public var observedAtMilliseconds: Int64
    public let capabilities: [String]
    public let sendReady: Bool
    public let legacyPromptFallback: Bool?
    public let totalAiCredits: Double?
    public let contextTokens: Int?
    public let contextTokenLimit: Int?
    public let limitsKnown: Bool
    public let maxAiCredits: Double?
    public let budgetRequest: RemoteBudgetRequest?
    public let agents: [RemoteWorkflowAgent]
    public let schedules: [String]
    public let error: String?
    public let imageAttachments: RemoteImageCapabilities?

    public init(
        version: Int = 1,
        observedAtMilliseconds: Int64,
        capabilities: [String],
        sendReady: Bool,
        legacyPromptFallback: Bool? = nil,
        totalAiCredits: Double? = nil,
        contextTokens: Int? = nil,
        contextTokenLimit: Int? = nil,
        limitsKnown: Bool = false,
        maxAiCredits: Double? = nil,
        budgetRequest: RemoteBudgetRequest? = nil,
        agents: [RemoteWorkflowAgent] = [],
        schedules: [String] = [],
        error: String? = nil,
        imageAttachments: RemoteImageCapabilities? = nil
    ) {
        self.version = version
        self.observedAtMilliseconds = observedAtMilliseconds
        self.capabilities = capabilities
        self.sendReady = sendReady
        self.legacyPromptFallback = legacyPromptFallback
        self.totalAiCredits = totalAiCredits
        self.contextTokens = contextTokens
        self.contextTokenLimit = contextTokenLimit
        self.limitsKnown = limitsKnown
        self.maxAiCredits = maxAiCredits
        self.budgetRequest = budgetRequest
        self.agents = agents
        self.schedules = schedules
        self.error = error
        self.imageAttachments = imageAttachments
    }

    /// Wall-clock freshness, for code running on the Mac that observed the workflow.
    /// Remote clients should use `isFresh(servedAtMilliseconds:receivedAt:now:at:)`.
    public func isFresh(at date: Date = Date()) -> Bool {
        let age = date.timeIntervalSince1970 * 1_000 - Double(observedAtMilliseconds)
        return version == 1 && age >= 0 && age <= Double(Self.freshnessLimitMilliseconds)
    }

    public func supports(_ kind: RemoteSessionActionKind, at date: Date = Date()) -> Bool {
        isFresh(at: date) && capabilities.contains(kind.rawValue)
    }
}

// MARK: - Remote client freshness

extension RemoteSessionWorkflow {
    /// The oldest a workflow observation may be, in milliseconds, and still be fresh.
    public static let freshnessLimitMilliseconds: Int64 = 15_000

    /// How far a snapshot's `servedAtMilliseconds` may precede the workflow's
    /// `observedAtMilliseconds` and still count as zero age. Both come from the
    /// Mac's clock, so only a clock step can order them that way; anything larger
    /// is rejected rather than trusted.
    public static let servedClockToleranceMilliseconds: Int64 = 1_000

    /// The observation's age in milliseconds as seen by a remote client, or `nil`
    /// when it cannot be trusted at all.
    ///
    /// With the `servedAtMilliseconds` of the `RemoteWorkspaceSnapshot` that carried
    /// this workflow, the age never compares the two devices' wall clocks:
    ///
    ///     age = max(0, servedAt - observedAt)   // Mac clock
    ///         + (now - receivedAt)              // client monotonic clock
    ///
    /// `receivedAt` is when the client received that snapshot. It must come from a
    /// clock that keeps counting while the device sleeps, like `ContinuousClock`;
    /// otherwise a snapshot cached across sleep would look younger than it is.
    /// Time spent between the gateway serving the snapshot and the client
    /// receiving it is not counted: no shared clock can measure it, and a
    /// streamed snapshot has no request of its own to start from. That is
    /// normally well under a second, and the Mac re-checks freshness on its own
    /// clock before it acts on any request, so this only decides what a client
    /// offers.
    /// The result is `nil` when `observedAtMilliseconds` is not a real observation
    /// (`<= 0`), servedAt precedes observedAt by more than
    /// `servedClockToleranceMilliseconds`, or `now` precedes `receivedAt`.
    ///
    /// Without `servedAtMilliseconds` (older gateways) this is the wall-clock rule
    /// of `isFresh(at:)`: `date - observedAt`, `nil` when negative.
    ///
    /// The arithmetic is in `Double` so arbitrary wire values cannot trap; every
    /// real timestamp is an exact integer below 2^53. JavaScript clients get the
    /// same results from `Number` and share the cases in the
    /// `workflow-freshness-cases` contract fixture.
    public func ageMilliseconds(
        servedAtMilliseconds: Int64?,
        receivedAt: ContinuousClock.Instant,
        now: ContinuousClock.Instant = .now,
        at date: Date = Date()
    ) -> Double? {
        guard let servedAtMilliseconds else {
            let age = date.timeIntervalSince1970 * 1_000 - Double(observedAtMilliseconds)
            return age >= 0 ? age : nil
        }
        guard observedAtMilliseconds > 0 else { return nil }
        let servedAfterObservation = Double(servedAtMilliseconds) - Double(observedAtMilliseconds)
        guard servedAfterObservation >= -Double(Self.servedClockToleranceMilliseconds) else {
            return nil
        }
        let sinceReceipt = receivedAt.duration(to: now).milliseconds
        guard sinceReceipt >= 0 else { return nil }
        return max(0, servedAfterObservation) + sinceReceipt
    }

    /// Whether a remote client may act on this observation; see
    /// `ageMilliseconds(servedAtMilliseconds:receivedAt:now:at:)`. Exactly
    /// `freshnessLimitMilliseconds` old is still fresh.
    public func isFresh(
        servedAtMilliseconds: Int64?,
        receivedAt: ContinuousClock.Instant,
        now: ContinuousClock.Instant = .now,
        at date: Date = Date()
    ) -> Bool {
        guard version == 1, let age = ageMilliseconds(
            servedAtMilliseconds: servedAtMilliseconds,
            receivedAt: receivedAt,
            now: now,
            at: date
        ) else { return false }
        return age <= Double(Self.freshnessLimitMilliseconds)
    }

    public func supports(
        _ kind: RemoteSessionActionKind,
        servedAtMilliseconds: Int64?,
        receivedAt: ContinuousClock.Instant,
        now: ContinuousClock.Instant = .now,
        at date: Date = Date()
    ) -> Bool {
        isFresh(
            servedAtMilliseconds: servedAtMilliseconds,
            receivedAt: receivedAt,
            now: now,
            at: date
        ) && capabilities.contains(kind.rawValue)
    }
}

private extension Duration {
    var milliseconds: Double {
        let (seconds, attoseconds) = components
        return Double(seconds) * 1_000 + Double(attoseconds) / 1e15
    }
}
