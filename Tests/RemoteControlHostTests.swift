import XCTest
import AppKit
import CopilotProjectsProtocol
@testable import CopilotProjectsHost

final class RemoteControlHostTests: XCTestCase {
    private struct Harness {
        let root: URL
        let project: Project
        let session: Session
        let model: AppModel
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
        let model = AppModel(
            stateRepository: repository,
            isAppActive: { false },
            agentActivityDirectory: root,
            resumeMarkerDirectory: root,
            kittyImageDiskStore: RemoteKittyImageDiskStore(root: root.appendingPathComponent("images"))
        )
        return Harness(root: root, project: project, session: session, model: model)
    }

    @MainActor
    private func message(
        _ harness: Harness,
        sessionId: String? = nil,
        sequence: Int64 = 1
    ) -> RemoteClientMessage {
        RemoteClientMessage(
            type: "input",
            clientId: "client",
            sessionId: sessionId ?? harness.session.id,
            requestId: "request-\(sequence)",
            data: "hello",
            delivery: RemoteControlDelivery(epoch: harness.model.remoteControlDeliveryEpoch, sequence: sequence)
        )
    }

    @MainActor
    func testOutOfRangeScrollReturnsWithoutChangingTheSession() throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        for delta in [Int.min, Int.max, -21, 21] {
            harness.model.sendRemoteScroll(sessionId: harness.session.id, delta: delta)
        }
        XCTAssertEqual(harness.model.projects[0].sessions.map(\.id), [harness.session.id])
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
        XCTAssertEqual(RemoteProtocolInfo.current.controlDeliverySupport, .unavailable)
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
