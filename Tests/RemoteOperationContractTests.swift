import XCTest
import AppKit
@testable import copilot_projects
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
        let legacy = snapshot(at: now)
        XCTAssertEqual(legacy.remoteOperationProjection(at: now).support, .legacy)

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
        XCTAssertEqual(workspace.protocolInfo, .current)
        let session = try XCTUnwrap(workspace.projects.first?.sessions.first)
        XCTAssertEqual(session.conversationEpoch, "epoch-1")
        XCTAssertEqual(session.operationSupport, .receipts)
        XCTAssertEqual(session.operationReceipts, [])
    }

    @MainActor
    func testAllSDKOperationsKeepLegacyHandoffsAndAddCorrelatedMetadata() throws {
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
            legacy: @MainActor () -> RemoteUserInputResult,
            correlated: @MainActor (CLIOperationRequest) -> RemoteUserInputResult
        )] = [
            (
                "user-input-response.json",
                "operation-user",
                .answerUserInput,
                {
                    harness.model.answerUserInput(
                        sessionId: harness.session.id,
                        answer: userAnswer,
                        now: now
                    )
                },
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
                {
                    harness.model.answerElicitation(
                        sessionId: harness.session.id,
                        answer: elicitationAnswer,
                        now: now
                    )
                },
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
                {
                    harness.model.setModel(
                        sessionId: harness.session.id,
                        selection: modelSelection,
                        now: now
                    )
                },
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
            XCTAssertEqual(operationCase.legacy(), .accepted)
            let legacy = try handoff(suffix: operationCase.suffix, in: harness)
            XCTAssertNil(legacy["operationId"])
            XCTAssertNil(legacy["conversationEpoch"])
            XCTAssertNil(legacy["kind"])
            XCTAssertNil(legacy["payloadFingerprint"])
            try FileManager.default.removeItem(
                at: harness.sessions.appendingPathComponent(
                    "\(harness.session.id).\(operationCase.suffix)"
                )
            )

            let operation = CLIOperationRequest(
                operationId: operationCase.operationId,
                conversationEpoch: "epoch-1"
            )
            XCTAssertEqual(operationCase.correlated(operation), .accepted)
            let correlated = try handoff(suffix: operationCase.suffix, in: harness)
            XCTAssertEqual(correlated["operationId"] as? String, operation.operationId)
            XCTAssertEqual(correlated["conversationEpoch"] as? String, "epoch-1")
            XCTAssertEqual(
                correlated["kind"] as? String,
                operationCase.kind.rawValue
            )
            XCTAssertEqual((correlated["payloadFingerprint"] as? String)?.count, 64)
            try FileManager.default.removeItem(
                at: harness.sessions.appendingPathComponent(
                    "\(harness.session.id).\(operationCase.suffix)"
                )
            )
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
            .invalid
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
            .conflict
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
            .conflict
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
            .invalid
        )
        XCTAssertEqual(
            harness.model.answerUserInput(
                sessionId: harness.session.id,
                answer: answer,
                now: now
            ),
            .invalid
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

    func testControlBodyValidationRequiresBothOperationFields() throws {
        let answerData = try JSONEncoder().encode(RemoteUserInputAnswer(
            requestId: "question-1",
            answer: "Go",
            wasFreeform: false
        ))
        let answerPayload = String(decoding: answerData, as: UTF8.self)
        let legacy = RemoteClientMessage(
            type: "answer-user-input",
            clientId: "phone",
            sessionId: "session",
            data: answerPayload
        )
        XCTAssertEqual(RemoteSDKControlValidation.operation(legacy), .legacy)
        XCTAssertEqual(
            RemoteSDKControlValidation.userInputAnswer(legacy)?.requestId,
            "question-1"
        )

        let partial = RemoteClientMessage(
            type: "answer-user-input",
            clientId: "phone",
            sessionId: "session",
            requestId: "operation-1",
            data: answerPayload
        )
        XCTAssertEqual(RemoteSDKControlValidation.operation(partial), .invalid)

        let invalidToken = RemoteClientMessage(
            type: "answer-user-input",
            clientId: "phone",
            sessionId: "session",
            requestId: "operation 1",
            data: answerPayload,
            conversationEpoch: "epoch-1"
        )
        XCTAssertEqual(RemoteSDKControlValidation.operation(invalidToken), .invalid)

        let correlated = RemoteClientMessage(
            type: "answer-user-input",
            clientId: "phone",
            sessionId: "session",
            requestId: "operation-1",
            data: answerPayload,
            conversationEpoch: "epoch-1"
        )
        XCTAssertEqual(
            RemoteSDKControlValidation.operation(correlated),
            .correlated(CLIOperationRequest(
                operationId: "operation-1",
                conversationEpoch: "epoch-1"
            ))
        )
        XCTAssertEqual(
            RemoteSDKControlValidation.userInputAnswer(correlated)?.requestId,
            "question-1"
        )
        XCTAssertNil(RemoteSDKControlValidation.userInputAnswer(RemoteClientMessage(
            type: "answer-user-input",
            clientId: "phone",
            sessionId: "session",
            data: "{"
        )))
        XCTAssertNil(RemoteSDKControlValidation.elicitationAnswer(RemoteClientMessage(
            type: "answer-elicitation",
            clientId: "phone",
            sessionId: "session",
            data: "{}"
        )))
        XCTAssertNil(RemoteSDKControlValidation.modelSelection(RemoteClientMessage(
            type: "set-model",
            clientId: "phone",
            sessionId: "session",
            data: "{\"modelId\":\"\"}"
        )))
        XCTAssertEqual(
            CLIOperationAdapter.payloadFingerprint(
                kind: .answerElicitation,
                payload: RemoteElicitationAnswer(
                    requestId: "elicitation",
                    action: .accept,
                    content: ["b": .number(2), "a": .number(1)]
                )
            ),
            CLIOperationAdapter.payloadFingerprint(
                kind: .answerElicitation,
                payload: RemoteElicitationAnswer(
                    requestId: "elicitation",
                    action: .accept,
                    content: ["a": .number(1), "b": .number(2)]
                )
            )
        )
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

    func testReceiptControlsPreserveWriterLeaseGating() {
        let leases = RemoteWriterLeases()
        leases.acquire(sessionId: "session", clientId: "phone")
        XCTAssertNil(leases.withHeldLease(
            sessionId: "session",
            clientId: "laptop"
        ) {
            CLIOperationRequest(
                operationId: "operation-1",
                conversationEpoch: "epoch-1"
            )
        })
        XCTAssertEqual(leases.withHeldLease(
            sessionId: "session",
            clientId: "phone"
        ) {
            CLIOperationRequest(
                operationId: "operation-1",
                conversationEpoch: "epoch-1"
            )
        }, CLIOperationRequest(
            operationId: "operation-1",
            conversationEpoch: "epoch-1"
        ))
    }
}
