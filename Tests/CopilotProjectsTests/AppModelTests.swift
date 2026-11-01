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

    func testRecentlyClosedSessionItemsAndTargetedReopenByIdAndRemoteBridge() throws {
        try withTempStateDirectory { root in
            let remoteHost = RemoteHostInfo(
                id: "woodhaven",
                displayName: "Woodhaven",
                sshTarget: "woodhaven",
                isLocal: false
            )
            let s1 = Session(title: "First", cwd: root.path)
            let s2 = Session(title: "Second-Remote", cwd: root.path, hostId: "woodhaven")
            let s3 = Session(title: "Third-Copilot", cwd: root.path)
            let s4 = Session(title: "KeepOpen", cwd: root.path)
            let projectA = Project(
                name: "Project A",
                cwd: root.path,
                sessions: [s1, s2, s3, s4],
                selectedSessionId: s1.id
            )
            let b1 = Session(title: "Other-Project-Tab", cwd: root.path)
            let projectB = Project(
                name: "Project B",
                cwd: root.path,
                sessions: [b1],
                selectedSessionId: b1.id
            )
            let repository = StateRepository(path: root.appendingPathComponent("state.json"))
            try repository.save(PersistedState(projects: [projectA, projectB], selectedProjectId: projectA.id))

            let model = AppModel(
                stateRepository: repository,
                isAppActive: { false },
                agentActivityDirectory: root,
                resumeMarkerDirectory: root,
                remoteCopilotExecutable: { "/usr/local/bin/copilot" },
                remoteWrapperExecutable: { "/usr/local/bin/copilot-remote-wrapper" },
                remoteSessionBackendAvailable: { true },
                availableHostsProvider: { [.local, remoteHost] },
                remoteSessionLauncher: { _, _, _ in },
                kittyImageDiskStore: RemoteKittyImageDiskStore(root: root.appendingPathComponent("images")),
                gracefulSessionDestroyer: { _, _ in Task {} },
                forcedSessionDestroyer: { _ in }
            )
            defer {
                model.forcePendingSessionDestroys()
                model.detachAllClients()
            }

            let copilotId = UUID().uuidString.lowercased()
            try Data("\(copilotId)\n".utf8).write(
                to: root.appendingPathComponent("\(s3.id).copilot-session")
            )

            let bridge = RemoteModelBridge(model: model)
            XCTAssertTrue(bridge.supportsReopenClosedSession)
            let emptySnapshotData = try JSONEncoder().encode(XCTUnwrap(bridge.workspace()))
            XCTAssertFalse(String(decoding: emptySnapshotData, as: UTF8.self).contains("recentlyClosedSessions"))
            XCTAssertNil(try JSONDecoder().decode(RemoteWorkspaceSnapshot.self, from: emptySnapshotData).recentlyClosedSessions)
            XCTAssertEqual(bridge.reopenClosedSession(id: nil), .missing)

            XCTAssertTrue(model.destroySession(projectId: projectA.id, sessionId: s1.id))
            XCTAssertTrue(model.destroySession(projectId: projectA.id, sessionId: s2.id))
            XCTAssertTrue(model.destroySession(projectId: projectB.id, sessionId: b1.id))
            XCTAssertTrue(model.destroySession(projectId: projectA.id, sessionId: s3.id))

            // Newest-first ordering across projects with host and Copilot metadata.
            let items = model.recentlyClosedSessionItems
            XCTAssertEqual(items.map(\.id), [s3.id, b1.id, s2.id, s1.id])
            XCTAssertEqual(items.map(\.title), ["Third-Copilot", "Other-Project-Tab", "Second-Remote", "First"])
            XCTAssertEqual(items.map(\.projectName), ["Project A", "Project B", "Project A", "Project A"])
            XCTAssertEqual(items.map(\.isCopilotSession), [true, false, false, false])
            XCTAssertEqual(items[2].hostId, "woodhaven")
            XCTAssertEqual(items[2].hostDisplayName, "Woodhaven")
            XCTAssertNil(items[0].hostId)
            XCTAssertNil(items[0].hostDisplayName)
            let snapshotData = try JSONEncoder().encode(model.remoteWorkspaceSnapshot())
            XCTAssertEqual(try JSONDecoder().decode(RemoteWorkspaceSnapshot.self, from: snapshotData).recentlyClosedSessions, items)

            // Reopen a specific non-top entry (s2) by id; newer/older entries remain intact.
            let reopenedS2Id = try XCTUnwrap(model.reopenClosedSession(id: s2.id))
            XCTAssertNotEqual(reopenedS2Id, s2.id)
            XCTAssertEqual(model.recentlyClosedSessionItems.map(\.id), [s3.id, b1.id, s1.id])
            XCTAssertEqual(model.projects[0].sessions.map(\.title), ["Second-Remote", "KeepOpen"])
            XCTAssertEqual(model.projects[0].sessions[0].hostId, "woodhaven")

            // Unknown id returns .missing without disturbing the remaining stack.
            XCTAssertEqual(bridge.reopenClosedSession(id: "nonexistent"), .missing)
            XCTAssertEqual(model.recentlyClosedSessionItems.map(\.id), [s3.id, b1.id, s1.id])

            // Remote reopen by explicit id for s1 (oldest entry).
            let remoteSpecific = bridge.reopenClosedSession(id: s1.id)
            guard case let .reopened(projectId: reopenedProjectId, sessionId: reopenedS1Id) = remoteSpecific else {
                return XCTFail("Expected .reopened for s1, got \(remoteSpecific)")
            }
            XCTAssertEqual(reopenedProjectId, projectA.id)
            XCTAssertEqual(model.projects[0].sessions.first?.id, reopenedS1Id)
            XCTAssertEqual(model.projects[0].sessions.map(\.title), ["First", "Second-Remote", "KeepOpen"])
            XCTAssertEqual(model.recentlyClosedSessionItems.map(\.id), [s3.id, b1.id])

            // Remote reopen with "latest" token reopens the newest remaining entry (s3) in its original position.
            let remoteLatest = bridge.reopenClosedSession(id: RemoteReopenSessionContract.latestSessionToken)
            guard case let .reopened(projectId: latestProjectId, sessionId: reopenedS3Id) = remoteLatest else {
                return XCTFail("Expected .reopened for latest, got \(remoteLatest)")
            }
            XCTAssertEqual(latestProjectId, projectA.id)
            XCTAssertEqual(model.capturedResumeLaunches[reopenedS3Id], copilotId)
            XCTAssertEqual(
                model.projects[0].sessions.map(\.title),
                ["First", "Second-Remote", "Third-Copilot", "KeepOpen"]
            )
            XCTAssertEqual(model.recentlyClosedSessionItems.map(\.id), [b1.id])

            // Closing a later tab (Second-Remote) and then an earlier tab (First) before reopening
            // Second-Remote by id shifts Second-Remote left while First remains closed.
            XCTAssertTrue(model.destroySession(projectId: projectA.id, sessionId: reopenedS2Id))
            XCTAssertTrue(model.destroySession(projectId: projectA.id, sessionId: reopenedS1Id))
            XCTAssertNotNil(model.reopenClosedSession(id: reopenedS2Id))
            XCTAssertEqual(
                model.projects[0].sessions.map(\.title),
                ["Second-Remote", "Third-Copilot", "KeepOpen"]
            )
            XCTAssertNotNil(model.reopenClosedSession(id: reopenedS1Id))
            XCTAssertEqual(
                model.projects[0].sessions.map(\.title),
                ["First", "Second-Remote", "Third-Copilot", "KeepOpen"]
            )
        }
    }

    func testProjectScopedRecentlyClosedSessionItemsAndReopen() throws {
        try withTempStateDirectory { root in
            let a1 = Session(title: "A-1", cwd: root.path)
            let a2 = Session(title: "A-2", cwd: root.path)
            let projectA = Project(name: "Project A", cwd: root.path, sessions: [a1, a2], selectedSessionId: a1.id)
            let b1 = Session(title: "B-1", cwd: root.path)
            let projectB = Project(name: "Project B", cwd: root.path, sessions: [b1], selectedSessionId: b1.id)
            let repository = StateRepository(path: root.appendingPathComponent("state.json"))
            try repository.save(PersistedState(projects: [projectA, projectB], selectedProjectId: projectA.id))

            let model = AppModel(
                stateRepository: repository,
                isAppActive: { false },
                agentActivityDirectory: root,
                resumeMarkerDirectory: root,
                remoteCopilotExecutable: { "/usr/local/bin/copilot" },
                remoteWrapperExecutable: { "/usr/local/bin/copilot-remote-wrapper" },
                remoteSessionBackendAvailable: { true },
                availableHostsProvider: { [.local] },
                remoteSessionLauncher: { _, _, _ in },
                kittyImageDiskStore: RemoteKittyImageDiskStore(root: root.appendingPathComponent("images")),
                gracefulSessionDestroyer: { _, _ in Task {} },
                forcedSessionDestroyer: { _ in }
            )
            defer {
                model.forcePendingSessionDestroys()
                model.detachAllClients()
            }

            XCTAssertTrue(model.destroySession(projectId: projectA.id, sessionId: a1.id))
            XCTAssertTrue(model.destroySession(projectId: projectA.id, sessionId: a2.id))
            XCTAssertTrue(model.destroySession(projectId: projectB.id, sessionId: b1.id))

            XCTAssertEqual(model.recentlyClosedSessionItems(forProjectId: projectA.id).map(\.id), [a2.id, a1.id])
            XCTAssertEqual(model.recentlyClosedSessionItems(forProjectId: projectB.id).map(\.id), [b1.id])
            XCTAssertTrue(model.recentlyClosedSessionItems(forProjectId: "unknown").isEmpty)
            XCTAssertNil(model.reopenClosedSession(inProjectId: "unknown"))

            // Reopening in Project A restores A-2 without consuming the newer closed B-1 from Project B.
            let reopenedA2Id = try XCTUnwrap(model.reopenClosedSession(inProjectId: projectA.id))
            XCTAssertEqual(model.projects[0].sessions.map(\.id), [reopenedA2Id])
            XCTAssertEqual(model.projects[0].sessions.map(\.title), ["A-2"])
            XCTAssertEqual(model.recentlyClosedSessionItems(forProjectId: projectA.id).map(\.id), [a1.id])
            XCTAssertEqual(model.recentlyClosedSessionItems(forProjectId: projectB.id).map(\.id), [b1.id])
        }
    }

    func testStartingPromptPersistsAcrossRestartReopenAndPresentAlert() throws {
        try withTempStateDirectory { root in
            let project = Project(name: "Alpha", cwd: root.path)
            let repository = StateRepository(path: root.appendingPathComponent("state.json"))
            try repository.save(PersistedState(projects: [project], selectedProjectId: project.id))

            var presentedAlerts: [(title: String, subtitle: String, text: String, buttons: [String])] = []
            var nextModalResponse: NSApplication.ModalResponse = .alertSecondButtonReturn

            let makeModel: () -> AppModel = {
                AppModel(
                    stateRepository: repository,
                    isAppActive: { false },
                    agentActivityDirectory: root,
                    resumeMarkerDirectory: root,
                    remoteCopilotExecutable: { "/usr/local/bin/copilot" },
                    remoteSessionBackendAvailable: { true },
                    remoteSessionLauncher: { _, _, _ in },
                    kittyImageDiskStore: RemoteKittyImageDiskStore(root: root.appendingPathComponent("images")),
                    gracefulSessionDestroyer: { _, _ in Task {} },
                    forcedSessionDestroyer: { _ in },
                    alertPresenter: { alert in
                        let scrollView = alert.accessoryView as? NSScrollView
                        let textView = scrollView?.documentView as? NSTextView
                        presentedAlerts.append((
                            title: alert.messageText,
                            subtitle: alert.informativeText,
                            text: textView?.string ?? "",
                            buttons: alert.buttons.map(\.title)
                        ))
                        return nextModalResponse
                    }
                )
            }

            let model = makeModel()
            defer {
                model.forcePendingSessionDestroys()
                model.detachAllClients()
            }

            let initialPrompt = "Investigate flaky CI in AppModelTests\nPreserve multiline details"
            let sessionId = try model.addCopilotSession(
                toProjectId: project.id,
                initialPrompt: initialPrompt
            )
            XCTAssertEqual(model.startingPrompt(for: sessionId), initialPrompt)
            XCTAssertEqual(
                model.remoteWorkspaceSnapshot().projects.first?.sessions.first?.startingPrompt,
                initialPrompt
            )

            // Restarting the app (no in-memory TerminalController) preserves startingPrompt from state.json.
            let restarted = makeModel()
            defer {
                restarted.forcePendingSessionDestroys()
                restarted.detachAllClients()
            }
            XCTAssertNil(restarted.controllers[sessionId])
            XCTAssertEqual(restarted.startingPrompt(for: sessionId), initialPrompt)
            XCTAssertEqual(
                restarted.remoteWorkspaceSnapshot().projects.first?.sessions.first?.startingPrompt,
                initialPrompt
            )

            // Presenting starting prompt shows read-only viewer and copies only on primary button.
            NSPasteboard.general.clearContents()
            nextModalResponse = .alertSecondButtonReturn
            restarted.presentStartingPrompt(for: sessionId)
            XCTAssertEqual(presentedAlerts.count, 1)
            XCTAssertEqual(presentedAlerts.last?.title, "Starting Prompt")
            XCTAssertEqual(presentedAlerts.last?.subtitle, "Copilot")
            XCTAssertEqual(presentedAlerts.last?.text, initialPrompt)
            XCTAssertEqual(presentedAlerts.last?.buttons, ["Copy Starting Prompt", "Done"])
            XCTAssertNil(NSPasteboard.general.string(forType: .string))

            nextModalResponse = .alertFirstButtonReturn
            restarted.presentStartingPrompt(for: sessionId)
            XCTAssertEqual(NSPasteboard.general.string(forType: .string), initialPrompt)

            // Destroying and reopening the session preserves startingPrompt on the reopened tab.
            XCTAssertTrue(restarted.destroySession(projectId: project.id, sessionId: sessionId))
            XCTAssertNil(restarted.startingPrompt(for: sessionId))
            XCTAssertEqual(restarted.recentlyClosedSessions.last?.startingPrompt, initialPrompt)

            let reopenedId = try XCTUnwrap(restarted.reopenClosedSession())
            XCTAssertEqual(restarted.startingPrompt(for: reopenedId), initialPrompt)
            XCTAssertEqual(
                restarted.remoteWorkspaceSnapshot().projects.first?.sessions.first?.startingPrompt,
                initialPrompt
            )

            // Adversarial review session also records its starting review prompt on Session.
            let reviewId = try XCTUnwrap(
                restarted.addAdversarialReviewSession(
                    toProjectId: project.id,
                    pullRequestURL: "https://github.com/sirfergy/copilot-projects/pull/99"
                )
            )
            let reviewPrompt = try XCTUnwrap(restarted.startingPrompt(for: reviewId))
            XCTAssertTrue(reviewPrompt.contains("https://github.com/sirfergy/copilot-projects/pull/99"))
        }
    }

    func testStartingPromptRecoversFromActivityFirstRemotePromptAndTranscriptFallback() throws {
        try withTempStateDirectory { root in
            let sActivity = Session(title: "FromActivity", cwd: root.path)
            let sRemote = Session(title: "FromRemoteSend", cwd: root.path)
            let sTranscript = Session(title: "FromTranscript", cwd: root.path)
            let project = Project(
                name: "Recovery",
                cwd: root.path,
                sessions: [sActivity, sRemote, sTranscript],
                selectedSessionId: sActivity.id
            )
            let repository = StateRepository(path: root.appendingPathComponent("state.json"))
            try repository.save(PersistedState(projects: [project], selectedProjectId: project.id))

            // 1. Plain Session without startingPrompt omits startingPrompt in encoded JSON,
            // and Session decodes both base64-prefixed and plain JSON startingPrompt values.
            let rawSessionJSON = String(decoding: try JSONEncoder().encode(sActivity), as: UTF8.self)
            XCTAssertFalse(rawSessionJSON.contains("startingPrompt"))
            let plainJSON = Data("""
            {"id":"s-plain","title":"Copilot","cwd":"/tmp","startingPrompt":"Plain JSON prompt"}
            """.utf8)
            XCTAssertEqual(try JSONDecoder().decode(Session.self, from: plainJSON).startingPrompt, "Plain JSON prompt")

            var sentRemotePrompts: [String] = []
            let model = AppModel(
                stateRepository: repository,
                isAppActive: { false },
                agentActivityDirectory: root,
                resumeMarkerDirectory: root,
                remotePromptLiveSessions: { _ in [sRemote.id] },
                remotePromptTarget: { id in
                    guard id == sRemote.id else { return nil }
                    return RemotePromptTarget(
                        activity: .idle,
                        send: { text in
                            sentRemotePrompts.append(text)
                            return true
                        }
                    )
                },
                remoteCopilotExecutable: { "/usr/local/bin/copilot" },
                remoteSessionBackendAvailable: { true },
                remoteSessionLauncher: { _, _, _ in },
                kittyImageDiskStore: RemoteKittyImageDiskStore(root: root.appendingPathComponent("images"))
            )
            defer {
                model.forcePendingSessionDestroys()
                model.detachAllClients()
            }

            // 2. Tracker agent-activity snapshot populates startingPrompt for a ⌘T session (preserving leading indentation) and persists it.
            let now = Date(timeIntervalSince1970: 1_787_865_600)
            var activity = AgentActivitySnapshot(
                schemaVersion: 1,
                updatedAt: Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(now),
                foregroundTurnActive: true,
                scheduledTurnActive: false,
                activeSubagents: [],
                schedules: [],
                idleGeneration: 0,
                lastIdleAborted: false,
                lastIdleTurnKind: nil,
                error: nil
            )
            activity.startingPrompt = "  Typed directly in terminal\n    indented line"
            try JSONEncoder().encode(activity).write(
                to: root.appendingPathComponent("\(sActivity.id).agent-activity.json"),
                options: .atomic
            )
            model.refreshAgentActivitySnapshots(now: now)
            XCTAssertEqual(
                model.startingPrompt(for: sActivity.id),
                "  Typed directly in terminal\n    indented line"
            )

            // 3. First remote prompt records startingPrompt, and later prompts do not overwrite it.
            XCTAssertEqual(model.sendRemotePrompt(sessionId: sRemote.id, value: "First remote prompt"), .sent)
            XCTAssertEqual(model.sendRemotePrompt(sessionId: sRemote.id, value: "Second follow-up prompt"), .sent)
            XCTAssertEqual(sentRemotePrompts, ["First remote prompt", "Second follow-up prompt"])
            XCTAssertEqual(model.startingPrompt(for: sRemote.id), "First remote prompt")

            // 4. Transcript fallback ignores truncated transcripts (with droppedTurns), retries when
            // transcript-live.json or sealed transcript updates, and ignores non-foreground turns.
            let truncatedTranscriptJSON = """
            {
              "schemaVersion": 4,
              "updatedAt": "2026-10-30T00:00:01Z",
              "copilotSessionId": "11111111-2222-3333-4444-555555555555",
              "revision": "r0",
              "droppedTurns": [
                {
                  "id": "dropped-1",
                  "startedAt": "2026-10-30T00:00:00Z",
                  "endedAt": "2026-10-30T00:00:01Z",
                  "kind": "foreground",
                  "userContent": "Evicted turn",
                  "assistantMessages": [],
                  "tools": [],
                  "isAborted": false
                }
              ],
              "turns": [
                {
                  "id": "t201",
                  "startedAt": "2026-10-30T00:00:02Z",
                  "endedAt": "2026-10-30T00:00:04Z",
                  "kind": "foreground",
                  "userContent": "Follow-up turn after eviction",
                  "assistantMessages": [],
                  "tools": [],
                  "isAborted": false
                }
              ]
            }
            """
            try Data(truncatedTranscriptJSON.utf8).write(
                to: root.appendingPathComponent("\(sTranscript.id).transcript.json"),
                options: .atomic
            )
            XCTAssertNil(model.startingPrompt(for: sTranscript.id))

            let transcriptJSON = """
            {
              "schemaVersion": 4,
              "updatedAt": "2026-10-30T00:00:05Z",
              "copilotSessionId": "11111111-2222-3333-4444-555555555555",
              "revision": "r1",
              "turns": [
                {
                  "id": "t0",
                  "startedAt": "2026-10-30T00:00:00Z",
                  "endedAt": "2026-10-30T00:00:01Z",
                  "kind": "scheduled",
                  "userContent": "Scheduled background check",
                  "assistantMessages": [],
                  "tools": [],
                  "isAborted": false
                },
                {
                  "id": "t1",
                  "startedAt": "2026-10-30T00:00:02Z",
                  "endedAt": "2026-10-30T00:00:04Z",
                  "kind": "foreground",
                  "userContent": "Recovered from transcript turn 1",
                  "assistantMessages": [],
                  "tools": [],
                  "isAborted": false
                }
              ]
            }
            """
            try Data(transcriptJSON.utf8).write(
                to: root.appendingPathComponent("\(sTranscript.id).transcript.json"),
                options: .atomic
            )
            XCTAssertEqual(model.startingPrompt(for: sTranscript.id), "Recovered from transcript turn 1")

            // Verify all three recovered prompts are persisted in state.json.
            guard case .loaded(let persisted) = repository.load() else {
                return XCTFail("Expected persisted state to load")
            }
            let persistedPrompts = Dictionary(
                uniqueKeysWithValues: persisted.projects[0].sessions.map { ($0.id, $0.startingPrompt) }
            )
            XCTAssertEqual(
                persistedPrompts[sActivity.id] ?? nil,
                "  Typed directly in terminal\n    indented line"
            )
            XCTAssertEqual(persistedPrompts[sRemote.id] ?? nil, "First remote prompt")
            XCTAssertEqual(persistedPrompts[sTranscript.id] ?? nil, "Recovered from transcript turn 1")
        }
    }

    func testTurnElapsedTimerAndLinkedPullRequestPillsEndToEnd() throws {
        // 1. Contract helpers: extractKeys, shortDisplayLabel, formattedElapsedDuration.
        let extracted = RemotePullRequestsContract.extractKeys(
            from: """
            Ignore malformed https://github.com/sirfergy/copilot-projects/pull/12abc,
            https://github.com/sirfergy/copilot-projects/pull/12%33, and
            https://github.com/sirfergy/copilot-projects/pull/12_3, then
            review https://GitHub.com/SirFergy/Copilot-Projects/pull/270 and
            duplicate https://github.com/sirfergy/copilot-projects/pull/270/files then
            https://github.com/octocat/hello-world/pull/12?expand=1 and
            https://github.com/octocat/hello-world/pull/34#discussion_r1
            """,
            limit: 3
        )
        XCTAssertEqual(
            extracted,
            [
                "sirfergy/copilot-projects#270",
                "octocat/hello-world#12",
                "octocat/hello-world#34",
            ]
        )
        XCTAssertEqual(
            RemotePullRequestsContract.extractKeys(
                from: """
                https://github.com/sirfergy/copilot-projects/pull/270
                https://github.com/octocat/hello-world/pull/12
                https://github.com/octocat/hello-world/pull/34
                https://github.com/octocat/hello-world/pull/56
                """,
                limit: 3
            ),
            []
        )
        XCTAssertEqual(
            RemotePullRequestsContract.shortDisplayLabel(for: "sirfergy/copilot-projects#270"),
            "#270"
        )
        XCTAssertNil(RemotePullRequestsContract.formattedElapsedDuration(fromMilliseconds: 0, nowMilliseconds: 1_000))
        XCTAssertNil(RemotePullRequestsContract.formattedElapsedDuration(fromMilliseconds: 2_000, nowMilliseconds: 1_000))
        XCTAssertEqual(
            RemotePullRequestsContract.formattedElapsedDuration(fromMilliseconds: 1_000, nowMilliseconds: 1_000),
            "1s"
        )
        XCTAssertEqual(
            RemotePullRequestsContract.formattedElapsedDuration(fromMilliseconds: 1_000, nowMilliseconds: 46_000),
            "45s"
        )
        XCTAssertEqual(
            RemotePullRequestsContract.formattedElapsedDuration(fromMilliseconds: 1_000, nowMilliseconds: 121_000),
            "2m"
        )
        XCTAssertEqual(
            RemotePullRequestsContract.formattedElapsedDuration(fromMilliseconds: 1_000, nowMilliseconds: 3_601_000),
            "1h"
        )
        XCTAssertEqual(
            RemotePullRequestsContract.formattedElapsedDuration(fromMilliseconds: 1_000, nowMilliseconds: 3_901_000),
            "1h 5m"
        )

        try withTempStateDirectory { root in
            let s1 = Session(
                title: "Feature Work",
                cwd: root.path,
                startingPrompt: "Investigate https://github.com/sirfergy/copilot-projects/pull/101"
            )
            let project = Project(
                name: "Alpha",
                cwd: root.path,
                sessions: [s1],
                selectedSessionId: s1.id
            )
            let repository = StateRepository(path: root.appendingPathComponent("state.json"))
            try repository.save(PersistedState(projects: [project], selectedProjectId: project.id))

            let model = AppModel(
                stateRepository: repository,
                isAppActive: { false },
                agentActivityDirectory: root,
                resumeMarkerDirectory: root,
                remoteCopilotExecutable: { "/usr/local/bin/copilot" },
                remoteSessionBackendAvailable: { true },
                remoteSessionLauncher: { _, _, _ in },
                kittyImageDiskStore: RemoteKittyImageDiskStore(root: root.appendingPathComponent("images")),
                gracefulSessionDestroyer: { _, _ in Task {} },
                forcedSessionDestroyer: { _ in }
            )
            defer {
                model.forcePendingSessionDestroys()
                model.detachAllClients()
            }

            // 2. Starting prompt PR URL extraction + adversarial review session PR key assignment.
            XCTAssertEqual(model.projects[0].sessions[0].effectivePullRequestKeys, ["sirfergy/copilot-projects#101"])

            let reviewSessionId = try XCTUnwrap(
                model.addAdversarialReviewSession(
                    toProjectId: project.id,
                    pullRequestURL: "https://github.com/SirFergy/Copilot-Projects/pull/270"
                )
            )
            let reviewSession = try XCTUnwrap(model.projects[0].sessions.first(where: { $0.id == reviewSessionId }))
            XCTAssertEqual(reviewSession.pullRequestKeys, ["sirfergy/copilot-projects#270"])
            XCTAssertEqual(reviewSession.effectivePullRequestKeys, ["sirfergy/copilot-projects#270"])

            // 3. Running status sets runningStartedAtMilliseconds and remoteWorkspaceSnapshot exposes both fields.
            let hookStartMs: Int64 = 1_788_000_000_000
            model.setStatus(
                sessionId: s1.id,
                status: .running,
                text: "Working",
                timestamp: hookStartMs,
                source: "user-prompt"
            )
            XCTAssertEqual(model.projects[0].sessions[0].runningStartedAtMilliseconds, hookStartMs)
            XCTAssertEqual(model.projects[0].sessions[0].effectiveRunningStartedAtMilliseconds, hookStartMs)

            // Tracker snapshot foregroundTransitionAt across multiple assistant.turn_start iterations
            // does not reset the request's runningStartedAtMilliseconds, and snapshot.pullRequestKeys
            // merges into Session.pullRequestKeys (capped at 5, effective capped at 3) and survives expiry.
            let now = Date(timeIntervalSince1970: 1_788_000_010)
            let transitionDate = Date(timeIntervalSince1970: 1_788_000_005)
            // Legacy snapshot without extraction-policy provenance token must not populate or persist pullRequestKeys.
            let legacySnapshot = AgentActivitySnapshot(
                schemaVersion: 1,
                updatedAt: Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(now),
                foregroundTurnActive: true,
                foregroundTransitionAt: Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(transitionDate),
                scheduledTurnActive: false,
                activeSubagents: [],
                schedules: [],
                idleGeneration: 0,
                lastIdleAborted: false,
                lastIdleTurnKind: nil,
                error: nil,
                pullRequestKeys: ["sirfergy/copilot-projects#990"]
            )
            try JSONEncoder().encode(legacySnapshot).write(
                to: root.appendingPathComponent("\(s1.id).agent-activity.json"),
                options: .atomic
            )
            model.refreshAgentActivitySnapshots(now: now)
            XCTAssertNil(model.projects[0].sessions[0].pullRequestKeys)
            XCTAssertEqual(model.projects[0].sessions[0].effectivePullRequestKeys, ["sirfergy/copilot-projects#101"])

            var activity = AgentActivitySnapshot(
                schemaVersion: 1,
                updatedAt: Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(now),
                foregroundTurnActive: true,
                foregroundTransitionAt: Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(transitionDate),
                scheduledTurnActive: false,
                activeSubagents: [],
                schedules: [],
                idleGeneration: 0,
                lastIdleAborted: false,
                lastIdleTurnKind: nil,
                error: nil,
                pullRequestKeys: [
                    Session.activityPullRequestPolicyToken,
                    "sirfergy/copilot-projects#202",
                    "sirfergy/copilot-projects#203",
                    "sirfergy/copilot-projects#204",
                    "sirfergy/copilot-projects#205",
                    "sirfergy/copilot-projects#206",
                    "sirfergy/copilot-projects#207",
                ]
            )
            try JSONEncoder().encode(activity).write(
                to: root.appendingPathComponent("\(s1.id).agent-activity.json"),
                options: .atomic
            )
            model.refreshAgentActivitySnapshots(now: now)

            let updatedS1 = model.projects[0].sessions[0]
            XCTAssertEqual(updatedS1.pullRequestKeys?.count, 5)
            XCTAssertEqual(
                updatedS1.effectivePullRequestKeys,
                [
                    "sirfergy/copilot-projects#202",
                    "sirfergy/copilot-projects#203",
                    "sirfergy/copilot-projects#204",
                ]
            )
            XCTAssertEqual(updatedS1.runningStartedAtMilliseconds, hookStartMs)
            XCTAssertEqual(updatedS1.effectiveRunningStartedAtMilliseconds, hookStartMs)

            let remoteRunning = try XCTUnwrap(
                model.remoteWorkspaceSnapshot().projects.first?.sessions.first(where: { $0.id == s1.id })
            )
            XCTAssertEqual(remoteRunning.runningStartedAtMilliseconds, hookStartMs)
            XCTAssertEqual(
                remoteRunning.pullRequestKeys,
                [
                    "sirfergy/copilot-projects#202",
                    "sirfergy/copilot-projects#203",
                    "sirfergy/copilot-projects#204",
                ]
            )

            // Subsequent tool-loop assistant.turn_start iteration rewrites foregroundTransitionAt,
            // but both local and remote projections preserve the initial request start timestamp.
            let secondIterationNow = Date(timeIntervalSince1970: 1_788_000_016)
            activity.updatedAt = Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(secondIterationNow)
            activity.foregroundTransitionAt = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
                .format(Date(timeIntervalSince1970: 1_788_000_015))
            try JSONEncoder().encode(activity).write(
                to: root.appendingPathComponent("\(s1.id).agent-activity.json"),
                options: .atomic
            )
            model.refreshAgentActivitySnapshots(now: secondIterationNow)
            XCTAssertEqual(model.projects[0].sessions[0].runningStartedAtMilliseconds, hookStartMs)
            XCTAssertEqual(model.projects[0].sessions[0].effectiveRunningStartedAtMilliseconds, hookStartMs)
            let remoteSecondIteration = try XCTUnwrap(
                model.remoteWorkspaceSnapshot().projects.first?.sessions.first(where: { $0.id == s1.id })
            )
            XCTAssertEqual(remoteSecondIteration.runningStartedAtMilliseconds, hookStartMs)

            // Pending question flips displayStatus to .waiting and hides effectiveRunningStartedAtMilliseconds.
            activity.trackedUserInputs = [
                TrackedUserInput(
                    requestId: "req-1",
                    question: "Proceed?",
                    choices: ["Yes"],
                    allowFreeform: false,
                    requestedAt: Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(now)
                )
            ]
            var waitingSession = updatedS1
            waitingSession.agentActivity = activity
            XCTAssertEqual(waitingSession.displayStatus, .waiting)
            XCTAssertNil(waitingSession.effectiveRunningStartedAtMilliseconds)

            // Transitioning to .idle clears runningStartedAtMilliseconds, and a subsequent turn start does not
            // mistake an old idle snapshot's foregroundTransitionAt for the new turn's start time.
            var idleSnapshot = activity
            idleSnapshot.trackedUserInputs = nil
            idleSnapshot.foregroundTurnActive = false
            idleSnapshot.foregroundTransitionAt = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
                .format(Date(timeIntervalSince1970: 1_788_000_020))
            try JSONEncoder().encode(idleSnapshot).write(
                to: root.appendingPathComponent("\(s1.id).agent-activity.json"),
                options: .atomic
            )
            model.refreshAgentActivitySnapshots(now: Date(timeIntervalSince1970: 1_788_000_021))
            model.setStatus(
                sessionId: s1.id,
                status: .idle,
                text: nil,
                timestamp: hookStartMs + 20_000,
                source: "session-idle"
            )
            XCTAssertNil(model.projects[0].sessions[0].runningStartedAtMilliseconds)
            XCTAssertNil(model.projects[0].sessions[0].effectiveRunningStartedAtMilliseconds)
            let remoteIdle = try XCTUnwrap(
                model.remoteWorkspaceSnapshot().projects.first?.sessions.first(where: { $0.id == s1.id })
            )
            XCTAssertNil(remoteIdle.runningStartedAtMilliseconds)

            let nextTurnStartMs: Int64 = 1_788_000_060_000
            model.setStatus(
                sessionId: s1.id,
                status: .running,
                text: "Next turn",
                timestamp: nextTurnStartMs,
                source: "user-prompt"
            )
            XCTAssertEqual(model.projects[0].sessions[0].runningStartedAtMilliseconds, nextTurnStartMs)
            XCTAssertEqual(model.projects[0].sessions[0].effectiveRunningStartedAtMilliseconds, nextTurnStartMs)

            // Transient permission wait preserves pre-wait runningStartedAtMilliseconds across .waiting -> .running,
            // including when a post-wait assistant.turn_start snapshot arrives with a newer foregroundTransitionAt.
            model.setStatus(
                sessionId: s1.id,
                status: .waiting,
                text: "Needs permission",
                timestamp: nextTurnStartMs + 5_000,
                source: "permission",
                notification: .permission
            )
            XCTAssertNil(model.projects[0].sessions[0].effectiveRunningStartedAtMilliseconds)
            model.setStatus(
                sessionId: s1.id,
                status: .running,
                text: "Resumed after permission",
                timestamp: nextTurnStartMs + 10_000,
                source: "tool"
            )
            var postWaitActivity = idleSnapshot
            postWaitActivity.conversationEpoch = "\(s1.id):1"
            postWaitActivity.updatedAt = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
                .format(Date(timeIntervalSince1970: 1_788_000_073))
            postWaitActivity.foregroundTurnActive = true
            postWaitActivity.foregroundTransitionAt = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
                .format(Date(timeIntervalSince1970: 1_788_000_072))
            try JSONEncoder().encode(postWaitActivity).write(
                to: root.appendingPathComponent("\(s1.id).agent-activity.json"),
                options: .atomic
            )
            model.refreshAgentActivitySnapshots(now: Date(timeIntervalSince1970: 1_788_000_073))
            XCTAssertEqual(model.projects[0].sessions[0].runningStartedAtMilliseconds, nextTurnStartMs)
            XCTAssertEqual(model.projects[0].sessions[0].effectiveRunningStartedAtMilliseconds, nextTurnStartMs)
            let remotePostWait = try XCTUnwrap(
                model.remoteWorkspaceSnapshot().projects.first?.sessions.first(where: { $0.id == s1.id })
            )
            XCTAssertEqual(remotePostWait.runningStartedAtMilliseconds, nextTurnStartMs)

            // Relaunching after an off-host tool hook (where statusTimestamp advances in .status-record.json
            // while the active snapshot's idleGeneration is unchanged) preserves the original request start,
            // and timestamp-less status transitions persist clocks.status so relaunch preserves the start too.
            SessionArtifacts.persistStatus(
                sessionId: s1.id,
                status: .running,
                timestamp: nextTurnStartMs + 15_000,
                promptStatusTimestamp: nextTurnStartMs + 15_000,
                sessionsDirectory: root
            )
            let relaunched = AppModel(
                stateRepository: repository,
                isAppActive: { false },
                agentActivityDirectory: root,
                resumeMarkerDirectory: root,
                remoteCopilotExecutable: { "/usr/local/bin/copilot" },
                remoteSessionBackendAvailable: { true },
                remoteSessionLauncher: { _, _, _ in },
                kittyImageDiskStore: RemoteKittyImageDiskStore(root: root.appendingPathComponent("images")),
                gracefulSessionDestroyer: { _, _ in Task {} },
                forcedSessionDestroyer: { _ in }
            )
            defer {
                relaunched.forcePendingSessionDestroys()
                relaunched.detachAllClients()
            }
            XCTAssertEqual(relaunched.projects[0].sessions[0].runningStartedAtMilliseconds, nextTurnStartMs)
            XCTAssertEqual(relaunched.projects[0].sessions[0].effectiveRunningStartedAtMilliseconds, nextTurnStartMs)
            XCTAssertEqual(
                relaunched.projects[0].sessions[0].effectivePullRequestKeys,
                [
                    "sirfergy/copilot-projects#202",
                    "sirfergy/copilot-projects#203",
                    "sirfergy/copilot-projects#204",
                ]
            )

            // Timestamp-less waiting -> running sequence updates runningStatusTimestampMilliseconds from clocks.status.
            relaunched.setStatus(sessionId: s1.id, status: .waiting, text: "Wait", notification: .permission)
            relaunched.setStatus(sessionId: s1.id, status: .running, text: "Resume")
            let relaunchedTimestampless = AppModel(
                stateRepository: repository,
                isAppActive: { false },
                agentActivityDirectory: root,
                resumeMarkerDirectory: root,
                remoteCopilotExecutable: { "/usr/local/bin/copilot" },
                remoteSessionBackendAvailable: { true },
                remoteSessionLauncher: { _, _, _ in },
                kittyImageDiskStore: RemoteKittyImageDiskStore(root: root.appendingPathComponent("images")),
                gracefulSessionDestroyer: { _, _ in Task {} },
                forcedSessionDestroyer: { _ in }
            )
            defer {
                relaunchedTimestampless.forcePendingSessionDestroys()
                relaunchedTimestampless.detachAllClients()
            }
            XCTAssertEqual(relaunchedTimestampless.projects[0].sessions[0].runningStartedAtMilliseconds, nextTurnStartMs)

            // Off-host CLI restart or new request (even if idleGeneration resets to 0 under a new conversationEpoch)
            // starts a fresh timer at the new request's timestamp.
            let offHostTurnStartMs = SessionArtifacts.currentStatusTimestamp() + 60_000
            var newOffHostActivity = postWaitActivity
            newOffHostActivity.conversationEpoch = "\(s1.id):2"
            newOffHostActivity.idleGeneration = 0
            try JSONEncoder().encode(newOffHostActivity).write(
                to: root.appendingPathComponent("\(s1.id).agent-activity.json"),
                options: .atomic
            )
            SessionArtifacts.persistStatus(
                sessionId: s1.id,
                status: .running,
                timestamp: offHostTurnStartMs,
                promptStatusTimestamp: offHostTurnStartMs,
                sessionsDirectory: root
            )
            let relaunchedOffHost = AppModel(
                stateRepository: repository,
                isAppActive: { false },
                agentActivityDirectory: root,
                resumeMarkerDirectory: root,
                remoteCopilotExecutable: { "/usr/local/bin/copilot" },
                remoteSessionBackendAvailable: { true },
                remoteSessionLauncher: { _, _, _ in },
                kittyImageDiskStore: RemoteKittyImageDiskStore(root: root.appendingPathComponent("images")),
                gracefulSessionDestroyer: { _, _ in Task {} },
                forcedSessionDestroyer: { _ in }
            )
            defer {
                relaunchedOffHost.forcePendingSessionDestroys()
                relaunchedOffHost.detachAllClients()
            }
            XCTAssertEqual(relaunchedOffHost.projects[0].sessions[0].runningStartedAtMilliseconds, offHostTurnStartMs)
            XCTAssertEqual(relaunchedOffHost.projects[0].sessions[0].effectiveRunningStartedAtMilliseconds, offHostTurnStartMs)

            // Untrusted/mismatched copilotSessionId snapshot must not leak pullRequestKeys or foregroundTransitionAt.
            let pinnedCopilotId = UUID().uuidString.lowercased()
            let foreignCopilotId = UUID().uuidString.lowercased()
            try Data("\(pinnedCopilotId)\n".utf8).write(
                to: root.appendingPathComponent("\(reviewSessionId).copilot-session"),
                options: .atomic
            )
            var foreignSnapshot = idleSnapshot
            foreignSnapshot.updatedAt = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
                .format(Date(timeIntervalSince1970: 1_788_000_051))
            foreignSnapshot.copilotSessionId = foreignCopilotId
            foreignSnapshot.foregroundTurnActive = true
            foreignSnapshot.foregroundTransitionAt = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
                .format(Date(timeIntervalSince1970: 1_788_000_050))
            foreignSnapshot.pullRequestKeys = ["evil/foreign#999"]
            try JSONEncoder().encode(foreignSnapshot).write(
                to: root.appendingPathComponent("\(reviewSessionId).agent-activity.json"),
                options: .atomic
            )
            model.refreshAgentActivitySnapshots(now: Date(timeIntervalSince1970: 1_788_000_051))
            model.setStatus(
                sessionId: reviewSessionId,
                status: .running,
                text: "Reviewing",
                timestamp: 1_788_000_080_000,
                source: "user-prompt"
            )
            let refreshedReview = try XCTUnwrap(
                model.projects[0].sessions.first(where: { $0.id == reviewSessionId })
            )
            XCTAssertEqual(refreshedReview.pullRequestKeys, ["sirfergy/copilot-projects#270"])
            XCTAssertEqual(refreshedReview.effectivePullRequestKeys, ["sirfergy/copilot-projects#270"])
            XCTAssertEqual(refreshedReview.runningStartedAtMilliseconds, 1_788_000_080_000)
            XCTAssertEqual(refreshedReview.effectiveRunningStartedAtMilliseconds, 1_788_000_080_000)

            // 4. SessionRow Equatable and VoiceOver accessibilityStatus include running elapsed time and PR keys.
            var rowSessionA = Session(id: "row-1", title: "Row", cwd: root.path)
            rowSessionA.status = .running
            rowSessionA.runningStartedAtMilliseconds = 1_000
            var rowSessionB = rowSessionA
            rowSessionB.runningStartedAtMilliseconds = 2_000
            XCTAssertNotEqual(
                SessionRow(session: rowSessionA, isActive: false, onSelect: {}, onClose: {}),
                SessionRow(session: rowSessionB, isActive: false, onSelect: {}, onClose: {})
            )
            XCTAssertEqual(
                SessionRow(session: rowSessionA, isActive: true, onSelect: {}, onClose: {})
                    .accessibilityStatus(nowMilliseconds: 181_000),
                "Selected, Running 3m"
            )
            var rowSessionC = rowSessionA
            rowSessionC.pullRequestKeys = ["sirfergy/copilot-projects#270"]
            XCTAssertNotEqual(
                SessionRow(session: rowSessionA, isActive: false, onSelect: {}, onClose: {}),
                SessionRow(session: rowSessionC, isActive: false, onSelect: {}, onClose: {})
            )

            // Idle session with active background work uses sparkles symbol and purple stateColor.
            var idlePlain = Session(id: "row-bg", title: "Background", cwd: root.path)
            XCTAssertEqual(SessionStateIndicator.symbolName(for: idlePlain), "terminal.fill")
            var idleWithBg = idlePlain
            idleWithBg.backgroundAgentsActive = true
            XCTAssertEqual(SessionStateIndicator.symbolName(for: idleWithBg), "sparkles")
            XCTAssertNotEqual(
                SessionStateIndicator(session: idlePlain),
                SessionStateIndicator(session: idleWithBg)
            )
            XCTAssertEqual(
                SessionRow(session: idleWithBg, isActive: false, onSelect: {}, onClose: {}).stateColor,
                .purple
            )

            // 4b. sanitizedPersistedPullRequestKeys() strips unbacked tool-scraped keys on load
            // while preserving resumed/explicit PR bindings, startingPrompt keys, and Review Pull Request title keys.
            var staleScrapedSession = Session(
                id: "stale-scraped",
                title: "shell",
                cwd: root.path,
                pullRequestKeys: ["sirfergy/copilot-projects#991", "sirfergy/copilot-projects#992"]
            )
            staleScrapedSession.verifiedPullRequestKeys = nil
            var ordinaryFingerprintedSession = Session(
                id: "ordinary-fingerprinted",
                title: "Copilot",
                cwd: root.path,
                creationFingerprint: SessionCreationRecord.fingerprint(
                    projectId: "p",
                    kind: .copilot,
                    initialPrompt: "Investigate build failure",
                    pullRequestURL: nil
                ),
                pullRequestKeys: ["sirfergy/copilot-projects#993"],
                startingPrompt: "Investigate build failure"
            )
            ordinaryFingerprintedSession.verifiedPullRequestKeys = nil
            let resumedCopilotId = UUID().uuidString.lowercased()
            try Data("\(resumedCopilotId)\n".utf8).write(
                to: root.appendingPathComponent("pr-fingerprint.copilot-session"),
                options: .atomic
            )
            let resumeRequest = RemotePullRequestSessionRequest(
                requestId: UUID(),
                kind: "resume",
                projectId: "p",
                pullRequestKeys: ["sirfergy/copilot-projects#301", "sirfergy/copilot-projects#302"],
                copilotSessionId: resumedCopilotId
            )
            var prFingerprintSession = Session(
                id: "pr-fingerprint",
                title: "Copilot",
                cwd: root.path,
                creationFingerprint: SessionCreationRecord.pullRequestFingerprint(resumeRequest),
                pullRequestKeys: [
                    "sirfergy/copilot-projects#301",
                    "sirfergy/copilot-projects#302",
                    "sirfergy/copilot-projects#998",
                ]
            )
            prFingerprintSession.verifiedPullRequestKeys = nil
            let existingBoundCopilotId = UUID().uuidString.lowercased()
            try Data("\(existingBoundCopilotId)\n".utf8).write(
                to: root.appendingPathComponent("existing-bound.copilot-session"),
                options: .atomic
            )
            let secondaryRequest = RemotePullRequestSessionRequest(
                requestId: UUID(),
                kind: "resume",
                projectId: "p",
                pullRequestKeys: ["sirfergy/copilot-projects#303", "sirfergy/copilot-projects#304"],
                copilotSessionId: existingBoundCopilotId
            )
            let sanitizeLedgerURL = root.appendingPathComponent("sanitize-ledger.json")
            try Data("corrupt".utf8).write(to: sanitizeLedgerURL, options: .atomic)
            let sanitizeLedger = SessionCreationLedger(url: sanitizeLedgerURL)
            var existingBoundSession = Session(
                id: "existing-bound",
                title: "Copilot",
                cwd: root.path,
                creationFingerprint: SessionCreationRecord.fingerprint(
                    projectId: "p",
                    kind: .copilot,
                    initialPrompt: "Inspect https://github.com/sirfergy/copilot-projects/pull/300",
                    pullRequestURL: nil
                ),
                pullRequestKeys: [
                    "sirfergy/copilot-projects#101",
                    "sirfergy/copilot-projects#102",
                    "sirfergy/copilot-projects#103",
                    "sirfergy/copilot-projects#104",
                    "sirfergy/copilot-projects#300",
                    "sirfergy/copilot-projects#303",
                    "sirfergy/copilot-projects#304",
                ],
                startingPrompt: "Inspect https://github.com/sirfergy/copilot-projects/pull/300"
            )
            existingBoundSession.verifiedPullRequestKeys = nil
            var promptBackedSession = Session(
                id: "prompt-backed",
                title: "Feature Work",
                cwd: root.path,
                pullRequestKeys: ["sirfergy/copilot-projects#401", "sirfergy/copilot-projects#999"],
                startingPrompt: "Please inspect https://github.com/sirfergy/copilot-projects/pull/401"
            )
            promptBackedSession.verifiedPullRequestKeys = nil
            var titleBackedSession = Session(
                id: "title-backed",
                title: "Review SirFergy/Copilot-Projects#501",
                cwd: root.path,
                pullRequestKeys: [
                    "sirfergy/copilot-projects#501",
                    "octocat/hello-world#501",
                    "sirfergy/copilot-projects#50",
                    "sirfergy/copilot-projects#999",
                ]
            )
            titleBackedSession.verifiedPullRequestKeys = nil
            let sanitizeRepo = StateRepository(path: root.appendingPathComponent("sanitize-state.json"))
            let sanitizeProject = Project(
                id: "p",
                name: "Sanitize",
                cwd: root.path,
                sessions: [
                    staleScrapedSession,
                    ordinaryFingerprintedSession,
                    prFingerprintSession,
                    existingBoundSession,
                    promptBackedSession,
                    titleBackedSession,
                ],
                selectedSessionId: staleScrapedSession.id
            )
            try sanitizeRepo.save(PersistedState(projects: [sanitizeProject], selectedProjectId: sanitizeProject.id))
            let corruptLedgerModel = AppModel(
                stateRepository: sanitizeRepo,
                isAppActive: { false },
                agentActivityDirectory: root,
                resumeMarkerDirectory: root,
                remoteCopilotExecutable: { "/usr/local/bin/copilot" },
                remoteSessionBackendAvailable: { true },
                remoteSessionLauncher: { _, _, _ in },
                sessionCreationLedger: sanitizeLedger,
                kittyImageDiskStore: RemoteKittyImageDiskStore(root: root.appendingPathComponent("images")),
                gracefulSessionDestroyer: { _, _ in Task {} },
                forcedSessionDestroyer: { _ in }
            )
            defer {
                corruptLedgerModel.forcePendingSessionDestroys()
                corruptLedgerModel.detachAllClients()
            }
            // While ledger is malformed, unverified legacy keys are hidden while prompt-backed keys remain visible.
            XCTAssertNil(corruptLedgerModel.projects[0].sessions.first(where: { $0.id == "stale-scraped" })?.pullRequestKeys)
            XCTAssertEqual(
                corruptLedgerModel.projects[0].sessions.first(where: { $0.id == "existing-bound" })?.pullRequestKeys,
                ["sirfergy/copilot-projects#300"]
            )
            var cleanSaveState = try XCTUnwrap(
                {
                    if case .loaded(let loaded) = sanitizeRepo.load() { return loaded }
                    return nil
                }()
            )
            cleanSaveState.projects = corruptLedgerModel.projects
            try sanitizeRepo.save(cleanSaveState)
            try? FileManager.default.removeItem(at: sanitizeLedgerURL)
            try sanitizeLedger.remember(
                SessionCreationRecord(
                    requestId: secondaryRequest.requestId.uuidString,
                    projectId: "p",
                    sessionId: "existing-bound",
                    createdAt: Date(),
                    creationFingerprint: SessionCreationRecord.pullRequestFingerprint(secondaryRequest)
                ),
                now: Date()
            )
            let sanitizedModel = AppModel(
                stateRepository: sanitizeRepo,
                isAppActive: { false },
                agentActivityDirectory: root,
                resumeMarkerDirectory: root,
                remoteCopilotExecutable: { "/usr/local/bin/copilot" },
                remoteSessionBackendAvailable: { true },
                remoteSessionLauncher: { _, _, _ in },
                sessionCreationLedger: sanitizeLedger,
                kittyImageDiskStore: RemoteKittyImageDiskStore(root: root.appendingPathComponent("images")),
                gracefulSessionDestroyer: { _, _ in Task {} },
                forcedSessionDestroyer: { _ in }
            )
            defer {
                sanitizedModel.forcePendingSessionDestroys()
                sanitizedModel.detachAllClients()
            }
            let loadedSessions = sanitizedModel.projects[0].sessions
            XCTAssertNil(loadedSessions.first(where: { $0.id == "stale-scraped" })?.pullRequestKeys)
            XCTAssertNil(loadedSessions.first(where: { $0.id == "ordinary-fingerprinted" })?.pullRequestKeys)
            XCTAssertEqual(
                loadedSessions.first(where: { $0.id == "pr-fingerprint" })?.pullRequestKeys,
                ["sirfergy/copilot-projects#301", "sirfergy/copilot-projects#302"]
            )
            XCTAssertEqual(
                loadedSessions.first(where: { $0.id == "existing-bound" })?.pullRequestKeys,
                [
                    "sirfergy/copilot-projects#300",
                    "sirfergy/copilot-projects#303",
                    "sirfergy/copilot-projects#304",
                ]
            )
            XCTAssertEqual(
                loadedSessions.first(where: { $0.id == "prompt-backed" })?.pullRequestKeys,
                ["sirfergy/copilot-projects#401"]
            )
            XCTAssertEqual(
                loadedSessions.first(where: { $0.id == "title-backed" })?.pullRequestKeys,
                ["sirfergy/copilot-projects#501"]
            )

            // 5. Shipped tracker extension extracts PR URLs from foreground prompts (<= 3 distinct PRs),
            // ignores read-only tool outputs, and records PR URLs only from successful gh pr create commands.
            let script = CopilotExtension.script
            let startIdx = try XCTUnwrap(script.range(of: "function recordPullRequestUrlsFromText(")?.lowerBound)
            let endIdx = try XCTUnwrap(script.range(of: "function syncStartingPromptFromTranscript(")?.lowerBound)
            let extractedJS = String(script[startIdx..<endIdx])
            let eventStartIdx = try XCTUnwrap(
                script.range(of: "function processTranscriptEvent(event, live) {")?.lowerBound
            )
            let eventEndIdx = try XCTUnwrap(script.range(of: "function replayHistoryEvent(")?.lowerBound)
            let processEventJS = String(script[eventStartIdx..<eventEndIdx])
            let harnessURL = root.appendingPathComponent("pr-extract-test.mjs")
            let harnessSource = """
            import assert from "node:assert/strict";
            let pullRequestKeys = [];
            const prCreateToolCallIds = new Set();
            let transcriptTurns = [];
            let pendingTranscriptTurn = null;
            let transcriptAssistantTurnActive = false;
            let transcriptPromptPhase = false;
            let latestResumeTranscriptTurnId = null;
            let synthesizedTaskCompletionContent = null;
            const PROMPT_HOOK_TYPES = new Set();
            const REQUEST_ACTIVITY_EVENT_TYPES = new Set();
            const liveRequestOpeners = new Set();
            const MAX_TRANSCRIPT_TOOLS = 64;
            let publishCount = 0;
            function rememberTranscriptEvent() { return true; }
            function ensureSyntheticTranscriptTurn() {
              if (!pendingTranscriptTurn) pendingTranscriptTurn = { assistantMessages: [], tools: [] };
            }
            function clearRecoveredTranscriptError() {}
            function boundedMetadataText(v) { return typeof v === "string" ? v : ""; }
            function durableAskUserMessage() { return null; }
            function toolTitle(data) { return data?.toolName || "Tool"; }
            function schedulePublishTranscript() {}
            function publishTranscript() {}
            function publish() { publishCount += 1; }
            \(extractedJS)
            \(processEventJS)
            assert.equal(recordPullRequestUrlsFromText("Ignore https://github.com/o/r/pull/12abc and https://github.com/o/r/pull/12%33"), false);
            assert.equal(recordPullRequestUrlsFromText(
              "https://github.com/o/r/pull/1 https://github.com/o/r/pull/2 https://github.com/o/r/pull/3 https://github.com/o/r/pull/4"
            ), false);
            assert.deepEqual(pullRequestKeys, []);
            assert.equal(recordPullRequestUrlsFromText("Review https://GitHub.com/SirFergy/Copilot-Projects/pull/270"), true);

            let runTool = (id, toolName, args, success, result) => {
              processTranscriptEvent({
                id: `${id}-start`,
                type: "tool.execution_start",
                data: { toolCallId: id, toolName, arguments: args }
              }, true);
              processTranscriptEvent({
                id: `${id}-done`,
                type: "tool.execution_complete",
                data: { toolCallId: id, success, result }
              }, true);
            };

            // Read-only tools (session_store_sql, view, gh pr list) and quoted/failed commands must NOT populate pullRequestKeys.
            runTool("t-sql", "session_store_sql", { query: "SELECT 1" }, true, {
              content: "Found https://github.com/octocat/hello-world/pull/901"
            });
            runTool("t-view", "view", { path: "/tmp/doc.md" }, true, {
              content: "See https://github.com/octocat/hello-world/pull/902"
            });
            runTool("t-list", "bash", { command: "gh pr list --limit 10" }, true, {
              content: "https://github.com/octocat/hello-world/pull/903"
            });
            runTool(
              "t-quoted",
              "bash",
              { command: "printf '%s\\n' 'gh pr create https://github.com/octocat/hello-world/pull/905' # gh pr create" },
              true,
              { content: "gh pr create https://github.com/octocat/hello-world/pull/905" }
            );
            runTool(
              "t-heredoc",
              "bash",
              { command: "cat <<'EOF'\\ngh pr create https://github.com/octocat/hello-world/pull/906\\nEOF" },
              true,
              { content: "gh pr create https://github.com/octocat/hello-world/pull/906" }
            );
            runTool(
              "t-compound-skip",
              "bash",
              { command: "false && gh pr create --fill; gh pr list --limit 10" },
              true,
              { content: "https://github.com/octocat/hello-world/pull/907" }
            );
            runTool(
              "t-compound-printf",
              "bash",
              { command: "printf 'https://github.com/octocat/hello-world/pull/909\\n' && gh pr create --fill" },
              true,
              { content: "https://github.com/octocat/hello-world/pull/909\\nhttps://github.com/octocat/hello-world/pull/42" }
            );
            runTool(
              "t-quoted-subcommand",
              "bash",
              { command: 'gh pr "view" create --json url --jq .url' },
              true,
              { content: "https://github.com/octocat/hello-world/pull/908" }
            );
            runTool(
              "t-dry-run",
              "bash",
              { command: "gh pr create --dry-run --title T --body 'See https://github.com/octocat/hello-world/pull/910'" },
              true,
              { content: "https://github.com/octocat/hello-world/pull/910" }
            );
            runTool(
              "t-quoted-dry-run",
              "bash",
              { command: 'gh pr create "--dry-run" --title T --body \\'See https://github.com/octocat/hello-world/pull/911\\'' },
              true,
              { content: "https://github.com/octocat/hello-world/pull/911" }
            );
            runTool(
              "t-partially-quoted-dry-run",
              "bash",
              { command: "gh pr create --dry-'run' --title T --body 'See https://github.com/octocat/hello-world/pull/912'" },
              true,
              { content: "https://github.com/octocat/hello-world/pull/912" }
            );
            runTool(
              "t-expanded-dry-run",
              "bash",
              { command: 'export MODE=--dry-run && gh pr create "$MODE" --title T --body \\'See https://github.com/octocat/hello-world/pull/913\\'' },
              true,
              { content: "https://github.com/octocat/hello-world/pull/913" }
            );
            runTool("t-create-fail", "bash", { command: "gh pr create --fill" }, false, {
              content: "https://github.com/octocat/hello-world/pull/904"
            });
            assert.deepEqual(pullRequestKeys, ["sirfergy/copilot-projects#270"]);
            assert.equal(publishCount, 0);

            // Successful gh pr create in bash (including --repo/-R flags and backslash line continuations) DOES populate pullRequestKeys.
            runTool("t-create-ok", "bash", { command: "GH_TOKEN=x gh --repo octocat/hello-world pr create \\\\\\n  --title T" }, true, {
              content: [{ type: "text", text: "Created https://github.com/octocat/hello-world/pull/42\\n" }]
            });
            assert.equal(publishCount, 1);

            transcriptTurns = [
              { kind: "scheduled", userContent: "https://github.com/octocat/hello-world/pull/999" },
              { kind: "foreground", userContent: "See https://github.com/octocat/hello-world/pull/43 and https://github.com/octocat/hello-world/pull/44" }
            ];
            assert.equal(syncPullRequestKeysFromTranscript(), true);
            assert.deepEqual(pullRequestKeys, [
              "sirfergy/copilot-projects#270",
              "octocat/hello-world#42",
              "octocat/hello-world#43"
            ]);
            """
            try Data(harnessSource.utf8).write(to: harnessURL, options: .atomic)
            try requireNodeForJavaScriptTests()
            let node = Process()
            node.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            node.arguments = ["node", harnessURL.path]
            try node.run()
            node.waitUntilExit()
            XCTAssertEqual(node.terminationStatus, 0)
        }
    }
}
