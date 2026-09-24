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

    func testRestoredModifiedReturnIsConsumedOnlyInRestoredLiveCopilotTabs() throws {
        try withWorkspace { model, input, sessions in
            let terminal = try XCTUnwrap(model.controller(for: sessions[0].id))
            XCTAssertFalse(terminal.reattachedToExistingShell)
            let view = terminal.terminalView
            let window = NSWindow(
                contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false
            )
            window.contentView = view
            defer { window.contentView = nil }
            XCTAssertTrue(window.makeFirstResponder(view))
            let rows = try XCTUnwrap(view.terminalInputStateSnapshot()).dimensions.rows
            view.feed(text: String(repeating: "\r\n", count: rows) + "/ commands · ? help · tab next tab")
            let process = try XCTUnwrap(view.process)
            let shiftReturn = try key("\r", code: 36, modifiers: .shift)
            let sends = process.sendCount

            model.setLiveAgentSessionsForTesting([sessions[0].id])
            XCTAssertNotNil(input.handleKeyDown(shiftReturn))
            terminal.markReattachedForTesting()
            model.setLiveAgentSessionsForTesting([])
            XCTAssertNotNil(input.handleKeyDown(shiftReturn))
            XCTAssertEqual(process.sendCount, sends)

            model.setLiveAgentSessionsForTesting([sessions[0].id])
            XCTAssertNil(input.handleKeyDown(shiftReturn))
            XCTAssertEqual(process.sendCount, sends + 1)

            for shellLine in ["zsh ~/working %", "~/src % echo esc stop agents"] {
                view.feed(text: "\r\n" + shellLine)
                XCTAssertNotNil(input.handleKeyDown(shiftReturn), shellLine)
                XCTAssertEqual(process.sendCount, sends + 1, shellLine)
            }
        }
    }

    func testReattachRequiresADtachMasterAcceptingTheSocket() throws {
        let root = "/tmp/cp-reattach-\(UUID().uuidString.prefix(8))"
        let deep = root + "/" + String(repeating: "d", count: 80)
        try FileManager.default.createDirectory(atPath: deep, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let attaches = TerminalController.attachesToExistingShell

        let socket = root + "/s.sock"
        XCTAssertFalse(attaches("/dtach", socket))
        let listener = try listeningSocket(socket)
        XCTAssertTrue(attaches("/dtach", socket))
        XCTAssertFalse(attaches(nil, socket))
        XCTAssertFalse(attaches("/dtach", nil))
        close(listener)
        XCTAssertTrue(FileManager.default.fileExists(atPath: socket))
        XCTAssertFalse(attaches("/dtach", socket))

        let file = root + "/file.sock"
        XCTAssertTrue(FileManager.default.createFile(atPath: file, contents: nil))
        XCTAssertFalse(attaches("/dtach", file))

        let long = deep + "/\(UUID().uuidString).sock"
        XCTAssertGreaterThan(long.utf8.count, 104)
        XCTAssertFalse(attaches("/dtach", long))
        XCTAssertTrue(FileManager.default.createFile(atPath: long, contents: nil))
        XCTAssertTrue(attaches("/dtach", long))
    }

    private func listeningSocket(_ path: String) throws -> Int32 {
        let listener = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(listener, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let name = Array(path.utf8CString)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            name.withUnsafeBytes { destination.copyMemory(from: $0) }
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(listen(listener, 4), 0)
        return listener
    }
}
