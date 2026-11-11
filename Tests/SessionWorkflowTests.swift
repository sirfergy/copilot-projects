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
        XCTAssertTrue(RemoteSessionAction(kind: .restart).isValid)
        XCTAssertFalse(RemoteSessionAction(kind: .restart, prompt: "/quit").isValid)
        XCTAssertFalse(RemoteSessionAction(kind: .restart, mode: .immediate).isValid)
        XCTAssertFalse(RemoteSessionAction(kind: .restart, attachmentIds: [UUID().uuidString]).isValid)
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

    func testRestartRequiresExplicitStateAndPendingRestartDisablesAllActions() {
        let now = Date()
        let observed = Int64(now.timeIntervalSince1970 * 1_000)
        let received = ContinuousClock.now
        for marker in [nil, false, true] as [Bool?] {
            let workflow = RemoteSessionWorkflow(
                observedAtMilliseconds: observed,
                capabilities: RemoteSessionActionKind.allCases.map(\.rawValue),
                sendReady: true, restartRequested: marker
            )
            for kind in RemoteSessionActionKind.allCases {
                let expected = kind == .restart ? marker == false : marker != true
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
            remotePromptTarget: { _ in RemotePromptTarget(activity: .idle) },
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
                restartRequested: false,
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
        try FileManager.default.removeItem(at: sessions.appendingPathComponent("\(session.id).session-send.json"))
        XCTAssertEqual(model.performSessionAction(
            sessionId: session.id, action: send,
            operation: CLIOperationRequest(operationId: "old", conversationEpoch: "epoch-0")
        ), .epochMismatch)
        let restart = RemoteSessionAction(kind: .restart)
        let restartID = CLIOperationRequest(operationId: "restart", conversationEpoch: "epoch-1")
        XCTAssertEqual(model.performSessionAction(
            sessionId: session.id, action: restart, operation: restartID
        ), .invalid)
        snapshot.runtimeActivity = RuntimeActivitySnapshot(
            processing: false, observedAtMilliseconds: Int64(now.timeIntervalSince1970 * 1_000)
        )
        try JSONEncoder().encode(snapshot).write(to: snapshotURL)
        XCTAssertEqual(model.performSessionAction(
            sessionId: session.id, action: restart, operation: restartID
        ), .accepted)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: sessions.appendingPathComponent("\(session.id).session-restart.json").path
        ))
        XCTAssertEqual(model.performSessionAction(
            sessionId: session.id, action: restart, operation: restartID
        ), .accepted)
        try FileManager.default.removeItem(at: sessions.appendingPathComponent("\(session.id).session-restart.json"))
        // restart-session: a waiting schedule does not block a restart.
        snapshot.schedules = [TrackedSchedule(
            id: 1, intervalMs: 60_000, cron: nil, tz: nil, at: nil,
            prompt: "Later", recurring: true, displayPrompt: nil, nextRunAt: "later"
        )]
        try JSONEncoder().encode(snapshot).write(to: snapshotURL)
        XCTAssertEqual(model.restartAutomationSession(sessionId: session.id, projectId: "other").code, "conflict")
        XCTAssertEqual(model.restartAutomationSession(sessionId: "missing", projectId: nil).code, "gone")
        XCTAssertEqual(model.restartAutomationSession(sessionId: session.id, projectId: project.id).code, "requested")
        try FileManager.default.removeItem(at: sessions.appendingPathComponent("\(session.id).session-restart.json"))
        model.projects[0].sessions[0].parked = ParkedSession(state: .parked, sinceMilliseconds: 1)
        XCTAssertEqual(model.restartAutomationSession(sessionId: session.id, projectId: nil).code, "busy")
        XCTAssertEqual(model.parkedState(session.id), .parked, "a refused restart must not resume a parked session")
        model.projects[0].sessions[0].parked = nil
        snapshot.schedules = []
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
            capabilities: [], sendReady: false, restartRequested: true
        )
        try JSONEncoder().encode(snapshot).write(to: snapshotURL)
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
            sessionId: session.id, action: restart,
            operation: CLIOperationRequest(operationId: "busy-restart", conversationEpoch: "epoch-1")
        ), .invalid)
        XCTAssertEqual(model.restartAutomationSession(sessionId: session.id, projectId: nil).code, "busy")
        snapshot.scheduledTurnActive = false
        snapshot.pendingPermissionRequestIds = ["pending"]
        try JSONEncoder().encode(snapshot).write(to: snapshotURL)
        XCTAssertEqual(model.performSessionAction(
            sessionId: session.id, action: send,
            operation: CLIOperationRequest(operationId: "blocked", conversationEpoch: "epoch-1")
        ), .conflict)

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

    @MainActor
    func testGroupSessionUnderParentAndMarkAllSessionsRead() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)

        var parentSession = Session(title: "Coordinator", cwd: root.path)
        parentSession.markedUnread = true
        var standaloneSession = Session(title: "Track 1", cwd: root.path)
        standaloneSession.hasUnread = true
        var secondChildSession = Session(title: "Track 2", cwd: root.path)
        secondChildSession.finishedUnseen = true

        let project = Project(
            name: "Grouping & Read Test",
            cwd: root.path,
            sessions: [parentSession, standaloneSession, secondChildSession],
            selectedSessionId: parentSession.id
        )
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(projects: [project], selectedProjectId: project.id))
        let model = AppModel(
            stateRepository: repository,
            persistPermissionStatus: { _, _, _, _ in },
            isAppActive: { false },
            agentActivityDirectory: sessions,
            resumeMarkerDirectory: sessions,
            kittyImageDiskStore: RemoteKittyImageDiskStore(root: root.appendingPathComponent("images"))
        )
        model.projects[0].sessions[1].hasUnread = true
        model.projects[0].sessions[2].finishedUnseen = true

        // Cannot group a session under itself.
        model.groupSessionUnderParent(
            projectId: project.id,
            sessionId: standaloneSession.id,
            parentSessionId: standaloneSession.id
        )
        XCTAssertNil(model.projects[0].sessions[1].parentSessionId)

        // Group standaloneSession under parentSession.
        model.groupSessionUnderParent(
            projectId: project.id,
            sessionId: standaloneSession.id,
            parentSessionId: parentSession.id
        )
        XCTAssertEqual(model.projects[0].sessions[1].parentSessionId, parentSession.id)
        XCTAssertTrue(model.isParentSessionExpanded(parentSession.id))

        // Cannot group a session under a child session, nor reparent a parent that already has children.
        model.groupSessionUnderParent(
            projectId: project.id,
            sessionId: secondChildSession.id,
            parentSessionId: standaloneSession.id
        )
        XCTAssertNil(model.projects[0].sessions[2].parentSessionId)

        model.groupSessionUnderParent(
            projectId: project.id,
            sessionId: parentSession.id,
            parentSessionId: secondChildSession.id
        )
        XCTAssertNil(model.projects[0].sessions[0].parentSessionId)

        // Mark all sessions read in project and persist cleared manual marks in a single save.
        model.projects[0].sessions[2].markedUnread = true
        XCTAssertTrue(model.projects[0].sessions.contains(where: \.offersMarkAsRead))
        model.markAllSessionsRead(inProjectId: project.id)
        XCTAssertFalse(model.projects[0].sessions.contains(where: \.offersMarkAsRead))
        guard case .loaded(let persisted) = repository.load() else {
            return XCTFail("Expected persisted state to load")
        }
        XCTAssertFalse(persisted.projects[0].sessions.contains(where: \.markedUnread))
    }

    func testCLISendSessionPromptCommandAndValidation() throws {
        XCTAssertTrue(CLIMain.isCommand("send-session-prompt"))

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let socketPath = root.appendingPathComponent("control.sock").path
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var received: [ControlRequest] = []
        var nextResponse = ControlResponse.success("op-123", code: "accepted")
        let server = ControlServer(socketPath: socketPath) { request in
            received.append(request)
            return nextResponse
        }
        XCTAssertTrue(server.start())
        defer { server.stop() }

        var environment = ProcessInfo.processInfo.environment
        environment["COPILOT_PROJECTS_SOCKET"] = socketPath

        // Inline prompt with auto-generated requestId.
        XCTAssertEqual(CLIMain.run([
            "send-session-prompt", "--session", "s1", "--prompt", "Keep going!",
        ], environment: environment), 0)
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.last?.command, "send-session-prompt")
        XCTAssertEqual(received.last?.sessionId, "s1")
        XCTAssertNil(received.last?.projectId)
        XCTAssertEqual(received.last?.prompt, "Keep going!")
        XCTAssertNotNil(received.last?.requestId.flatMap(UUID.init(uuidString:)))

        // Prompt file with explicit project and request-id.
        let promptFile = root.appendingPathComponent("prompt.txt")
        try Data("Run full test suite".utf8).write(to: promptFile)
        let explicitId = UUID()
        XCTAssertEqual(CLIMain.run([
            "send-session-prompt",
            "--session", "s1",
            "--project", "p1",
            "--request-id", explicitId.uuidString,
            "--prompt-file", promptFile.path,
        ], environment: environment), 0)
        XCTAssertEqual(received.last?.projectId, "p1")
        XCTAssertEqual(received.last?.requestId, explicitId.uuidString)
        XCTAssertEqual(received.last?.prompt, "Run full test suite")

        // Validation failures return exit code 2 without hitting the server.
        let sentCount = received.count
        let rejected: [[String]] = [
            ["send-session-prompt"],
            ["send-session-prompt", "--session", "s1"],
            ["send-session-prompt", "--session", "s1", "--prompt", "hi", "--prompt-file", promptFile.path],
            ["send-session-prompt", "--session", "s1", "--prompt", ""],
            ["send-session-prompt", "--session", "s1", "--request-id", "not-a-uuid", "--prompt", "hi"],
            ["send-session-prompt", "--session", "s1", "--prompt", "hi", "--unknown-flag"],
        ]
        for args in rejected {
            XCTAssertEqual(CLIMain.run(args, environment: environment), 2, args.joined(separator: " "))
        }
        XCTAssertEqual(received.count, sentCount)
    }

    @MainActor
    func testSetParentSessionAndCLICommand() throws {
        XCTAssertTrue(CLIMain.isCommand("set-parent-session"))

        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)

        let parent1 = Session(title: "Parent 1", cwd: root.path)
        let parent2 = Session(title: "Parent 2", cwd: root.path)
        let child = Session(title: "Child", cwd: root.path, parentSessionId: parent1.id)
        let project = Project(
            name: "Reparent Test",
            cwd: root.path,
            sessions: [parent1, parent2, child],
            selectedSessionId: parent1.id
        )
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(projects: [project], selectedProjectId: project.id))
        let model = AppModel(
            stateRepository: repository,
            persistPermissionStatus: { _, _, _, _ in },
            isAppActive: { false },
            agentActivityDirectory: sessions,
            resumeMarkerDirectory: sessions,
            kittyImageDiskStore: RemoteKittyImageDiskStore(root: root.appendingPathComponent("images"))
        )

        // Reparent child from parent1 to parent2 in-place; parent1 loses its only child and is cleaned up.
        model.toggleParentSessionExpanded(parent1.id)
        XCTAssertTrue(model.isParentSessionExpanded(parent1.id))
        let reparented = model.setParentSession(
            projectId: project.id,
            sessionId: child.id,
            parentSessionId: parent2.id
        )
        XCTAssertTrue(reparented.ok)
        XCTAssertEqual(reparented.code, "reparented")
        XCTAssertEqual(reparented.text, child.id)
        XCTAssertEqual(model.projects[0].sessions[2].parentSessionId, parent2.id)
        XCTAssertTrue(model.isParentSessionExpanded(parent2.id))
        XCTAssertFalse(model.isParentSessionExpanded(parent1.id))

        // Reject self-parenting, nested parenting (under a child), and reparenting a parent that has children.
        XCTAssertEqual(
            model.setParentSession(projectId: project.id, sessionId: child.id, parentSessionId: child.id).code,
            "bad-request"
        )
        XCTAssertEqual(
            model.setParentSession(projectId: project.id, sessionId: parent1.id, parentSessionId: child.id).code,
            "bad-request"
        )
        XCTAssertEqual(
            model.setParentSession(projectId: project.id, sessionId: parent2.id, parentSessionId: parent1.id).code,
            "bad-request"
        )
        XCTAssertEqual(
            model.setParentSession(projectId: "   ", sessionId: child.id, parentSessionId: parent1.id).code,
            "bad-request"
        )
        XCTAssertEqual(
            model.setParentSession(projectId: "missing-project", sessionId: child.id, parentSessionId: parent1.id).code,
            "unknown-project"
        )
        XCTAssertEqual(
            model.setParentSession(projectId: project.id, sessionId: "missing-session", parentSessionId: parent1.id).code,
            "gone"
        )
        XCTAssertEqual(
            model.handle(ControlRequest(command: "set-parent-session")).code,
            "bad-request"
        )
        var routedReq = ControlRequest(command: "set-parent-session")
        routedReq.projectId = project.id
        routedReq.sessionId = child.id
        routedReq.parentSessionId = parent1.id
        XCTAssertEqual(model.handle(routedReq).code, "reparented")
        XCTAssertEqual(model.projects[0].sessions[2].parentSessionId, parent1.id)
        XCTAssertTrue(model.isParentSessionExpanded(parent1.id))
        XCTAssertFalse(model.isParentSessionExpanded(parent2.id))

        // Ungroup when parentSessionId is nil.
        let ungrouped = model.setParentSession(
            projectId: project.id,
            sessionId: child.id,
            parentSessionId: nil
        )
        XCTAssertTrue(ungrouped.ok)
        XCTAssertEqual(ungrouped.code, "reparented")
        XCTAssertNil(model.projects[0].sessions[2].parentSessionId)
        XCTAssertFalse(model.isParentSessionExpanded(parent1.id))

        // Verify CLI command wiring over a control socket.
        let socketPath = root.appendingPathComponent("control.sock").path
        var received: [ControlRequest] = []
        let server = ControlServer(socketPath: socketPath) { request in
            received.append(request)
            return .success(request.sessionId, code: "reparented")
        }
        XCTAssertTrue(server.start())
        defer { server.stop() }

        var environment = ProcessInfo.processInfo.environment
        environment["COPILOT_PROJECTS_SOCKET"] = socketPath

        XCTAssertEqual(CLIMain.run([
            "set-parent-session",
            "--session", child.id,
            "--parent-session", parent2.id,
            "--project", project.id,
        ], environment: environment), 0)
        XCTAssertEqual(received.last?.command, "set-parent-session")
        XCTAssertEqual(received.last?.sessionId, child.id)
        XCTAssertEqual(received.last?.parentSessionId, parent2.id)
        XCTAssertEqual(received.last?.projectId, project.id)

        XCTAssertEqual(CLIMain.run([
            "set-parent-session",
            "--session", child.id,
            "--no-parent",
        ], environment: environment), 0)
        XCTAssertEqual(received.last?.command, "set-parent-session")
        XCTAssertEqual(received.last?.sessionId, child.id)
        XCTAssertNil(received.last?.parentSessionId)
        XCTAssertNil(received.last?.projectId)

        let countBeforeRejected = received.count
        for badArgs in [
            ["set-parent-session"],
            ["set-parent-session", "--session", ""],
            ["set-parent-session", "--session", child.id, "--parent-session", parent2.id, "--no-parent"],
            ["set-parent-session", "--session", child.id, "--parent-session", ""],
            ["set-parent-session", "--session", child.id, "--no-parent", "--unknown"],
        ] {
            XCTAssertEqual(CLIMain.run(badArgs, environment: environment), 2, badArgs.joined(separator: " "))
        }
        XCTAssertEqual(received.count, countBeforeRejected)
    }

    func testDesktopModelPickerCategoryGroupingAndInitialEffortPreselection() {
        XCTAssertTrue(DesktopModelPicker.sections(for: []).isEmpty)

        let uncategorized = [
            RemoteAvailableModel(id: "m1", name: "First"),
            RemoteAvailableModel(id: "m2", name: "Second", category: "experimental"),
        ]
        XCTAssertEqual(
            DesktopModelPicker.sections(for: uncategorized),
            [DesktopModelSection(id: "all", title: "", models: uncategorized)]
        )

        let fast1 = RemoteAvailableModel(id: "haiku", name: "Haiku", category: "lightweight")
        let pow1 = RemoteAvailableModel(id: "opus", name: "Opus", category: "powerful")
        let other1 = RemoteAvailableModel(id: "byok", name: "BYOK")
        let vers1 = RemoteAvailableModel(id: "sonnet", name: "Sonnet", category: "versatile")
        let pow2 = RemoteAvailableModel(id: "gpt-5.6-sol", name: "GPT-5.6 Sol", category: "powerful")
        let other2 = RemoteAvailableModel(id: "custom", name: "Custom", category: "preview")
        XCTAssertEqual(
            DesktopModelPicker.sections(for: [fast1, pow1, other1, vers1, pow2, other2]),
            [
                DesktopModelSection(id: "powerful", title: "Powerful", models: [pow1, pow2]),
                DesktopModelSection(id: "versatile", title: "Versatile", models: [vers1]),
                DesktopModelSection(id: "lightweight", title: "Lightweight", models: [fast1]),
                DesktopModelSection(id: "other", title: "Other", models: [other1, other2]),
            ]
        )

        // Never fall back to the first advertised level when it could be "none".
        XCTAssertNil(
            ModelReasoningEffortDefault.initialEffort(
                supported: ["none", "low", "medium", "high"],
                sessionCurrent: nil,
                modelDefault: nil
            )
        )
        XCTAssertEqual(
            ModelReasoningEffortDefault.initialEffort(
                supported: ["low", "medium", "high", "xhigh"],
                sessionCurrent: "xhigh",
                modelDefault: "medium"
            ),
            "xhigh"
        )
        XCTAssertEqual(
            ModelReasoningEffortDefault.initialEffort(
                supported: ["low", "medium", "high"],
                sessionCurrent: "xhigh",
                modelDefault: "medium"
            ),
            "medium"
        )
        XCTAssertNil(
            ModelReasoningEffortDefault.initialEffort(
                supported: ["low", "high"],
                sessionCurrent: "xhigh",
                modelDefault: "max"
            )
        )

        XCTAssertEqual(
            DesktopModelPicker.modelSummary(
                RemoteModelInfo(name: "gemini-4-argon", reasoningEffort: "high", contextTier: "long_context")
            ),
            "gemini-4-argon · high · long context"
        )
        XCTAssertEqual(
            DesktopModelPicker.modelSummary(RemoteModelInfo(name: "Claude Sonnet 4.6", contextTier: "default")),
            "Claude Sonnet 4.6"
        )
        XCTAssertTrue(DesktopModelPicker.isCurrent(pow2, current: RemoteModelInfo(name: "gpt-5.6-sol")))
        XCTAssertTrue(DesktopModelPicker.isCurrent(pow2, current: RemoteModelInfo(name: "GPT-5.6 Sol")))
        XCTAssertFalse(DesktopModelPicker.isCurrent(pow2, current: RemoteModelInfo(name: "opus")))
    }

    @MainActor
    func testPerformLocalModelSwitchHandlesAppliedRejectedAndInvalidSelections() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)

        let session = Session(title: "Model switch", cwd: root.path)
        let project = Project(name: "Model switch project", cwd: root.path, sessions: [session])
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(projects: [project], selectedProjectId: project.id))
        let model = AppModel(
            stateRepository: repository,
            persistPermissionStatus: { _, _, _, _ in },
            isAppActive: { false },
            agentActivityDirectory: sessions,
            resumeMarkerDirectory: sessions,
            kittyImageDiskStore: RemoteKittyImageDiskStore(root: root.appendingPathComponent("images"))
        )

        let sdkID = UUID().uuidString
        let snapshotURL = sessions.appendingPathComponent("\(session.id).agent-activity.json")
        let handoffURL = sessions.appendingPathComponent("\(session.id).set-model-request.json")
        try Data(sdkID.utf8).write(to: sessions.appendingPathComponent("\(session.id).copilot-session"))

        let now = Date()
        var snapshot = AgentActivitySnapshot(
            schemaVersion: 1,
            updatedAt: now.ISO8601Format(.init(includingFractionalSeconds: true)),
            foregroundTurnActive: false,
            scheduledTurnActive: false,
            activeSubagents: [],
            schedules: [],
            idleGeneration: 0,
            lastIdleAborted: false,
            lastIdleTurnKind: nil,
            error: nil,
            model: TrackedModel(name: "claude-sonnet-4.6", reasoningEffort: "medium", contextTier: "default"),
            availableModels: [
                TrackedAvailableModel(
                    id: "gpt-5.6-sol",
                    name: "GPT-5.6 Sol",
                    supportedReasoningEfforts: ["low", "medium", "high"],
                    defaultReasoningEffort: "high",
                    longContextAvailable: true,
                    disabled: nil,
                    category: "powerful"
                ),
                TrackedAvailableModel(
                    id: "disabled-model",
                    name: "Disabled",
                    supportedReasoningEfforts: nil,
                    defaultReasoningEffort: nil,
                    longContextAvailable: false,
                    disabled: true,
                    category: "lightweight"
                ),
            ],
            copilotSessionId: sdkID,
            conversationEpoch: "epoch-1",
            operationReceiptVersion: 1,
            operationReceipts: [],
            workflow: RemoteSessionWorkflow(
                observedAtMilliseconds: Int64(now.timeIntervalSince1970 * 1_000),
                capabilities: [RemoteSessionActionKind.send.rawValue],
                sendReady: true
            )
        )
        try JSONEncoder().encode(snapshot).write(to: snapshotURL)
        model.refreshAgentActivitySnapshots(now: now)

        XCTAssertEqual(
            model.sessionModelInfo(sessionId: session.id),
            RemoteModelInfo(name: "claude-sonnet-4.6", reasoningEffort: "medium", contextTier: "default")
        )
        XCTAssertEqual(model.sessionAvailableModels(sessionId: session.id).map(\.id), ["gpt-5.6-sol", "disabled-model"])

        // Invalid selections (unknown model, disabled model, mismatched epoch) fail immediately without writing handoff.
        let invalidModel = await model.performLocalModelSwitch(
            sessionId: session.id,
            selection: RemoteModelSelection(modelId: "unknown-model")
        )
        XCTAssertEqual(invalidModel.state, .rejected)
        XCTAssertEqual(invalidModel.message, "Model switch was not accepted.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: handoffURL.path))

        let disabledResult = await model.performLocalModelSwitch(
            sessionId: session.id,
            selection: RemoteModelSelection(modelId: "disabled-model")
        )
        XCTAssertEqual(disabledResult.state, .rejected)
        XCTAssertFalse(FileManager.default.fileExists(atPath: handoffURL.path))

        let epochMismatch = await model.performLocalModelSwitch(
            sessionId: session.id,
            selection: RemoteModelSelection(modelId: "gpt-5.6-sol"),
            expectedConversationEpoch: "epoch-stale"
        )
        XCTAssertEqual(epochMismatch.state, .rejected)
        XCTAssertFalse(FileManager.default.fileExists(atPath: handoffURL.path))

        // Accepted + applied receipt.
        let validSelection = RemoteModelSelection(
            modelId: "gpt-5.6-sol",
            reasoningEffort: "high",
            contextTier: "long_context"
        )
        let appliedTask = Task {
            await model.performLocalModelSwitch(
                sessionId: session.id,
                selection: validSelection,
                expectedConversationEpoch: "epoch-1",
                pollInterval: .milliseconds(5)
            )
        }
        for _ in 0..<20 where !FileManager.default.fileExists(atPath: handoffURL.path) {
            await Task.yield()
        }
        let handoffData = try Data(contentsOf: handoffURL)
        let handoffJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: handoffData) as? [String: Any])
        let appliedOpId = try XCTUnwrap(handoffJSON["operationId"] as? String)
        XCTAssertEqual(handoffJSON["modelId"] as? String, "gpt-5.6-sol")
        XCTAssertEqual(handoffJSON["reasoningEffort"] as? String, "high")
        XCTAssertEqual(handoffJSON["contextTier"] as? String, "long_context")
        try FileManager.default.removeItem(at: handoffURL)
        snapshot.operationReceipts = [
            TrackedOperationReceipt(
                operationId: appliedOpId,
                conversationEpoch: "epoch-1",
                kind: CLISDKOperationKind.setModel.rawValue,
                state: .applied,
                updatedAtMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000),
                payloadFingerprint: CLIOperationAdapter.payloadFingerprint(kind: .setModel, payload: validSelection)
            ),
        ]
        try JSONEncoder().encode(snapshot).write(to: snapshotURL)
        let appliedResult = await appliedTask.value
        XCTAssertEqual(appliedResult.state, .applied)
        XCTAssertNil(appliedResult.message)
        XCTAssertEqual(appliedResult.operationId, appliedOpId)

        // Accepted + rejected receipt.
        let rejectedSelection = RemoteModelSelection(modelId: "gpt-5.6-sol", reasoningEffort: "low")
        let rejectedTask = Task {
            await model.performLocalModelSwitch(
                sessionId: session.id,
                selection: rejectedSelection,
                expectedConversationEpoch: "epoch-1",
                pollInterval: .milliseconds(5)
            )
        }
        for _ in 0..<20 where !FileManager.default.fileExists(atPath: handoffURL.path) {
            await Task.yield()
        }
        let rejectedHandoff = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: handoffURL)) as? [String: Any]
        )
        let rejectedOpId = try XCTUnwrap(rejectedHandoff["operationId"] as? String)
        try FileManager.default.removeItem(at: handoffURL)
        snapshot.operationReceipts = [
            TrackedOperationReceipt(
                operationId: rejectedOpId,
                conversationEpoch: "epoch-1",
                kind: CLISDKOperationKind.setModel.rawValue,
                state: .rejected,
                updatedAtMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000),
                errorCode: "rpc-error",
                payloadFingerprint: CLIOperationAdapter.payloadFingerprint(kind: .setModel, payload: rejectedSelection)
            ),
        ]
        try JSONEncoder().encode(snapshot).write(to: snapshotURL)
        let rejectedResult = await rejectedTask.value
        XCTAssertEqual(rejectedResult.state, .rejected)
        XCTAssertEqual(rejectedResult.message, "Copilot did not apply this model switch.")
        XCTAssertEqual(rejectedResult.operationId, rejectedOpId)

        // Terminal disconnect hides sessionModelInfo and sessionAvailableModels.
        snapshot.error = "Connection is closed."
        model.projects[0].sessions[0].agentActivity = snapshot
        XCTAssertNil(model.sessionModelInfo(sessionId: session.id))
        XCTAssertTrue(model.sessionAvailableModels(sessionId: session.id).isEmpty)
    }
}
