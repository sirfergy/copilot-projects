import AppKit
import Darwin
import XCTest
import CopilotProjectsCore
import CopilotProjectsProtocol
@testable import CopilotProjectsHost

@MainActor
final class ComposerSlashCommandTests: XCTestCase {
    /// One idle session whose Copilot is live and at its prompt.
    @MainActor
    private final class Fixture {
        final class Copilot {
            var live = true
        }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let session: Session
        let model: AppModel
        let copilot = Copilot()
        let operation = AgentOperationProjection(conversationEpoch: "epoch-1", support: .receipts, receipts: [])
        let workflow = RemoteSessionWorkflow(
            observedAtMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000),
            capabilities: ["session-send"], sendReady: true
        )
        /// What the composer sent to Copilot as messages.
        var sent: [RemoteSessionAction] = []
        private var pipeEnd: Int32 = -1

        var composer: DesktopSessionPromptComposer { model.sessionPromptComposer(sessionId: session.id) }
        var blocked: String? { composer.slashCommandBlockedReason() }

        init() throws {
            _ = NSApplication.shared
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let session = Session(title: "Slash", cwd: root.path)
            self.session = session
            let repository = StateRepository(path: root.appendingPathComponent("state.json"))
            let project = Project(name: "Slash", cwd: root.path, sessions: [session], selectedSessionId: session.id)
            try repository.save(PersistedState(projects: [project], selectedProjectId: project.id))
            let copilot = copilot
            model = AppModel(
                stateRepository: repository, persistPermissionStatus: { _, _, _, _ in },
                isAppActive: { false }, agentActivityDirectory: root, resumeMarkerDirectory: root,
                remotePromptLiveSessions: { _ in copilot.live ? [session.id] : [] },
                remotePromptTarget: { _ in RemotePromptTarget(activity: .idle) },
                kittyImageDiskStore: RemoteKittyImageDiskStore(root: root.appendingPathComponent("images"))
            )
        }

        func close() {
            model.forcePendingSessionDestroys()
            model.detachAllClients()
            if pipeEnd >= 0 { Darwin.close(pipeEnd) }
            try? FileManager.default.removeItem(at: root)
        }

        /// Presses Send, with the outcome a message gets from Copilot.
        func submit(_ state: RemoteOperationState = .applied) async {
            await composer.send(workflow: workflow, operation: operation) { action in
                self.sent.append(action)
                return RemoteWorkflowActionResult(state: state, operationId: "operation")
            }
        }

