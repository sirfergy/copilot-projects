import AppKit
import SwiftUI
import XCTest
import CopilotProjectsCore
import CopilotProjectsProtocol
@testable import CopilotProjectsHost

@MainActor
final class SlashCommandTests: XCTestCase {
    /// Two idle sessions whose Copilots are live and whose trackers offer a
    /// restart: `session` is the one on screen and `other` is another row of
    /// its project.
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

        var composer: DesktopSessionPromptComposer { model.sessionPromptComposer(sessionId: session.id) }
        var blocked: String? { composer.restartBlockedReason() }

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
            try heartbeat(session)
            try heartbeat(other)
        }

        func close() {
            model.forcePendingSessionDestroys()
            model.detachAllClients()
            try? FileManager.default.removeItem(at: root)
        }

        private func file(_ session: Session, _ suffix: String) -> URL {
            root.appendingPathComponent("\(session.id).\(suffix)")
        }

        /// Publishes a session's tracker snapshot, as its heartbeat does, and has the model read it.
        func heartbeat(
            _ session: Session, offering capabilities: [String] = ["session-send", "session-restart"],
            receipts: [TrackedOperationReceipt] = []
        ) throws {
            let now = Date()
            let milliseconds = Int64(now.timeIntervalSince1970 * 1_000)
            var snapshot = AgentActivitySnapshot(
                schemaVersion: 1, updatedAt: now.ISO8601Format(.init(includingFractionalSeconds: true)),
                foregroundTurnActive: false, scheduledTurnActive: false, activeSubagents: [], schedules: [],
                idleGeneration: 0, lastIdleAborted: false, lastIdleTurnKind: nil, error: nil,
                pendingPermissionRequestIds: [], copilotSessionId: session.id,
                conversationEpoch: "epoch-1", operationReceiptVersion: 1, operationReceipts: receipts,
                workflow: RemoteSessionWorkflow(
                    observedAtMilliseconds: milliseconds, capabilities: capabilities, sendReady: true,
                    restartRequested: false
                )
            )
            snapshot.runtimeActivity = RuntimeActivitySnapshot(processing: false, observedAtMilliseconds: milliseconds)
            try JSONEncoder().encode(snapshot).write(to: file(session, "agent-activity.json"))
            try Data(session.id.utf8).write(to: file(session, "copilot-session"))
            model.refreshAgentActivitySnapshots()
        }

        /// Plays the tracker: takes the restart request it was handed and says it queued `/restart`.
        func confirmRestart(of session: Session) throws {
            let handoff = file(session, "session-restart.json")
            let asked = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: handoff)) as? [String: Any])
            try FileManager.default.removeItem(at: handoff)
            try heartbeat(session, receipts: [TrackedOperationReceipt(
                operationId: asked["operationId"] as? String, conversationEpoch: "epoch-1",
                kind: "session-restart", state: .applied,
                updatedAtMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000),
                payloadFingerprint: asked["payloadFingerprint"] as? String
            )])
        }

        /// A tracker that exits removes its snapshot and any request it was handed.
        func stopTracker(of session: Session) throws {
            try FileManager.default.removeItem(at: file(session, "agent-activity.json"))
            try? FileManager.default.removeItem(at: file(session, "session-restart.json"))
            model.refreshAgentActivitySnapshots()
        }

        /// Whether the model has handed a session's tracker a restart request,
        /// after giving a request that was just made the chance to be written.
        func restartRequested(of session: Session) async -> Bool {
            let path = file(session, "session-restart.json").path
            for _ in 0..<20 where !FileManager.default.fileExists(atPath: path) {
                await Task.yield()
            }
            return FileManager.default.fileExists(atPath: path)
        }

        /// Presses Send, with the outcome a message gets from Copilot.
        func submit() async {
            await composer.send(workflow: workflow, operation: operation) { action in
                self.sent.append(action)
                return RemoteWorkflowActionResult(state: .applied, operationId: "operation")
            }
        }
    }

    func testRestartOnItsOwnAsksTheTrackerInsteadOfBeingSentAsAMessage() async throws {
        let f = try Fixture()
        defer { f.close() }

        f.composer.prompt = "/restart now"
        await f.submit()
        XCTAssertEqual(f.sent.map(\.prompt), ["/restart now"])

        f.composer.prompt = " /Restart\n"
        XCTAssertTrue(f.composer.canSend(workflow: f.workflow, operation: f.operation))
        let run = Task { await f.submit() }
        let requested = await f.restartRequested(of: f.session)
        XCTAssertTrue(requested)
        // Until the tracker answers, the draft stays and a second Run asks for nothing more.
        await f.submit()
        XCTAssertEqual(f.composer.prompt, " /Restart\n")
        XCTAssertEqual(f.composer.statusMessage, "Waiting for Copilot to confirm...")
        XCTAssertFalse(f.composer.canSend(workflow: f.workflow, operation: f.operation))

        try f.confirmRestart(of: f.session)
        await run.value
        XCTAssertNil(f.composer.statusMessage)
        XCTAssertEqual(f.composer.prompt, "")
        // Nothing went to Copilot as a message, and no terminal was started to type into.
        XCTAssertEqual(f.sent.count, 1)
        XCTAssertNil(f.model.controllers[f.session.id])
    }

    func testAnUnconfirmedRestartSaysSoAndADraftWrittenWhileWaitingIsKept() async throws {
        let f = try Fixture()
        defer { f.close() }

        // A tracker that stops before the app reads its answer leaves the outcome unknown.
        f.composer.prompt = "/restart"
        let unconfirmed = Task { await f.submit() }
        let requested = await f.restartRequested(of: f.session)
        XCTAssertTrue(requested)
        try f.stopTracker(of: f.session)
        await unconfirmed.value
        XCTAssertEqual(
            f.composer.statusMessage, "Couldn't confirm the outcome. Inspect the terminal before trying again."
        )
        XCTAssertEqual(f.composer.prompt, "/restart")

        // The tracker's answer doesn't erase a draft written while it was awaited.
        try f.heartbeat(f.session)
        let confirmed = Task { await f.submit() }
        let requestedAgain = await f.restartRequested(of: f.session)
        XCTAssertTrue(requestedAgain)
        f.composer.prompt = "next message"
        try f.confirmRestart(of: f.session)
        await confirmed.value
        XCTAssertNil(f.composer.statusMessage)
        XCTAssertEqual(f.composer.prompt, "next message")
    }

    func testBlockedStatesSayWhyAndKeepTheDraft() async throws {
        let f = try Fixture()
        defer { f.close() }
        let composer = f.composer
        composer.prompt = "/restart"
        XCTAssertNil(f.blocked)

        let notIdle = "Wait until Copilot is idle before restarting it"
        f.model.setStatus(sessionId: f.session.id, status: .running, text: nil, timestamp: 1)
        XCTAssertEqual(f.blocked, notIdle)
        XCTAssertFalse(composer.canSend(workflow: f.workflow, operation: f.operation))
        await f.submit()
        XCTAssertEqual(composer.statusMessage, notIdle)
        XCTAssertEqual(composer.prompt, "/restart")
        f.model.setStatus(sessionId: f.session.id, status: .idle, text: nil, timestamp: 2)
        XCTAssertNil(f.blocked)

        f.model.projects[0].sessions[0].backgroundAgentsActive = true
        XCTAssertEqual(f.blocked, notIdle)
        f.model.projects[0].sessions[0].backgroundAgentsActive = false

        f.model.projects[0].sessions[0].parked = ParkedSession(state: .parked, sinceMilliseconds: 1)
        XCTAssertEqual(f.blocked, "This session is parked")
        f.model.projects[0].sessions[0].parked = nil

        // A tracker that offers no restart, or has stopped, leaves the terminal.
        let useTerminal = "This session can't be restarted from here. Run /restart in its terminal."
        try f.heartbeat(f.session, offering: ["session-send"])
        XCTAssertEqual(f.blocked, useTerminal)
        try f.stopTracker(of: f.session)
        XCTAssertEqual(f.blocked, useTerminal)
        try f.heartbeat(f.session)
        XCTAssertNil(f.blocked)

        // The tracker has moved to another conversation since the model read its snapshot.
        f.model.projects[0].sessions[0].agentActivity?.conversationEpoch = "epoch-0"
        await f.submit()
        XCTAssertEqual(
            composer.statusMessage, "The conversation changed. Review your message before sending again."
        )
        f.model.refreshAgentActivitySnapshots()

        // The host's admission still decides: no Copilot is running in the session.
        f.copilot.live.remove(f.session.id)
        XCTAssertNil(f.blocked)
        await f.submit()
        XCTAssertEqual(composer.statusMessage, "The session action was not accepted.")
        XCTAssertEqual(composer.prompt, "/restart")

        // None of that asked the tracker or went to Copilot as a message.
        let requested = await f.restartRequested(of: f.session)
        XCTAssertFalse(requested)
        XCTAssertEqual(f.sent.count, 0)
    }

    /// A session row's Restart Session, in a window that stays open across the test.
    private func rowWindow(for session: Session, in model: AppModel) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: -20_000, y: -20_000, width: 120, height: 40),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = NSHostingView(rootView: Text("row").frame(width: 120, height: 40).contextMenu {
            RestartSessionMenuItem(model: model, sessionId: session.id)
        })
        return window
    }

    /// The menu AppKit builds for a right-click on that row now.
    private func rowMenu(in window: NSWindow) throws -> NSMenu {
        window.contentView?.layoutSubtreeIfNeeded()
        let point = NSPoint(x: 60, y: 20)
        let click = try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        var view = window.contentView?.hitTest(point)
        while let candidate = view {
            if let menu = candidate.menu(for: click) { return menu }
            view = candidate.superview
        }
        return try XCTUnwrap(nil as NSMenu?)
    }

    func testRestartSessionAsksTheRowItWasChosenOnAndIsDisabledWhileItCannotRestart() async throws {
        let f = try Fixture()
        defer { f.close() }
        XCTAssertEqual(f.model.globalSelectedSessionId, f.session.id)
        let row = rowWindow(for: f.other, in: f.model)

        // The other row's item is enabled, and choosing it asks that row's tracker only.
        let menu = try rowMenu(in: row)
        XCTAssertEqual(menu.items.map(\.title), ["Restart Session"])
        XCTAssertTrue(menu.items[0].isEnabled)
        menu.performActionForItem(at: 0)
        let requestedInRow = await f.restartRequested(of: f.other)
        XCTAssertTrue(requestedInRow)
        let requestedOnScreen = await f.restartRequested(of: f.session)
        XCTAssertFalse(requestedOnScreen)

        // The row's item follows what the model publishes about its session.
        f.model.setStatus(sessionId: f.other.id, status: .running, text: nil, timestamp: 1)
        XCTAssertFalse(try rowMenu(in: row).items[0].isEnabled)
        f.model.setStatus(sessionId: f.other.id, status: .idle, text: nil, timestamp: 2)
        XCTAssertTrue(try rowMenu(in: row).items[0].isEnabled)

        // A heartbeat that only refreshes the tracker's observation is not published, so an
        // item judged while it was stale is judged again by the publish a right-click makes.
        f.model.projects[0].sessions[1].agentActivity?.workflow?.observedAtMilliseconds -= 16_000
        XCTAssertFalse(try rowMenu(in: row).items[0].isEnabled)
        try f.heartbeat(f.other)
        f.model.objectWillChange.send()
        XCTAssertTrue(try rowMenu(in: row).items[0].isEnabled)

        // The Session menu's item follows the session on screen.
        f.model.syncMenuState(includeRuntimeAttention: true)
        XCTAssertTrue(f.model.menuState.snapshot.selectedSessionCanRestart)
        f.model.setStatus(sessionId: f.session.id, status: .running, text: nil, timestamp: 3)
        f.model.syncMenuState(includeRuntimeAttention: true)
        XCTAssertFalse(f.model.menuState.snapshot.selectedSessionCanRestart)
    }

    func testRestartIdleSessionsAsksTheIdleSessionsAndLeavesABusyOneAlone() async throws {
        let f = try Fixture()
        defer { f.close() }
        f.model.setStatus(sessionId: f.session.id, status: .running, text: nil, timestamp: 1)

        f.model.restartIdleSessions(inProjectId: f.model.projects[0].id)
        let requestedIdle = await f.restartRequested(of: f.other)
        XCTAssertTrue(requestedIdle)
        let requestedBusy = await f.restartRequested(of: f.session)
        XCTAssertFalse(requestedBusy)
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
