import AppKit
import XCTest
import CopilotProjectsCore
import CopilotProjectsProtocol
@testable import CopilotProjectsHost

private struct OfflineRanker: SessionRanking {
    func rank(query: String, entries: [SessionFinderEntry]) async throws -> [LunaMatch] { [] }
}

@MainActor
final class AppModelTests: XCTestCase {
    private func withTempStateDirectory(_ body: (URL) throws -> Void) throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let oldStateDir = ProcessInfo.processInfo.environment["COPILOT_PROJECTS_STATE_DIR"]
        let oldCopilotHome = ProcessInfo.processInfo.environment["COPILOT_HOME"]
        setenv("COPILOT_PROJECTS_STATE_DIR", root.path, 1)
        setenv("COPILOT_HOME", root.path, 1)
        defer {
            if let oldStateDir {
                setenv("COPILOT_PROJECTS_STATE_DIR", oldStateDir, 1)
            } else {
                unsetenv("COPILOT_PROJECTS_STATE_DIR")
            }
            if let oldCopilotHome {
                setenv("COPILOT_HOME", oldCopilotHome, 1)
            } else {
                unsetenv("COPILOT_HOME")
            }
            try? FileManager.default.removeItem(at: root)
        }
        try body(root)
    }

    func testDestroyAndReopenCopilotSessionRestoresMetadataPositionAndCompletesPendingDestroy() throws {
        try withTempStateDirectory { root in
            let parent = Session(title: "Parent", cwd: root.path)
            let copilotId = UUID().uuidString.lowercased()
            let middle = Session(
                title: "Review PR #42",
                cwd: root.path,
                hostId: "woodhaven",
                pullRequestKeys: ["github/copilot-projects#42"],
                parentSessionId: parent.id
            )
            var activity = AgentActivitySnapshot(
                schemaVersion: 1,
                updatedAt: "2026-10-30T00:00:00Z",
                foregroundTurnActive: false,
                scheduledTurnActive: false,
                activeSubagents: [],
                schedules: [],
                idleGeneration: 1,
                lastIdleAborted: false,
                lastIdleTurnKind: nil,
                error: nil
            )
            activity.copilotSessionId = copilotId
            let last = Session(title: "Tail", cwd: root.path)
            let project = Project(
                name: "Main",
                cwd: root.path,
                sessions: [parent, middle, last],
                selectedSessionId: middle.id
            )
            let repository = StateRepository(path: root.appendingPathComponent("state.json"))
            try repository.save(PersistedState(projects: [project], selectedProjectId: project.id))

            var forcedDestroyed: [[String]] = []
            var launched: [(sessionId: String, executable: String?, prompt: String?)] = []
            let remoteHost = RemoteHostInfo(
                id: "woodhaven",
                displayName: "Woodhaven",
                sshTarget: "woodhaven",
                isLocal: false
            )

            let model = AppModel(
                stateRepository: repository,
                isAppActive: { false },
                agentActivityDirectory: root,
                resumeMarkerDirectory: root,
                remoteCopilotExecutable: { "/usr/local/bin/copilot" },
                remoteWrapperExecutable: { "/usr/local/bin/copilot-remote-wrapper" },
                remoteSessionBackendAvailable: { true },
                availableHostsProvider: { [.local, remoteHost] },
                remoteSessionLauncher: { sessionId, executable, prompt in
                    launched.append((sessionId, executable, prompt))
                },
                kittyImageDiskStore: RemoteKittyImageDiskStore(root: root.appendingPathComponent("images")),
                gracefulSessionDestroyer: { _, _ in
                    Task {
                        try? await Task.sleep(nanoseconds: 60_000_000_000)
                    }
                },
                forcedSessionDestroyer: { ids in
                    forcedDestroyed.append(ids)
                }
            )
            defer {
                model.forcePendingSessionDestroys()
                model.detachAllClients()
            }
            model.projects[0].sessions[1].agentActivity = activity

            XCTAssertFalse(model.canReopenClosedSession)
            XCTAssertTrue(model.destroySession(projectId: project.id, sessionId: middle.id))
            XCTAssertTrue(model.canReopenClosedSession)
            XCTAssertEqual(model.recentlyClosedSessions.count, 1)
            XCTAssertEqual(model.recentlyClosedSessions.first?.originalSessionId, middle.id)
            XCTAssertEqual(model.recentlyClosedSessions.first?.copilotSessionId, copilotId)
            XCTAssertTrue(forcedDestroyed.isEmpty, "Graceful destroy is still in flight before reopen")

            let reopenedId = try XCTUnwrap(model.reopenClosedSession())
            XCTAssertNotEqual(reopenedId, middle.id)
            XCTAssertFalse(model.canReopenClosedSession)
            XCTAssertEqual(forcedDestroyed, [[middle.id]], "Reopening force-completes the closed tab's pending destroy first")

            let sessions = model.projects[0].sessions
            XCTAssertEqual(sessions.map(\.id), [parent.id, reopenedId, last.id])
            let reopened = sessions[1]
            XCTAssertEqual(reopened.title, "Review PR #42")
            XCTAssertEqual(reopened.cwd, root.path)
            XCTAssertEqual(reopened.hostId, "woodhaven")
            XCTAssertEqual(reopened.pullRequestKeys, ["github/copilot-projects#42"])
            XCTAssertEqual(reopened.parentSessionId, parent.id)
            XCTAssertEqual(
                reopened.creationFingerprint,
                SessionCreationRecord.resumeFingerprint(projectId: project.id, copilotSessionId: copilotId)
            )
            XCTAssertEqual(model.selectedProjectId, project.id)
            XCTAssertEqual(model.projects[0].selectedSessionId, reopenedId)
            XCTAssertEqual(model.capturedResumeLaunches[reopenedId], copilotId)
            XCTAssertEqual(launched.count, 1)
            XCTAssertEqual(launched.first?.sessionId, reopenedId)
            XCTAssertEqual(launched.first?.executable, "/usr/local/bin/copilot-remote-wrapper")
            XCTAssertNil(launched.first?.prompt)
        }
    }

    func testCommandShiftTReopensClosedPlainTerminalInSameProjectAndPosition() throws {
        try withTempStateDirectory { root in
            let first = Session(title: "first", cwd: root.path)
            let second = Session(title: "build-shell", cwd: "/tmp")
            let third = Session(title: "third", cwd: root.path)
            let project = Project(
                name: "Alpha",
                cwd: root.path,
                sessions: [first, second, third],
                selectedSessionId: second.id
            )
            let otherSession = Session(title: "other", cwd: root.path)
            let otherProject = Project(
                name: "Beta",
                cwd: root.path,
                sessions: [otherSession],
                selectedSessionId: otherSession.id
            )
            let repository = StateRepository(path: root.appendingPathComponent("state.json"))
            try repository.save(PersistedState(projects: [project, otherProject], selectedProjectId: project.id))

            var launched: [(sessionId: String, executable: String?, prompt: String?)] = []
            let model = AppModel(
                stateRepository: repository,
                isAppActive: { false },
                agentActivityDirectory: root,
                resumeMarkerDirectory: root,
                remoteSessionLauncher: { sessionId, executable, prompt in
                    launched.append((sessionId, executable, prompt))
                },
                kittyImageDiskStore: RemoteKittyImageDiskStore(root: root.appendingPathComponent("images")),
                gracefulSessionDestroyer: { _, _ in Task {} },
                forcedSessionDestroyer: { _ in }
            )
            defer {
                model.forcePendingSessionDestroys()
                model.detachAllClients()
            }

            let input = WorkspaceInputController(model: model, sessionRanker: OfflineRanker())
            XCTAssertTrue(model.destroySession(projectId: project.id, sessionId: second.id))
            model.selectProject(otherProject.id)
            XCTAssertEqual(model.selectedProjectId, otherProject.id)

            let reopenEvent = try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.command, .shift],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "T",
                charactersIgnoringModifiers: "T",
                isARepeat: false,
                keyCode: 17
            ))
            XCTAssertNil(input.handleKeyDown(reopenEvent))

            XCTAssertEqual(model.selectedProjectId, project.id)
            XCTAssertEqual(model.projects[0].sessions.count, 3)
            let reopened = model.projects[0].sessions[1]
            XCTAssertNotEqual(reopened.id, second.id)
            XCTAssertEqual(reopened.title, "build-shell")
            XCTAssertEqual(reopened.cwd, "/tmp")
            XCTAssertNil(reopened.creationFingerprint)
            XCTAssertEqual(model.projects[0].selectedSessionId, reopened.id)
            XCTAssertNil(model.capturedResumeLaunches[reopened.id])
            XCTAssertEqual(launched.last?.sessionId, reopened.id)
            XCTAssertNil(launched.last?.executable)
        }
    }

    func testLifoReopenOrderCapExistingTabReuseAndCloseProjectCleanup() throws {
        try withTempStateDirectory { root in
            let a1 = Session(title: "A-1", cwd: root.path)
            let a2 = Session(title: "A-2", cwd: root.path)
            let a3 = Session(title: "A-3", cwd: root.path)
            let projectA = Project(
                name: "Project A",
                cwd: root.path,
                sessions: [a1, a2, a3],
                selectedSessionId: a1.id
            )
            let b1 = Session(title: "B-1", cwd: root.path)
            let b2 = Session(title: "B-2", cwd: root.path)
            let projectB = Project(
                name: "Project B",
                cwd: root.path,
                sessions: [b1, b2],
                selectedSessionId: b1.id
            )
            let repository = StateRepository(path: root.appendingPathComponent("state.json"))
            try repository.save(PersistedState(projects: [projectA, projectB], selectedProjectId: projectA.id))

            var launchedCount = 0
            let model = AppModel(
                stateRepository: repository,
                isAppActive: { false },
                agentActivityDirectory: root,
                resumeMarkerDirectory: root,
                remoteSessionLauncher: { _, _, _ in launchedCount += 1 },
                kittyImageDiskStore: RemoteKittyImageDiskStore(root: root.appendingPathComponent("images")),
                gracefulSessionDestroyer: { _, _ in Task {} },
                forcedSessionDestroyer: { _ in }
            )
            defer {
                model.forcePendingSessionDestroys()
                model.detachAllClients()
            }

            let markerCopilotId = UUID().uuidString.lowercased()
            try Data("\(markerCopilotId)\n".utf8).write(
                to: root.appendingPathComponent("\(a2.id).copilot-session")
            )

            XCTAssertTrue(model.destroySession(projectId: projectA.id, sessionId: a1.id))
            XCTAssertTrue(model.destroySession(projectId: projectB.id, sessionId: b1.id))
            XCTAssertTrue(model.destroySession(projectId: projectA.id, sessionId: a2.id))
            XCTAssertEqual(
                model.recentlyClosedSessions.map(\.title),
                ["A-1", "B-1", "A-2"]
            )

            // Closing Project B removes B-1 from the undo stack without touching Project A's entries.
            model.closeProject(projectB.id)
            XCTAssertEqual(
                model.recentlyClosedSessions.map(\.title),
                ["A-1", "A-2"]
            )
            XCTAssertTrue(model.canReopenClosedSession)

            // Reopen in LIFO order: A-2 first (with its marker-backed copilotSessionId), then A-1.
            let reopenedA2Id = try XCTUnwrap(model.reopenClosedSession())
            XCTAssertEqual(model.capturedResumeLaunches[reopenedA2Id], markerCopilotId)
            XCTAssertEqual(model.projects[0].sessions.map(\.title), ["A-2", "A-3"])

            // If another closed entry shares the same live copilotSessionId, reopening selects the existing tab
            // while within startup grace or backed by a validated marker, but not a stale markerless shell.
            let duplicateTab = Session(title: "Dup", cwd: root.path)
            model.projects[0].sessions.append(duplicateTab)
            try Data("\(markerCopilotId)\n".utf8).write(
                to: root.appendingPathComponent("\(duplicateTab.id).copilot-session")
            )
            XCTAssertTrue(model.destroySession(projectId: projectA.id, sessionId: duplicateTab.id))
            let launchesBeforeDuplicateReopen = launchedCount
            XCTAssertEqual(model.reopenClosedSession(), reopenedA2Id)
            XCTAssertEqual(launchedCount, launchesBeforeDuplicateReopen)
            XCTAssertEqual(model.projects[0].selectedSessionId, reopenedA2Id)

            // Once startup grace expires without a marker on reopenedA2Id, a closed session for the same
            // copilotSessionId must not match the stale markerless tab via capturedResumeLaunches.
            model.pullRequestsResumeLaunches[markerCopilotId] = (
                reopenedA2Id,
                Date(timeIntervalSinceNow: -(AppModel.pullRequestsResumeStartupGrace + 1))
            )
            let anotherClosed = Session(title: "Resumed Later", cwd: root.path)
            model.projects[0].sessions.append(anotherClosed)
            try Data("\(markerCopilotId)\n".utf8).write(
                to: root.appendingPathComponent("\(anotherClosed.id).copilot-session")
            )
            XCTAssertTrue(model.destroySession(projectId: projectA.id, sessionId: anotherClosed.id))
            let freshReopenedId = try XCTUnwrap(model.reopenClosedSession())
            XCTAssertNotEqual(freshReopenedId, reopenedA2Id)
            XCTAssertEqual(model.capturedResumeLaunches[freshReopenedId], markerCopilotId)
            model.projects[0].sessions.removeAll { $0.id == freshReopenedId }

            let reopenedA1Id = try XCTUnwrap(model.reopenClosedSession())
            XCTAssertNil(model.capturedResumeLaunches[reopenedA1Id])
            XCTAssertEqual(model.projects[0].sessions.map(\.title), ["A-1", "A-2", "A-3"])
            XCTAssertFalse(model.canReopenClosedSession)
            XCTAssertNil(model.reopenClosedSession())

            // Verify 20-entry cap on recentlyClosedSessions.
            for idx in 1...25 {
                let extra = Session(title: "Extra-\(idx)", cwd: root.path)
                model.projects[0].sessions.append(extra)
                XCTAssertTrue(model.destroySession(projectId: projectA.id, sessionId: extra.id))
            }
            XCTAssertEqual(model.recentlyClosedSessions.count, AppModel.maxRecentlyClosedSessions)
            XCTAssertEqual(model.recentlyClosedSessions.first?.title, "Extra-6")
            XCTAssertEqual(model.recentlyClosedSessions.last?.title, "Extra-25")
        }
    }

    func testReopenWaitsForSessionLockReleaseAndRetainsUndoEntryOnTimeout() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let oldStateDir = ProcessInfo.processInfo.environment["COPILOT_PROJECTS_STATE_DIR"]
        let oldCopilotHome = ProcessInfo.processInfo.environment["COPILOT_HOME"]
        setenv("COPILOT_PROJECTS_STATE_DIR", root.path, 1)
        setenv("COPILOT_HOME", root.path, 1)
        defer {
            if let oldStateDir { setenv("COPILOT_PROJECTS_STATE_DIR", oldStateDir, 1) } else { unsetenv("COPILOT_PROJECTS_STATE_DIR") }
            if let oldCopilotHome { setenv("COPILOT_HOME", oldCopilotHome, 1) } else { unsetenv("COPILOT_HOME") }
            try? FileManager.default.removeItem(at: root)
        }

        let copilotId = UUID().uuidString.lowercased()
        let session = Session(title: "Locked Copilot", cwd: root.path)
        let later = Session(title: "Closed During Wait", cwd: root.path)
        let project = Project(name: "Main", cwd: root.path, sessions: [session, later], selectedSessionId: session.id)
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(projects: [project], selectedProjectId: project.id))
        try Data("\(copilotId)\n".utf8).write(to: root.appendingPathComponent("\(session.id).copilot-session"))

        let sessionDir = root.appendingPathComponent("session-state/\(copilotId)")
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let lockFile = sessionDir.appendingPathComponent("inuse.\(getpid()).lock")
        try Data().write(to: lockFile)

        var launched: [String] = []
        let model = AppModel(
            stateRepository: repository,
            isAppActive: { false },
            agentActivityDirectory: root,
            resumeMarkerDirectory: root,
            remoteCopilotExecutable: { "/usr/local/bin/copilot" },
            remoteSessionLauncher: { sessionId, _, _ in launched.append(sessionId) },
            kittyImageDiskStore: RemoteKittyImageDiskStore(root: root.appendingPathComponent("images")),
            gracefulSessionDestroyer: { _, _ in Task {} },
            forcedSessionDestroyer: { _ in }
        )
        defer {
            model.forcePendingSessionDestroys()
            model.detachAllClients()
        }
        model.reopenShutdownTimeout = .milliseconds(120)

        XCTAssertTrue(model.destroySession(projectId: project.id, sessionId: session.id))

        // 1. When the lock remains held past the timeout, reopen does not launch and retains the undo entry
        // in its original LIFO position beneath any session closed during the wait.
        XCTAssertNil(model.reopenClosedSession())
        XCTAssertTrue(model.destroySession(projectId: project.id, sessionId: later.id))
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(launched.isEmpty)
        XCTAssertEqual(model.recentlyClosedSessions.map(\.title), ["Locked Copilot", "Closed During Wait"])
        let reopenedLaterId = try XCTUnwrap(model.reopenClosedSession())
        XCTAssertEqual(launched, [reopenedLaterId])
        XCTAssertEqual(model.recentlyClosedSessions.map(\.title), ["Locked Copilot"])

        // 2. When the lock releases during the bounded wait, reopen finishes launching asynchronously.
        model.reopenShutdownTimeout = .milliseconds(500)
        XCTAssertNil(model.reopenClosedSession())
        try? FileManager.default.removeItem(at: lockFile)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(launched.count, 2)
        XCTAssertTrue(model.recentlyClosedSessions.isEmpty)
        XCTAssertEqual(model.capturedResumeLaunches[launched[1]], copilotId)
    }
}
