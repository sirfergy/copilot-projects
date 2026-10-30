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
        XCTAssertTrue(RemoteSessionAction(kind: .bounce).isValid)
        XCTAssertFalse(RemoteSessionAction(kind: .bounce, prompt: "/quit").isValid)
        XCTAssertFalse(RemoteSessionAction(kind: .bounce, mode: .immediate).isValid)
        XCTAssertFalse(RemoteSessionAction(kind: .bounce, attachmentIds: [UUID().uuidString]).isValid)
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

    func testBounceRequiresExplicitStateAndPendingBounceDisablesAllActions() {
        let now = Date()
        let observed = Int64(now.timeIntervalSince1970 * 1_000)
        let received = ContinuousClock.now
        for marker in [nil, false, true] as [Bool?] {
            let workflow = RemoteSessionWorkflow(
                observedAtMilliseconds: observed,
                capabilities: RemoteSessionActionKind.allCases.map(\.rawValue),
                sendReady: true, bounceRequested: marker
            )
            for kind in RemoteSessionActionKind.allCases {
                let expected = kind == .bounce ? marker == false : marker != true
                XCTAssertEqual(workflow.supports(kind, at: now), expected)
                XCTAssertEqual(workflow.supports(
                    kind, servedAtMilliseconds: observed, receivedAt: received, now: received, at: now
                ), expected)
            }
        }
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
            remotePromptLiveSessions: { _ in [session.id] },
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
                bounceRequested: false,
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
        let bounce = RemoteSessionAction(kind: .bounce)
        let bounceID = CLIOperationRequest(operationId: "bounce", conversationEpoch: "epoch-1")
        XCTAssertEqual(model.performSessionAction(
            sessionId: session.id, action: bounce, operation: bounceID
        ), .invalid)
        snapshot.runtimeActivity = RuntimeActivitySnapshot(
            processing: false, observedAtMilliseconds: Int64(now.timeIntervalSince1970 * 1_000)
        )
        try JSONEncoder().encode(snapshot).write(to: snapshotURL)
        XCTAssertEqual(model.performSessionAction(
            sessionId: session.id, action: bounce, operation: bounceID
        ), .accepted)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: sessions.appendingPathComponent("\(session.id).session-bounce.json").path
        ))
        XCTAssertEqual(model.sendRemotePrompt(sessionId: session.id, value: "pending handoff"), .busy)
        XCTAssertEqual(model.performSessionAction(
            sessionId: session.id, action: bounce, operation: bounceID
        ), .accepted)
        try FileManager.default.removeItem(at: sessions.appendingPathComponent("\(session.id).session-bounce.json"))
        let readyWorkflow = snapshot.workflow
        let selection = RemoteModelSelection(modelId: "gpt-5.6-sol")
        let modelOperation = CLIOperationRequest(operationId: "model", conversationEpoch: "epoch-1")
        snapshot.availableModels = [TrackedAvailableModel(id: selection.modelId, name: "Model")]
        try JSONEncoder().encode(snapshot).write(to: snapshotURL)
        XCTAssertEqual(model.setModel(
            sessionId: session.id, selection: selection, operation: modelOperation
        ), .accepted)
        let modelHandoff = sessions.appendingPathComponent("\(session.id).set-model-request.json")
        try FileManager.default.removeItem(at: modelHandoff)
        snapshot.operationReceipts = [TrackedOperationReceipt(
            operationId: modelOperation.operationId, conversationEpoch: "epoch-1",
            kind: "set-model", state: .applied,
            updatedAtMilliseconds: Int64(now.timeIntervalSince1970 * 1_000),
            payloadFingerprint: CLIOperationAdapter.payloadFingerprint(kind: .setModel, payload: selection)
        )]
        snapshot.workflow = RemoteSessionWorkflow(
            observedAtMilliseconds: Int64(now.timeIntervalSince1970 * 1_000),
            capabilities: [], sendReady: false, bounceRequested: true
        )
        try JSONEncoder().encode(snapshot).write(to: snapshotURL)
        XCTAssertEqual(model.sendRemotePrompt(sessionId: session.id, value: "pending bounce"), .busy)
        XCTAssertEqual(model.setModel(
            sessionId: session.id, selection: selection,
            operation: CLIOperationRequest(operationId: "new-model", conversationEpoch: "epoch-1")
        ), .invalid)
        XCTAssertEqual(model.setModel(
            sessionId: session.id, selection: selection, operation: modelOperation
        ), .accepted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: modelHandoff.path))
        snapshot.workflow = readyWorkflow
        snapshot.scheduledTurnActive = true
        try JSONEncoder().encode(snapshot).write(to: snapshotURL)
        XCTAssertEqual(model.performSessionAction(
            sessionId: session.id, action: bounce,
            operation: CLIOperationRequest(operationId: "busy-bounce", conversationEpoch: "epoch-1")
        ), .invalid)
        snapshot.scheduledTurnActive = false
        snapshot.pendingPermissionRequestIds = ["pending"]
        try JSONEncoder().encode(snapshot).write(to: snapshotURL)
        XCTAssertEqual(model.performSessionAction(
            sessionId: session.id, action: send,
            operation: CLIOperationRequest(operationId: "blocked", conversationEpoch: "epoch-1")
        ), .invalid)

        // Verify host attachment admission in performSessionAction for text-only and mixed sends.
        snapshot.pendingPermissionRequestIds = []
        let imageCaps = RemoteImageCapabilities(
            maxImages: 1,
            maxBytes: RemoteAttachmentContract.maxBytes,
            mimeTypes: ["image/png"]
        )
        let jsonAttachment = try model.attachmentStore.store(
            Data(#"{"ok":true}"#.utf8),
            id: UUID().uuidString.lowercased(),
            sessionId: session.id,
            conversationEpoch: "epoch-1",
            mimeType: "application/json",
            displayName: "config.json",
            now: now
        )
        let mdAttachment = try model.attachmentStore.store(
            Data("# Notes\n".utf8),
            id: UUID().uuidString.lowercased(),
            sessionId: session.id,
            conversationEpoch: "epoch-1",
            mimeType: "text/markdown",
            displayName: "NOTES.md",
            now: now
        )
        // Without file-attachments-v1, text attachments are rejected.
        snapshot.workflow = RemoteSessionWorkflow(
            observedAtMilliseconds: Int64(now.timeIntervalSince1970 * 1_000),
            capabilities: [RemoteSessionActionKind.send.rawValue, RemoteAttachmentContract.capability],
            sendReady: true,
            imageAttachments: imageCaps
        )
        try JSONEncoder().encode(snapshot).write(to: snapshotURL)
        let textSend = RemoteSessionAction(
            kind: .send,
            prompt: "review files",
            mode: .enqueue,
            attachmentIds: [jsonAttachment.id, mdAttachment.id]
        )
        XCTAssertEqual(model.performSessionAction(
            sessionId: session.id,
            action: textSend,
            operation: CLIOperationRequest(operationId: "text-no-cap", conversationEpoch: "epoch-1")
        ), .invalid)

        // With file-attachments-v1 and no vision support, stored JSON and Markdown are accepted and preserved in handoff.
        snapshot.workflow = RemoteSessionWorkflow(
            observedAtMilliseconds: Int64(now.timeIntervalSince1970 * 1_000),
            capabilities: [RemoteSessionActionKind.send.rawValue, RemoteAttachmentContract.fileCapability],
            sendReady: true,
            imageAttachments: nil
        )
        try JSONEncoder().encode(snapshot).write(to: snapshotURL)
        let sendHandoffURL = sessions.appendingPathComponent("\(session.id).session-send.json")
        XCTAssertEqual(model.performSessionAction(
            sessionId: session.id,
            action: textSend,
            operation: CLIOperationRequest(operationId: "text-with-cap", conversationEpoch: "epoch-1")
        ), .accepted)
        let handoffData = try Data(contentsOf: sendHandoffURL)
        let handoffString = try XCTUnwrap(String(data: handoffData, encoding: .utf8))
        XCTAssertTrue(handoffString.contains(jsonAttachment.id))
        XCTAssertTrue(handoffString.contains(mdAttachment.id))
        try FileManager.default.removeItem(at: sendHandoffURL)

        // Mixed sends: 2 text + 1 image (total 3 > maxImages=1) is accepted when image count <= maxImages,
        // and 2 images (> maxImages=1) is rejected.
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let pngData = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        let img1 = try model.attachmentStore.store(
            pngData,
            id: UUID().uuidString.lowercased(),
            sessionId: session.id,
            conversationEpoch: "epoch-1",
            mimeType: "image/png",
            now: now,
            limits: imageCaps
        )
        let img2 = try model.attachmentStore.store(
            pngData,
            id: UUID().uuidString.lowercased(),
            sessionId: session.id,
            conversationEpoch: "epoch-1",
            mimeType: "image/png",
            now: now,
            limits: imageCaps
        )
        snapshot.workflow = RemoteSessionWorkflow(
            observedAtMilliseconds: Int64(now.timeIntervalSince1970 * 1_000),
            capabilities: [
                RemoteSessionActionKind.send.rawValue,
                RemoteAttachmentContract.capability,
                RemoteAttachmentContract.fileCapability,
            ],
            sendReady: true,
            imageAttachments: imageCaps
        )
        try JSONEncoder().encode(snapshot).write(to: snapshotURL)
        let mixedValidSend = RemoteSessionAction(
            kind: .send,
            prompt: "mixed valid",
            mode: .enqueue,
            attachmentIds: [jsonAttachment.id, mdAttachment.id, img1.id]
        )
        XCTAssertEqual(model.performSessionAction(
            sessionId: session.id,
            action: mixedValidSend,
            operation: CLIOperationRequest(operationId: "mixed-valid", conversationEpoch: "epoch-1")
        ), .accepted)
        try FileManager.default.removeItem(at: sendHandoffURL)

        let mixedTooManyImagesSend = RemoteSessionAction(
            kind: .send,
            prompt: "mixed too many images",
            mode: .enqueue,
            attachmentIds: [jsonAttachment.id, img1.id, img2.id]
        )
        XCTAssertEqual(model.performSessionAction(
            sessionId: session.id,
            action: mixedTooManyImagesSend,
            operation: CLIOperationRequest(operationId: "mixed-too-many-images", conversationEpoch: "epoch-1")
        ), .invalid)

        let missingAttachmentSend = RemoteSessionAction(
            kind: .send,
            prompt: "missing attachment",
            mode: .enqueue,
            attachmentIds: [UUID().uuidString.lowercased()]
        )
        XCTAssertEqual(model.performSessionAction(
            sessionId: session.id,
            action: missingAttachmentSend,
            operation: CLIOperationRequest(operationId: "missing-attachment", conversationEpoch: "epoch-1")
        ), .invalid)
    }
}
