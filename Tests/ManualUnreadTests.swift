import XCTest
import AppKit
import CopilotProjectsCore
import CopilotProjectsProtocol
@testable import CopilotProjectsHost

final class ManualUnreadTests: XCTestCase {
    func testManualMarkIsSavedOnlyWhileSet() throws {
        let legacy = Data(#"{"id":"s","title":"Session","cwd":"/tmp"}"#.utf8)
        var session = try JSONDecoder().decode(Session.self, from: legacy)
        XCTAssertFalse(session.markedUnread)
        XCTAssertFalse(session.isUnread)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(session), as: UTF8.self)
            .contains("markedUnread"))

        session.markedUnread = true
        let marked = try JSONDecoder().decode(Session.self, from: JSONEncoder().encode(session))
        XCTAssertTrue(marked.markedUnread)
        XCTAssertTrue(marked.isUnread)
        XCTAssertFalse(marked.hasUnread, "the transient notification flag stays separate")
    }

    @MainActor
    func testManualMarkSurvivesActivationAndOtherTabsUntilYouReturn() throws {
        let f = try ManualUnreadFixture()
        defer { f.clean() }
        let marked = f.project.sessions[0].id
        let otherTab = f.project.sessions[1].id

        f.model.markSessionUnread(sessionId: marked)
        XCTAssertTrue(f.session(marked).markedUnread)
        XCTAssertTrue(f.model.projects[0].hasUnread)
        XCTAssertEqual(NSApp.dockTile.badgeLabel, "1")
        XCTAssertTrue(f.model.remoteWorkspaceSnapshot().projects[0].sessions[0].unread)
        let row = SessionRow(session: f.session(marked), isActive: true, onSelect: {}, onClose: {})
        XCTAssertTrue(row.showsUnreadIndicator)
        XCTAssertEqual(row.accessibilityStatus, "Selected, Idle, Unread")

        f.model.markActiveSessionSeen()
        XCTAssertTrue(f.session(marked).markedUnread, "Returning to the app is not returning to the session")

        f.model.selectSession(projectId: f.project.id, sessionId: otherTab)
        f.model.selectProject(f.other.id)
        f.model.selectProject(f.project.id)
        XCTAssertTrue(f.session(marked).markedUnread, "The project reopens on the other tab")
        XCTAssertFalse(f.session(otherTab).markedUnread)
        XCTAssertEqual(NSApp.dockTile.badgeLabel, "1")

        let saved = try f.savedSessions()
        XCTAssertEqual(saved[marked]?.markedUnread, true)
        XCTAssertEqual(saved[otherTab]?.markedUnread, false)
        XCTAssertEqual(try f.stateText().components(separatedBy: "markedUnread").count - 1, 1)

        f.model.selectSession(projectId: f.project.id, sessionId: marked)
        XCTAssertFalse(f.session(marked).markedUnread)
        XCTAssertFalse(f.model.projects[0].hasUnread)
        XCTAssertNil(NSApp.dockTile.badgeLabel)
        XCTAssertEqual(try f.savedSessions()[marked]?.markedUnread, false)
        XCTAssertFalse(try f.stateText().contains("markedUnread"))
    }

    @MainActor
    func testReturningToTheProjectOrRevealingTheSessionClearsTheMark() throws {
        let f = try ManualUnreadFixture()
        defer { f.clean() }
        let shown = f.project.sessions[0].id
        let otherTab = f.project.sessions[1].id

        f.model.toggleSelectedSessionRead()
        XCTAssertTrue(f.session(shown).markedUnread)
        f.model.selectProject(f.other.id)
        XCTAssertTrue(f.session(shown).markedUnread)
        f.model.selectProject(f.project.id)
        XCTAssertFalse(f.session(shown).markedUnread, "The project reopens on the marked tab")

        f.model.markSessionUnread(sessionId: otherTab)
        f.model.selectProject(f.other.id)
        XCTAssertEqual(f.model.revealSession(projectId: nil, sessionId: otherTab).code, "revealed")
        XCTAssertFalse(f.session(otherTab).markedUnread)
        XCTAssertEqual(try f.savedSessions()[otherTab]?.markedUnread, false)
    }

    @MainActor
    func testRelaunchRestoresTheMarkAndItsDockCount() throws {
        let f = try ManualUnreadFixture()
        defer { f.clean() }
        let marked = f.project.sessions[1].id
        f.model.markSessionUnread(sessionId: marked)
        NSApp.dockTile.badgeLabel = nil

        let relaunched = f.relaunch()
        XCTAssertTrue(try XCTUnwrap(relaunched.projects[0].sessions.first { $0.id == marked }).markedUnread)
        XCTAssertTrue(relaunched.remoteWorkspaceSnapshot().projects[0].sessions[1].unread)
        relaunched.bootstrapIfNeeded()
        XCTAssertEqual(NSApp.dockTile.badgeLabel, "1")
    }

    @MainActor
    func testClosingOrMovingTheVisibleTabClearsTheMarkOnTheTabItReveals() throws {
        let f = try ManualUnreadFixture()
        defer { f.clean() }
        let marked = f.project.sessions[0].id
        let meanwhile = f.project.sessions[1].id

        f.model.markSessionUnread(sessionId: marked)
        f.model.requestCloseSession(projectId: f.project.id, sessionId: meanwhile)
        XCTAssertTrue(f.session(marked).markedUnread, "Closing a hidden tab doesn't reveal the marked one")

        let closing = try XCTUnwrap(f.model.addSession(toProjectId: f.project.id))
        XCTAssertEqual(f.model.globalSelectedSessionId, closing)
        f.model.closeSelectedSession()
        XCTAssertEqual(f.model.globalSelectedSessionId, marked)
        XCTAssertFalse(f.session(marked).markedUnread)
        XCTAssertNil(NSApp.dockTile.badgeLabel)
        XCTAssertEqual(try f.savedSessions()[marked]?.markedUnread, false)

        f.model.markSessionUnread(sessionId: marked)
        let moving = try XCTUnwrap(f.model.addSession(toProjectId: f.project.id))
        f.model.moveSession(toProjectId: f.other.id, draggedId: moving)
        XCTAssertEqual(f.model.globalSelectedSessionId, marked)
        XCTAssertFalse(f.session(marked).markedUnread)

        let elsewhere = f.other.sessions[0].id
        f.model.markSessionUnread(sessionId: elsewhere)
        f.model.markSessionUnread(sessionId: moving)
        f.model.closeProject(f.project.id)
        XCTAssertEqual(f.model.selectedProjectId, f.other.id)
        XCTAssertEqual(f.model.globalSelectedSessionId, moving)
        XCTAssertFalse(f.session(moving).markedUnread, "Ending the project reveals the other project's tab")
        XCTAssertTrue(f.session(elsewhere).markedUnread)
        XCTAssertEqual(NSApp.dockTile.badgeLabel, "1")
    }

    @MainActor
    func testRemoteClientsMarkUnreadAndReadThroughTheBridge() throws {
        let f = try ManualUnreadFixture()
        defer { f.clean() }
        let shown = f.project.sessions[0].id
        let target = f.project.sessions[1].id
        let bridge: any SessionHost = RemoteModelBridge(model: f.model)
        XCTAssertTrue(bridge.supportsMarkUnread)

        bridge.markUnread(sessionId: target)
        XCTAssertTrue(f.session(target).markedUnread)
        XCTAssertEqual(f.model.projects[0].selectedSessionId, shown, "A remote mark doesn't move the Mac")
        XCTAssertEqual(NSApp.dockTile.badgeLabel, "1")
        var sessions = try XCTUnwrap(bridge.workspace()?.projects[0].sessions)
        XCTAssertEqual(sessions[1].unread, true)
        XCTAssertEqual(sessions[1].markedUnread, true)
        XCTAssertNil(sessions[0].markedUnread)
        XCTAssertEqual(try f.savedSessions()[target]?.markedUnread, true)

        bridge.markRead(sessionId: target)
        sessions = try XCTUnwrap(bridge.workspace()?.projects[0].sessions)
        XCTAssertFalse(sessions[1].unread)
        XCTAssertNil(sessions[1].markedUnread)
        XCTAssertEqual(try f.savedSessions()[target]?.markedUnread, false)

        bridge.markUnread(sessionId: "does-not-exist")
        XCTAssertNil(NSApp.dockTile.badgeLabel)
    }

    @MainActor
    func testLateMarkReadLeavesANewerFinishedTurnUnread() throws {
        let f = try ManualUnreadFixture()
        defer { f.clean() }
        let target = f.project.sessions[1].id
        let bridge: any SessionHost = RemoteModelBridge(model: f.model)
        func snapshot() throws -> RemoteSessionSnapshot {
            try XCTUnwrap(bridge.workspace()?.projects[0].sessions[1])
        }
        XCTAssertNil(try snapshot().unreadMarker, "A read session has nothing to acknowledge")

        f.finishTurn(target, startingAt: 100)
        let seen = try snapshot()
        XCTAssertTrue(seen.unread && seen.ready, "The client saw the first turn finish")

        f.finishTurn(target, startingAt: 300)
        bridge.markRead(sessionId: target, unreadMarker: seen.unreadMarker)
        var current = try snapshot()
        XCTAssertTrue(current.unread, "The mark was for the first turn, not the one that finished since")
        XCTAssertTrue(current.ready)
        XCTAssertNotEqual(current.unreadMarker, seen.unreadMarker)

        bridge.markRead(sessionId: target, unreadMarker: current.unreadMarker)
        current = try snapshot()
        XCTAssertFalse(current.unread || current.ready, "A mark for what is shown now applies")
        XCTAssertNil(current.unreadMarker)

        // An aborted turn lights only the finished dot, and a second one outdates the first.
        f.model.setStatus(sessionId: target, status: .running, text: nil, timestamp: 500)
        f.model.setStatus(sessionId: target, status: .idle, text: nil, timestamp: 550, source: "session-end")
        let aborted = try snapshot()
        XCTAssertTrue(aborted.ready && !aborted.unread)
        f.model.setStatus(sessionId: target, status: .running, text: nil, timestamp: 600)
        f.model.setStatus(sessionId: target, status: .idle, text: nil, timestamp: 650, source: "session-end")
        bridge.markRead(sessionId: target, unreadMarker: aborted.unreadMarker)
        current = try snapshot()
        XCTAssertTrue(current.ready)
        bridge.markRead(sessionId: target, unreadMarker: current.unreadMarker)
        XCTAssertFalse(try snapshot().ready)

        // A notification on a session that is already unread is something newer too.
        f.model.postNotification(projectId: f.project.id, sessionId: target, title: "First", body: nil)
        let notified = try snapshot()
        XCTAssertTrue(notified.unread && !notified.ready)
        f.model.postNotification(projectId: f.project.id, sessionId: target, title: "Second", body: nil)
        bridge.markRead(sessionId: target, unreadMarker: notified.unreadMarker)
        XCTAssertTrue(try snapshot().unread)

        // A client that sends no marker clears whatever is unread, as it always has.
        f.finishTurn(target, startingAt: 700)
        f.finishTurn(target, startingAt: 900)
        bridge.markRead(sessionId: target)
        XCTAssertFalse(try snapshot().unread)
    }

    @MainActor
    func testLateMarkReadLeavesANewerManualMarkUnread() throws {
        let f = try ManualUnreadFixture()
        defer { f.clean() }
        let target = f.project.sessions[1].id
        let bridge: any SessionHost = RemoteModelBridge(model: f.model)
        func snapshot() throws -> RemoteSessionSnapshot {
            try XCTUnwrap(bridge.workspace()?.projects[0].sessions[1])
        }

        f.finishTurn(target, startingAt: 100)
        let seen = try snapshot()
        f.model.markSessionRead(sessionId: target)
        bridge.markUnread(sessionId: target)

        bridge.markRead(sessionId: target, unreadMarker: seen.unreadMarker)
        let marked = try snapshot()
        XCTAssertEqual(marked.markedUnread, true, "The mark was set after the state this receipt is for")
        XCTAssertEqual(try f.savedSessions()[target]?.markedUnread, true)

        // The saved mark outlives a relaunch. Its marker doesn't, so a receipt from
        // before the relaunch is stale and one for the new snapshot applies.
        let relaunched = f.relaunch()
        let restarted: any SessionHost = RemoteModelBridge(model: relaunched)
        restarted.markRead(sessionId: target, unreadMarker: marked.unreadMarker)
        let restored = try XCTUnwrap(restarted.workspace()?.projects[0].sessions[1])
        XCTAssertEqual(restored.markedUnread, true)
        XCTAssertNotEqual(restored.unreadMarker, marked.unreadMarker)

        restarted.markRead(sessionId: target, unreadMarker: restored.unreadMarker)
        XCTAssertFalse(try XCTUnwrap(restarted.workspace()?.projects[0].sessions[1]).unread)
        XCTAssertEqual(try f.savedSessions()[target]?.markedUnread, false)
    }

    @MainActor
    func testMarkAsReadClearsTheManualMarkAndAllAttention() throws {
        let f = try ManualUnreadFixture()
        defer { f.clean() }
        let target = f.project.sessions[1].id

        f.model.markSessionUnread(sessionId: target)
        f.model.markSessionUnread(sessionId: target)
        f.model.markSessionUnread(sessionId: "does-not-exist")
        XCTAssertEqual(NSApp.dockTile.badgeLabel, "1")

        f.model.markSessionRead(sessionId: target)
        XCTAssertFalse(f.session(target).isUnread)
        XCTAssertFalse(f.session(target).finishedUnseen)
        XCTAssertNil(NSApp.dockTile.badgeLabel)
        XCTAssertFalse(f.model.remoteWorkspaceSnapshot().projects[0].sessions[1].unread)
        XCTAssertEqual(try f.savedSessions()[target]?.markedUnread, false)
        XCTAssertEqual(f.model.projects[0].selectedSessionId, f.project.sessions[0].id)
    }

    @MainActor
    func testSessionMenuTogglesBetweenMarkAsUnreadAndMarkAsRead() throws {
        let f = try ManualUnreadFixture()
        defer { f.clean() }
        let shown = f.project.sessions[0].id

        XCTAssertFalse(f.model.selectedSessionOffersMarkAsRead)
        f.model.toggleSelectedSessionRead()
        XCTAssertTrue(f.session(shown).markedUnread)
        XCTAssertTrue(f.model.selectedSessionOffersMarkAsRead, "⇧⌘U now offers Mark as Read")
        XCTAssertEqual(NSApp.dockTile.badgeLabel, "1")

        f.model.toggleSelectedSessionRead()
        XCTAssertFalse(f.session(shown).isUnread)
        XCTAssertFalse(f.model.selectedSessionOffersMarkAsRead)
        XCTAssertNil(NSApp.dockTile.badgeLabel)
        XCTAssertEqual(try f.savedSessions()[shown]?.markedUnread, false)
        XCTAssertFalse(try f.stateText().contains("markedUnread"))

        var notified = Session(title: "Notified", cwd: f.root.path)
        XCTAssertFalse(notified.offersMarkAsRead)
        notified.hasUnread = true
        XCTAssertTrue(notified.offersMarkAsRead)
        var finished = Session(title: "Finished", cwd: f.root.path)
        finished.finishedUnseen = true
        XCTAssertTrue(finished.offersMarkAsRead, "A finished dot also offers Mark as Read")
    }
}

