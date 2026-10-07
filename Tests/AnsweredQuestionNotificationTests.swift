import XCTest
import CopilotProjectsCore
@testable import CopilotProjectsHost

final class AnsweredQuestionNotificationTests: XCTestCase {
    private let root = "11111111-2222-3333-4444-555555555555"
    private let otherRoot = "66666666-7777-8888-9999-000000000000"
    private let epoch = "tracker:0"
    // Whole seconds, so snapshot timestamps round-trip through ISO8601 to the
    // same milliseconds `milliseconds(_:)` computes.
    private let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))

    private func milliseconds(_ offset: TimeInterval) -> Int64 {
        Int64(now.addingTimeInterval(offset).timeIntervalSince1970 * 1_000)
    }

    private func snapshot(
        at offset: TimeInterval,
        root: String? = nil,
        epoch: String? = nil,
        userInputs: [String]? = [],
        elicitations: [String]? = []
    ) -> AgentActivitySnapshot {
        var snapshot = AgentActivitySnapshot(
            schemaVersion: AgentActivitySnapshot.currentSchemaVersion,
            updatedAt: now.addingTimeInterval(offset)
                .ISO8601Format(.init(includingFractionalSeconds: true)),
            foregroundTurnActive: false,
            scheduledTurnActive: false,
            activeSubagents: [],
            schedules: [],
            idleGeneration: 0,
            lastIdleAborted: false,
            lastIdleTurnKind: nil,
            error: nil,
            trackedUserInputs: userInputs?.map {
                TrackedUserInput(
                    requestId: $0, question: "Continue?", choices: [], allowFreeform: true,
                    requestedAt: "2026-10-05T10:00:00.000Z", agentId: nil
                )
            },
            trackedElicitations: elicitations?.map {
                TrackedElicitation(
                    requestId: $0, message: "Ship it?", mode: nil, url: nil, schema: nil,
                    elicitationSource: nil, requestedAt: "2026-10-05T10:00:00.000Z", agentId: nil
                )
            },
            pendingPermissionRequestIds: []
        )
        snapshot.copilotSessionId = root ?? self.root
        snapshot.conversationEpoch = epoch ?? self.epoch
        snapshot.operationReceiptVersion = 1
        return snapshot
    }

    private func posted(
        _ requestId: String?,
        evidenceAfter offset: TimeInterval = -10,
        root: String? = nil
    ) -> PostedQuestionNotification {
        PostedQuestionNotification(
            id: UUID(),
            requestId: requestId,
            rootSessionId: root ?? self.root,
            conversationEpoch: epoch,
            evidenceAfterMilliseconds: milliseconds(offset)
        )
    }

    private func isAnswered(
        _ notification: PostedQuestionNotification,
        status: SessionStatus = .waiting,
        snapshot: AgentActivitySnapshot?,
        owner: String? = nil
    ) -> Bool {
        AnsweredQuestionNotifications.partition(
            [notification],
            status: status,
            snapshot: snapshot,
            ownerSessionId: owner ?? root,
            now: now
        ).answered == [notification.id]
    }

    func testTrackedQuestionIsAnsweredOnceANewerSnapshotOfItsEpochDropsIt() {
        let alert = posted("ask-1")
        for status in SessionStatus.allCases {
            XCTAssertFalse(isAnswered(
                alert, status: status, snapshot: snapshot(at: -5, userInputs: ["ask-1"])
            ), "\(status)")
            XCTAssertTrue(isAnswered(
                alert, status: status, snapshot: snapshot(at: -5, userInputs: ["other"])
            ), "\(status)")
        }
        let elicitation = posted("form-1")
        XCTAssertFalse(isAnswered(elicitation, snapshot: snapshot(at: -5, elicitations: ["form-1"])))
        XCTAssertTrue(isAnswered(elicitation, snapshot: snapshot(at: -5)))
    }

    func testSnapshotsThatCannotVouchForAnAnswerKeepTheAlert() {
        let alert = posted("ask-1")
        let cases: [(String, AgentActivitySnapshot?, SessionStatus)] = [
            ("older than the alert", snapshot(at: -11), .running),
            ("same snapshot as the alert", snapshot(at: -10), .running),
            ("stale", snapshot(at: -30), .running),
            ("missing", nil, .running),
            ("missing while waiting", nil, .waiting),
            ("restarted tracker", snapshot(at: -5, epoch: "tracker-2:0"), .running),
            ("no question tracking", snapshot(at: -5, userInputs: nil), .running),
            ("future dated", snapshot(at: 5), .running),
        ]
        for (name, snapshot, status) in cases {
            XCTAssertFalse(isAnswered(alert, status: status, snapshot: snapshot), name)
        }
        // A tracker that stopped vouching only counts once the turn has ended.
        XCTAssertTrue(isAnswered(alert, status: .idle, snapshot: nil))
        XCTAssertTrue(isAnswered(alert, status: .idle, snapshot: snapshot(at: -30)))
    }

    func testRestartedTrackerRebindsARecoveredQuestion() throws {
        let alert = posted("ask-1")
        let recovered = AnsweredQuestionNotifications.partition(
            [alert],
            status: .waiting,
            snapshot: snapshot(at: -5, epoch: "tracker-2:0", userInputs: ["ask-1"]),
            ownerSessionId: root,
            now: now
        )
        XCTAssertTrue(recovered.answered.isEmpty)
        let rebound = try XCTUnwrap(recovered.pending.first)
        XCTAssertEqual(rebound.conversationEpoch, "tracker-2:0")
        XCTAssertEqual(rebound.evidenceAfterMilliseconds, milliseconds(-5))

        XCTAssertFalse(isAnswered(rebound, snapshot: snapshot(at: -5, epoch: "tracker-2:0")))
        XCTAssertFalse(isAnswered(rebound, snapshot: snapshot(at: -4)))
        XCTAssertTrue(isAnswered(rebound, snapshot: snapshot(at: -4, epoch: "tracker-2:0")))
    }

    func testConversationReplacedInTheTabWithdrawsTheAlert() {
        for requestId in ["ask-1", nil] {
            let alert = posted(requestId)
            let replaced = snapshot(at: -5, root: otherRoot, userInputs: ["new"])
            XCTAssertTrue(
                isAnswered(alert, snapshot: replaced, owner: otherRoot.uppercased()),
                "\(String(describing: requestId))"
            )
            XCTAssertFalse(isAnswered(alert, snapshot: replaced, owner: root))
            XCTAssertFalse(isAnswered(alert, snapshot: snapshot(at: -11, root: otherRoot), owner: otherRoot))
        }
        // Request IDs are scoped to their conversation, so a replacement that
        // reuses one does not keep the old alert.
        let reused = snapshot(at: -5, root: otherRoot, userInputs: ["ask-1"])
        XCTAssertTrue(isAnswered(posted("ask-1"), snapshot: reused, owner: otherRoot))
        XCTAssertFalse(isAnswered(posted("ask-1"), snapshot: reused, owner: root))
        var ownerReads = 0
        _ = AnsweredQuestionNotifications.partition(
            [posted("ask-1"), posted(nil)],
            status: .waiting,
            snapshot: snapshot(at: -5, userInputs: ["ask-1"]),
            ownerSessionId: { ownerReads += 1; return self.root }(),
            now: now
        )
        XCTAssertEqual(ownerReads, 0)
    }

    func testUntrackedQuestionFollowsTheSessionLeavingTheWait() {
        let alert = posted(nil)
        XCTAssertFalse(isAnswered(alert, status: .waiting, snapshot: nil))
        XCTAssertTrue(isAnswered(alert, status: .running, snapshot: nil))
        XCTAssertTrue(isAnswered(alert, status: .idle, snapshot: snapshot(at: -30)))
        XCTAssertTrue(isAnswered(alert, status: .running, snapshot: snapshot(at: -5)))
        XCTAssertTrue(isAnswered(alert, status: .running, snapshot: snapshot(
            at: -5, userInputs: nil, elicitations: nil
        )))
        XCTAssertFalse(isAnswered(alert, status: .waiting, snapshot: snapshot(at: -5)))
        XCTAssertFalse(isAnswered(alert, status: .running, snapshot: snapshot(at: -11)))
        XCTAssertFalse(isAnswered(alert, status: .running, snapshot: snapshot(
            at: -5, userInputs: ["still-pending"]
        )))
        XCTAssertFalse(isAnswered(alert, status: .running, snapshot: snapshot(
            at: -5, elicitations: ["synthetic::durable-ask-user::call"]
        )))
    }

    func testPartitionKeepsUnansweredAlertsInOrder() {
        let first = posted("ask-1")
        let second = posted("ask-2")
        let third = posted("ask-3")
        let result = AnsweredQuestionNotifications.partition(
            [first, second, third],
            status: .waiting,
            snapshot: snapshot(at: -5, userInputs: ["ask-1", "ask-3"]),
            ownerSessionId: root,
            now: now
        )
        XCTAssertEqual(result.answered, [second.id])
        XCTAssertEqual(result.pending, [first, third])
    }

    func testAFullQuestionListNeverProvesAnAnswer() throws {
        let limit = AnsweredQuestionNotifications.trackerQuestionLimit
        let others = (1..<limit).map { "other-\($0)" }
        for (inputs, elicitations) in [
            (["ask-1"] + others, [String]()),
            (["ask-1"], ["form-1"] + others),
        ] {
            let alert = posted("ask-1")
            let full = AnsweredQuestionNotifications.partition(
                [alert],
                status: .waiting,
                snapshot: snapshot(at: -5, userInputs: inputs, elicitations: elicitations),
                ownerSessionId: root,
                now: now
            )
            let remembered = try XCTUnwrap(full.pending.first)
            XCTAssertTrue(remembered.mayBeUnlisted)
            // The tracker may have dropped it to fit a newer question, so it
            // stays even once the list shrinks again.
            XCTAssertFalse(isAnswered(remembered, snapshot: snapshot(at: -4, userInputs: others)))
            XCTAssertFalse(isAnswered(remembered, snapshot: snapshot(at: -4)))
            XCTAssertTrue(isAnswered(remembered, status: .idle, snapshot: nil))
            XCTAssertTrue(isAnswered(
                remembered, snapshot: snapshot(at: -4, root: otherRoot), owner: otherRoot
            ))
        }
        var dropped = posted("ask-1")
        dropped.mayBeUnlisted = AnsweredQuestionNotifications.mayOmitQuestions(
            snapshot(at: -10, userInputs: ["ask-1"] + others)
        )
        XCTAssertFalse(isAnswered(dropped, snapshot: snapshot(at: -5)))
        XCTAssertTrue(isAnswered(
            posted("ask-1"), snapshot: snapshot(at: -5, userInputs: Array(others.dropLast()))
        ))
    }

    func testQuestionLimitMatchesTheTracker() {
        let limit = AnsweredQuestionNotifications.trackerQuestionLimit
        XCTAssertTrue(CopilotExtension.script.contains("const MAX_USER_INPUTS = \(limit);"))
        XCTAssertTrue(CopilotExtension.script.contains("const MAX_ELICITATIONS = \(limit);"))
    }
}
