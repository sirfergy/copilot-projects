import XCTest
import AppKit
import CopilotProjectsCore
import CopilotProjectsProtocol
@testable import CopilotProjectsHost

final class SessionEndingTests: XCTestCase {
    func testPolicyUsesWorkRatherThanUnreadOrLiveSessionMarkers() {
        var session = Session(title: "Example", cwd: "/tmp")
        session.hasUnread = true
        session.finishedUnseen = true
        XCTAssertFalse(session.requiresEndConfirmation)
        for status: SessionStatus in [.running, .waiting] {
            session.status = status
            XCTAssertTrue(session.requiresEndConfirmation)
        }
        session.status = .idle
        session.backgroundAgentsActive = true
        XCTAssertTrue(session.requiresEndConfirmation)
        session.backgroundAgentsActive = false
        session.scheduledTurnActive = true
        XCTAssertTrue(session.requiresEndConfirmation)
        session.scheduledTurnActive = false
        var activity = AgentActivitySnapshot(
            schemaVersion: 1, updatedAt: "2026-09-19T00:00:00Z",
            foregroundTurnActive: false, scheduledTurnActive: false,
            activeSubagents: [], schedules: [], idleGeneration: 0,
            lastIdleAborted: false, lastIdleTurnKind: nil, error: nil
        )
        activity.pendingPermissionRequestIds = ["permission"]
        session.agentActivity = activity
        XCTAssertTrue(session.requiresEndConfirmation)
        activity.pendingPermissionRequestIds = []
        activity.schedules = [TrackedSchedule(
            id: 1, intervalMs: 60_000, cron: nil, tz: nil, at: nil,
            prompt: "Later", recurring: true, displayPrompt: nil, nextRunAt: "later"
        )]
        session.agentActivity = activity
        XCTAssertTrue(session.requiresEndConfirmation)
        activity.schedules = []
        activity.activeSubagents = [TrackedSubagent(id: "agent", name: "Agent", description: "", model: nil)]
        session.agentActivity = activity
        XCTAssertTrue(session.requiresEndConfirmation)
        activity.activeSubagents = []
        activity.workflow = RemoteSessionWorkflow(
            observedAtMilliseconds: 0, capabilities: [], sendReady: false,
            budgetRequest: RemoteBudgetRequest(requestId: "budget", maxAiCredits: 30, usedAiCredits: 30)
        )
        session.agentActivity = activity
        XCTAssertTrue(session.requiresEndConfirmation)
    }

    @MainActor
    func testIdleSelectedSessionEndsWithoutPrompt() throws {
        let f = try EndingFixture { _ in XCTFail("Idle must not prompt"); return .alertFirstButtonReturn }
        defer { f.clean() }
        f.model.closeSelectedSession()
        XCTAssertEqual(f.calls.batches, [[f.project.sessions[0].id]])
    }

    @MainActor
    func testActiveCancelAndConfirmUseSafeDefaultAndCapturedTarget() throws {
        var accept = false
        var alerts: [NSAlert] = []
        let f = try EndingFixture { alert in
            alerts.append(alert)
            return accept ? .alertSecondButtonReturn : .alertFirstButtonReturn
        }
        defer { f.clean() }
        let id = f.project.sessions[0].id
        f.model.setStatus(sessionId: id, status: .running, text: nil, timestamp: 100)
        f.model.closeSelectedSession()
        XCTAssertTrue(f.calls.batches.isEmpty)
        XCTAssertEqual(alerts[0].buttons.map(\.title), ["Cancel", "End Session"])
        XCTAssertEqual(alerts[0].buttons[0].keyEquivalent, "\u{1b}")
        XCTAssertEqual(alerts[0].buttons[1].keyEquivalent, "")
        XCTAssertTrue(alerts[0].window.initialFirstResponder === alerts[0].buttons[0])
        XCTAssertTrue(alerts[0].buttons[1].hasDestructiveAction)
        accept = true
        f.model.closeSelectedSession()
        XCTAssertEqual(f.calls.batches, [[id]])
    }

    @MainActor
    func testOneActiveProjectSessionUsesSingularConsequences() throws {
        var message = ""
        let f = try EndingFixture { alert in
            message = alert.informativeText
            return .alertFirstButtonReturn
        }
        defer { f.clean() }
        f.model.setStatus(sessionId: f.other.sessions[0].id, status: .running, text: nil, timestamp: 100)
        f.model.requestCloseProject(f.other.id)
        XCTAssertTrue(message.contains("This ends 1 session: Other session."))
        XCTAssertTrue(message.contains("One session has active or pending work."))
        XCTAssertTrue(f.calls.batches.isEmpty)
    }

