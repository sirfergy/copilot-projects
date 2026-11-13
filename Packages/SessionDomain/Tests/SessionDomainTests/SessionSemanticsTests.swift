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

    func testOnlyAnAgentStopOutsideAScheduledTurnIsACompletionSignal() {
        XCTAssertTrue(SessionSemantics.isCompletionSignal(
            status: .idle,
            source: "agent-stop",
            scheduledTurnActive: false
        ))
        XCTAssertFalse(SessionSemantics.isCompletionSignal(
            status: .idle,
            source: "agent-stop",
            scheduledTurnActive: true
        ))
        XCTAssertFalse(SessionSemantics.isCompletionSignal(
            status: .idle,
            source: "session-end",
            scheduledTurnActive: false
        ))
    }
}
