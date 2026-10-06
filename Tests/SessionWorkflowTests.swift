import AppKit
import XCTest
import CopilotProjectsCore
import CopilotProjectsProtocol
@testable import CopilotProjectsHost

final class SessionWorkflowTests: XCTestCase {
    func testActionValidationIsClosedAndBudgetLimitsAreExplicit() throws {
        XCTAssertTrue(RemoteSessionAction(kind: .send, prompt: "hello", mode: .enqueue).isValid)
        XCTAssertFalse(RemoteSessionAction(kind: .send, prompt: "hello").isValid)
        XCTAssertFalse(RemoteSessionAction(kind: .abort, prompt: "unexpected").isValid)
        XCTAssertFalse(RemoteSessionAction(kind: .setBudget, maxAiCredits: 29).isValid)
        XCTAssertFalse(RemoteSessionAction(kind: .setBudget, maxAiCredits: .infinity).isValid)
        XCTAssertTrue(RemoteSessionAction(kind: .setBudget, maxAiCredits: 30).isValid)
        XCTAssertTrue(RemoteSessionAction(kind: .setBudget).isValid)
        XCTAssertFalse(RemoteSessionAction(kind: .answerBudget, requestId: "id", additionalAiCredits: 0).isValid)
        XCTAssertTrue(RemoteSessionAction(kind: .answerBudget, requestId: "id").isValid)
        XCTAssertThrowsError(try JSONDecoder().decode(
            RemoteSessionAction.self, from: Data(#"{"kind":"arbitrary-rpc"}"#.utf8)
        ))
    }

    func testWorkflowCapabilityRequiresCurrentVersionAndFreshEvidence() {
        let date = Date()
        let workflow = RemoteSessionWorkflow(
            observedAtMilliseconds: Int64(date.timeIntervalSince1970 * 1000),
            capabilities: ["session-send"], sendReady: true
        )
        XCTAssertTrue(workflow.supports(.send, at: date))
        XCTAssertFalse(workflow.supports(.abort, at: date))
        XCTAssertFalse(workflow.supports(.send, at: date.addingTimeInterval(16)))
        XCTAssertFalse(workflow.supports(.send, at: date.addingTimeInterval(-1)))
    }

    func testRemoteFreshnessAgesFromServeTimeOnTheClientsOwnClock() {
        let observedAt: Int64 = 1_787_788_800_000
        let workflow = RemoteSessionWorkflow(
            observedAtMilliseconds: observedAt,
            capabilities: ["session-send"], sendReady: true
        )
        let receivedAt = ContinuousClock.now
        // The phone's wall clock is a minute behind the Mac, which the wall-clock
        // rule reads as an observation from the future.
        let skewedPhone = Date(timeIntervalSince1970: Double(observedAt - 60_000) / 1_000)
        XCTAssertFalse(workflow.isFresh(at: skewedPhone))
        XCTAssertTrue(workflow.supports(
            .send, servedAtMilliseconds: observedAt + 4_000, receivedAt: receivedAt,
            now: receivedAt.advanced(by: .seconds(11)), at: skewedPhone
        ))
        XCTAssertFalse(workflow.supports(
            .send, servedAtMilliseconds: observedAt + 4_000, receivedAt: receivedAt,
            now: receivedAt.advanced(by: .milliseconds(11_001)), at: skewedPhone
        ))
        // Sub-millisecond monotonic time still counts toward the limit.
        XCTAssertEqual(
            workflow.ageMilliseconds(
                servedAtMilliseconds: observedAt + 4_000, receivedAt: receivedAt,
                now: receivedAt.advanced(by: .microseconds(10_999_500))
            ),
            14_999.5
        )
        // Defaults read the current clocks: a just-received snapshot is fresh.
        XCTAssertTrue(workflow.isFresh(
            servedAtMilliseconds: observedAt, receivedAt: .now
        ))
        let current = RemoteSessionWorkflow(
            observedAtMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000),
            capabilities: ["session-send"], sendReady: true
        )
        XCTAssertTrue(current.isFresh(servedAtMilliseconds: nil, receivedAt: .now))
    }

