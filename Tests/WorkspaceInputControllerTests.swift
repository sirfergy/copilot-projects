import AppKit
import XCTest
import CopilotProjectsCore
@testable import CopilotProjectsHost
@testable import SwiftTerm

/// Any finder query can reach Luna, so input tests must never start a real copilot run.
private struct OfflineRanker: SessionRanking {
    func rank(query: String, entries: [SessionFinderEntry]) async throws -> [LunaMatch] { [] }
}

private struct StubHistorySearcher: SessionHistorySearching {
    let matches: [LunaMatch]

    func searchHistory(
        query: String,
        excludedCopilotSessionIds: Set<String>
    ) async throws -> [LunaMatch] {
        matches
    }
}

@MainActor
final class WorkspaceInputControllerTests: XCTestCase {
    private func withWorkspace(
        otherSessions: [Session] = [],
        _ body: (AppModel, WorkspaceInputController, [Session]) throws -> Void
    ) throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let keys = ["SHELL", "COPILOT_PROJECTS_STATE_DIR", "COPILOT_PROJECTS_DTACH", "COPILOT_HOME"]
        let previous = Dictionary(uniqueKeysWithValues: keys.map { ($0, ProcessInfo.processInfo.environment[$0]) })
        setenv("SHELL", "/bin/cat", 1)
        setenv("COPILOT_PROJECTS_STATE_DIR", root.path, 1)
        setenv("COPILOT_HOME", root.appendingPathComponent("copilot").path, 1)
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
        var projects = [project]
        if let first = otherSessions.first {
            projects.append(Project(name: "Other fixture", cwd: root.path,
                                    sessions: otherSessions, selectedSessionId: first.id))
        }
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(projects: projects, selectedProjectId: project.id))
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
        try body(model, WorkspaceInputController(model: model, sessionRanker: OfflineRanker()), sessions)
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

    func testReleaseNotesProtectTerminalInputAndDismissWithoutEndingSession() throws {
        try withWorkspace { model, input, sessions in
            let controller = try XCTUnwrap(model.controller(for: sessions[0].id))
            let process = try XCTUnwrap(controller.terminalView.process)
            let sends = process.sendCount
            input.presentReleaseNotes()
            XCTAssertTrue(input.hasWorkspaceSheet)
            input.presentSessionFinder()
            XCTAssertNil(input.sessionFinder)
            XCTAssertNil(input.handleKeyDown(try key("x", code: 7)))
            XCTAssertNil(input.handleKeyDown(try key("w", code: 13, modifiers: .command)))
            XCTAssertFalse(input.showsReleaseNotes)
            XCTAssertEqual(model.globalSelectedSessionId, sessions[0].id)
            XCTAssertEqual(process.sendCount, sends)
        }
    }

    func testSessionFinderOwnsTheKeyboardUntilItClosesOrOpensASession() throws {
        try withWorkspace { model, input, sessions in
            let terminal = try XCTUnwrap(model.controller(for: sessions[0].id))
            let process = try XCTUnwrap(terminal.terminalView.process)
            let sends = process.sendCount
            let original = model.projects.flatMap(\.sessions).map(\.id)
            @MainActor func assertWorkspaceUntouched(selected: String, file: StaticString = #filePath, line: UInt = #line) {
                XCTAssertEqual(model.projects.flatMap(\.sessions).map(\.id), original, file: file, line: line)
                XCTAssertEqual(model.globalSelectedSessionId, selected, file: file, line: line)
                XCTAssertEqual(process.sendCount, sends, file: file, line: line)
                XCTAssertFalse(terminal.exited, file: file, line: line)
            }

            XCTAssertNil(input.handleKeyDown(try key("k", code: 40, modifiers: .command)))
            XCTAssertNotNil(input.sessionFinder)
            XCTAssertTrue(input.hasWorkspaceSheet)
            input.presentImage(image(sessions[0]))
            XCTAssertNil(input.imagePreview, "Only one workspace sheet may own the keyboard")
            for event in [
                try key("2", code: 19, modifiers: .control),
                try key("2", code: 19, modifiers: .command),
                try key("\t", code: 48, modifiers: .control),
                try key("k", code: 40, modifiers: .command),
                try key("x", code: 7),
            ] {
                XCTAssertNil(input.handleKeyDown(event))
                XCTAssertNotNil(input.sessionFinder)
            }
            assertWorkspaceUntouched(selected: sessions[0].id)

            for dismissal in [try key("w", code: 13, modifiers: .command), try key("\u{1b}", code: 53)] {
                input.presentSessionFinder()
                XCTAssertNil(input.handleKeyDown(dismissal))
                XCTAssertNil(input.sessionFinder)
                assertWorkspaceUntouched(selected: sessions[0].id)
            }

            input.presentSessionFinder()
            let finder = try XCTUnwrap(input.sessionFinder)
            finder.query = "fi"
            XCTAssertNil(input.handleKeyDown(try key("\u{1b}", code: 53)))
            XCTAssertEqual(finder.query, "", "Escape clears a search before it closes")
            XCTAssertNotNil(input.sessionFinder)

            // Browsing starts past the current session, like ⌘Tab.
            XCTAssertEqual(finder.highlightedId, sessions[1].id)
            let up = String(Character(try XCTUnwrap(UnicodeScalar(NSUpArrowFunctionKey))))
            let down = String(Character(try XCTUnwrap(UnicodeScalar(NSDownArrowFunctionKey))))
            XCTAssertNil(input.handleKeyDown(try key(up, code: 126)))
            XCTAssertEqual(finder.highlightedId, sessions[0].id)
            XCTAssertNil(input.handleKeyDown(try key("n", code: 45, modifiers: .control)))
            XCTAssertEqual(finder.highlightedId, sessions[1].id)
            XCTAssertNil(input.handleKeyDown(try key("p", code: 35, modifiers: .control)))
            XCTAssertEqual(finder.highlightedId, sessions[0].id)
            XCTAssertNil(input.handleKeyDown(try key(down, code: 125)))
            XCTAssertEqual(finder.highlightedId, sessions[1].id)

            input.openFromSessionFinder("ended-session")
            XCTAssertNotNil(input.sessionFinder, "An ended session leaves the finder open")
            XCTAssertNil(input.handleKeyDown(try key("\r", code: 36)))
            XCTAssertNil(input.sessionFinder)
            assertWorkspaceUntouched(selected: sessions[1].id)
        }
    }

    func testOpeningASessionInAnotherProjectLeavesThatProjectsShownTabUnread() throws {
        let other = [Session(title: "shown", cwd: "/tmp"), Session(title: "target", cwd: "/tmp")]
        try withWorkspace(otherSessions: other) { model, input, _ in
            for session in other {
                model.setStatus(sessionId: session.id, status: .running, text: nil, timestamp: 1, source: "test")
                model.setStatus(sessionId: session.id, status: .idle, text: nil, timestamp: 2, source: "test")
            }
            @MainActor func finishedUnseen(_ session: Session) -> Bool? {
                model.projects.flatMap(\.sessions).first { $0.id == session.id }?.finishedUnseen
            }
            XCTAssertEqual(other.map(finishedUnseen), [true, true])

            input.openFromSessionFinder(other[1].id)

            XCTAssertEqual(model.selectedProjectId, model.projects[1].id)
            XCTAssertEqual(model.projects[1].selectedSessionId, other[1].id)
            XCTAssertEqual(finishedUnseen(other[1]), false)
            XCTAssertEqual(finishedUnseen(other[0]), true, "The tab that was shown before was never seen")
        }
    }

    func testJumpToNextAttentionSessionAndFleetStatusBarPillsCycleAcrossProjectsByUrgency() throws {
        let b1 = Session(id: "b1", title: "Ready 1", cwd: "/tmp")
        let b2 = Session(id: "b2", title: "Waiting 1", cwd: "/tmp")
        let b3 = Session(id: "b3", title: "Waiting 2", cwd: "/tmp")
        let b4 = Session(id: "b4", title: "Ready 2", cwd: "/tmp")
        try withWorkspace(otherSessions: [b1, b2, b3, b4]) { model, input, sessions in
            // sessions[0] is current; sessions[1] is manually marked unread;
            // b1 & b4 finished unseen ("ready"); b2 & b3 are waiting for input.
            model.markSessionUnread(sessionId: sessions[1].id)
            for ready in [b1, b4] {
                model.setStatus(sessionId: ready.id, status: .running, text: nil, timestamp: 1, source: "test")
                model.setStatus(sessionId: ready.id, status: .idle, text: nil, timestamp: 2, source: "test")
            }
            model.setStatus(sessionId: b2.id, status: .waiting, text: "approve 1?", timestamp: 3, source: "test")
            model.setStatus(sessionId: b3.id, status: .waiting, text: "approve 2?", timestamp: 4, source: "test")

            XCTAssertTrue(model.hasAttentionSessions)
            XCTAssertEqual(model.totalWaiting, 2)
            XCTAssertEqual(model.totalReady, 2)

            // FleetStatusBar pill for `.ready` jumps directly to the first ready session (`b1`),
            // clearing only `b1`'s `finishedUnseen` while leaving `b4`'s intact.
            XCTAssertEqual(model.selectNextSession(matching: .ready)?.sessionId, "b1")
            XCTAssertEqual(model.globalSelectedSessionId, "b1")
            XCTAssertEqual(model.totalReady, 1)
            let p2AfterB1 = try XCTUnwrap(model.projects.last)
            XCTAssertEqual(p2AfterB1.sessions.first { $0.id == "b4" }?.finishedUnseen, true)

            // Repeated ⇧⌘A cycles through ALL waiting sessions (`b2` -> `b3`), then lower-tier
            // unread/ready sessions (`sessions[1]` -> `b4`) without getting stuck on `b2`/`b3`,
            // and wraps back to `b2`.
            let shiftCommandA = try key("A", code: 0, modifiers: [.command, .shift])
            XCTAssertNil(input.handleKeyDown(shiftCommandA))
            XCTAssertEqual(model.globalSelectedSessionId, "b2")
            XCTAssertNil(input.handleKeyDown(shiftCommandA))
            XCTAssertEqual(model.globalSelectedSessionId, "b3")
            XCTAssertNil(input.handleKeyDown(shiftCommandA))
            XCTAssertEqual(model.globalSelectedSessionId, sessions[1].id)
            XCTAssertEqual(model.projects[0].sessions[1].markedUnread, false)
            XCTAssertNil(input.handleKeyDown(shiftCommandA))
            XCTAssertEqual(model.globalSelectedSessionId, "b4")
            XCTAssertEqual(model.totalReady, 0)
            XCTAssertNil(input.handleKeyDown(shiftCommandA))
            XCTAssertEqual(model.globalSelectedSessionId, "b2", "wraps back to the first waiting session")
        }
    }

    func testOpeningAResumableSessionFromFinderResumesItInTheMatchedProject() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repoWork = root.appendingPathComponent("other-work")
        try FileManager.default.createDirectory(at: repoWork, withIntermediateDirectories: true)
        let keys = ["SHELL", "COPILOT_PROJECTS_STATE_DIR", "COPILOT_PROJECTS_DTACH", "COPILOT_HOME"]
        let previous = Dictionary(uniqueKeysWithValues: keys.map { ($0, ProcessInfo.processInfo.environment[$0]) })
        setenv("SHELL", "/bin/cat", 1)
        setenv("COPILOT_PROJECTS_STATE_DIR", root.path, 1)
        setenv("COPILOT_HOME", root.appendingPathComponent("copilot").path, 1)
        unsetenv("COPILOT_PROJECTS_DTACH")
        defer {
            for (key, value) in previous {
                if let value { setenv(key, value, 1) } else { unsetenv(key) }
            }
            try? FileManager.default.removeItem(at: root)
        }

        let home = try CopilotHomeFixture(root: root.appendingPathComponent("copilot"))
        let copilotId = try home.addSession(
            cwd: repoWork.path,
            name: "Investigate flaky webhook",
            transcript: #"{"type":"user.message","data":{"content":"debug the webhook retry"}}"#
        )

        let lockedCopilotId = try home.addSession(
            cwd: repoWork.path,
            name: "Locked session",
            updated: Date(timeIntervalSince1970: 1_800_000_200),
            transcript: #"{"type":"user.message","data":{"content":"locked conversation"}}"#
        )
        try home.lock(lockedCopilotId)

        let p1Session = Session(title: "first", cwd: root.path)
        let p2Session = Session(title: "second", cwd: repoWork.path)
        let p1 = Project(id: "p1", name: "First", cwd: root.path, sessions: [p1Session], selectedSessionId: p1Session.id)
        let p2 = Project(id: "p2", name: "Second", cwd: repoWork.path, sessions: [p2Session], selectedSessionId: p2Session.id)
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(projects: [p1, p2], selectedProjectId: p1.id))

        var backendAvailable = false
        var launches: [(id: String, executable: String?, prompt: String?)] = []
        let model = AppModel(
            stateRepository: repository,
            isAppActive: { false },
            agentActivityDirectory: root,
            resumeMarkerDirectory: root,
            remoteCopilotExecutable: { "/opt/copilot/bin/copilot" },
            remoteReposDirectory: { root.path },
            remoteSessionBackendAvailable: { backendAvailable },
            remoteSessionLauncher: { launches.append(($0, $1, $2)) },
            sessionCreationLedger: SessionCreationLedger(url: root.appendingPathComponent("ledger.json")),
            kittyImageDiskStore: RemoteKittyImageDiskStore(root: root.appendingPathComponent("images"))
        )
        defer {
            model.forcePendingSessionDestroys()
            model.detachAllClients()
        }

        let input = WorkspaceInputController(
            model: model,
            sessionRanker: OfflineRanker(),
            copilotSessionStore: { home.store }
        )
        input.presentSessionFinder()
        let finder = try XCTUnwrap(input.sessionFinder)
        for _ in 0..<200 where finder.isLoadingResumable {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(finder.isLoadingResumable)
        XCTAssertTrue(finder.hasResumableSessions)
        let resumableRowId = SessionFinderSource.resumableSessionId(for: copilotId)
        XCTAssertTrue(finder.rows.contains { $0.id == resumableRowId && $0.section == .recentEnded })

        // Temporary failure preserves the row and surfaces the error in the finder.
        input.openFromSessionFinder(resumableRowId)
        XCTAssertNotNil(input.sessionFinder)
        XCTAssertNotNil(finder.resumeError)
        XCTAssertTrue(finder.rows.contains { $0.id == resumableRowId })

        backendAvailable = true
        input.openFromSessionFinder(resumableRowId)
        XCTAssertNil(input.sessionFinder)
        XCTAssertEqual(model.selectedProjectId, "p2")
        XCTAssertEqual(launches.count, 1)
        let resumedTabId = launches[0].id
        XCTAssertEqual(model.capturedResumeLaunches[resumedTabId], copilotId)
        let resumedSession = try XCTUnwrap(model.project("p2")?.sessions.first { $0.id == resumedTabId })
        XCTAssertEqual(resumedSession.title, "Investigate flaky webhook")
        XCTAssertEqual(resumedSession.cwd, repoWork.path)
        XCTAssertEqual(model.project("p2")?.selectedSessionId, resumedTabId)
    }

    func testSessionFinderDeepHistorySearchSurfacesAndResumesSessionBeyondInitialLimit() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repoWork = root.appendingPathComponent("deep-work")
        try FileManager.default.createDirectory(at: repoWork, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let home = try CopilotHomeFixture(root: root.appendingPathComponent("copilot"))
        let olderCopilotId = try home.addSession(
            cwd: repoWork.path,
            name: "Deep archived migration",
            updated: Date(timeIntervalSince1970: 1_700_000_000),
            transcript: #"{"type":"user.message","data":{"content":"migrate legacy schema"}}"#
        )
        for index in 0..<SessionFinderResumableLoader.defaultLimit {
            _ = try home.addSession(
                cwd: root.path,
                name: "Recent session \(index)",
                updated: Date(timeIntervalSince1970: TimeInterval(1_800_000_000 + index)),
                transcript: #"{"type":"user.message","data":{"content":"routine work"}}"#
            )
        }

        let p1Session = Session(title: "first", cwd: root.path)
        let p2Session = Session(title: "second", cwd: repoWork.path)
        let p1 = Project(id: "p1", name: "First", cwd: root.path, sessions: [p1Session], selectedSessionId: p1Session.id)
        let p2 = Project(id: "p2", name: "Second", cwd: repoWork.path, sessions: [p2Session], selectedSessionId: p2Session.id)
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(projects: [p1, p2], selectedProjectId: p1.id))

        var launches: [(id: String, executable: String?, prompt: String?)] = []
        let model = AppModel(
            stateRepository: repository,
            isAppActive: { false },
            agentActivityDirectory: root,
            resumeMarkerDirectory: root,
            remoteCopilotExecutable: { "/opt/copilot/bin/copilot" },
            remoteReposDirectory: { root.path },
            remoteSessionBackendAvailable: { true },
            remoteSessionLauncher: { launches.append(($0, $1, $2)) },
            sessionCreationLedger: SessionCreationLedger(url: root.appendingPathComponent("ledger.json")),
            kittyImageDiskStore: RemoteKittyImageDiskStore(root: root.appendingPathComponent("images"))
        )
        defer {
            model.forcePendingSessionDestroys()
            model.detachAllClients()
        }

        let deepRowId = SessionFinderSource.resumableSessionId(for: olderCopilotId)
        let input = WorkspaceInputController(
            model: model,
            sessionRanker: OfflineRanker(),
            sessionHistorySearcher: StubHistorySearcher(matches: [
                LunaMatch(sessionId: deepRowId, reason: "migrated legacy schema"),
            ]),
            copilotSessionStore: { home.store }
        )
        input.presentSessionFinder()
        let finder = try XCTUnwrap(input.sessionFinder)
        for _ in 0..<200 where finder.isIndexing || finder.isLoadingResumable {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        // The older session is past the initial 30-session cap, so it is not in entries yet.
        XCTAssertFalse(finder.entries.contains { $0.id == deepRowId })

        finder.query = "legacy schema"
        for _ in 0..<200 {
            if case .finished = finder.deepSearch { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(finder.rows.map(\.id), [deepRowId])
        XCTAssertEqual(finder.rows.first?.lunaReason, "migrated legacy schema")

        input.openFromSessionFinder(deepRowId)
        XCTAssertNil(input.sessionFinder)
        XCTAssertEqual(model.selectedProjectId, "p2")
        XCTAssertEqual(launches.count, 1)
        let resumedTabId = launches[0].id
        XCTAssertEqual(model.capturedResumeLaunches[resumedTabId], olderCopilotId)
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

    func testSessionBackAndForwardNavigationAcrossProjectsAndClosedSessions() throws {
        let other = [Session(id: "other-1", title: "Other 1", cwd: "/tmp"),
                     Session(id: "other-2", title: "Other 2", cwd: "/tmp")]
        try withWorkspace(otherSessions: other) { model, input, sessions in
            model.bootstrapIfNeeded()
            XCTAssertFalse(model.canNavigateSessionBack)
            XCTAssertFalse(model.canNavigateSessionForward)
            XCTAssertEqual(model.globalSelectedSessionId, sessions[0].id)

            model.selectSession(projectId: model.projects[0].id, sessionId: sessions[1].id)
            XCTAssertTrue(model.canNavigateSessionBack)
            XCTAssertFalse(model.canNavigateSessionForward)
            XCTAssertEqual(model.previousHistorySessionTitle, sessions[0].title)

            input.openFromSessionFinder(other[1].id)
            XCTAssertEqual(model.globalSelectedSessionId, other[1].id)
            XCTAssertEqual(model.previousHistorySessionTitle, sessions[1].title)
            XCTAssertEqual(
                model.backHistoryMenuItems.map(\.menuTitle),
                ["second — Input fixture", "first — Input fixture"],
                "Back menu lists previous sessions most-recent-first with their project name"
            )
            XCTAssertTrue(model.forwardHistoryMenuItems.isEmpty)

            // Jumping directly to the earliest item via the Back right-click menu
            // populates the Forward menu in nearest-first order.
            let earliestBack = try XCTUnwrap(model.backHistoryMenuItems.last)
            XCTAssertEqual(model.navigateToSessionHistory(index: earliestBack.index)?.sessionId, sessions[0].id)
            XCTAssertEqual(model.globalSelectedSessionId, sessions[0].id)
            XCTAssertTrue(model.backHistoryMenuItems.isEmpty)
            XCTAssertEqual(
                model.forwardHistoryMenuItems.map(\.menuTitle),
                ["second — Input fixture", "Other 2 — Other fixture"]
            )
            let furthestForward = try XCTUnwrap(model.forwardHistoryMenuItems.last)
            XCTAssertEqual(model.navigateToSessionHistory(index: furthestForward.index)?.sessionId, other[1].id)
            XCTAssertEqual(model.globalSelectedSessionId, other[1].id)

            // Back and Forward menus cap at 10 entries.
            var capped = SessionNavigationHistory()
            let validIds = Set((0..<15).map { "s\($0)" })
            for i in 0..<15 {
                capped.reconcile(validSessionIds: validIds, currentSessionId: "s\(i)")
            }
            XCTAssertEqual(capped.backEntries().map(\.sessionId), (4..<14).reversed().map { "s\($0)" })
            _ = capped.goTo(index: 0, validSessionIds: validIds)
            XCTAssertEqual(capped.forwardEntries().map(\.sessionId), (1...10).map { "s\($0)" })

            let commandBack = try key("[", code: 33, modifiers: .command)
            let commandForward = try key("]", code: 30, modifiers: .command)

            XCTAssertNil(input.handleKeyDown(commandBack))
            XCTAssertEqual(model.globalSelectedSessionId, sessions[1].id)
            XCTAssertEqual(model.selectedProjectId, model.projects[0].id)
            XCTAssertTrue(model.canNavigateSessionBack)
            XCTAssertTrue(model.canNavigateSessionForward)
            XCTAssertEqual(model.previousHistorySessionTitle, sessions[0].title)
            XCTAssertEqual(model.nextHistorySessionTitle, other[1].title)

            XCTAssertNil(input.handleKeyDown(commandForward))
            XCTAssertEqual(model.globalSelectedSessionId, other[1].id)
            XCTAssertEqual(model.selectedProjectId, model.projects[1].id)
            XCTAssertFalse(model.canNavigateSessionForward)

            // Mouse Back (button 3) and Forward (button 4) navigate history on mouseDown,
            // swallow mouseUp, leave middle-click (button 2) untouched, and ignore sheets.
            func mouse(_ type: CGEventType, button: Int) throws -> NSEvent {
                let cgEvent = try XCTUnwrap(CGEvent(
                    mouseEventSource: nil,
                    mouseType: type,
                    mouseCursorPosition: .zero,
                    mouseButton: try XCTUnwrap(CGMouseButton(rawValue: UInt32(button)))
                ))
                return try XCTUnwrap(NSEvent(cgEvent: cgEvent))
            }
            let middleDown = try mouse(.otherMouseDown, button: 2)
            XCTAssertNotNil(input.handleOtherMouse(middleDown))
            XCTAssertEqual(model.globalSelectedSessionId, other[1].id)

            XCTAssertNil(input.handleOtherMouse(try mouse(.otherMouseDown, button: 3)))
            XCTAssertNil(input.handleOtherMouse(try mouse(.otherMouseUp, button: 3)))
            XCTAssertEqual(model.globalSelectedSessionId, sessions[1].id)

            input.presentSessionFinder()
            XCTAssertNotNil(input.handleOtherMouse(try mouse(.otherMouseDown, button: 4)))
            XCTAssertEqual(model.globalSelectedSessionId, sessions[1].id, "Mouse Back/Forward is ignored while a workspace sheet is open")
            input.dismissSessionFinder()

            XCTAssertNil(input.handleOtherMouse(try mouse(.otherMouseDown, button: 4)))
            XCTAssertNil(input.handleOtherMouse(try mouse(.otherMouseUp, button: 4)))
            XCTAssertEqual(model.globalSelectedSessionId, other[1].id)

            // Navigating back and then choosing a new branch truncates forward history.
            XCTAssertEqual(model.navigateSessionBack()?.sessionId, sessions[1].id)
            model.selectSession(projectId: model.projects[1].id, sessionId: other[0].id)
            model.selectProject(model.projects[1].id)
            XCTAssertEqual(model.globalSelectedSessionId, other[0].id)
            XCTAssertFalse(model.canNavigateSessionForward)
            XCTAssertEqual(model.previousHistorySessionTitle, sessions[1].title)

            // Closing the selected project's last session leaves no session displayed,
            // and Back reaches the most recent surviving visit without skipping entries.
            _ = model.closeRemoteSession(sessionId: other[1].id)
            _ = model.closeRemoteSession(sessionId: other[0].id)
            XCTAssertNil(model.globalSelectedSessionId)
            XCTAssertTrue(model.canNavigateSessionBack)
            XCTAssertFalse(model.canNavigateSessionForward)
            XCTAssertEqual(model.previousHistorySessionTitle, sessions[1].title)
            XCTAssertEqual(model.navigateSessionBack()?.sessionId, sessions[1].id)
            XCTAssertEqual(model.globalSelectedSessionId, sessions[1].id)
            XCTAssertTrue(model.canNavigateSessionBack)
            XCTAssertEqual(model.previousHistorySessionTitle, sessions[0].title)

            // Pruning a session in history while no session is displayed keeps the
            // remaining entry reachable via Back.
            model.selectProject(model.projects[1].id)
            XCTAssertNil(model.globalSelectedSessionId)
            _ = model.closeRemoteSession(sessionId: sessions[1].id)
            XCTAssertTrue(model.canNavigateSessionBack)
            XCTAssertFalse(model.canNavigateSessionForward)
            XCTAssertEqual(model.previousHistorySessionTitle, sessions[0].title)
            XCTAssertEqual(model.navigateSessionBack()?.sessionId, sessions[0].id)
            XCTAssertEqual(model.globalSelectedSessionId, sessions[0].id)
            XCTAssertFalse(model.canNavigateSessionBack)
            XCTAssertFalse(model.canNavigateSessionForward)

            // Closing the earliest visit with only forward survivors preserves a
            // before-first cursor so Forward opens the next surviving session in order.
            let reopenedB = try XCTUnwrap(model.addSession(toProjectId: model.projects[1].id, cwd: "/tmp"))
            model.selectProject(model.projects[1].id)
            let reopenedC = try XCTUnwrap(model.addSession(toProjectId: model.projects[1].id, cwd: "/tmp"))
            XCTAssertEqual(model.navigateSessionBack()?.sessionId, reopenedB)
            XCTAssertEqual(model.navigateSessionBack()?.sessionId, sessions[0].id)
            _ = model.closeRemoteSession(sessionId: sessions[0].id)
            XCTAssertNil(model.globalSelectedSessionId)
            XCTAssertFalse(model.canNavigateSessionBack)
            XCTAssertTrue(model.canNavigateSessionForward)
            XCTAssertEqual(model.navigateSessionForward()?.sessionId, reopenedB)
            XCTAssertEqual(model.globalSelectedSessionId, reopenedB)
            XCTAssertFalse(model.canNavigateSessionBack)
            XCTAssertTrue(model.canNavigateSessionForward)
            XCTAssertEqual(model.navigateSessionForward()?.sessionId, reopenedC)
            XCTAssertEqual(model.globalSelectedSessionId, reopenedC)
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

            for footer in [
                "Autopilot · Allow All    GPT-6.1 Sol · Max",
                "Autopilot · Allow All GPT-6.1 Sol · Max",
                "Interactive · Manual Approval · @ files · # issues    GPT-6.1 Sol",
                "◎ Working   esc cancel    GPT-6.1 Sol · Max",
                "◎ Running tests esc esc interrupt · ctrl+q enqueue GPT-6.1 Sol",
                "◎ Running tests ctrl+c interrupt · ctrl+q enqueue GPT-6.1 Sol",
            ] {
                view.feed(text: "\r\n" + footer)
                for modifiers in [NSEvent.ModifierFlags.command, .shift] {
                    let event = try key("\r", code: 36, modifiers: modifiers)
                    let before = process.sendCount
                    XCTAssertNil(input.handleKeyDown(event), footer)
                    XCTAssertEqual(process.sendCount, before + 1, footer)
                    XCTAssertTrue(view.terminalInputStateSnapshot()?.keyboardEnhancementFlags.isEmpty == true)
                }
            }

            let acceptedSends = process.sendCount
            for shellLine in ["zsh ~/working %", "~/src % echo esc stop agents"] {
                view.feed(text: "\r\n" + shellLine)
                XCTAssertNotNil(input.handleKeyDown(shiftReturn), shellLine)
                XCTAssertEqual(process.sendCount, acceptedSends, shellLine)
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