        /// Gives the session a terminal whose "dtach" hands everything typed
        /// into it to a pipe, and returns once it is raw and reading.
        func attachTerminal() async throws {
            var ends: [Int32] = [0, 0]
            XCTAssertEqual(pipe(&ends), 0)
            pipeEnd = ends[0]
            let dtach = root.appendingPathComponent("dtach")
            // The terminal's child inherits the pipe's write end.
            let script = "#!/bin/sh\nstty raw -echo\nprintf '\\004' > /dev/fd/\(ends[1])\nexec /bin/cat > /dev/fd/\(ends[1])\n"
            try Data(script.utf8).write(to: dtach)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dtach.path)
            model.controllers[session.id] = TerminalController(
                sessionId: session.id, cwd: root.path, extraEnvironment: [:],
                dtachExecutable: dtach.path, dtachSocket: root.appendingPathComponent("socket").path,
                kittyImageDiskStore: RemoteKittyImageDiskStore(root: root.appendingPathComponent("images"))
            )
            Darwin.close(ends[1])
            let started = await readToEndMark()
            XCTAssertEqual(started, "")
        }

        /// What was typed into the terminal since the last call. An end mark
        /// typed now bounds the read, so a missing byte fails instead of hanging.
        func typed() async -> String? {
            guard model.sendRemoteInput(sessionId: session.id, value: "\u{4}") == .sent else { return nil }
            return await readToEndMark()
        }

        /// The pipe's bytes before the next end mark, or nil if it closed first.
        private func readToEndMark() async -> String? {
            let pipeEnd = pipeEnd
            return await Task.detached {
                let handle = FileHandle(fileDescriptor: pipeEnd)
                var data = Data()
                while data.last != 4 {
                    guard let byte = try? handle.read(upToCount: 1), !byte.isEmpty else { return nil }
                    data.append(byte)
                }
                return String(decoding: data.dropLast(), as: UTF8.self)
            }.value
        }
    }

    func testRestartOnItsOwnIsTypedIntoTheTerminalInsteadOfSentAsAMessage() async throws {
        let f = try Fixture()
        defer { f.close() }
        try await f.attachTerminal()

        f.composer.prompt = "/restart now"
        await f.submit()
        XCTAssertEqual(f.sent.map(\.prompt), ["/restart now"])
        let nothing = await f.typed()
        XCTAssertEqual(nothing, "")

        f.composer.prompt = " /Restart\n"
        XCTAssertTrue(f.composer.canSend(workflow: f.workflow, operation: f.operation))
        await f.submit()
        XCTAssertEqual(f.sent.count, 1)
        XCTAssertNil(f.composer.statusMessage)
        XCTAssertEqual(f.composer.prompt, "")
        // Ctrl+C clears a draft left on the CLI's input line. The terminal is not
        // focused, so the command and its Enter are typed between focus reports.
        let typed = await f.typed()
        XCTAssertEqual(typed?.debugDescription, "\u{3}\u{1b}[I/restart\r\u{1b}[O".debugDescription)
    }

    func testBlockedStatesSayWhyAndKeepTheDraft() async throws {
        let f = try Fixture()
        defer { f.close() }
        try await f.attachTerminal()
        let composer = f.composer
        composer.prompt = "/restart"
        XCTAssertNil(f.blocked)

        f.model.setStatus(sessionId: f.session.id, status: .running, text: nil, timestamp: 1)
        XCTAssertEqual(f.blocked, "Wait for Copilot to finish before running a slash command")
        XCTAssertFalse(composer.canSend(workflow: f.workflow, operation: f.operation))
        await f.submit()
        XCTAssertEqual(composer.statusMessage, "Wait for Copilot to finish before running a slash command")
        XCTAssertEqual(composer.prompt, "/restart")
        f.model.setStatus(sessionId: f.session.id, status: .idle, text: nil, timestamp: 2)
        XCTAssertNil(f.blocked)

        f.copilot.live = false
        XCTAssertEqual(f.blocked, "Copilot is not ready for slash commands")
        f.copilot.live = true

        // A message whose outcome is unknown is still being sent.
        composer.prompt = "hello"
        await f.submit(.indeterminate)
        XCTAssertEqual(f.sent.map(\.prompt), ["hello"])
        composer.prompt = "/restart"
        XCTAssertEqual(f.blocked, "Wait for Copilot to finish before running a slash command")

        // None of that typed anything, and a quitting app's terminal takes no input.
        let typed = await f.typed()
        XCTAssertEqual(typed, "")
        f.model.beginTermination()
        XCTAssertEqual(f.blocked, "This session's terminal is not taking input")
    }

    func testSuggestionsAreOfferedWhileTheDraftCouldStillBecomeTheCommand() {
        XCTAssertEqual(ComposerSlashCommand.suggestions(for: "/").map(\.command), ["/restart"])
        XCTAssertEqual(ComposerSlashCommand.suggestions(for: " /RES").map(\.command), ["/restart"])
        XCTAssertEqual(ComposerSlashCommand.suggestions(for: "/restart").map(\.summary), [
            "Restart Copilot and preserve this session",
        ])
        for draft in ["", "restart", "/model", "/restart now", "please /restart"] {
            XCTAssertTrue(ComposerSlashCommand.suggestions(for: draft).isEmpty, draft)
        }
        XCTAssertNil(ComposerSlashCommand.parse("please /restart"))
    }
}
