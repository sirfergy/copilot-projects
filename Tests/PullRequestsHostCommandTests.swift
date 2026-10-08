import AppKit
import Foundation
import XCTest
import CopilotProjectsCore
@testable import CopilotProjectsHost

/// The control commands Copilot Pull Requests uses, against a real workspace
/// model with launches captured and an isolated state directory.
@MainActor
final class PullRequestsHostCommandTests: XCTestCase {
    private struct Host {
        let model: AppModel
        let root: URL
        let launches: () -> [(id: String, executable: String?, prompt: String?)]
        /// Another model over the same saved workspace and creation ledger, as after a restart.
        let restart: () -> AppModel
        /// Stands in for the tabs whose shell is still bringing back a Copilot session.
        let resuming: Resuming
    }

    private final class Resuming {
        var tabs: [String: Set<String>] = [:]
    }

    private func withHost(
        projects: (URL) -> [Project], selectedProjectIndex: Int = 0,
        _ body: (Host) throws -> Void
    ) throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("work"), withIntermediateDirectories: true)
        let keys = ["SHELL", "COPILOT_PROJECTS_STATE_DIR", "COPILOT_PROJECTS_SOCKET", "COPILOT_PROJECTS_DTACH", "COPILOT_HOME"]
        let previous = Dictionary(uniqueKeysWithValues: keys.map { ($0, ProcessInfo.processInfo.environment[$0]) })
        setenv("SHELL", "/bin/cat", 1)
        setenv("COPILOT_HOME", root.appendingPathComponent("copilot").path, 1)
        setenv("COPILOT_PROJECTS_STATE_DIR", root.path, 1)
        setenv("COPILOT_PROJECTS_SOCKET", root.appendingPathComponent("control.sock").path, 1)
        unsetenv("COPILOT_PROJECTS_DTACH")
        defer {
            for (key, value) in previous {
                if let value { setenv(key, value, 1) } else { unsetenv(key) }
            }
            try? FileManager.default.removeItem(at: root)
        }
        guard Paths.dtachExecutable == nil else { return XCTFail("Host command tests must not create persistent sessions") }
        let fixture = projects(root)
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(projects: fixture, selectedProjectId: fixture[selectedProjectIndex].id))
        var launches: [(id: String, executable: String?, prompt: String?)] = []
        var models: [AppModel] = []
        let resuming = Resuming()
        func makeModel() -> AppModel {
            let model = AppModel(
                stateRepository: repository, isAppActive: { false },
                agentActivityDirectory: root, resumeMarkerDirectory: root,
                copilotResumeSessions: { resuming.tabs[$0] ?? [] },
                remoteCopilotExecutable: { "/opt/copilot/bin/copilot" },
                remoteReposDirectory: { root.path },
                remoteSessionBackendAvailable: { true },
                remoteSessionLauncher: { launches.append(($0, $1, $2)) },
                sessionCreationLedger: SessionCreationLedger(url: root.appendingPathComponent("ledger.json")),
                kittyImageDiskStore: RemoteKittyImageDiskStore(root: root.appendingPathComponent("images"))
            )
            models.append(model)
            return model
        }
        let model = makeModel()
        defer {
            for model in models {
                model.forcePendingSessionDestroys()
                model.detachAllClients()
            }
        }
        try body(Host(model: model, root: root, launches: { launches }, restart: makeModel, resuming: resuming))
    }

    private func twoProjects(_ root: URL) -> [Project] {
        let a1 = Session(id: "a1", title: "Ship it - GitHub Copilot", cwd: root.appendingPathComponent("work").path)
        let a2 = Session(id: "a2", title: "shell", cwd: root.path)
        let b1 = Session(id: "b1", title: "Ops", cwd: root.path)
        return [
            Project(id: "A", name: "Features", cwd: root.path, sessions: [a1, a2], selectedSessionId: "a1"),
            Project(id: "B", name: "Ops", cwd: root.path, sessions: [b1], selectedSessionId: "b1"),
        ]
    }

    nonisolated private func request(_ command: String, project: String? = nil, session: String? = nil,
                         requestId: String? = nil, prompt: String? = nil, copilot: String? = nil) -> ControlRequest {
        var request = ControlRequest(command: command)
        request.projectId = project
        request.sessionId = session
        request.requestId = requestId
        request.prompt = prompt
        request.copilotSessionId = copilot
        return request
    }

    func testRouterValidatesThePullRequestsCommandsBeforeDispatch() {
        var dispatched: [String] = []
        let router = ControlCommandRouter(actions: .init(
            listProjects: { "" }, listStatus: { "" },
            setStatus: { _, _, _ in .success() }, notify: { _, _, _ in .success() },
            newProject: { _ in .success() }, newSession: { _ in .success() },
            newCopilotSession: { _ in dispatched.append("new-copilot-session"); return .success() },
            closeSession: { _ in .success() }, renameProject: { _, _ in .success() }, focus: { _ in .success() },
            listSessions: { dispatched.append("list-sessions"); return .success("{}") },
            revealSession: { dispatched.append("reveal-session:\($0.sessionId ?? "")"); return .success(code: "revealed") },
            startCopilotSession: { dispatched.append("start:\($0.requestId ?? "")"); return .success("s", code: "created") },
            resumeCopilotSession: {
                dispatched.append("resume:\($0.copilotSessionId ?? "")")
                return .success("t", code: "created")
            },
            screenshot: { _ in .success() }, diagnostics: { "" }, remote: { _ in .success() }
        ))
        let uuid = UUID().uuidString
        for invalid in [
            request("reveal-session"),
            request("reveal-session", session: ""),
            request("reveal-session", project: "", session: "s"),
            request("start-copilot-session", requestId: uuid, prompt: "p"),
            request("start-copilot-session", project: "", requestId: uuid, prompt: "p"),
            request("start-copilot-session", project: "A", prompt: "p"),
            request("start-copilot-session", project: "A", requestId: "not-a-uuid", prompt: "p"),
            request("start-copilot-session", project: "A", requestId: uuid),
            request("resume-copilot-session", requestId: uuid, copilot: uuid),
            request("resume-copilot-session", project: "", requestId: uuid, copilot: uuid),
            request("resume-copilot-session", project: "A", copilot: uuid),
            request("resume-copilot-session", project: "A", requestId: "not-a-uuid", copilot: uuid),
            request("resume-copilot-session", project: "A", requestId: uuid),
            request("resume-copilot-session", project: "A", requestId: uuid, copilot: "../../etc/passwd"),
        ] {
            let response = router.handle(invalid)
            XCTAssertFalse(response.ok)
            XCTAssertEqual(response.code, "bad-request", invalid.command)
        }
        XCTAssertTrue(dispatched.isEmpty)
        XCTAssertEqual(router.handle(request("list-sessions")).text, "{}")
        XCTAssertEqual(router.handle(request("reveal-session", session: "s")).code, "revealed")
        XCTAssertEqual(router.handle(request("start-copilot-session", project: "A", requestId: uuid, prompt: "p")).code,
                       "created")
        XCTAssertEqual(router.handle(request("resume-copilot-session", project: "A", requestId: uuid, copilot: uuid)).code,
                       "created")
        XCTAssertEqual(dispatched, ["list-sessions", "reveal-session:s", "start:\(uuid)", "resume:\(uuid)"])
    }

    func testListSessionsReportsEveryProjectAndSessionAsJSON() throws {
        try withHost(projects: twoProjects) { host in
            try Data("  0f1e2d3c-4b5a-4000-8000-000000000001\n".utf8)
                .write(to: host.root.appendingPathComponent("a1.copilot-session"))
            var waiting = request("set-status", session: "b1")
            waiting.status = "waiting"
            XCTAssertTrue(host.model.handle(waiting).ok)

            let response = host.model.handle(request("list-sessions"))
            XCTAssertTrue(response.ok)
            let text = try XCTUnwrap(response.text)
            let snapshot = try JSONDecoder().decode(WorkspaceSnapshot.self, from: Data(text.utf8))
            XCTAssertEqual(snapshot.version, 1)
            XCTAssertEqual(snapshot.hostProcessIdentifier, ProcessInfo.processInfo.processIdentifier)
            XCTAssertEqual(snapshot.selectedProjectId, "A")
            XCTAssertEqual(snapshot.projects.map(\.id), ["A", "B"])
            XCTAssertEqual(snapshot.projects.map(\.name), ["Features", "Ops"])
            XCTAssertEqual(snapshot.projects[0].sessions.map(\.id), ["a1", "a2"])
            XCTAssertEqual(snapshot.projects[0].sessions[0].title, "Ship it - GitHub Copilot")
            XCTAssertEqual(snapshot.projects[0].sessions[0].copilotSessionId, "0f1e2d3c-4b5a-4000-8000-000000000001")
            XCTAssertNil(snapshot.projects[0].sessions[1].copilotSessionId)
            XCTAssertEqual(snapshot.projects[0].sessions[0].status, .idle)
            XCTAssertEqual(snapshot.projects[1].sessions[0].status, .waiting)
            XCTAssertEqual(snapshot, host.model.workspaceSnapshot())

            // The wire shape Copilot Pull Requests decodes.
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
            XCTAssertEqual(Set(json.keys), ["version", "hostProcessIdentifier", "selectedProjectId", "projects"])
            let project = try XCTUnwrap((json["projects"] as? [[String: Any]])?.first)
            XCTAssertEqual(Set(project.keys), ["id", "name", "sessions"])
            let session = try XCTUnwrap((project["sessions"] as? [[String: Any]])?.first)
            XCTAssertEqual(
                Set(session.keys),
                ["id", "title", "status", "finishedUnseen", "hasPendingInput", "copilotSessionId"]
            )
            XCTAssertEqual(session["status"] as? String, "idle")
        }
    }

    func testRevealSessionIsStrictAndShowsTheSessionWithoutFallingBack() throws {
        try withHost(projects: twoProjects) { host in
            let model = host.model
            var windowRequests = 0
            model.requestMainWindow = { windowRequests += 1 }

            let gone = model.handle(request("reveal-session", project: "A", session: "ended"))
            XCTAssertFalse(gone.ok)
            XCTAssertEqual(gone.code, "gone")
            let moved = model.handle(request("reveal-session", project: "A", session: "b1"))
            XCTAssertFalse(moved.ok)
            XCTAssertEqual(moved.code, "conflict")
            XCTAssertEqual(model.selectedProjectId, "A")
            XCTAssertEqual(model.globalSelectedSessionId, "a1")
            XCTAssertEqual(windowRequests, 0, "a refused reveal changes nothing")

            let revealed = model.handle(request("reveal-session", project: "B", session: "b1"))
            XCTAssertTrue(revealed.ok)
            XCTAssertEqual(revealed.code, "revealed")
            XCTAssertEqual(model.selectedProjectId, "B")
            XCTAssertEqual(model.globalSelectedSessionId, "b1")
            XCTAssertEqual(windowRequests, 1)
            let shown = try XCTUnwrap(model.project("B")?.sessions.first)
            XCTAssertFalse(shown.hasUnread)
            XCTAssertFalse(shown.finishedUnseen)

            XCTAssertEqual(model.handle(request("reveal-session", session: "a2")).code, "revealed")
            XCTAssertEqual(model.selectedProjectId, "A")
            XCTAssertEqual(model.globalSelectedSessionId, "a2")
            XCTAssertEqual(windowRequests, 2)
        }
    }

    func testStartCopilotSessionMatchesTheInAppButtonAndIsIdempotentPerRequest() throws {
        try withHost(projects: twoProjects, selectedProjectIndex: 1) { host in
            let model = host.model
            let requestId = UUID().uuidString
            let prompt = "Help me move this pull request forward:\r\n\r\n- https://github.com/o/r/pull/1"
            @MainActor func start(
                _ id: String = requestId, project: String = "A", prompt: String = prompt, on model: AppModel = model
            ) -> ControlResponse {
                model.handle(request("start-copilot-session", project: project, requestId: id, prompt: prompt))
            }

            let created = start()
            XCTAssertTrue(created.ok, created.error ?? "")
            XCTAssertEqual(created.code, "created")
            let sessionId = try XCTUnwrap(created.text)
            XCTAssertEqual(host.launches().count, 1)
            XCTAssertEqual(host.launches()[0].id, sessionId)
            XCTAssertEqual(host.launches()[0].executable, "/opt/copilot/bin/copilot")
            XCTAssertEqual(host.launches()[0].prompt, prompt.replacingOccurrences(of: "\r\n", with: "\n"))
            let project = try XCTUnwrap(model.project("A"))
            let session = try XCTUnwrap(project.sessions.last)
            XCTAssertEqual(session.id, sessionId)
            XCTAssertEqual(session.title, "Copilot")
            XCTAssertEqual(session.cwd, host.root.appendingPathComponent("work").path,
                           "local semantics: the project's shown session's folder, not ~/Repos")
            XCTAssertEqual(project.selectedSessionId, sessionId, "selected in its project, as the in-app button did")
            XCTAssertEqual(model.selectedProjectId, "B", "revealing it is a separate request")

            let replay = start()
            XCTAssertEqual(replay.code, "existing")
            XCTAssertEqual(replay.text, sessionId)
            XCTAssertEqual(start(prompt: "something else").code, "conflict")
            XCTAssertEqual(start(project: "B").code, "conflict")
            XCTAssertEqual(host.launches().count, 1)

            let invalid = start(UUID().uuidString, prompt: "bell\u{7}")
            XCTAssertEqual(invalid.code, "bad-request")
            XCTAssertEqual(start(UUID().uuidString, project: "missing").code, "unknown-project")
            XCTAssertEqual(host.launches().count, 1)

            // A restart forgets nothing: an answer lost before it must not start a second session.
            let restarted = host.restart()
            let replayed = start(on: restarted)
            XCTAssertEqual(replayed.code, "existing")
            XCTAssertEqual(replayed.text, sessionId)
            XCTAssertEqual(start(prompt: "something else", on: restarted).code, "conflict")
            XCTAssertEqual(start(project: "B", on: restarted).code, "conflict")
            XCTAssertEqual(host.launches().count, 1)

            restarted.closeSession(projectId: "A", sessionId: sessionId)
            let ended = start(on: restarted)
            XCTAssertFalse(ended.ok)
            XCTAssertEqual(ended.code, "gone", "an ended session is never started again for the same request")
            XCTAssertEqual(start(on: host.restart()).code, "gone", "nor after another restart")
            XCTAssertEqual(host.launches().count, 1)

            try Data("{".utf8).write(to: host.root.appendingPathComponent("ledger.json"))
            let unreadable = start(UUID().uuidString, on: restarted)
            XCTAssertEqual(unreadable.code, "persistence-unavailable", "an unreadable ledger never risks a duplicate")
            XCTAssertEqual(host.launches().count, 1)
        }
    }

    func testResumeCopilotSessionOpensItInItsFolderAndIsIdempotentPerRequest() throws {
        try withHost(projects: twoProjects, selectedProjectIndex: 1) { host in
            let model = host.model
            let home = try CopilotHomeFixture(root: host.root.appendingPathComponent("copilot"))
            let folder = host.root.appendingPathComponent("worktree")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let copilotId = try home.addSession(cwd: folder.path, transcript: "")
            let other = try home.addSession(cwd: folder.path, transcript: "")
            let requestId = UUID().uuidString
            @MainActor func resume(_ id: String = requestId, project: String = "A", copilot: String = copilotId,
                                   on target: AppModel? = nil) -> ControlResponse {
                (target ?? model).handle(request("resume-copilot-session", project: project, requestId: id, copilot: copilot))
            }

            let created = resume()
            XCTAssertTrue(created.ok, created.error ?? "")
            XCTAssertEqual(created.code, "created")
            let tab = try XCTUnwrap(created.text)
            XCTAssertEqual(host.launches().map(\.id), [tab])
            XCTAssertEqual(host.launches()[0].executable, "/opt/copilot/bin/copilot")
            XCTAssertNil(host.launches()[0].prompt)
            XCTAssertEqual(model.capturedResumeLaunches, [tab: copilotId])
            let project = try XCTUnwrap(model.project("A"))
            let session = try XCTUnwrap(project.sessions.last)
            XCTAssertEqual(session.id, tab)
            XCTAssertEqual(session.title, "Copilot")
            XCTAssertEqual(session.cwd, folder.path, "it resumes in the folder it worked in")
            XCTAssertEqual(project.selectedSessionId, tab)
            XCTAssertEqual(model.selectedProjectId, "B", "revealing it is a separate request")
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: host.root.appendingPathComponent("\(tab).copilot-session").path),
                "Copilot writes the resume marker once it has resumed"
            )

            XCTAssertEqual(resume().code, "existing")
            XCTAssertEqual(resume().text, tab)
            XCTAssertEqual(resume(project: "B").code, "conflict")
            XCTAssertEqual(resume(copilot: other).code, "conflict")

            // Before its shell has started the command that resumes it, a new request finds the tab.
            let starting = resume(UUID().uuidString, copilot: copilotId.uppercased())
            XCTAssertEqual(starting.code, "existing")
            XCTAssertEqual(starting.text, tab)
            // Later, for as long as that command or the Copilot it started runs there, however
            // long Copilot takes before it locks the session.
            let later = Date().addingTimeInterval(AppModel.pullRequestsResumeStartupGrace + 60)
            host.resuming.tabs[copilotId] = [tab]
            let resuming = model.resumePullRequestsSession(
                requestId: UUID(), projectId: "B", copilotSessionId: copilotId, now: later
            )
            XCTAssertEqual(resuming.code, "existing")
            XCTAssertEqual(resuming.text, tab)
            // Once resumed, its marker names it wherever the request asks.
            host.resuming.tabs = [:]
            try Data("\(copilotId)\n".utf8).write(to: host.root.appendingPathComponent("\(tab).copilot-session"))
            let marked = resume(UUID().uuidString, project: "B")
            XCTAssertEqual(marked.code, "existing")
            XCTAssertEqual(marked.text, tab)
            XCTAssertEqual(host.launches().count, 1)

            // A restart forgets nothing: an answer lost before it never opens a second tab.
            let restarted = host.restart()
            XCTAssertEqual(resume(on: restarted).code, "existing")
            XCTAssertEqual(resume(on: restarted).text, tab)
            XCTAssertEqual(resume(project: "B", on: restarted).code, "conflict")
            XCTAssertEqual(resume(copilot: other, on: restarted).code, "conflict")
            XCTAssertEqual(host.launches().count, 1)

            restarted.closeSession(projectId: "A", sessionId: tab)
            let ended = resume(on: restarted)
            XCTAssertFalse(ended.ok)
            XCTAssertEqual(ended.code, "gone", "an ended tab is never opened again for the same request")
            XCTAssertEqual(resume(on: host.restart()).code, "gone", "nor after another restart")
            XCTAssertEqual(host.launches().count, 1)

            try Data("{".utf8).write(to: host.root.appendingPathComponent("ledger.json"))
            let unreadable = resume(UUID().uuidString, on: restarted)
            XCTAssertEqual(unreadable.code, "persistence-unavailable", "an unreadable ledger never risks a second tab")
            XCTAssertEqual(host.launches().count, 1)
        }
    }

    func testOnlyTheCommandThatResumesASessionCountsAsBringingItBack() {
        let id = "0f1e2d3c-4b5a-4000-8000-0000000000aa"
        let resume = TerminalController.startupProgram(
            shell: "/bin/zsh", copilotSessionId: id, resumeCopilotExecutable: "/opt/copilot", launchCopilotExecutable: nil
        )
        XCTAssertTrue(ProcessTree.resumes(resume, copilotSessionId: id.uppercased()), "the tab's shell while it runs")
        XCTAssertTrue(ProcessTree.resumes(["/opt/copilot", "--no-remote", "--no-remote-export", "--resume=\(id)"],
                                          copilotSessionId: id), "the Copilot it starts")
        XCTAssertTrue(ProcessTree.resumes(["copilot", "--resume", id], copilotSessionId: id), "typed by hand")
        XCTAssertTrue(ProcessTree.resumes(
            ["node", "/opt/homebrew/lib/node_modules/@github/copilot/index.js", "--resume=\(id)"], copilotSessionId: id
        ), "run by its loader")
        XCTAssertFalse(ProcessTree.resumes(["rg", "--", "--resume=\(id)", "/work"], copilotSessionId: id),
                       "another program searching for it")
        XCTAssertFalse(ProcessTree.resumes(["grep", "-r", "--resume=\(id)", "."], copilotSessionId: id))
        XCTAssertFalse(ProcessTree.resumes(["copilot", "--", "--resume=\(id)"], copilotSessionId: id))

        // A session started to talk about it, however its prompt quotes the command.
        for prompt in [
            "Explain why copilot --resume=\(id) failed",
            "Explain why '--resume=\(id)' || printf failed",
            "--resume=\(id)",
            "ends with '--resume=\(id)",
            "' || printf '\\n[Copilot Projects] could not resume Copilot session \(id)\\n'",
        ] {
            let start = TerminalController.startupProgram(
                shell: "/bin/zsh", copilotSessionId: nil, launchCopilotExecutable: "/opt/copilot",
                launchCopilotInitialPrompt: prompt
            )
            XCTAssertFalse(ProcessTree.resumes(start, copilotSessionId: id), prompt)
            XCTAssertFalse(ProcessTree.resumes(
                ["/opt/copilot", "--no-remote", "--no-remote-export", "--interactive", prompt], copilotSessionId: id
            ), prompt)
        }
    }

    func testAResumeThatEndedWithoutResumingLetsTheNextRequestOpenItAgain() throws {
        try withHost(projects: twoProjects) { host in
            let model = host.model
            let home = try CopilotHomeFixture(root: host.root.appendingPathComponent("copilot"))
            let copilotId = try home.addSession(cwd: host.root.path, transcript: "")
            let start = Date()
            let first = model.resumePullRequestsSession(
                requestId: UUID(), projectId: "A", copilotSessionId: copilotId, now: start
            )
            XCTAssertEqual(first.code, "created")
            let failed = try XCTUnwrap(first.text)

            // Copilot exited without resuming it: no marker, no lock, and its tab is a plain shell.
            let later = start.addingTimeInterval(AppModel.pullRequestsResumeStartupGrace + 60)
            let second = model.resumePullRequestsSession(
                requestId: UUID(), projectId: "A", copilotSessionId: copilotId, now: later
            )
            XCTAssertEqual(second.code, "created")
            let retried = try XCTUnwrap(second.text)
            XCTAssertNotEqual(retried, failed)
            XCTAssertEqual(host.launches().map(\.id), [failed, retried])

            // Only the tab still bringing it back has it, not the one where it failed.
            host.resuming.tabs[copilotId] = [retried]
            let third = model.resumePullRequestsSession(
                requestId: UUID(), projectId: "A", copilotSessionId: copilotId, now: later.addingTimeInterval(60)
            )
            XCTAssertEqual(third.code, "existing")
            XCTAssertEqual(third.text, retried)
            XCTAssertEqual(host.launches().count, 2)
        }
    }

    func testAResumeThatCouldNotBeSavedKeepsItsTabForTheRetry() throws {
        try withHost(projects: twoProjects) { host in
            let model = host.model
            let home = try CopilotHomeFixture(root: host.root.appendingPathComponent("copilot"))
            let copilotId = try home.addSession(cwd: host.root.path, transcript: "")
            try Data(#"{"records":[]}"#.utf8).write(to: host.root.appendingPathComponent("ledger.json"))
            let requestId = UUID().uuidString
            XCTAssertEqual(chmod(host.root.path, 0o500), 0)
            let unsaved = model.handle(request("resume-copilot-session", project: "A", requestId: requestId, copilot: copilotId))
            XCTAssertEqual(chmod(host.root.path, 0o700), 0)
            XCTAssertEqual(unsaved.code, "persistence-unavailable")
            XCTAssertEqual(host.launches().map(\.id), [requestId], "the tab stays open")

            let retried = model.handle(request("resume-copilot-session", project: "A", requestId: requestId, copilot: copilotId))
            XCTAssertEqual(retried.code, "existing")
            XCTAssertEqual(retried.text, requestId)
            XCTAssertEqual(host.launches().count, 1)
            XCTAssertEqual(host.restart().handle(
                request("resume-copilot-session", project: "A", requestId: requestId, copilot: copilotId)
            ).text, requestId, "and is saved for good")
        }
    }

    func testResumeCopilotSessionReturnsATabWhoseMarkerAlreadyNamesIt() throws {
        try withHost(projects: twoProjects) { host in
            let home = try CopilotHomeFixture(root: host.root.appendingPathComponent("copilot"))
            let copilotId = try home.addSession(cwd: host.root.path, transcript: "")
            try Data(copilotId.uppercased().utf8).write(to: host.root.appendingPathComponent("b1.copilot-session"))
            let response = host.model.handle(request(
                "resume-copilot-session", project: "A", requestId: UUID().uuidString, copilot: copilotId
            ))
            XCTAssertEqual(response.code, "existing")
            XCTAssertEqual(response.text, "b1")
            XCTAssertTrue(host.launches().isEmpty)
        }
    }

    func testResumeCopilotSessionRefusesSessionsItCannotOpenHere() throws {
        try withHost(projects: twoProjects) { host in
            let model = host.model
            let home = try CopilotHomeFixture(root: host.root.appendingPathComponent("copilot"))
            @MainActor func resume(_ copilot: String, project: String = "A") -> ControlResponse {
                model.handle(request(
                    "resume-copilot-session", project: project, requestId: UUID().uuidString, copilot: copilot
                ))
            }
            let gone = resume(UUID().uuidString)
            XCTAssertEqual(gone.code, "gone")
            XCTAssertEqual(gone.error, "That Copilot session no longer exists.")

            let held = try home.addSession(cwd: host.root.path, transcript: "")
            try home.lock(held)
            let inUse = resume(held)
            XCTAssertEqual(inUse.code, "in-use")
            XCTAssertEqual(inUse.error, "That Copilot session is open somewhere else.")

            let deleted = host.root.appendingPathComponent("deleted-worktree").path
            let invalid = resume(try home.addSession(cwd: deleted, transcript: ""))
            XCTAssertEqual(invalid.code, "invalid")
            XCTAssertEqual(invalid.error, "The folder it worked in, \(deleted), no longer exists.")

            XCTAssertEqual(resume(try home.addSession(cwd: host.root.path, transcript: ""), project: "missing").code,
                           "unknown-project")
            XCTAssertTrue(host.launches().isEmpty)
            XCTAssertEqual(model.project("A")?.sessions.map(\.id), ["a1", "a2"])
        }
    }
}