private final class ManualUnreadFixture {
    let root: URL
    let repository: StateRepository
    let project: Project
    let other: Project
    let model: AppModel
    private var relaunched: [AppModel] = []
    private let oldStateDirectory: String?
    private let originalDockBadge: String?

    @MainActor
    init() throws {
        _ = NSApplication.shared
        originalDockBadge = NSApp.dockTile.badgeLabel
        NSApp.dockTile.badgeLabel = nil
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        oldStateDirectory = ProcessInfo.processInfo.environment["COPILOT_PROJECTS_STATE_DIR"]
        setenv("COPILOT_PROJECTS_STATE_DIR", root.path, 1)
        let sessions = [Session(title: "Come back", cwd: root.path), Session(title: "Meanwhile", cwd: root.path)]
        project = Project(name: "Work", cwd: root.path, sessions: sessions, selectedSessionId: sessions[0].id)
        other = Project(name: "Other", cwd: root.path, sessions: [Session(title: "Elsewhere", cwd: root.path)])
        repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(projects: [project, other], selectedProjectId: project.id))
        model = Self.makeModel(repository: repository, root: root)
    }

    @MainActor
    private static func makeModel(repository: StateRepository, root: URL) -> AppModel {
        AppModel(
            stateRepository: repository, isAppActive: { true },
            agentActivityDirectory: root, resumeMarkerDirectory: root,
            kittyImageDiskStore: RemoteKittyImageDiskStore(root: root.appendingPathComponent("images")),
            gracefulSessionDestroyer: { _, _ in Task {} },
            forcedSessionDestroyer: { _ in },
            alertPresenter: { alert in
                XCTFail("Unexpected alert: \(alert.messageText)")
                return .alertFirstButtonReturn
            }
        )
    }

    /// A fresh model over the same saved workspace, as after quitting and reopening.
    @MainActor
    func relaunch() -> AppModel {
        let model = Self.makeModel(repository: repository, root: root)
        relaunched.append(model)
        return model
    }

    @MainActor
    func session(_ id: String) -> Session {
        model.projects.flatMap(\.sessions).first { $0.id == id }!
    }

    /// Runs a turn to completion, as the CLI's hooks report it.
    @MainActor
    func finishTurn(_ sessionId: String, startingAt start: Int64) {
        model.setStatus(sessionId: sessionId, status: .running, text: nil, timestamp: start)
        model.setStatus(
            sessionId: sessionId, status: .idle, text: nil, timestamp: start + 100,
            source: "session-idle", notification: .completed
        )
    }

    func savedSessions() throws -> [String: Session] {
        guard case .loaded(let state) = repository.load() else {
            struct WorkspaceDidNotLoad: Error {}
            throw WorkspaceDidNotLoad()
        }
        return Dictionary(uniqueKeysWithValues: state.projects.flatMap(\.sessions).map { ($0.id, $0) })
    }

    func stateText() throws -> String {
        String(decoding: try Data(contentsOf: repository.path), as: UTF8.self)
    }

    @MainActor
    func clean() {
        for model in relaunched + [self.model] {
            model.forcePendingSessionDestroys()
            model.detachAllClients()
        }
        NSApp.dockTile.badgeLabel = originalDockBadge
        if let oldStateDirectory { setenv("COPILOT_PROJECTS_STATE_DIR", oldStateDirectory, 1) }
        else { unsetenv("COPILOT_PROJECTS_STATE_DIR") }
        try? FileManager.default.removeItem(at: root)
    }
}
