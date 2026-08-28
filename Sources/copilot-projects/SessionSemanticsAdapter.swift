import Foundation
import SessionDomain

enum SessionSemanticsAdapter {
    static func backgroundEvidence(
        snapshot: AgentActivitySnapshot,
        backgroundAgentsActive: Bool,
        now: Date
    ) -> BackgroundEvidence {
        BackgroundEvidence(
            isFresh: snapshot.isFresh(at: now),
            foregroundTurnActive: snapshot.foregroundTurnActive,
            foregroundTransitionMilliseconds:
                snapshot.foregroundTransitionMilliseconds,
            scheduledTurnActive: snapshot.scheduledTurnActive,
            hasActiveSubagents: !snapshot.activeSubagents.isEmpty,
            backgroundAgentsActive: backgroundAgentsActive,
            reportsTerminalDisconnect: snapshot.reportsTerminalDisconnect,
            updatedAtMilliseconds: snapshot.updatedAtMilliseconds
        )
    }

    static func remotePromptResult(
        status: SessionStatus,
        scheduledTurnActive: Bool,
        hasPendingQuestions: Bool,
        hasLiveAgent: Bool,
        backgroundOnly: Bool,
        footerActivity: FooterActivity
    ) -> RemotePromptResult {
        switch SessionSemantics.promptEligibility(PromptabilityInput(
            status: status,
            scheduledTurnActive: scheduledTurnActive,
            hasPendingQuestions: hasPendingQuestions,
            hasLiveAgent: hasLiveAgent,
            hasBackgroundOnlyEvidence: backgroundOnly,
            footerActivity: footerActivity
        )) {
        case .send:
            return .sent
        case .busy:
            return .busy
        case .noLiveAgent:
            return .noLiveCopilot
        }
    }

    static func backgroundOnlyEvidenceMilliseconds(
        snapshot: AgentActivitySnapshot?,
        backgroundAgentsActive: Bool,
        now: Date,
        nowMilliseconds: Int64
    ) -> Int64? {
        guard let snapshot else { return nil }
        return SessionSemantics.backgroundOnlyEvidenceMilliseconds(
            evidence: backgroundEvidence(
                snapshot: snapshot,
                backgroundAgentsActive: backgroundAgentsActive,
                now: now
            ),
            nowMilliseconds: nowMilliseconds
        )
    }

    static func hasBackgroundOnlyPromptEvidence(
        status: SessionStatus,
        snapshot: AgentActivitySnapshot?,
        backgroundAgentsActive: Bool,
        now: Date,
        nowMilliseconds: Int64,
        promptClockMilliseconds: Int64?
    ) -> Bool {
        guard let snapshot else { return false }
        return SessionSemantics.hasBackgroundOnlyPromptEvidence(
            status: status,
            evidence: backgroundEvidence(
                snapshot: snapshot,
                backgroundAgentsActive: backgroundAgentsActive,
                now: now
            ),
            nowMilliseconds: nowMilliseconds,
            promptClockMilliseconds: promptClockMilliseconds
        )
    }

    static func backgroundDemotionEvidenceMilliseconds(
        status: SessionStatus,
        snapshot: AgentActivitySnapshot?,
        backgroundAgentsActive: Bool,
        now: Date,
        nowMilliseconds: Int64,
        statusClockMilliseconds: Int64?
    ) -> Int64? {
        guard let snapshot else { return nil }
        return SessionSemantics.backgroundDemotionEvidenceMilliseconds(
            status: status,
            evidence: backgroundEvidence(
                snapshot: snapshot,
                backgroundAgentsActive: backgroundAgentsActive,
                now: now
            ),
            nowMilliseconds: nowMilliseconds,
            statusClockMilliseconds: statusClockMilliseconds
        )
    }

    static func disconnectDemotionEvidenceMilliseconds(
        status: SessionStatus,
        footerActivity: FooterActivity,
        snapshot: AgentActivitySnapshot?,
        now: Date,
        nowMilliseconds: Int64,
        statusClockMilliseconds: Int64
    ) -> Int64? {
        guard let snapshot else { return nil }
        return SessionSemantics.disconnectDemotionEvidenceMilliseconds(
            status: status,
            footerActivity: footerActivity,
            evidence: backgroundEvidence(
                snapshot: snapshot,
                backgroundAgentsActive: false,
                now: now
            ),
            nowMilliseconds: nowMilliseconds,
            statusClockMilliseconds: statusClockMilliseconds
        )
    }

    static func foregroundRecoveryEvidenceMilliseconds(
        status: SessionStatus,
        snapshot: AgentActivitySnapshot?,
        now: Date,
        nowMilliseconds: Int64,
        statusClockMilliseconds: Int64
    ) -> Int64? {
        guard let snapshot else { return nil }
        return SessionSemantics.foregroundRecoveryEvidenceMilliseconds(
            status: status,
            evidence: backgroundEvidence(
                snapshot: snapshot,
                backgroundAgentsActive: false,
                now: now
            ),
            nowMilliseconds: nowMilliseconds,
            statusClockMilliseconds: statusClockMilliseconds
        )
    }

    static func permissionDecision(
        status: SessionStatus,
        hasPendingQuestions: Bool,
        hasPendingPermissionRequests: Bool?
    ) -> PermissionNotificationDecision {
        switch SessionSemantics.permissionPromptDisposition(
            status: status,
            hasPendingQuestions: hasPendingQuestions,
            hasPendingPermissionRequests: hasPendingPermissionRequests
        ) {
        case .cancel:
            return .cancel
        case .post:
            return .post
        case .suppress:
            return .suppress
        }
    }

}