final class PullRequestsAppLauncherTests: XCTestCase {
    func testOnlyTheAllowlistCrossesIntoTheHelperAndTokensNeverDo() {
        let environment = [
            "GH_TOKEN": "gho_secret", "GITHUB_TOKEN": "ghp_secret", "PATH": "/usr/bin", "HOME": "/Users/me",
            "COPILOT_HOME": "/Users/me/.copilot", "COPILOT_PROJECTS_GH": "/opt/homebrew/bin/gh",
            "COPILOT_PROJECTS_DTACH": "/opt/dtach", "COPILOT_PROJECTS_SOCKET": "",
        ]
        let launch = PullRequestsAppLauncher.launch(environment: environment)
        XCTAssertEqual(launch.environment, [
            "COPILOT_HOME": "/Users/me/.copilot", "COPILOT_PROJECTS_GH": "/opt/homebrew/bin/gh",
        ])
        XCTAssertTrue(launch.activates)
        XCTAssertFalse(launch.allowsRunningApplicationSubstitution)
        XCTAssertFalse(launch.createsNewApplicationInstance, "the user's own helper is reused")

        let isolated = PullRequestsAppLauncher.launch(environment: environment.merging([
            "COPILOT_PROJECTS_STATE_DIR": "/Users/me/isolated-state",
        ]) { $1 })
        XCTAssertTrue(isolated.createsNewApplicationInstance)
        XCTAssertEqual(isolated.environment["COPILOT_PROJECTS_STATE_DIR"], "/Users/me/isolated-state")
        XCTAssertNil(isolated.environment["GH_TOKEN"])
        XCTAssertTrue(PullRequestsAppLauncher.launch(environment: ["COPILOT_PROJECTS_SOCKET": "/Users/me/isolated.sock"])
            .createsNewApplicationInstance)
        XCTAssertEqual(PullRequestsAppBundle.forwardedEnvironmentKeys.sorted(), [
            "COPILOT_HOME", "COPILOT_PROJECTS_GH", "COPILOT_PROJECTS_SOCKET", "COPILOT_PROJECTS_STATE_DIR",
        ])
    }

