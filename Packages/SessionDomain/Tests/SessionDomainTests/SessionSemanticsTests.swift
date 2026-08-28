import XCTest
@testable import SessionDomain

final class SessionSemanticsTests: XCTestCase {
    func testSessionStatusRoundTrips() throws {
        for status in SessionStatus.allCases {
            let data = try JSONEncoder().encode(status)
            XCTAssertEqual(try JSONDecoder().decode(SessionStatus.self, from: data), status)
        }
    }

    func testStatusAndPromptClocksKeepIndependentAuthority() {
        var state = SessionSemanticsState()

        XCTAssertTrue(state.shouldApplyStatusEvent(
            sessionId: "session",
            timestamp: 100,
            source: "turn-start"
        ))
        XCTAssertTrue(state.shouldApplyStatusEvent(
            sessionId: "session",
            timestamp: 200,
            source: "scheduled-active"
        ))
        XCTAssertEqual(state.statusClock.timestamp(for: "session"), 200)
        XCTAssertEqual(state.promptSafetyClock.timestamp(for: "session"), 100)
        XCTAssertFalse(state.shouldApplyStatusEvent(
            sessionId: "session",
            timestamp: 150,
            source: "turn-end"
        ))
        XCTAssertEqual(state.promptSafetyClock.timestamp(for: "session"), 100)
    }

    func testLocalClockRecordingIsMonotonicWithoutAdvancingScheduledPromptClock() {
        var state = SessionSemanticsState()
        state.statusClock.seed(sessionId: "session", timestamp: 300)
        state.promptSafetyClock.seed(sessionId: "session", timestamp: 100)

        let scheduled = state.recordLocalStatusEvent(
            sessionId: "session",
            nowMilliseconds: 200,
            source: "scheduled-active"
        )
        XCTAssertEqual(scheduled.status, 300)
        XCTAssertEqual(scheduled.promptSafety, 100)

        let foreground = state.recordLocalStatusEvent(
            sessionId: "session",
            nowMilliseconds: 250,
            source: "turn-start"
        )
        XCTAssertEqual(foreground.status, 300)
        XCTAssertEqual(foreground.promptSafety, 300)
    }

    func testOlderPermissionRestoreCannotOvershadowNewerHooks() {
        var state = SessionSemanticsState()
        XCTAssertTrue(state.shouldApplyStatusEvent(
            sessionId: "session",
            timestamp: 300,
            source: "permission-resolved"
        ))

        state.statusClock.seed(sessionId: "session", timestamp: 200)
        state.promptSafetyClock.seed(sessionId: "session", timestamp: 200)

        XCTAssertEqual(state.statusClock.timestamp(for: "session"), 300)
        XCTAssertEqual(state.promptSafetyClock.timestamp(for: "session"), 300)
    }

    func testPromptabilityBlocksPermissionAndForegroundWork() {
        XCTAssertEqual(SessionSemantics.promptEligibility(.init(
            status: .waiting,
            hasLiveAgent: true,
            footerActivity: .idle
        )), .busy)
        XCTAssertEqual(SessionSemantics.promptEligibility(.init(
            status: .running,
            hasLiveAgent: true,
            hasBackgroundOnlyEvidence: false,
            footerActivity: .idle
        )), .busy)
        XCTAssertEqual(SessionSemantics.promptEligibility(.init(
            status: .running,
            scheduledTurnActive: true,
            hasLiveAgent: true,
            hasBackgroundOnlyEvidence: true,
            footerActivity: .idle
        )), .send)
        XCTAssertEqual(SessionSemantics.promptEligibility(.init(
            status: .idle,
            hasLiveAgent: false,
            footerActivity: .idle
        )), .noLiveAgent)
    }

