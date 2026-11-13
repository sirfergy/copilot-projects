import XCTest
@testable import CopilotProjectsHost
import CopilotProjectsCore
import CopilotProjectsProtocol
import AppKit

final class NotificationIndicatorTests: XCTestCase {
    @MainActor
    func testSessionRowAccessibilityKeepsSelectionAndAttentionDistinct() {
        var session = Session(title: "Review", cwd: "/tmp")
        session.status = .waiting
        session.hasUnread = true
        let selected = SessionRow(session: session, isActive: true, onSelect: {}, onClose: {})
        XCTAssertEqual(selected.accessibilityStatus, "Selected, Waiting for input, Unread")
        XCTAssertEqual(selected.stateLabel, "Waiting for input")

        session.status = .idle
        session.finishedUnseen = true
        let background = SessionRow(session: session, isActive: false, onSelect: {}, onClose: {})
        XCTAssertEqual(background.accessibilityStatus, "Finished, Unread")
        XCTAssertEqual(background.stateLabel, "Finished")
        session.hasUnread = false
        session.finishedUnseen = false
        XCTAssertEqual(
            SessionRow(session: session, isActive: false, onSelect: {}, onClose: {}).accessibilityStatus,
            "Idle"
        )
    }

    @MainActor
    func testUnreadIndicatorDoesNotDuplicateFinishedDot() {
        let cases: [(status: SessionStatus, finished: Bool, unread: Bool, showNumber: Bool, expected: Bool)] = [
            (.idle, false, false, false, false),
            (.idle, false, true, false, true), // A custom alert has no leading finished dot.
            (.idle, true, false, false, false),
            (.idle, true, true, false, false), // Completion already has a leading blue dot.
            (.idle, true, true, true, true), // Number hint hides the leading completion dot.
            (.running, false, false, false, false),
            (.running, false, true, false, true),
            (.running, true, false, false, false),
            (.running, true, true, false, true),
            (.waiting, false, false, false, false),
            (.waiting, false, true, false, true),
            (.waiting, true, false, false, false),
            (.waiting, true, true, false, true),
        ]
        for (status, finished, unread, showNumber, expected) in cases {
            var session = Session(title: "target", cwd: "/tmp")
            session.status = status
            session.finishedUnseen = finished
            session.hasUnread = unread
            let row = SessionRow(
                session: session, isActive: false, showNumber: showNumber,
                onSelect: {}, onClose: {}
            )
            XCTAssertEqual(
                row.showsUnreadIndicator, expected,
                "status=\(status), finished=\(finished), unread=\(unread), showNumber=\(showNumber)"
            )
        }
    }

    @MainActor
    func testActivationClearsOnlySelectedSessionNotifications() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let originalDockBadge = NSApp.dockTile.badgeLabel
        defer {
            NSApp.dockTile.badgeLabel = originalDockBadge
            try? FileManager.default.removeItem(at: root)
        }