    @MainActor
    func testMultipleIdleSessionsRequireConfirmationButSingleAndEmptyProjectsDoNot() throws {
        let f = try EndingFixture { _ in .alertFirstButtonReturn }
        defer { f.clean() }
        f.model.requestCloseProject(f.project.id)
        XCTAssertTrue(f.calls.batches.isEmpty)
        XCTAssertEqual(f.model.projects.count, 3)
        f.model.requestCloseProject(f.other.id)
        XCTAssertEqual(f.calls.batches, [f.other.sessions.map(\.id)])
        f.model.requestCloseProject(f.empty.id)
        XCTAssertEqual(f.model.projects.map(\.id), [f.project.id])
    }

    @MainActor
    func testAddedProjectMemberIsNotIncludedInAnEarlierConfirmation() throws {
        var duringConfirmation: (() -> Void)?
        var alerts = 0
        let f = try EndingFixture { _ in
            alerts += 1
            if alerts == 1 { duringConfirmation?() }
            return .alertSecondButtonReturn
        }
        defer { f.clean() }
        duringConfirmation = { [weak model = f.model, other = f.other, project = f.project] in
            _ = model?.moveSession(toProjectId: project.id, draggedId: other.sessions[0].id, selectInTarget: false)
        }
        f.model.requestCloseProject(f.project.id)
        XCTAssertTrue(f.calls.batches.isEmpty)
        XCTAssertEqual(alerts, 2, "Explain why the changed project was not ended")
        XCTAssertEqual(f.model.projects[0].sessions.count, 3)
    }

    @MainActor
    func testDepartedProjectMemberIsNotChasedIntoAnotherProject() throws {
        var duringConfirmation: (() -> Void)?
        let f = try EndingFixture { _ in
            duringConfirmation?()
            return .alertSecondButtonReturn
        }
        defer { f.clean() }
        let moved = f.project.sessions[1].id
        duringConfirmation = { [weak model = f.model, other = f.other] in
            _ = model?.moveSession(toProjectId: other.id, draggedId: moved, selectInTarget: false)
        }
        f.model.requestCloseProject(f.project.id)
        XCTAssertEqual(f.calls.batches, [[f.project.sessions[0].id]])
        XCTAssertTrue(f.model.projects.flatMap(\.sessions).contains { $0.id == moved })
    }

    @MainActor
    func testMovedSingleTargetFailsSafeAndAutomationStaysHeadless() throws {
        var duringConfirmation: (() -> Void)?
        var alerts = 0
        let f = try EndingFixture { _ in
            alerts += 1
            if alerts == 1 { duringConfirmation?() }
            return .alertSecondButtonReturn
        }
        defer { f.clean() }
        let id = f.project.sessions[0].id
        f.model.setStatus(sessionId: id, status: .waiting, text: nil, timestamp: 100)
        duringConfirmation = { [weak model = f.model, other = f.other] in
            _ = model?.moveSession(toProjectId: other.id, draggedId: id, selectInTarget: false)
        }
        f.model.requestCloseSession(projectId: f.project.id, sessionId: id)
        XCTAssertTrue(f.calls.batches.isEmpty)
        XCTAssertEqual(alerts, 2)
        XCTAssertEqual(f.model.closeRemoteSession(sessionId: id), .closed)
        XCTAssertEqual(alerts, 2, "Automation must not display a local confirmation")
        XCTAssertEqual(f.calls.batches, [[id]])
    }
}

@MainActor
private final class EndingFixture {
    final class Calls { var batches: [[String]] = [] }
    let calls = Calls()
    let root: URL
    let project: Project
    let other: Project
    let empty: Project
    let model: AppModel
    let oldStateDirectory: String?

    init(present: @escaping (NSAlert) -> NSApplication.ModalResponse) throws {
        _ = NSApplication.shared
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        oldStateDirectory = ProcessInfo.processInfo.environment["COPILOT_PROJECTS_STATE_DIR"]
        setenv("COPILOT_PROJECTS_STATE_DIR", root.path, 1)
        let sessions = [Session(title: "First", cwd: root.path), Session(title: "Second", cwd: root.path)]
        project = Project(name: "Original", cwd: root.path, sessions: sessions, selectedSessionId: sessions[0].id)
        other = Project(name: "Other", cwd: root.path, sessions: [Session(title: "Other session", cwd: root.path)])
        empty = Project(name: "Empty", cwd: root.path)
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(projects: [project, other, empty], selectedProjectId: project.id))
        let calls = calls
        model = AppModel(
            stateRepository: repository, isAppActive: { false },
            agentActivityDirectory: root, resumeMarkerDirectory: root,
            kittyImageDiskStore: RemoteKittyImageDiskStore(root: root.appendingPathComponent("images")),
            gracefulSessionDestroyer: { ids, _ in calls.batches.append(ids); return Task {} },
            forcedSessionDestroyer: { _ in },
            alertPresenter: present
        )
    }

    func clean() {
        model.forcePendingSessionDestroys()
        model.detachAllClients()
        if let oldStateDirectory { setenv("COPILOT_PROJECTS_STATE_DIR", oldStateDirectory, 1) }
        else { unsetenv("COPILOT_PROJECTS_STATE_DIR") }
        try? FileManager.default.removeItem(at: root)
    }
}
