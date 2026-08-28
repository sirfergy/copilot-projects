import Foundation

public enum FooterActivity: Equatable, Sendable {
    case working
    case idle
    case unknown
}

public enum PromptEligibility: Equatable, Sendable {
    case send
    case busy
    case noLiveAgent
}

public enum PermissionPromptDisposition: Equatable, Sendable {
    case cancel
    case post
    case suppress
}

public struct PromptabilityInput: Equatable, Sendable {
    public var status: SessionStatus
    public var scheduledTurnActive: Bool
    public var hasPendingQuestions: Bool
    public var hasLiveAgent: Bool
    public var hasBackgroundOnlyEvidence: Bool
    public var footerActivity: FooterActivity

    public init(
        status: SessionStatus,
        scheduledTurnActive: Bool = false,
        hasPendingQuestions: Bool = false,
        hasLiveAgent: Bool,
        hasBackgroundOnlyEvidence: Bool = false,
        footerActivity: FooterActivity
    ) {
        self.status = status
        self.scheduledTurnActive = scheduledTurnActive
        self.hasPendingQuestions = hasPendingQuestions
        self.hasLiveAgent = hasLiveAgent
        self.hasBackgroundOnlyEvidence = hasBackgroundOnlyEvidence
        self.footerActivity = footerActivity
    }
}

public struct BackgroundEvidence: Equatable, Sendable {
    public var isFresh: Bool
    public var foregroundTurnActive: Bool
    public var foregroundTransitionMilliseconds: Int64?
    public var scheduledTurnActive: Bool
    public var hasActiveSubagents: Bool
    public var backgroundAgentsActive: Bool
    public var reportsTerminalDisconnect: Bool
    public var updatedAtMilliseconds: Int64?

    public init(
        isFresh: Bool,
        foregroundTurnActive: Bool,
        foregroundTransitionMilliseconds: Int64?,
        scheduledTurnActive: Bool,
        hasActiveSubagents: Bool,
        backgroundAgentsActive: Bool,
        reportsTerminalDisconnect: Bool,
        updatedAtMilliseconds: Int64?
    ) {
        self.isFresh = isFresh
        self.foregroundTurnActive = foregroundTurnActive
        self.foregroundTransitionMilliseconds = foregroundTransitionMilliseconds
        self.scheduledTurnActive = scheduledTurnActive
        self.hasActiveSubagents = hasActiveSubagents
        self.backgroundAgentsActive = backgroundAgentsActive
        self.reportsTerminalDisconnect = reportsTerminalDisconnect
        self.updatedAtMilliseconds = updatedAtMilliseconds
    }
}

public enum SessionSemantics {
    public static func promptEligibility(_ input: PromptabilityInput) -> PromptEligibility {
        guard input.hasLiveAgent else { return .noLiveAgent }
        guard !input.hasPendingQuestions, input.status != .waiting else {
            return .busy
        }
        guard !input.scheduledTurnActive || input.hasBackgroundOnlyEvidence else {
            return .busy
        }
        guard input.status != .running || input.hasBackgroundOnlyEvidence else {
            return .busy
        }
        guard input.footerActivity == .idle else { return .busy }
        return .send
    }

    public static func backgroundOnlyEvidenceMilliseconds(
        evidence: BackgroundEvidence,
        nowMilliseconds: Int64
    ) -> Int64? {
        guard evidence.isFresh,
              !evidence.foregroundTurnActive,
              evidence.scheduledTurnActive
                || evidence.hasActiveSubagents
                || evidence.backgroundAgentsActive,
              let transition = evidence.foregroundTransitionMilliseconds,
              transition <= nowMilliseconds else {
            return nil
        }
        return transition
    }

    public static func hasBackgroundOnlyPromptEvidence(
        status: SessionStatus,
        evidence: BackgroundEvidence,
        nowMilliseconds: Int64,
        promptClockMilliseconds: Int64?
    ) -> Bool {
        guard !evidence.reportsTerminalDisconnect,
              let transition = backgroundOnlyEvidenceMilliseconds(
                evidence: evidence,
                nowMilliseconds: nowMilliseconds
              ) else {
            return false
        }
        guard let promptClockMilliseconds else { return true }
        return status == .idle
            ? transition >= promptClockMilliseconds
            : transition > promptClockMilliseconds
    }

    public static func backgroundDemotionEvidenceMilliseconds(
        status: SessionStatus,
        evidence: BackgroundEvidence,
        nowMilliseconds: Int64,
        statusClockMilliseconds: Int64?
    ) -> Int64? {
        guard status == .running,
              let transition = backgroundOnlyEvidenceMilliseconds(
                evidence: evidence,
                nowMilliseconds: nowMilliseconds
              ),
              transition >= (statusClockMilliseconds ?? transition) else {
            return nil
        }
        return transition
    }

    public static func disconnectDemotionEvidenceMilliseconds(
        status: SessionStatus,
        footerActivity: FooterActivity,
        evidence: BackgroundEvidence,
        nowMilliseconds: Int64,
        statusClockMilliseconds: Int64
    ) -> Int64? {
        guard status == .running,
              footerActivity == .idle,
              evidence.isFresh,
              evidence.reportsTerminalDisconnect,
              let updatedAt = evidence.updatedAtMilliseconds,
              updatedAt <= nowMilliseconds,
              updatedAt >= statusClockMilliseconds else {
            return nil
        }
        return updatedAt
    }

    public static func foregroundRecoveryEvidenceMilliseconds(
        status: SessionStatus,
        evidence: BackgroundEvidence,
        nowMilliseconds: Int64,
        statusClockMilliseconds: Int64
    ) -> Int64? {
        guard status == .idle,
              evidence.isFresh,
              evidence.foregroundTurnActive,
              !evidence.reportsTerminalDisconnect,
              let transition = evidence.foregroundTransitionMilliseconds,
              transition <= nowMilliseconds,
              transition > statusClockMilliseconds else {
            return nil
        }
        return transition
    }

    public static func livenessShouldDemote(
        status: SessionStatus,
        hasLiveAgent: Bool
    ) -> Bool {
        (status == .running || status == .waiting) && !hasLiveAgent
    }

    public static func canPromoteIdleFromFooter(
        backgroundAgentsActive: Bool,
        hasLiveAgent: Bool,
        supportsSessionIdleHook: Bool
    ) -> Bool {
        !backgroundAgentsActive && hasLiveAgent && !supportsSessionIdleHook
    }

    public static func advancesPromptSafetyClock(source: String?) -> Bool {
        source != "scheduled-active"
    }

    public static func permissionPromptDisposition(
        status: SessionStatus,
        hasPendingQuestions: Bool,
        hasPendingPermissionRequests: Bool?
    ) -> PermissionPromptDisposition {
        guard status == .waiting else { return .cancel }
        if hasPendingPermissionRequests == true { return .post }
        guard !hasPendingQuestions else { return .cancel }
        guard let hasPendingPermissionRequests else { return .post }
        return hasPendingPermissionRequests ? .post : .suppress
    }

    public static func isCompletionSignal(
        status: SessionStatus,
        source: String?,
        notificationIsCompleted: Bool,
        scheduledTurnActive: Bool
    ) -> Bool {
        status == .idle
            && (source == "agent-stop" || notificationIsCompleted)
            && !scheduledTurnActive
    }

    public static func canPostCompletion(
        status: SessionStatus,
        footerActivity: FooterActivity?
    ) -> Bool {
        status == .idle && footerActivity != .working
    }

    public static func shouldClearPendingCompletion(
        status: SessionStatus,
        source: String?
    ) -> Bool {
        (status == .running || status == .waiting) && source != "footer"
    }
}