    func testPermissionDispositionPreservesPerFieldAuthority() {
        XCTAssertEqual(SessionSemantics.permissionPromptDisposition(
            status: .waiting,
            hasPendingQuestions: true,
            hasPendingPermissionRequests: true
        ), .post)
        XCTAssertEqual(SessionSemantics.permissionPromptDisposition(
            status: .waiting,
            hasPendingQuestions: true,
            hasPendingPermissionRequests: false
        ), .cancel)
        XCTAssertEqual(SessionSemantics.permissionPromptDisposition(
            status: .waiting,
            hasPendingQuestions: false,
            hasPendingPermissionRequests: nil
        ), .post)
        XCTAssertEqual(SessionSemantics.permissionPromptDisposition(
            status: .waiting,
            hasPendingQuestions: false,
            hasPendingPermissionRequests: false
        ), .suppress)
        XCTAssertEqual(SessionSemantics.permissionPromptDisposition(
            status: .running,
            hasPendingQuestions: false,
            hasPendingPermissionRequests: true
        ), .cancel)
    }

    func testBackgroundEvidenceRejectsStaleFutureAndOlderClockValues() {
        let current = evidence(transition: 900)
        XCTAssertEqual(SessionSemantics.backgroundOnlyEvidenceMilliseconds(
            evidence: current,
            nowMilliseconds: 1_000
        ), 900)
        XCTAssertNil(SessionSemantics.backgroundOnlyEvidenceMilliseconds(
            evidence: evidence(isFresh: false, transition: 900),
            nowMilliseconds: 1_000
        ))
        XCTAssertNil(SessionSemantics.backgroundOnlyEvidenceMilliseconds(
            evidence: evidence(transition: 1_001),
            nowMilliseconds: 1_000
        ))
        XCTAssertFalse(SessionSemantics.hasBackgroundOnlyPromptEvidence(
            status: .running,
            evidence: current,
            nowMilliseconds: 1_000,
            promptClockMilliseconds: 900
        ))
        XCTAssertEqual(SessionSemantics.backgroundDemotionEvidenceMilliseconds(
            status: .running,
            evidence: current,
            nowMilliseconds: 1_000,
            statusClockMilliseconds: 900
        ), 900)
        XCTAssertTrue(SessionSemantics.hasBackgroundOnlyPromptEvidence(
            status: .idle,
            evidence: current,
            nowMilliseconds: 1_000,
            promptClockMilliseconds: 900
        ))
        XCTAssertFalse(SessionSemantics.hasBackgroundOnlyPromptEvidence(
            status: .idle,
            evidence: evidence(transition: 900, disconnected: true),
            nowMilliseconds: 1_000,
            promptClockMilliseconds: nil
        ))
    }

    func testForegroundRecoveryUsesCausalTransitionNotHeartbeat() {
        XCTAssertEqual(SessionSemantics.foregroundRecoveryEvidenceMilliseconds(
            status: .idle,
            evidence: evidence(
                foregroundActive: true,
                transition: 900,
                updatedAt: 999
            ),
            nowMilliseconds: 1_000,
            statusClockMilliseconds: 899
        ), 900)
        XCTAssertNil(SessionSemantics.foregroundRecoveryEvidenceMilliseconds(
            status: .idle,
            evidence: evidence(
                foregroundActive: true,
                transition: 900,
                updatedAt: 999
            ),
            nowMilliseconds: 1_000,
            statusClockMilliseconds: 900
        ))
        XCTAssertNil(SessionSemantics.foregroundRecoveryEvidenceMilliseconds(
            status: .idle,
            evidence: evidence(
                foregroundActive: true,
                transition: 1_001,
                updatedAt: 999
            ),
            nowMilliseconds: 1_000,
            statusClockMilliseconds: 0
        ))
    }