        let selected = Session(title: "selected", cwd: "/tmp")
        let otherTab = Session(title: "other tab", cwd: "/tmp")
        let otherSession = Session(title: "other project", cwd: "/tmp")
        let project = Project(
            name: "selected", cwd: "/tmp", sessions: [selected, otherTab],
            selectedSessionId: selected.id
        )
        let otherProject = Project(
            name: "other", cwd: "/tmp", sessions: [otherSession],
            selectedSessionId: otherSession.id
        )
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(
            projects: [project, otherProject], selectedProjectId: project.id
        ))
        var appIsActive = false
        let model = AppModel(stateRepository: repository, isAppActive: { appIsActive })
        for session in [selected, otherTab, otherSession] {
            model.setStatus(sessionId: session.id, status: .running, text: nil, timestamp: 100)
            model.setStatus(
                sessionId: session.id, status: .idle, text: nil, timestamp: 200,
                source: "agent-stop"
            )
            model.postCompletionIfReady(sessionId: session.id)
        }
        XCTAssertTrue(model.projects[0].sessions[0].hasUnread)
        XCTAssertTrue(model.projects[0].sessions[0].finishedUnseen)
        XCTAssertEqual(NSApp.dockTile.badgeLabel, "3")

        appIsActive = true
        model.markActiveSessionSeen()

        XCTAssertFalse(model.projects[0].sessions[0].hasUnread)
        XCTAssertFalse(model.projects[0].sessions[0].finishedUnseen)
        XCTAssertEqual(NSApp.dockTile.badgeLabel, "2")
        XCTAssertEqual(model.totalReady, 2)
        XCTAssertEqual(model.selectedProjectId, project.id)
        XCTAssertEqual(model.projects[0].selectedSessionId, selected.id)
        XCTAssertTrue(model.projects[0].sessions[1].hasUnread)
        XCTAssertTrue(model.projects[0].sessions[1].finishedUnseen)
        XCTAssertTrue(model.projects[1].sessions[0].hasUnread)
        XCTAssertTrue(model.projects[1].sessions[0].finishedUnseen)

        let snapshot = model.remoteWorkspaceSnapshot()
        XCTAssertFalse(snapshot.projects[0].sessions[0].unread)
        XCTAssertFalse(snapshot.projects[0].sessions[0].ready)
        XCTAssertTrue(snapshot.projects[0].sessions[1].unread)
        XCTAssertTrue(snapshot.projects[0].sessions[1].ready)
        XCTAssertTrue(snapshot.projects[1].sessions[0].unread)
        XCTAssertTrue(snapshot.projects[1].sessions[0].ready)

        model.markActiveSessionSeen()
        XCTAssertEqual(NSApp.dockTile.badgeLabel, "2")

        model.setStatus(sessionId: otherTab.id, status: .running, text: nil, timestamp: 300)
        let runningSession = model.projects[0].sessions[1]
        XCTAssertFalse(runningSession.finishedUnseen)
        XCTAssertTrue(runningSession.hasUnread)
        XCTAssertTrue(SessionRow(
            session: runningSession, isActive: false, onSelect: {}, onClose: {}
        ).showsUnreadIndicator)
    }

    @MainActor
    func testActivationClearsUnreadOnlyNotificationAndDockBadge() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let originalDockBadge = NSApp.dockTile.badgeLabel
        defer {
            NSApp.dockTile.badgeLabel = originalDockBadge
            try? FileManager.default.removeItem(at: root)
        }

        let session = Session(title: "selected", cwd: "/tmp")
        let project = Project(
            name: "selected", cwd: "/tmp", sessions: [session], selectedSessionId: session.id
        )
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(projects: [project], selectedProjectId: project.id))
        var appIsActive = false
        let model = AppModel(stateRepository: repository, isAppActive: { appIsActive })
        model.postNotification(
            projectId: project.id, sessionId: session.id, title: "Update", body: nil
        )
        XCTAssertTrue(model.projects[0].sessions[0].hasUnread)
        XCTAssertFalse(model.projects[0].sessions[0].finishedUnseen)
        XCTAssertEqual(NSApp.dockTile.badgeLabel, "1")

        appIsActive = true
        model.markActiveSessionSeen()

        XCTAssertFalse(model.projects[0].sessions[0].hasUnread)
        XCTAssertFalse(model.projects[0].sessions[0].finishedUnseen)
        XCTAssertNil(NSApp.dockTile.badgeLabel)

        model.postNotification(
            projectId: project.id, sessionId: session.id, title: "Visible update", body: nil
        )
        XCTAssertFalse(model.projects[0].sessions[0].hasUnread)
        XCTAssertNil(NSApp.dockTile.badgeLabel)
    }

    @MainActor
    func testChildSessionSuppressesCompletionNotificationUnlessAskingQuestionOrUngrouped() async throws {
        _ = NSApplication.shared
        final class NotificationSpy: NotificationPosting {
            var posted: [NotificationEvent] = []
            var onPost: ((NotificationEvent) -> Void)?
            func post(_ event: NotificationEvent) {
                posted.append(event)
                onPost?(event)
            }
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let parent = Session(title: "Orchestrator", cwd: "/tmp")
        let child = Session(title: "Worker", cwd: "/tmp", parentSessionId: parent.id)
        let originalDockBadge = NSApp.dockTile.badgeLabel
        // The first step expects no badge, and an earlier test's model can leave a count here.
        NSApp.dockTile.badgeLabel = nil
        defer {
            NSApp.dockTile.badgeLabel = originalDockBadge
            SessionArtifacts.removeFiles(sessionId: parent.id)
            SessionArtifacts.removeFiles(sessionId: child.id)
            try? FileManager.default.removeItem(at: root)
        }

        let project = Project(
            name: "Fleet", cwd: "/tmp", sessions: [parent, child], selectedSessionId: parent.id
        )
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(projects: [project], selectedProjectId: project.id))
        let spy = NotificationSpy()
        let model = AppModel(
            stateRepository: repository,
            completionTranscriptLoader: { _ in
                TranscriptSnapshot(schemaVersion: 3, updatedAt: Date(), copilotSessionId: "conv", turns: [])
            },
            elicitationReplyRetryDelaysNanoseconds: [],
            isAppActive: { false },
            agentActivityDirectory: root,
            resumeMarkerDirectory: root
        )
        model.attach(notifications: spy)

        // 1. Child finishing a turn stays quiet (no completed notification, unread, or ready dot).
        model.setStatus(
            sessionId: child.id, status: .running, text: nil, timestamp: 100,
            copilotSessionId: "conv"
        )
        model.setStatus(
            sessionId: child.id, status: .idle, text: nil, timestamp: 200,
            source: "agent-stop", copilotSessionId: "conv"
        )
        model.postCompletionIfReady(sessionId: child.id)
        XCTAssertTrue(spy.posted.isEmpty)
        XCTAssertFalse(model.projects[0].sessions[1].hasUnread)
        XCTAssertFalse(model.projects[0].sessions[1].finishedUnseen)
        XCTAssertNil(NSApp.dockTile.badgeLabel)

        // 2. Child aborting/ending without a completion signal also stays quiet.
        model.setStatus(sessionId: child.id, status: .running, text: nil, timestamp: 300)
        model.setStatus(sessionId: child.id, status: .idle, text: nil, timestamp: 400, source: "session-end")
        XCTAssertTrue(spy.posted.isEmpty)
        XCTAssertFalse(model.projects[0].sessions[1].hasUnread)
        XCTAssertFalse(model.projects[0].sessions[1].finishedUnseen)


        // 3. Child asking a question still notifies and marks unread.
        let questionTimestamp = SessionArtifacts.currentStatusTimestamp() + 10
        model.setStatus(
            sessionId: child.id, status: .waiting, text: "Ask user", timestamp: questionTimestamp,
            notification: .elicitation
        )
        XCTAssertEqual(spy.posted.map(\.kind), [.elicitation])
        XCTAssertEqual(spy.posted.first?.sessionId, child.id)
        XCTAssertTrue(model.projects[0].sessions[1].hasUnread)

        model.markSessionRead(sessionId: child.id)
        spy.posted.removeAll()

        // 4. Once ungrouped to top-level, turn completion marks ready and notifies normally.
        model.ungroupSession(projectId: project.id, sessionId: child.id)

        let completed = expectation(description: "ungrouped completion posted")
        spy.onPost = { event in
            if event.kind == .completed {
                completed.fulfill()
            }
        }
        let finishStart = SessionArtifacts.currentStatusTimestamp() + 1_000
        model.setStatus(
            sessionId: child.id, status: .running, text: nil, timestamp: finishStart,
            copilotSessionId: "conv"
        )
        model.setStatus(
            sessionId: child.id, status: .idle, text: nil, timestamp: finishStart + 100,
            source: "agent-stop", copilotSessionId: "conv"
        )
        model.postCompletionIfReady(sessionId: child.id)
        await fulfillment(of: [completed], timeout: 1.0)
        XCTAssertEqual(spy.posted.map(\.kind), [.completed])
        XCTAssertTrue(model.projects[0].sessions[1].hasUnread)
        XCTAssertTrue(model.projects[0].sessions[1].finishedUnseen)
    }
}
