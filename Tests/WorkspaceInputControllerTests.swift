import AppKit
import XCTest
import CopilotProjectsCore
@testable import CopilotProjectsHost
@testable import SwiftTerm

@MainActor
final class WorkspaceInputControllerTests: XCTestCase {
    private func withWorkspace(
        _ body: (AppModel, WorkspaceInputController, [Session]) throws -> Void
    ) throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let keys = ["SHELL", "COPILOT_PROJECTS_STATE_DIR", "COPILOT_PROJECTS_DTACH"]
        let previous = Dictionary(uniqueKeysWithValues: keys.map { ($0, ProcessInfo.processInfo.environment[$0]) })
        setenv("SHELL", "/bin/cat", 1)
        setenv("COPILOT_PROJECTS_STATE_DIR", root.path, 1)
        unsetenv("COPILOT_PROJECTS_DTACH")
        defer {
            for (key, value) in previous {
                if let value { setenv(key, value, 1) } else { unsetenv(key) }
            }
            try? FileManager.default.removeItem(at: root)
        }
        guard Paths.dtachExecutable == nil else { return XCTFail("Input tests must not create persistent sessions") }
        let sessions = [Session(title: "first", cwd: root.path), Session(title: "second", cwd: root.path)]
        let project = Project(name: "Input fixture", cwd: root.path,
                              sessions: sessions, selectedSessionId: sessions[0].id)
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(projects: [project], selectedProjectId: project.id))
        let model = AppModel(
            stateRepository: repository, isAppActive: { false },
            agentActivityDirectory: root, resumeMarkerDirectory: root,
            kittyImageDiskStore: RemoteKittyImageDiskStore(root: root.appendingPathComponent("images"))
        )
        defer {
            model.forcePendingSessionDestroys()
            model.detachAllClients()
        }
        model.openTranscriptDrawer(sessionId: sessions[0].id)
        try body(model, WorkspaceInputController(model: model), sessions)
    }

    private func image(_ session: Session) -> TranscriptImagePreviewItem {
        TranscriptImagePreviewItem(
            id: TranscriptImageIdentity(sessionId: session.id, imageId: 42, version: 1), data: Data([1, 2, 3])
        )
    }

    private func key(_ text: String, code: UInt16, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: 0, context: nil, characters: text, charactersIgnoringModifiers: text,
            isARepeat: false, keyCode: code
        ))
    }

    func testPreviewDispatchConsumesDismissalBeforeWorkspaceOrTerminalActions() throws {
        try withWorkspace { model, input, sessions in
            let terminal = try XCTUnwrap(model.controller(for: sessions[0].id))
            let process = try XCTUnwrap(terminal.terminalView.process)
            let sends = process.sendCount
            let pid = terminal.shellPID
            let original = model.projects.flatMap(\.sessions).map(\.id)
            input.presentImage(image(sessions[0]))
            for event in [
                try key("2", code: 19, modifiers: .control),
                try key("2", code: 19, modifiers: .command),
                try key("\t", code: 48, modifiers: .control),
                try key("x", code: 7),
            ] {
                XCTAssertNil(input.handleKeyDown(event))
                XCTAssertNotNil(input.imagePreview)
            }
            for dismissal in [try key("w", code: 13, modifiers: .command), try key("\u{1b}", code: 53)] {
                input.presentImage(image(sessions[0]))
                XCTAssertNil(input.handleKeyDown(dismissal))
                XCTAssertNil(input.imagePreview)
                XCTAssertEqual(model.projects.flatMap(\.sessions).map(\.id), original)
                XCTAssertEqual(model.globalSelectedSessionId, sessions[0].id)
                XCTAssertEqual(process.sendCount, sends)
                XCTAssertEqual(terminal.shellPID, pid)
                XCTAssertFalse(terminal.exited)
            }
            XCTAssertNil(input.handleKeyDown(try key("2", code: 19, modifiers: .control)))
            XCTAssertEqual(model.globalSelectedSessionId, sessions[1].id)
            XCTAssertNil(input.handleKeyDown(try key("w", code: 13, modifiers: .command)))
            XCTAssertFalse(model.projects.flatMap(\.sessions).contains { $0.id == sessions[1].id })
        }
    }

    func testStalePreviewIsRejectedAndBusinessCloseIsNotGatedByUIState() throws {
        try withWorkspace { model, input, sessions in
            input.presentImage(image(sessions[1]))
            XCTAssertNil(input.imagePreview)
            input.presentImage(image(sessions[0]))
            XCTAssertNotNil(input.imagePreview)
            guard case .closed = model.closeRemoteSession(sessionId: sessions[0].id) else {
                return XCTFail("Automation must remain independent of preview presentation")
            }
            XCTAssertFalse(model.projects.flatMap(\.sessions).contains { $0.id == sessions[0].id })
        }
    }
}