    func testDisconnectNeedsIdleFooterAndCannotProveCompletion() {
        let disconnected = evidence(
            foregroundActive: true,
            transition: 800,
            disconnected: true,
            updatedAt: 950
        )
        XCTAssertEqual(SessionSemantics.disconnectDemotionEvidenceMilliseconds(
            status: .running,
            footerActivity: .idle,
            evidence: disconnected,
            nowMilliseconds: 1_000,
            statusClockMilliseconds: 900
        ), 950)
        XCTAssertNil(SessionSemantics.disconnectDemotionEvidenceMilliseconds(
            status: .running,
            footerActivity: .working,
            evidence: disconnected,
            nowMilliseconds: 1_000,
            statusClockMilliseconds: 900
        ))
        XCTAssertNil(SessionSemantics.disconnectDemotionEvidenceMilliseconds(
            status: .running,
            footerActivity: .idle,
            evidence: evidence(disconnected: true, updatedAt: 1_001),
            nowMilliseconds: 1_000,
            statusClockMilliseconds: 0
        ))
        XCTAssertFalse(SessionSemantics.isCompletionSignal(
            status: .idle,
            source: "disconnect",
            notificationIsCompleted: false,
            scheduledTurnActive: false
        ))
    }

    func testFooterAndBackgroundBackstopsRequireTwoTicks() {
        var tracker = ActivityTracker()

        XCTAssertFalse(tracker.shouldPromoteFromFooter(
            sessionId: "footer",
            currentStatus: .idle,
            activity: .working
        ))
        XCTAssertTrue(tracker.shouldPromoteFromFooter(
            sessionId: "footer",
            currentStatus: .idle,
            activity: .working
        ))
        XCTAssertFalse(tracker.observeFooter(
            sessionId: "footer",
            currentStatus: .running,
            activity: .idle
        ))
        XCTAssertTrue(tracker.observeFooter(
            sessionId: "footer",
            currentStatus: .running,
            activity: .idle
        ))

        XCTAssertFalse(tracker.observeForegroundIdle(
            sessionId: "background",
            currentStatus: .running,
            foregroundTurnActive: false
        ))
        XCTAssertFalse(tracker.observeDisconnectIdle(
            sessionId: "background",
            currentStatus: .running
        ))
        XCTAssertTrue(tracker.observeDisconnectIdle(
            sessionId: "background",
            currentStatus: .running
        ))
    }

    func testCompletionRulesDoNotLetFooterRecoveryErasePendingSignal() {
        XCTAssertTrue(SessionSemantics.isCompletionSignal(
            status: .idle,
            source: "agent-stop",
            notificationIsCompleted: false,
            scheduledTurnActive: false
        ))
        XCTAssertFalse(SessionSemantics.isCompletionSignal(
            status: .idle,
            source: "agent-stop",
            notificationIsCompleted: false,
            scheduledTurnActive: true
        ))
        XCTAssertFalse(SessionSemantics.shouldClearPendingCompletion(
            status: .running,
            source: "footer"
        ))
        XCTAssertTrue(SessionSemantics.shouldClearPendingCompletion(
            status: .waiting,
            source: "hook"
        ))
        XCTAssertTrue(SessionSemantics.canPostCompletion(
            status: .idle,
            footerActivity: .unknown
        ))
        XCTAssertFalse(SessionSemantics.canPostCompletion(
            status: .idle,
            footerActivity: .working
        ))
    }

    private func evidence(
        isFresh: Bool = true,
        foregroundActive: Bool = false,
        transition: Int64? = 900,
        scheduled: Bool = true,
        hasSubagents: Bool = false,
        backgroundAgents: Bool = false,
        disconnected: Bool = false,
        updatedAt: Int64? = 900
    ) -> BackgroundEvidence {
        BackgroundEvidence(
            isFresh: isFresh,
            foregroundTurnActive: foregroundActive,
            foregroundTransitionMilliseconds: transition,
            scheduledTurnActive: scheduled,
            hasActiveSubagents: hasSubagents,
            backgroundAgentsActive: backgroundAgents,
            reportsTerminalDisconnect: disconnected,
            updatedAtMilliseconds: updatedAt
        )
    }
}
