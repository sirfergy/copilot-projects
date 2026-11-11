import AppKit
import Darwin
import SwiftUI
import XCTest
import CopilotProjectsCore
import CopilotProjectsProtocol
@testable import CopilotProjectsHost

@MainActor
final class SlashCommandTests: XCTestCase {
    /// Two idle sessions whose Copilots are live and at their prompts: `session`
    /// is the one on screen and `other` is another row of its project.
    @MainActor
    private final class Fixture {
        final class Copilot {
            var live: Set<String> = []
        }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let session: Session
        let other: Session
        let model: AppModel
        let copilot = Copilot()
        let operation = AgentOperationProjection(conversationEpoch: "epoch-1", support: .receipts, receipts: [])
        let workflow = RemoteSessionWorkflow(
            observedAtMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000),
            capabilities: ["session-send"], sendReady: true
        )
        /// What the composer sent to Copilot as messages.
        var sent: [RemoteSessionAction] = []
        private var pipeEnds: [String: Int32] = [:]

        var composer: DesktopSessionPromptComposer { model.sessionPromptComposer(sessionId: session.id) }
        var blocked: String? { composer.slashCommandBlockedReason() }

        init() throws {
            _ = NSApplication.shared
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let session = Session(title: "Slash", cwd: root.path)
            let other = Session(title: "Other", cwd: root.path)
            self.session = session
            self.other = other
            let repository = StateRepository(path: root.appendingPathComponent("state.json"))
            let project = Project(
                name: "Slash", cwd: root.path, sessions: [session, other], selectedSessionId: session.id
            )
            try repository.save(PersistedState(projects: [project], selectedProjectId: project.id))
            let copilot = copilot
            copilot.live = [session.id, other.id]
            model = AppModel(
                stateRepository: repository, persistPermissionStatus: { _, _, _, _ in },
                isAppActive: { false }, agentActivityDirectory: root, resumeMarkerDirectory: root,
                remotePromptLiveSessions: { _ in copilot.live },
                remotePromptTarget: { _ in RemotePromptTarget(activity: .idle) },
                kittyImageDiskStore: RemoteKittyImageDiskStore(root: root.appendingPathComponent("images"))
            )
        }

        func close() {
            model.forcePendingSessionDestroys()
            model.detachAllClients()
            pipeEnds.values.forEach { Darwin.close($0) }
            try? FileManager.default.removeItem(at: root)
        }

        /// Presses Send, with the outcome a message gets from Copilot.
        func submit(_ state: RemoteOperationState = .applied) async {
            await composer.send(workflow: workflow, operation: operation) { action in
                self.sent.append(action)
                return RemoteWorkflowActionResult(state: state, operationId: "operation")
            }
        }

