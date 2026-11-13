import Foundation

public enum FooterActivity: Equatable, Sendable {
    case working
    case idle
    case unknown
}

public enum ForegroundActivity: Equatable, Sendable {
    case working
    case idle
    case unknown
}

public enum PermissionPromptDisposition: Equatable, Sendable {
    case cancel
    case post
    case suppress
}

public enum SessionSemantics {
    public static func livenessShouldDemote(
        status: SessionStatus,
        hasLiveAgent: Bool
    ) -> Bool {
        (status == .running || status == .waiting) && !hasLiveAgent
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
        scheduledTurnActive: Bool
    ) -> Bool {
        status == .idle && source == "agent-stop" && !scheduledTurnActive
    }
}
