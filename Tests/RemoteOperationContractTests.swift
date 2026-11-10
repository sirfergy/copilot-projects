import XCTest
import AppKit
@testable import CopilotProjectsHost
import CopilotProjectsProtocol

final class RemoteOperationContractTests: XCTestCase {
    private struct Harness {
        let root: URL
        let sessions: URL
        let session: Session
        let model: AppModel
    }

    private func snapshot(
        at date: Date,
        error: String? = nil,
        userInputs: [TrackedUserInput]? = nil,
        elicitations: [TrackedElicitation]? = nil,
        pendingPermissionRequestIds: [String]? = nil,
        availableModels: [TrackedAvailableModel]? = nil,
        copilotSessionId: String? = nil,
        conversationEpoch: String? = nil,
        operationReceiptVersion: Int? = nil,
        operationReceipts: [TrackedOperationReceipt]? = nil
    ) -> AgentActivitySnapshot {
        AgentActivitySnapshot(
            schemaVersion: AgentActivitySnapshot.currentSchemaVersion,
            updatedAt: date.ISO8601Format(.init(includingFractionalSeconds: true)),
            foregroundTurnActive: false,
            scheduledTurnActive: false,
            activeSubagents: [],
            schedules: [],
            idleGeneration: 0,
            lastIdleAborted: false,
            lastIdleTurnKind: nil,
            error: error,
            trackedUserInputs: userInputs,
            trackedElicitations: elicitations,
            pendingPermissionRequestIds: pendingPermissionRequestIds,
            availableModels: availableModels,
            copilotSessionId: copilotSessionId,
            conversationEpoch: conversationEpoch,
            operationReceiptVersion: operationReceiptVersion,
            operationReceipts: operationReceipts
        )
    }