        /// Gives a session a terminal whose "dtach" hands everything typed into
        /// it to a pipe, and returns once it is raw and reading.
        func attachTerminal(to session: Session) async throws {
            var ends: [Int32] = [0, 0]
            XCTAssertEqual(pipe(&ends), 0)
            pipeEnds[session.id] = ends[0]
            let dtach = root.appendingPathComponent("dtach-\(session.id)")
            // The terminal's child inherits the pipe's write end.
            let script = "#!/bin/sh\nstty raw -echo\nprintf '\\004' > /dev/fd/\(ends[1])\n"
                + "exec /bin/cat > /dev/fd/\(ends[1])\n"
            try Data(script.utf8).write(to: dtach)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dtach.path)
            model.controllers[session.id] = TerminalController(
                sessionId: session.id, cwd: root.path, extraEnvironment: [:],
                dtachExecutable: dtach.path, dtachSocket: root.appendingPathComponent(session.id).path,
                kittyImageDiskStore: RemoteKittyImageDiskStore(root: root.appendingPathComponent("images"))
            )
            Darwin.close(ends[1])
            let started = await readToEndMark(of: session)
            XCTAssertEqual(started, "")
        }

        /// What was typed into a session's terminal since the last call. An end mark
        /// typed now bounds the read, so a missing byte fails instead of hanging.
        func typed(in session: Session) async -> String? {
            guard model.sendRemoteInput(sessionId: session.id, value: "\u{4}") == .sent else { return nil }
            return await readToEndMark(of: session)
        }

        /// The pipe's bytes before the next end mark, or nil if it closed first.
        private func readToEndMark(of session: Session) async -> String? {
            guard let pipeEnd = pipeEnds[session.id] else { return nil }
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

    /// Ctrl+C clears a draft left on the CLI's input line. The terminals here are
    /// not focused, so the command and its Enter are typed between focus reports.
    private let restartTyped = "\u{3}\u{1b}[I/restart\r\u{1b}[O".debugDescription

    func testRestartOnItsOwnIsTypedIntoTheTerminalInsteadOfSentAsAMessage() async throws {
        let f = try Fixture()
        defer { f.close() }
        try await f.attachTerminal(to: f.session)

        f.composer.prompt = "/restart now"
        await f.submit()
        XCTAssertEqual(f.sent.map(\.prompt), ["/restart now"])
        let nothing = await f.typed(in: f.session)
        XCTAssertEqual(nothing, "")

        f.composer.prompt = " /Restart\n"
        XCTAssertTrue(f.composer.canSend(workflow: f.workflow, operation: f.operation))
        await f.submit()
        XCTAssertEqual(f.sent.count, 1)
        XCTAssertNil(f.composer.statusMessage)
        XCTAssertEqual(f.composer.prompt, "")
        let typed = await f.typed(in: f.session)
        XCTAssertEqual(typed?.debugDescription, restartTyped)
    }

    func testBlockedStatesSayWhyAndKeepTheDraft() async throws {
        let f = try Fixture()
        defer { f.close() }
        try await f.attachTerminal(to: f.session)
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

        f.copilot.live.remove(f.session.id)
        XCTAssertEqual(f.blocked, "Copilot is not ready for slash commands")
        f.copilot.live.insert(f.session.id)

        // A message whose outcome is unknown is still being sent.
        composer.prompt = "hello"
        await f.submit(.indeterminate)
        XCTAssertEqual(f.sent.map(\.prompt), ["hello"])
        composer.prompt = "/restart"
        XCTAssertEqual(f.blocked, "Wait for Copilot to finish before running a slash command")

        // None of that typed anything, and a quitting app's terminal takes no input.
        let typed = await f.typed(in: f.session)
        XCTAssertEqual(typed, "")
        f.model.beginTermination()
        XCTAssertEqual(f.blocked, "This session's terminal is not taking input")
    }

    /// A session row's Restart Session in the menu AppKit builds for a right-click,
    /// with the window that keeps it alive.
    private func rowMenu(for session: Session, in model: AppModel) throws -> (menu: NSMenu, window: NSWindow) {
        let window = NSWindow(
            contentRect: NSRect(x: -20_000, y: -20_000, width: 120, height: 40),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        let host = NSHostingView(rootView: Text("row").frame(width: 120, height: 40).contextMenu {
            RestartSessionMenuItem(model: model, sessionId: session.id)
        })
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let click = try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown, location: NSPoint(x: 60, y: 20), modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        var view = host.hitTest(click.locationInWindow)
        while let candidate = view {
            if let menu = candidate.menu(for: click) { return (menu, window) }
            view = candidate.superview
        }
        throw CocoaError(.featureUnsupported, userInfo: [NSDebugDescriptionErrorKey: "no context menu was built"])
    }

    func testRestartSessionRunsInTheRowItWasChosenOnAndIsDisabledWhileItCannotRun() async throws {
        let f = try Fixture()
        defer { f.close() }
        try await f.attachTerminal(to: f.session)
        XCTAssertEqual(f.model.globalSelectedSessionId, f.session.id)

        // A row with no terminal is disabled, and asking didn't start one.
        XCTAssertEqual(
            f.model.slashCommandBlockedReason(sessionId: f.other.id), "This session's terminal is not taking input"
        )
        XCTAssertNil(f.model.controllers[f.other.id])
        try await f.attachTerminal(to: f.other)

        // The other row's item is enabled, and choosing it types into that row's terminal only.
        let row = try rowMenu(for: f.other, in: f.model)
        XCTAssertEqual(row.menu.items.map(\.title), ["Restart Session"])
        XCTAssertTrue(row.menu.items[0].isEnabled)
        row.menu.performActionForItem(at: 0)
        let typedInRow = await f.typed(in: f.other)
        XCTAssertEqual(typedInRow?.debugDescription, restartTyped)
        let typedOnScreen = await f.typed(in: f.session)
        XCTAssertEqual(typedOnScreen, "")

        // With no Copilot in the row its item is disabled, and running it anyway types nothing.
        f.copilot.live.remove(f.other.id)
        XCTAssertFalse(try rowMenu(for: f.other, in: f.model).menu.items[0].isEnabled)
        f.model.restartSession(f.other.id)
        let refused = await f.typed(in: f.other)
        XCTAssertEqual(refused, "")

        // The Session menu's item follows the session on screen.
        f.model.syncMenuState(includeRuntimeAttention: true)
        XCTAssertTrue(f.model.menuState.snapshot.selectedSessionCanRestart)
        f.copilot.live.remove(f.session.id)
        f.model.syncMenuState(includeRuntimeAttention: true)
        XCTAssertFalse(f.model.menuState.snapshot.selectedSessionCanRestart)
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
