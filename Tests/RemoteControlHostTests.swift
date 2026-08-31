import XCTest
import AppKit
import CopilotProjectsProtocol
@testable import copilot_projects

final class RemoteControlHostTests: XCTestCase {
    private final class PromptState {
        var activity = FooterActivity.idle
        var isLive = true
        var accepts = true
        var values: [String] = []
    }

    private struct Harness {
        let root: URL
        let project: Project
        let session: Session
        let model: AppModel
        let prompt: PromptState
    }

    @MainActor
    private func makeHarness() throws -> Harness {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/remote-control-host-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let session = Session(title: "Replay test", cwd: root.path)
        let project = Project(name: "Replay project", cwd: root.path, sessions: [session])
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(projects: [project], selectedProjectId: project.id))
        let prompt = PromptState()
        let model = AppModel(
            stateRepository: repository,
            persistPermissionStatus: { _, _, _, _ in },
            isAppActive: { false },
            agentActivityDirectory: root,
            resumeMarkerDirectory: root,
            remotePromptLiveSessions: { _ in prompt.isLive ? [session.id] : [] },
            remotePromptTarget: { id in
                guard id == session.id else { return nil }
                return RemotePromptTarget(activity: prompt.activity, send: { value in
                    guard prompt.accepts else { return false }
                    prompt.values.append(value)
                    return true
                })
            },
            kittyImageDiskStore: RemoteKittyImageDiskStore(root: root.appendingPathComponent("images"))
        )
        return Harness(root: root, project: project, session: session, model: model, prompt: prompt)
    }

    @MainActor
    private func message(
        _ harness: Harness,
        kind: String = "input",
        clientId: String = "client",
        sessionId: String? = nil,
        sequence: Int64 = 1,
        data: String = "hello",
        conversationEpoch: String? = nil
    ) -> RemoteClientMessage {
        RemoteClientMessage(
            type: kind,
            clientId: clientId,
            sessionId: sessionId ?? harness.session.id,
            requestId: "request-\(sequence)",
            data: data,
            conversationEpoch: conversationEpoch,
            delivery: RemoteControlDelivery(epoch: harness.model.remoteControlDeliveryEpoch, sequence: sequence)
        )
    }

    @MainActor
    private func publishConversation(_ epoch: String?, in harness: Harness) throws {
        let now = Date()
        let snapshot = AgentActivitySnapshot(
            schemaVersion: AgentActivitySnapshot.currentSchemaVersion,
            updatedAt: now.ISO8601Format(.init(includingFractionalSeconds: true)),
            foregroundTurnActive: false,
            scheduledTurnActive: false,
            activeSubagents: [],
            schedules: [],
            idleGeneration: 0,
            lastIdleAborted: false,
            lastIdleTurnKind: nil,
            error: nil,
            copilotSessionId: epoch == nil ? nil : "copilot-session",
            conversationEpoch: epoch,
            operationReceiptVersion: epoch == nil ? nil : 1
        )
        try JSONEncoder().encode(snapshot).write(
            to: harness.root.appendingPathComponent("\(harness.session.id).agent-activity.json"),
            options: .atomic
        )
        harness.model.refreshAgentActivitySnapshots(now: now)
    }

    @MainActor
    func testModelAdvertisesItsOwnStableHostLifetimeEpoch() throws {
        let first = try makeHarness()
        defer { try? FileManager.default.removeItem(at: first.root) }
        let second = try makeHarness()
        defer { try? FileManager.default.removeItem(at: second.root) }
        XCTAssertNotNil(UUID(uuidString: first.model.remoteControlDeliveryEpoch))
        XCTAssertNotEqual(first.model.remoteControlDeliveryEpoch, second.model.remoteControlDeliveryEpoch)
        XCTAssertEqual(
            first.model.remoteWorkspaceSnapshot().protocolInfo?.controlDeliverySupport,
            .replaySafe(epoch: first.model.remoteControlDeliveryEpoch)
        )
        XCTAssertEqual(
            first.model.remoteWorkspaceSnapshot().protocolInfo?.controlDeliveryEpoch,
            first.model.remoteControlDeliveryEpoch
        )
        XCTAssertEqual(RemoteProtocolInfo.current.controlDeliverySupport, .legacy)
    }

    @MainActor
    func testLeaseTakeoverAcknowledgesExactReplayButBlocksNewInjection() throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let bridge = RemoteModelBridge(model: harness.model)
        let leases = RemoteWriterLeases()
        leases.acquire(sessionId: harness.session.id, clientId: "client")
        var injections = 0
        func submit(_ request: RemoteClientMessage) -> RemoteControlResult {
            bridge.performControl(request) {
                leases.withHeldLease(sessionId: harness.session.id, clientId: "client") {
                    injections += 1
                    return RemoteControlResult.sent
                } ?? .forbidden
            }
        }
        let accepted = message(harness)
        XCTAssertEqual(submit(accepted), .sent)
        leases.acquire(sessionId: harness.session.id, clientId: "takeover")
        XCTAssertEqual(submit(accepted), .sent)
        let next = message(harness, sequence: 2)
        XCTAssertEqual(submit(next), .forbidden)
        XCTAssertEqual(injections, 1)
        leases.acquire(sessionId: harness.session.id, clientId: "client")
        XCTAssertEqual(submit(next), .sent)
        XCTAssertEqual(injections, 2)
    }

    @MainActor
    func testPromptReplayPrecedesSubmissionThrottleAndTakeover() throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let bridge = RemoteModelBridge(model: harness.model)
        let leases = RemoteWriterLeases()
        let now = Date()
        leases.acquire(sessionId: harness.session.id, clientId: "client")
        func submit(_ request: RemoteClientMessage) -> RemoteControlResult {
            bridge.performControl(request) {
                RemoteControlResult(leases.submitPrompt(
                    sessionId: harness.session.id, clientId: "client", now: now
                ) {
                    bridge.sendPrompt(sessionId: harness.session.id, value: request.data!)
                })
            }
        }
        let accepted = message(harness, kind: "prompt")
        XCTAssertEqual(submit(accepted), .sent)
        XCTAssertEqual(submit(accepted), .sent)
        let next = message(harness, kind: "prompt", sequence: 2, data: "next")
        XCTAssertEqual(submit(next), .busy)
        leases.acquire(sessionId: harness.session.id, clientId: "takeover")
        XCTAssertEqual(submit(accepted), .sent)
        XCTAssertEqual(submit(next), .forbidden)
        XCTAssertEqual(harness.prompt.values, ["hello"])
        leases.acquire(sessionId: harness.session.id, clientId: "client")
        leases.observePromptUnavailable(sessionId: harness.session.id, observedAt: now)
        XCTAssertEqual(submit(next), .sent)
        XCTAssertEqual(harness.prompt.values, ["hello", "next"])
    }

    @MainActor
    func testBusyAndFailedPromptInjectionRemainRetryable() throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let request = message(harness, kind: "prompt")
        func submit() -> RemoteControlResult {
            harness.model.performRemoteControl(request) {
                RemoteControlResult(harness.model.sendRemotePrompt(sessionId: harness.session.id, value: "hello"))
            }
        }
        harness.prompt.activity = .working
        XCTAssertEqual(submit(), .busy)
        harness.prompt.activity = .idle
        harness.prompt.accepts = false
        XCTAssertEqual(submit(), .invalid)
        XCTAssertTrue(harness.prompt.values.isEmpty)
        harness.prompt.accepts = true
        XCTAssertEqual(submit(), .sent)
        harness.prompt.activity = .working
        XCTAssertEqual(submit(), .sent)
        XCTAssertEqual(harness.prompt.values, ["hello"])
    }

    @MainActor
    func testPromptConversationCheckAppliesOnlyToNewInjection() throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        try publishConversation("before", in: harness)
        func submit(_ request: RemoteClientMessage) -> RemoteControlResult {
            harness.model.performRemoteControl(request) {
                RemoteControlResult(harness.model.sendRemotePrompt(
                    sessionId: harness.session.id, value: request.data!
                ))
            }
        }
        let accepted = message(harness, kind: "prompt", conversationEpoch: "before")
        XCTAssertEqual(submit(accepted), .sent)
        try publishConversation("after", in: harness)
        XCTAssertEqual(submit(accepted), .sent)
        XCTAssertEqual(submit(message(
            harness, kind: "prompt", sequence: 2, conversationEpoch: "before"
        )), .invalid)
        XCTAssertEqual(harness.prompt.values, ["hello"])
        XCTAssertEqual(submit(message(
            harness, kind: "prompt", sequence: 2, data: "new conversation", conversationEpoch: "after"
        )), .sent)
        XCTAssertEqual(harness.prompt.values, ["hello", "new conversation"])
    }

    @MainActor
    func testOmittedConversationEpochSupportsLegacyTrackerAndCachedReplayAfterTransition() throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let tiedToMissingConversation = message(harness, kind: "prompt", conversationEpoch: "missing")
        XCTAssertEqual(harness.model.performRemoteControl(tiedToMissingConversation) {
            XCTFail("A supplied epoch must match a live target")
            return .sent
        }, .invalid)
        let accepted = message(harness, kind: "prompt")
        XCTAssertEqual(harness.model.performRemoteControl(accepted) {
            RemoteControlResult(harness.model.sendRemotePrompt(sessionId: harness.session.id, value: "hello"))
        }, .sent)
        try publishConversation("now-known", in: harness)
        XCTAssertEqual(harness.model.performRemoteControl(accepted) {
            XCTFail("An accepted nil-epoch prompt must be acknowledged without reinjection")
            return .invalid
        }, .sent)
        XCTAssertEqual(harness.prompt.values, ["hello"])
    }

    @MainActor
    func testQueuedPromptRejectsAbsentEpochWhenTrackerEpochAppears() throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let pending = message(harness, kind: "prompt")
        try publishConversation("now-known", in: harness)
        XCTAssertEqual(harness.model.performRemoteControl(pending) {
            XCTFail("A queued nil-epoch prompt must not target a newly known conversation")
            return .sent
        }, .invalid)
        XCTAssertTrue(harness.prompt.values.isEmpty)
        XCTAssertEqual(harness.model.performRemoteControl(message(
            harness, kind: "prompt", conversationEpoch: "now-known"
        )) {
            RemoteControlResult(harness.model.sendRemotePrompt(sessionId: harness.session.id, value: "hello"))
        }, .sent)
        XCTAssertEqual(harness.prompt.values, ["hello"], "A rejected delivery must not advance the watermark")
    }

    @MainActor
    func testQueuedPromptRejectsCapturedEpochWhenTrackerEpochDisappears() throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        try publishConversation("before", in: harness)
        let accepted = message(harness, kind: "prompt", conversationEpoch: "before")
        XCTAssertEqual(harness.model.performRemoteControl(accepted) {
            RemoteControlResult(harness.model.sendRemotePrompt(sessionId: harness.session.id, value: "hello"))
        }, .sent)
        let pending = message(harness, kind: "prompt", sequence: 2, conversationEpoch: "before")
        try publishConversation(nil, in: harness)
        XCTAssertEqual(harness.model.performRemoteControl(pending) {
            XCTFail("A queued prompt must not execute after losing its conversation identity")
            return .sent
        }, .invalid)
        XCTAssertEqual(harness.model.performRemoteControl(accepted) {
            XCTFail("An accepted prompt must still be acknowledged after its epoch disappears")
            return .invalid
        }, .sent)
        XCTAssertEqual(harness.prompt.values, ["hello"])
    }

    @MainActor
    func testMissingSessionAndControllerNeverAcknowledgeInputKeyOrCommand() throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        // Preserve lazy controller creation in production, but make this fixture's
        // controller unavailable without launching or touching a real terminal.
        harness.model.beginTermination()
        let bridge = RemoteModelBridge(model: harness.model)
        for sessionId in ["missing", harness.session.id] {
            XCTAssertEqual(bridge.sendInput(sessionId: sessionId, value: "hello"), .missing)
            XCTAssertEqual(bridge.sendKey(sessionId: sessionId, key: "enter"), .missing)
            XCTAssertEqual(bridge.sendCommand(sessionId: sessionId, requestId: "command", value: "hello"), .missing)
        }
        XCTAssertEqual(bridge.performControl(message(harness, sessionId: "missing")) {
            XCTFail("A nonexistent session must not reach the execution closure")
            return .sent
        }, .missing)
        let request = message(harness)
        XCTAssertEqual(bridge.performControl(request) {
            RemoteControlResult(bridge.sendInput(sessionId: harness.session.id, value: "hello"))
        }, .missing)
        var injections = 0
        XCTAssertEqual(bridge.performControl(request) {
            injections += 1
            return .sent
        }, .sent)
        XCTAssertEqual(injections, 1, "A missing controller must not be cached as success")
    }

    @MainActor
    func testInvalidTerminalInputAndKeysAreTypedRefusals() throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let bridge = RemoteModelBridge(model: harness.model)
        XCTAssertEqual(bridge.sendInput(sessionId: harness.session.id, value: String(repeating: "x", count: 8_193)), .invalid)
        XCTAssertEqual(bridge.sendKey(sessionId: harness.session.id, key: "unknown"), .invalid)
        XCTAssertEqual(bridge.sendCommand(sessionId: harness.session.id, requestId: "command", value: "bad\u{0}command"), .invalid)
    }

    @MainActor
    func testClosedSessionCannotReplayOrCreateNewState() throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let request = message(harness)
        XCTAssertEqual(harness.model.performRemoteControl(request) { .sent }, .sent)
        harness.model.closeSession(projectId: harness.project.id, sessionId: harness.session.id)
        XCTAssertEqual(harness.model.performRemoteControl(request) {
            XCTFail("A closed session cannot be injected")
            return .sent
        }, .missing)
        XCTAssertEqual(harness.model.performRemoteControl(message(harness, sequence: 2)) { .sent }, .missing)
    }

    @MainActor
    func testBridgeWithoutModelReturnsMissingInsteadOfSyntheticSuccess() throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        var model: AppModel? = AppModel(
            stateRepository: StateRepository(path: harness.root.appendingPathComponent("empty-state.json")),
            agentActivityDirectory: harness.root,
            resumeMarkerDirectory: harness.root,
            kittyImageDiskStore: RemoteKittyImageDiskStore(root: harness.root.appendingPathComponent("empty-images"))
        )
        let bridge = RemoteModelBridge(model: try XCTUnwrap(model))
        model = nil
        XCTAssertNil(bridge.workspace())
        XCTAssertEqual(bridge.sendInput(sessionId: harness.session.id, value: "hello"), .missing)
        XCTAssertEqual(bridge.sendKey(sessionId: harness.session.id, key: "enter"), .missing)
        XCTAssertEqual(bridge.sendCommand(sessionId: harness.session.id, requestId: "command", value: "hello"), .missing)
        XCTAssertEqual(bridge.performControl(message(harness)) {
            XCTFail("A deallocated model cannot perform a delivery")
            return .sent
        }, .missing)
    }
}