    @MainActor
    private func makeHarness(
        sessionId: String = UUID().uuidString,
        remotePromptLiveSessions: ((Set<String>) -> Set<String>)? = nil,
        remoteElicitationTarget:
            ((String) -> RemoteElicitationTerminalTarget?)? = nil
    ) throws -> Harness {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sessions,
            withIntermediateDirectories: true
        )
        let session = Session(id: sessionId, title: "Operation test", cwd: root.path)
        let project = Project(
            id: "operation-project",
            name: "Operation project",
            cwd: root.path,
            sessions: [session]
        )
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(
            projects: [project],
            selectedProjectId: project.id
        ))
        let model = AppModel(
            stateRepository: repository,
            persistPermissionStatus: { _, _, _, _ in },
            isAppActive: { false },
            agentActivityDirectory: sessions,
            resumeMarkerDirectory: sessions,
            remotePromptLiveSessions: remotePromptLiveSessions,
            remoteElicitationTarget: remoteElicitationTarget,
            kittyImageDiskStore: RemoteKittyImageDiskStore(
                root: root.appendingPathComponent("kitty-images", isDirectory: true)
            )
        )
        return Harness(root: root, sessions: sessions, session: session, model: model)
    }

    private func write(
        _ snapshot: AgentActivitySnapshot,
        to harness: Harness
    ) throws {
        try JSONEncoder().encode(snapshot).write(
            to: harness.sessions.appendingPathComponent(
                "\(harness.session.id).agent-activity.json"
            )
        )
    }

    private func writeMarker(_ value: String, to harness: Harness) throws {
        try Data(value.utf8).write(
            to: harness.sessions.appendingPathComponent(
                "\(harness.session.id).copilot-session"
            )
        )
    }

    private func handoff(
        suffix: String,
        in harness: Harness
    ) throws -> [String: Any] {
        let data = try Data(contentsOf: harness.sessions.appendingPathComponent(
            "\(harness.session.id).\(suffix)"
        ))
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }

    func testWorkspaceNegotiatesFreshTrackerStateAndBoundsCurrentEpochReceipts() throws {
        let now = Date()
        let receiptless = snapshot(at: now)
        XCTAssertEqual(receiptless.remoteOperationProjection(at: now).support, .unavailable)

        var receipts = (0..<70).map { index in
            TrackedOperationReceipt(
                operationId: "terminal-\(index)",
                conversationEpoch: "epoch-1",
                kind: CLISDKOperationKind.answerUserInput.rawValue,
                state: .applied,
                updatedAtMilliseconds: Int64(index + 10),
                errorCode: nil,
                payloadFingerprint: "fingerprint-\(index)"
            )
        }

        receipts.append(TrackedOperationReceipt(
            operationId: "accepted",
            conversationEpoch: "epoch-1",
            kind: CLISDKOperationKind.setModel.rawValue,
            state: .accepted,
            updatedAtMilliseconds: 1,
            errorCode: nil,
            payloadFingerprint: "accepted-fingerprint"
        ))
        receipts.append(TrackedOperationReceipt(
            operationId: "old-epoch",
            conversationEpoch: "epoch-0",
            kind: CLISDKOperationKind.answerElicitation.rawValue,
            state: .indeterminate,
            updatedAtMilliseconds: 100,
            errorCode: "transport-lost",
            payloadFingerprint: "old"
        ))
        let current = snapshot(
            at: now,
            copilotSessionId: "sdk-session",
            conversationEpoch: "epoch-1",
            operationReceiptVersion: 1,
            operationReceipts: receipts
        )
        let projection = current.remoteOperationProjection(at: now)
        XCTAssertEqual(projection.support, .receipts)
        XCTAssertEqual(projection.conversationEpoch, "epoch-1")
        XCTAssertEqual(projection.receipts?.count, 64)
        XCTAssertFalse(projection.receipts?.contains { $0.operationId == "accepted" } == true)
        XCTAssertEqual(
            projection.receipts?.first?.operationId,
            "terminal-69",
            "terminal outcomes must win the bounded projection over accepted receipts"
        )
        XCTAssertTrue(projection.receipts?.allSatisfy {
            $0.conversationEpoch == "epoch-1"
        } == true)
        XCTAssertFalse(projection.receipts?.contains {
            $0.operationId == "old-epoch"
        } == true)

        XCTAssertEqual(
            snapshot(
                at: now.addingTimeInterval(-30),
                copilotSessionId: "sdk-session",
                conversationEpoch: "epoch-1",
                operationReceiptVersion: 1
            ).remoteOperationProjection(at: now).support,
            .unavailable
        )
        XCTAssertEqual(
            snapshot(
                at: now,
                error: "Connection is disposed",
                copilotSessionId: "sdk-session",
                conversationEpoch: "epoch-1",
                operationReceiptVersion: 1
            ).remoteOperationProjection(at: now).support,
            .unavailable
        )
        XCTAssertEqual(
            snapshot(
                at: now,
                copilotSessionId: "sdk-session",
                operationReceiptVersion: 1
            ).remoteOperationProjection(at: now).support,
            .unavailable
        )
    }

    func testReceiptProjectionOrderingIsStableWhenTimestampsTie() {
        let now = Date()
        let operationIds: [String] = ["zeta", "alpha", "middle"]
        let receipts = operationIds.map { operationId in
            TrackedOperationReceipt(
                operationId: operationId,
                conversationEpoch: "epoch-1",
                kind: CLISDKOperationKind.answerUserInput.rawValue,
                state: .applied,
                updatedAtMilliseconds: 10,
                errorCode: nil,
                payloadFingerprint: "fingerprint-\(operationId)"
            )
        }
        let projection = snapshot(
            at: now,
            copilotSessionId: "sdk-session",
            conversationEpoch: "epoch-1",
            operationReceiptVersion: 1,
            operationReceipts: receipts
        ).remoteOperationProjection(at: now)

        XCTAssertEqual(
            projection.receipts?.map(\.operationId),
            ["alpha", "middle", "zeta"]
        )
    }

    @MainActor
    func testWorkspacePublishesCurrentProtocolAndReceiptState() throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let now = Date()
        try write(snapshot(
            at: now,
            copilotSessionId: "sdk-session",
            conversationEpoch: "epoch-1",
            operationReceiptVersion: 1,
            operationReceipts: []
        ), to: harness)

        harness.model.refreshAgentActivitySnapshots(now: now)
        let workspace = harness.model.remoteWorkspaceSnapshot()
        XCTAssertEqual(
            workspace.protocolInfo,
            .current.supportingReplaySafeControl(epoch: harness.model.remoteControlDeliveryEpoch)
        )
        let session = try XCTUnwrap(workspace.projects.first?.sessions.first)
        XCTAssertEqual(session.conversationEpoch, "epoch-1")
        XCTAssertEqual(session.operationSupport, .receipts)
        XCTAssertEqual(session.operationReceipts, [])
    }

    @MainActor
    func testSDKOperationsRefuseAMissingIdentityAndWriteCorrelatedMetadata() throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let now = Date()
        let userAnswer = RemoteUserInputAnswer(
            requestId: "question-1",
            answer: "Go",
            wasFreeform: false
        )
        let elicitationAnswer = RemoteElicitationAnswer(
            requestId: "elicitation-1",
            action: .accept,
            content: ["fruit": .string("apple")]
        )
        let modelSelection = RemoteModelSelection(
            modelId: "gpt-5.6-sol",
            reasoningEffort: "high",
            contextTier: "long_context"
        )
        try write(snapshot(
            at: now,
            userInputs: [TrackedUserInput(
                requestId: userAnswer.requestId,
                question: "Continue?",
                choices: ["Go", "Wait"],
                allowFreeform: false,
                requestedAt: now.ISO8601Format(.init(includingFractionalSeconds: true)),
                agentId: nil
            )],
            elicitations: [TrackedElicitation(
                requestId: elicitationAnswer.requestId,
                message: "Pick a fruit",
                mode: "form",
                url: nil,
                schema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "fruit": .object(["type": .string("string")])
                    ]),
                ]),
                elicitationSource: nil,
                requestedAt: now.ISO8601Format(.init(includingFractionalSeconds: true)),
                agentId: nil
            )],
            availableModels: [TrackedAvailableModel(
                id: modelSelection.modelId,
                name: "GPT-5.6 Sol",
                supportedReasoningEfforts: ["high"],
                defaultReasoningEffort: "high",
                longContextAvailable: true,
                disabled: false,
                category: "versatile"
            )],
            copilotSessionId: "sdk-session",
            conversationEpoch: "epoch-1",
            operationReceiptVersion: 1,
            operationReceipts: []
        ), to: harness)
        try writeMarker("sdk-session", to: harness)

        let cases: [(
            suffix: String,
            operationId: String,
            kind: CLISDKOperationKind,
            submit: @MainActor (CLIOperationRequest?) -> RemoteUserInputResult
        )] = [
            (
                "user-input-response.json",
                "operation-user",
                .answerUserInput,
                { operation in
                    harness.model.answerUserInput(
                        sessionId: harness.session.id,
                        answer: userAnswer,
                        operation: operation,
                        now: now
                    )
                }
            ),
            (
                "elicitation-response.json",
                "operation-elicitation",
                .answerElicitation,
                { operation in
                    harness.model.answerElicitation(
                        sessionId: harness.session.id,
                        answer: elicitationAnswer,
                        operation: operation,
                        now: now
                    )
                }
            ),
            (
                "set-model-request.json",
                "operation-model",
                .setModel,
                { operation in
                    harness.model.setModel(
                        sessionId: harness.session.id,
                        selection: modelSelection,
                        operation: operation,
                        now: now
                    )
                }
            ),
        ]

        for operationCase in cases {
            let handoffPath = harness.sessions.appendingPathComponent(
                "\(harness.session.id).\(operationCase.suffix)"
            ).path
            // Without an operation identity the tracker could not publish a receipt.
            XCTAssertEqual(operationCase.submit(nil), .invalid)
            XCTAssertFalse(FileManager.default.fileExists(atPath: handoffPath))

            let operation = CLIOperationRequest(
                operationId: operationCase.operationId,
                conversationEpoch: "epoch-1"
            )
            XCTAssertEqual(operationCase.submit(operation), .accepted)
            let correlated = try handoff(suffix: operationCase.suffix, in: harness)
            XCTAssertEqual(correlated["operationId"] as? String, operation.operationId)
            XCTAssertEqual(correlated["conversationEpoch"] as? String, "epoch-1")
            XCTAssertEqual(
                correlated["kind"] as? String,
                operationCase.kind.rawValue
            )
            XCTAssertEqual((correlated["payloadFingerprint"] as? String)?.count, 64)
            try FileManager.default.removeItem(atPath: handoffPath)
        }
    }

    @MainActor
    func testCorrelatedOperationsRejectExpiredEpochAndSessionTupleChanges() throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let now = Date()
        let answer = RemoteUserInputAnswer(
            requestId: "question-1",
            answer: "Go",
            wasFreeform: false
        )
        let input = TrackedUserInput(
            requestId: answer.requestId,
            question: "Continue?",
            choices: ["Go"],
            allowFreeform: false,
            requestedAt: now.ISO8601Format(.init(includingFractionalSeconds: true)),
            agentId: nil
        )
        let operation = CLIOperationRequest(
            operationId: "operation-1",
            conversationEpoch: "epoch-1"
        )
        try writeMarker("sdk-session", to: harness)

        try write(snapshot(
            at: now.addingTimeInterval(-30),
            userInputs: [input],
            copilotSessionId: "sdk-session",
            conversationEpoch: "epoch-1",
            operationReceiptVersion: 1
        ), to: harness)
        XCTAssertEqual(
            harness.model.answerUserInput(
                sessionId: harness.session.id,
                answer: answer,
                operation: operation,
                now: now
            ),
            .conflict
        )

        try write(snapshot(
            at: now,
            userInputs: [input],
            copilotSessionId: "sdk-session",
            conversationEpoch: "epoch-2",
            operationReceiptVersion: 1
        ), to: harness)
        XCTAssertEqual(
            harness.model.answerUserInput(
                sessionId: harness.session.id,
                answer: answer,
                operation: operation,
                now: now
            ),
            .epochMismatch
        )

        try write(snapshot(
            at: now,
            userInputs: [input],
            copilotSessionId: "different-sdk-session",
            conversationEpoch: "epoch-1",
            operationReceiptVersion: 1
        ), to: harness)
        XCTAssertEqual(
            harness.model.answerUserInput(
                sessionId: harness.session.id,
                answer: answer,
                operation: operation,
                now: now
            ),
            .epochMismatch
        )

        try write(snapshot(
            at: now,
            userInputs: [input],
            copilotSessionId: "sdk-session",
            operationReceiptVersion: 1
        ), to: harness)
        XCTAssertEqual(
            harness.model.answerUserInput(
                sessionId: harness.session.id,
                answer: answer,
                operation: operation,
                now: now
            ),
            .conflict
        )
    }

    @MainActor
    func testExistingHandoffWithSameOperationIdAndDifferentEpochIsAConflict() throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let now = Date()
        let answer = RemoteUserInputAnswer(
            requestId: "question-1",
            answer: "Go",
            wasFreeform: false
        )
        let input = TrackedUserInput(
            requestId: answer.requestId,
            question: "Continue?",
            choices: ["Go"],
            allowFreeform: false,
            requestedAt: now.ISO8601Format(.init(includingFractionalSeconds: true)),
            agentId: nil
        )
        try writeMarker("sdk-session", to: harness)
        try write(snapshot(
            at: now,
            userInputs: [input],
            copilotSessionId: "sdk-session",
            conversationEpoch: "epoch-1",
            operationReceiptVersion: 1,
            operationReceipts: []
        ), to: harness)
        let first = CLIOperationRequest(
            operationId: "operation-1",
            conversationEpoch: "epoch-1"
        )
        XCTAssertEqual(
            harness.model.answerUserInput(
                sessionId: harness.session.id,
                answer: answer,
                operation: first,
                now: now
            ),
            .accepted
        )

        try write(snapshot(
            at: now,
            userInputs: [input],
            copilotSessionId: "sdk-session",
            conversationEpoch: "epoch-2",
            operationReceiptVersion: 1,
            operationReceipts: []
        ), to: harness)
        let reused = CLIOperationRequest(
            operationId: first.operationId,
            conversationEpoch: "epoch-2"
        )
        XCTAssertEqual(
            harness.model.answerUserInput(
                sessionId: harness.session.id,
                answer: answer,
                operation: reused,
                now: now
            ),
            .conflict
        )
    }

    /// A client whose reply is lost resends the same identity until it gets an
    /// answer other than 409. Each retry here is one the readiness gates alone refuse.
    @MainActor
    func testSessionSendRetryWithTheSameIdentityGetsTheFirstAnswer() throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let now = Date()
        let stale = now.addingTimeInterval(30)
        let prompt = RemoteSessionAction(kind: .send, prompt: "hello", mode: .enqueue)
        let changed = RemoteSessionAction(kind: .send, prompt: "goodbye", mode: .enqueue)
        let first = CLIOperationRequest(operationId: "send-1", conversationEpoch: "epoch-1")
        let second = CLIOperationRequest(operationId: "send-2", conversationEpoch: "epoch-1")
        let handoffURL = harness.sessions.appendingPathComponent(
            "\(harness.session.id).session-send.json"
        )
        func tracker(
            epoch: String = "epoch-1",
            error: String? = nil,
            receipts: [TrackedOperationReceipt] = []
        ) -> AgentActivitySnapshot {
            var value = snapshot(
                at: now, error: error, copilotSessionId: "sdk-session", conversationEpoch: epoch,
                operationReceiptVersion: 1, operationReceipts: receipts
            )
            value.workflow = RemoteSessionWorkflow(
                observedAtMilliseconds: Int64(now.timeIntervalSince1970 * 1_000),
                capabilities: [RemoteSessionActionKind.send.rawValue], sendReady: true
            )
            return value
        }
        @MainActor func send(
            _ action: RemoteSessionAction, _ operation: CLIOperationRequest, at date: Date
        ) -> RemoteUserInputResult {
            harness.model.performSessionAction(
                sessionId: harness.session.id, action: action, operation: operation, now: date
            )
        }
        try writeMarker("sdk-session", to: harness)
        try write(tracker(), to: harness)

        // The reply is lost after the handoff is written, and by the retry the
        // tracker's snapshot is too old to judge. The one handoff stays as it was.
        XCTAssertEqual(send(prompt, first, at: now), .accepted)
        let written = try Data(contentsOf: handoffURL)
        XCTAssertEqual(send(prompt, first, at: stale), .accepted)
        XCTAssertEqual(send(changed, first, at: now), .conflict)
        XCTAssertEqual(try Data(contentsOf: handoffURL), written)

        // The tracker takes the handoff and publishes its receipt, then loses its CLI.
        try FileManager.default.removeItem(at: handoffURL)
        try write(tracker(error: "Connection is closed", receipts: [TrackedOperationReceipt(
            operationId: first.operationId,
            conversationEpoch: first.conversationEpoch,
            kind: CLISDKOperationKind.sessionSend.rawValue,
            state: .applied,
            updatedAtMilliseconds: 10,
            errorCode: nil,
            payloadFingerprint: CLIOperationAdapter.payloadFingerprint(kind: .sessionSend, payload: prompt)
        )]), to: harness)
        XCTAssertEqual(send(prompt, first, at: now), .accepted)
        XCTAssertEqual(send(prompt, first, at: stale), .accepted)
        XCTAssertEqual(send(changed, first, at: now), .conflict)
        // A send that never landed, retried while the tracker is gone: try again.
        XCTAssertEqual(send(prompt, second, at: now), .conflict)
        XCTAssertFalse(FileManager.default.fileExists(atPath: handoffURL.path))

        // A new snapshot that is already too old to judge: try again, not 422.
        try write(tracker(), to: harness)
        XCTAssertEqual(send(prompt, second, at: stale), .conflict)
        XCTAssertFalse(FileManager.default.fileExists(atPath: handoffURL.path))

        // `/new` clears the receipts and names a new epoch: final for both.
        try write(tracker(epoch: "epoch-2"), to: harness)
        XCTAssertEqual(send(prompt, first, at: now), .epochMismatch)
        XCTAssertEqual(send(prompt, second, at: now), .epochMismatch)
        XCTAssertFalse(FileManager.default.fileExists(atPath: handoffURL.path))
    }

    @MainActor
    func testSyntheticTerminalDefaultRejectsReceiptModeWithoutInvokingTerminal() throws {
        let sessionId = "synthetic-session"
        let request = TrackedElicitation(
            requestId: "synthetic::durable-ask-user::operation",
            message: "Rerun failed jobs?",
            mode: "terminal-default",
            url: nil,
            schema: .object([
                "x-copilot-projects-terminal-default": .bool(true),
                "properties": .object([
                    "rerun": .object([
                        "type": .string("boolean"),
                        "default": .bool(true),
                    ]),
                ]),
            ]),
            elicitationSource: "durable-ask-user",
            requestedAt: Date().ISO8601Format(.init(includingFractionalSeconds: true)),
            agentId: nil
        )
        let answer = RemoteElicitationAnswer(
            requestId: request.requestId,
            action: .accept,
            content: ["rerun": .bool(true)]
        )
        var enterCount = 0
        let screen = RemoteTerminalScreen(
            sessionId: sessionId,
            cols: 80,
            rows: 4,
            scrollMode: .terminal,
            historyStartLine: 0,
            firstLine: 0,
            liveTopLine: 0,
            reset: true,
            lines: [
                "Copilot needs information.",
                "Rerun failed jobs?",
                "❯ Yes",
                "  No",
            ]
        )
        let harness = try makeHarness(
            sessionId: sessionId,
            remotePromptLiveSessions: { _ in [sessionId] },
            remoteElicitationTarget: { requestedSessionId in
                guard requestedSessionId == sessionId else { return nil }
                return RemoteElicitationTerminalTarget(
                    isAtLiveBottom: true,
                    screen: screen,
                    sendEnter: {
                        enterCount += 1
                        return true
                    }
                )
            }
        )
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let now = Date()
        try write(snapshot(
            at: now,
            elicitations: [request],
            pendingPermissionRequestIds: [],
            copilotSessionId: "sdk-session",
            conversationEpoch: "epoch-1",
            operationReceiptVersion: 1,
            operationReceipts: []
        ), to: harness)
        harness.model.setStatus(
            sessionId: sessionId,
            status: .waiting,
            text: nil,
            timestamp: 1
        )

        XCTAssertEqual(
            harness.model.answerElicitation(
                sessionId: sessionId,
                answer: answer,
                operation: CLIOperationRequest(
                    operationId: "operation-1",
                    conversationEpoch: "epoch-1"
                ),
                now: now
            ),
            .conflict
        )
        XCTAssertEqual(enterCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.sessions
            .appendingPathComponent("\(sessionId).elicitation-response.json").path))

        XCTAssertEqual(
            harness.model.answerElicitation(
                sessionId: sessionId,
                answer: answer,
                operation: nil,
                now: now
            ),
            .accepted
        )
        XCTAssertEqual(enterCount, 1)
    }

    @MainActor
    func testDuplicateOperationIdsReplayOnlyTheSameKindEpochAndPayload() throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let now = Date()
        let operation = CLIOperationRequest(
            operationId: "operation-1",
            conversationEpoch: "epoch-1"
        )
        let answer = RemoteUserInputAnswer(
            requestId: "question-1",
            answer: "Go",
            wasFreeform: false
        )
        let changedAnswer = RemoteUserInputAnswer(
            requestId: "question-1",
            answer: "Wait",
            wasFreeform: false
        )
        let input = TrackedUserInput(
            requestId: answer.requestId,
            question: "Continue?",
            choices: ["Go", "Wait"],
            allowFreeform: false,
            requestedAt: now.ISO8601Format(.init(includingFractionalSeconds: true)),
            agentId: nil
        )
        try writeMarker("sdk-session", to: harness)
        try write(snapshot(
            at: now,
            userInputs: [input],
            copilotSessionId: "sdk-session",
            conversationEpoch: "epoch-1",
            operationReceiptVersion: 1,
            operationReceipts: []
        ), to: harness)

        XCTAssertEqual(
            harness.model.answerUserInput(
                sessionId: harness.session.id,
                answer: answer,
                operation: operation,
                now: now
            ),
            .accepted
        )
        XCTAssertEqual(
            harness.model.answerUserInput(
                sessionId: harness.session.id,
                answer: answer,
                operation: operation,
                now: now
            ),
            .accepted
        )
        XCTAssertEqual(
            harness.model.answerUserInput(
                sessionId: harness.session.id,
                answer: changedAnswer,
                operation: operation,
                now: now
            ),
            .conflict
        )
        XCTAssertEqual(
            harness.model.setModel(
                sessionId: harness.session.id,
                selection: RemoteModelSelection(modelId: "gpt-5.6-sol"),
                operation: operation,
                now: now
            ),
            .conflict
        )

        let responseURL = harness.sessions.appendingPathComponent(
            "\(harness.session.id).user-input-response.json"
        )
        try FileManager.default.removeItem(at: responseURL)
        let fingerprint = try XCTUnwrap(CLIOperationAdapter.payloadFingerprint(
            kind: .answerUserInput,
            payload: answer
        ))
        try write(snapshot(
            at: now,
            userInputs: nil,
            copilotSessionId: "sdk-session",
            conversationEpoch: "epoch-1",
            operationReceiptVersion: 1,
            operationReceipts: [TrackedOperationReceipt(
                operationId: operation.operationId,
                conversationEpoch: operation.conversationEpoch,
                kind: CLISDKOperationKind.answerUserInput.rawValue,
                state: .applied,
                updatedAtMilliseconds: 10,
                errorCode: nil,
                payloadFingerprint: fingerprint
            )]
        ), to: harness)
        XCTAssertEqual(
            harness.model.answerUserInput(
                sessionId: harness.session.id,
                answer: answer,
                operation: operation,
                now: now
            ),
            .accepted
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: responseURL.path))
        XCTAssertEqual(
            harness.model.answerUserInput(
                sessionId: harness.session.id,
                answer: changedAnswer,
                operation: operation,
                now: now
            ),
            .conflict
        )
    }

    @MainActor
    func testReceiptsFromAnotherKindConflictAndAnotherEpochCannotDriveReplay() throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let now = Date()
        let operation = CLIOperationRequest(
            operationId: "operation-1",
            conversationEpoch: "epoch-1"
        )
        let answer = RemoteUserInputAnswer(
            requestId: "question-1",
            answer: "Go",
            wasFreeform: false
        )
        let input = TrackedUserInput(
            requestId: answer.requestId,
            question: "Continue?",
            choices: ["Go"],
            allowFreeform: false,
            requestedAt: now.ISO8601Format(.init(includingFractionalSeconds: true)),
            agentId: nil
        )
        let fingerprint = try XCTUnwrap(CLIOperationAdapter.payloadFingerprint(
            kind: .answerUserInput,
            payload: answer
        ))
        try writeMarker("sdk-session", to: harness)
        try write(snapshot(
            at: now,
            userInputs: [input],
            copilotSessionId: "sdk-session",
            conversationEpoch: "epoch-1",
            operationReceiptVersion: 1,
            operationReceipts: [TrackedOperationReceipt(
                operationId: operation.operationId,
                conversationEpoch: operation.conversationEpoch,
                kind: CLISDKOperationKind.setModel.rawValue,
                state: .applied,
                updatedAtMilliseconds: 10,
                errorCode: nil,
                payloadFingerprint: fingerprint
            )]
        ), to: harness)
        XCTAssertEqual(
            harness.model.answerUserInput(
                sessionId: harness.session.id,
                answer: answer,
                operation: operation,
                now: now
            ),
            .conflict
        )

        try write(snapshot(
            at: now,
            userInputs: [input],
            copilotSessionId: "sdk-session",
            conversationEpoch: "epoch-1",
            operationReceiptVersion: 1,
            operationReceipts: [TrackedOperationReceipt(
                operationId: operation.operationId,
                conversationEpoch: "epoch-0",
                kind: CLISDKOperationKind.answerUserInput.rawValue,
                state: .applied,
                updatedAtMilliseconds: 10,
                errorCode: nil,
                payloadFingerprint: fingerprint
            )]
        ), to: harness)
        XCTAssertEqual(
            harness.model.answerUserInput(
                sessionId: harness.session.id,
                answer: answer,
                operation: operation,
                now: now
            ),
            .accepted
        )
        let projection = snapshot(
            at: now,
            copilotSessionId: "sdk-session",
            conversationEpoch: "epoch-1",
            operationReceiptVersion: 1,
            operationReceipts: [TrackedOperationReceipt(
                operationId: operation.operationId,
                conversationEpoch: "epoch-0",
                kind: CLISDKOperationKind.answerUserInput.rawValue,
                state: .applied,
                updatedAtMilliseconds: 10,
                errorCode: nil,
                payloadFingerprint: fingerprint
            )]
        ).remoteOperationProjection(at: now)
        XCTAssertEqual(projection.receipts, [])
    }

}
