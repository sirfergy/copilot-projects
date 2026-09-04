import XCTest
@testable import copilot_projects
import CopilotProjectsCore
import AppKit

final class NotificationIndicatorTests: XCTestCase {
    @MainActor
    func testUnreadIndicatorDoesNotDuplicateFinishedDot() {
        let cases: [(status: SessionStatus, finished: Bool, unread: Bool, expected: Bool)] = [
            (.idle, false, false, false),
            (.idle, false, true, true), // A custom alert has no leading finished dot.
            (.idle, true, false, false),
            (.idle, true, true, false), // Completion already has a leading blue dot.
            (.running, false, false, false),
            (.running, false, true, true),
            (.running, true, false, false),
            (.running, true, true, true),
            (.waiting, false, false, false),
            (.waiting, false, true, true),
            (.waiting, true, false, false),
            (.waiting, true, true, true),
        ]
        for (status, finished, unread, expected) in cases {
            var session = Session(title: "target", cwd: "/tmp")
            session.status = status
            session.finishedUnseen = finished
            session.hasUnread = unread
            let tab = SessionTab(
                session: session, isActive: false, onSelect: {}, onClose: {}
            )
            XCTAssertEqual(
                tab.showsUnreadIndicator, expected,
                "status=\(status), finished=\(finished), unread=\(unread)"
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
                source: "session-idle", notification: .completed
            )
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
        XCTAssertTrue(SessionTab(
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
}