    @MainActor
    func testNativeHostActionsUseDistinctHandoffsAndNeverInjectTerminalInput() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let session = Session(title: "Native actions", cwd: root.path)
        let project = Project(name: "Workflow test", cwd: root.path, sessions: [session])
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(projects: [project], selectedProjectId: project.id))
        let model = AppModel(
            stateRepository: repository, persistPermissionStatus: { _, _, _, _ in },
            isAppActive: { false }, agentActivityDirectory: sessions, resumeMarkerDirectory: sessions,
            remotePromptTarget: { _ in
                RemotePromptTarget(activity: .idle, send: { _ in
                    XCTFail("Native actions must not touch the terminal draft")
                    return false
                })
            },
            kittyImageDiskStore: RemoteKittyImageDiskStore(root: root.appendingPathComponent("images"))
        )
        let now = Date()
        let sdkID = UUID().uuidString
        var snapshot = AgentActivitySnapshot(
            schemaVersion: 1, updatedAt: now.ISO8601Format(.init(includingFractionalSeconds: true)),
            foregroundTurnActive: false, scheduledTurnActive: false, activeSubagents: [], schedules: [],
            idleGeneration: 0, lastIdleAborted: false, lastIdleTurnKind: nil, error: nil,
            pendingPermissionRequestIds: [], copilotSessionId: sdkID,
            conversationEpoch: "epoch-1", operationReceiptVersion: 1, operationReceipts: [],
            workflow: RemoteSessionWorkflow(
                observedAtMilliseconds: Int64(now.timeIntervalSince1970 * 1000),
                capabilities: RemoteSessionActionKind.allCases.map(\.rawValue), sendReady: true,
                limitsKnown: true
            )
        )
        let snapshotURL = sessions.appendingPathComponent("\(session.id).agent-activity.json")
        try JSONEncoder().encode(snapshot).write(to: snapshotURL)
        try Data(sdkID.utf8).write(to: sessions.appendingPathComponent("\(session.id).copilot-session"))
        let send = RemoteSessionAction(kind: .send, prompt: "native", mode: .immediate)
        let sendID = CLIOperationRequest(operationId: "send", conversationEpoch: "epoch-1")
        XCTAssertEqual(model.performSessionAction(sessionId: session.id, action: send, operation: sendID), .accepted)
        XCTAssertEqual(model.performSessionAction(sessionId: session.id, action: send, operation: sendID), .accepted)
        let stop = RemoteSessionAction(kind: .abort)
        XCTAssertEqual(model.performSessionAction(
            sessionId: session.id, action: stop,
            operation: CLIOperationRequest(operationId: "stop", conversationEpoch: "epoch-1")
        ), .accepted)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessions.appendingPathComponent("\(session.id).session-send.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessions.appendingPathComponent("\(session.id).session-abort.json").path))
        XCTAssertEqual(model.performSessionAction(sessionId: session.id, action: stop, operation: sendID), .conflict)
        XCTAssertEqual(model.performSessionAction(
            sessionId: session.id, action: send,
            operation: CLIOperationRequest(operationId: "old", conversationEpoch: "epoch-0")
        ), .conflict)
        try FileManager.default.removeItem(at: sessions.appendingPathComponent("\(session.id).session-send.json"))
        snapshot.pendingPermissionRequestIds = ["pending"]
        try JSONEncoder().encode(snapshot).write(to: snapshotURL)
        XCTAssertEqual(model.performSessionAction(
            sessionId: session.id, action: send,
            operation: CLIOperationRequest(operationId: "blocked", conversationEpoch: "epoch-1")
        ), .invalid)
    }

    func testLegacyTaskResultIsIgnoredWithoutChangingConversationHistory() throws {
        let payload = Data(#"""
        {
          "schemaVersion": 3, "updatedAt": "2026-09-16T12:00:00Z", "copilotSessionId": "sdk",
          "turns": [{
            "id": "turn", "startedAt": "2026-09-16T11:00:00Z",
            "kind": "foreground", "userContent": "Keep this conversation",
            "assistantMessages": [], "tools": [], "isAborted": false
          }],
          "latestResult": {"turnId": "turn", "summary": "Ignore this legacy result"}
        }
        """#.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(TranscriptSnapshot.self, from: payload)
        XCTAssertEqual(snapshot.turns.map(\.userContent), ["Keep this conversation"])
        let enriched = TranscriptImageAssociation.attach(
            images: [], to: snapshot.limitedToMostRecentTurns(1)
        )
        XCTAssertEqual(enriched.turns, snapshot.turns)
        XCTAssertEqual(enriched.totalTurns, 1)
        let encoded = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(enriched)) as? [String: Any]
        )
        XCTAssertNil(encoded["latestResult"])
    }

    func testLegacyTaskResultSidecarDoesNotChangeTranscriptOrRevision() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let previous = ProcessInfo.processInfo.environment["COPILOT_PROJECTS_STATE_DIR"]
        setenv("COPILOT_PROJECTS_STATE_DIR", root.path, 1)
        defer {
            if let previous { setenv("COPILOT_PROJECTS_STATE_DIR", previous, 1) }
            else { unsetenv("COPILOT_PROJECTS_STATE_DIR") }
        }
        Paths.ensureStateDir()
        let sessionID = UUID().uuidString
        let copilotID = UUID().uuidString
        let turn = TranscriptTurn(
            id: "turn", startedAt: Date(), endedAt: Date(), kind: "foreground",
            userContent: "work", assistantMessages: [], tools: [], isAborted: false
        )
        let snapshot = TranscriptSnapshot(schemaVersion: 3, updatedAt: Date(), copilotSessionId: copilotID, turns: [turn])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(snapshot).write(to: URL(fileURLWithPath: Paths.transcriptSnapshotPath(sessionId: sessionID)))
        let before = TranscriptController.loadRemoteSnapshot(sessionId: sessionID)
        XCTAssertEqual(before.turns.map(\.userContent), ["work"])
        let revision = TranscriptController.remoteRevision(sessionId: sessionID)
        let sidecar = Paths.sessionsDir.appendingPathComponent("\(sessionID).task-result.json")
        for legacyContents in [
            #"{"schemaVersion":1,"copilotSessionId":"\#(copilotID)","result":{"turnId":"turn","capturedAt":"2026-09-16T12:00:00Z","status":"finished","summary":"Old result","checks":[],"pullRequests":[]}}"#,
            "invalid legacy JSON",
        ] {
            try Data(legacyContents.utf8).write(to: sidecar)
            XCTAssertEqual(TranscriptController.loadRemoteSnapshot(sessionId: sessionID), before)
            XCTAssertEqual(TranscriptController.remoteRevision(sessionId: sessionID), revision)
            XCTAssertEqual(try String(contentsOf: sidecar, encoding: .utf8), legacyContents)
        }
    }
}