    func testTheHelperIsNestedInTheHostAndFindsItsWayBack() {
        let host = URL(fileURLWithPath: "/Applications/Copilot Projects.app")
        let helper = PullRequestsAppBundle.helperURL(inHostBundle: host)
        XCTAssertEqual(helper.path, "/Applications/Copilot Projects.app/Contents/Helpers/Copilot Pull Requests.app")
        XCTAssertEqual(AppDeepLink.parentApplicationURL(forHelperBundleURL: helper)?.path, host.path)
        XCTAssertEqual(
            PullRequestsAppBundle.helperBundleIdentifier(hostBundleIdentifier: "com.obvioussean.copilot-projects"),
            "com.obvioussean.copilot-projects.pull-requests"
        )
        XCTAssertEqual(Paths.pullRequestsAppPIDPath, Paths.stateDir.appendingPathComponent("pull-requests/app.pid").path)
        XCTAssertEqual(Paths.pullRequestsAppLockPath, Paths.stateDir.appendingPathComponent("pull-requests/app.lock").path)
    }

    @MainActor
    func testAStaleOrForeignPidIsNotTheHelper() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pidPath = root.appendingPathComponent("app.pid").path
        XCTAssertNil(PullRequestsAppLauncher.runningHelper(bundleIdentifier: "x.pull-requests", pidPath: pidPath))
        try Data("not a pid\n".utf8).write(to: URL(fileURLWithPath: pidPath))
        XCTAssertNil(PullRequestsAppLauncher.runningHelper(bundleIdentifier: "x.pull-requests", pidPath: pidPath))
        try Data("\(getpid())\n".utf8).write(to: URL(fileURLWithPath: pidPath))
        XCTAssertNil(
            PullRequestsAppLauncher.runningHelper(bundleIdentifier: "com.example.not-this.pull-requests", pidPath: pidPath),
            "a live process that isn't the helper is never activated"
        )
        XCTAssertNil(PullRequestsAppLauncher.runningHelper(bundleIdentifier: nil, pidPath: pidPath))
    }
}
