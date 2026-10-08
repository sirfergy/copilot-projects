import AppKit
import Foundation
import XCTest
import CopilotProjectsCore
import CopilotProjectsProtocol
@testable import CopilotProjectsPullRequests
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
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".scratch/pr-host-\(UUID().uuidString)")
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
        XCTAssertFalse(ProcessTree.resumes(["rg", "-e", "copilot", "-e", "--resume=\(id)", "/work"], copilotSessionId: id))
        XCTAssertFalse(ProcessTree.resumes(["rg", "-c", "x", "copilot", "--resume=\(id)"], copilotSessionId: id))
        XCTAssertTrue(ProcessTree.resumes(["node", "/opt/homebrew/bin/copilot", "--resume=\(id)"], copilotSessionId: id))
        XCTAssertTrue(ProcessTree.resumes(
            ["/bin/sh", "-c", #"exec "$0" "$@""#, "/opt/copilot", "--no-remote", "--resume=\(id)"], copilotSessionId: id
        ), "the wrapper that starts it")

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

            // Not one another tab's Copilot wrote: that tab never had it.
            let foreign = try home.addSession(cwd: host.root.path, transcript: "")
            try Data(foreign.utf8).write(to: host.root.appendingPathComponent("a2.copilot-session"))
            try JSONSerialization.data(withJSONObject: [
                "appSessionId": "b1", "copilotSessionId": foreign, "pid": ProcessInfo.processInfo.processIdentifier,
            ]).write(to: host.root.appendingPathComponent("a2.transcript-owner.json"))
            let resumed = host.model.handle(request(
                "resume-copilot-session", project: "A", requestId: UUID().uuidString, copilot: foreign
            ))
            XCTAssertEqual(resumed.code, "created")
            XCTAssertNotEqual(resumed.text, "a2")
            XCTAssertEqual(host.launches().count, 1)
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

extension PullRequestsHostCommandTests {
    private func overview(
        _ host: Host, prs: [PullRequestSnapshot] = [makePR(1), makePR(2)],
        resumable: [PullRequestKey: ResumableSession] = [:]
    ) -> PullRequestsModel {
        let engine = PullRequestsModel(
            workspace: FakeWorkspace(snapshot: host.model.workspaceSnapshot()),
            defaults: UserDefaults(suiteName: "host-pr-\(UUID().uuidString)")!,
            stateDirectory: host.root.appendingPathComponent("host-cache"), loadAccounts: { [] },
            resumableFinder: ResumableSessionFinder(
                store: CopilotSessionStore(environment: ["COPILOT_HOME": host.root.appendingPathComponent("copilot").path]),
                cacheURL: nil
            ),
            hostedReadOnly: true, readOnlyGoalsURL: host.root.appendingPathComponent("goals.json"),
            transcriptPath: { _ in nil }, isVisible: { false }, presentError: { _, _ in XCTFail("No remote alerts") }
        )
        engine.apply(.snapshot(host.model.workspaceSnapshot()))
        engine.show(prs, links: [:], resumable: resumable)
        host.model.pullRequestsOverviewProvider = PullRequestsOverviewProvider(
            model: engine, workspace: { [weak model = host.model] in model?.workspaceSnapshot() }
        )
        return engine
    }

    private func prRequest(
        _ id: UUID = UUID(), kind: String = "start", project: String = "A",
        keys: [String] = ["github/github#1"], cid: String? = nil
    ) -> RemotePullRequestSessionRequest {
        .init(requestId: id, kind: kind, projectId: project, pullRequestKeys: keys, copilotSessionId: cid)
    }

    func testRemotePullRequestStartConflictReplayRestartAndMacSelection() throws {
        try withHost(projects: twoProjects, selectedProjectIndex: 1) { host in
            let engine = overview(host)
            let model = host.model
            var windows = 0
            model.requestMainWindow = { windows += 1 }
            let selectedTabCwd = try XCTUnwrap(model.project("A")?.sessions.first { $0.id == "a1" }?.cwd)
            XCTAssertNotEqual(selectedTabCwd, model.project("A")?.cwd)
            let request = prRequest(keys: ["GITHUB/GITHUB#2", "github/github#1", "github/github#2"])
            guard case .created(let created) = model.performRemotePullRequestSession(request) else {
                return XCTFail("Start should create")
            }
            XCTAssertEqual(host.launches().count, 1)
            XCTAssertEqual(model.selectedProjectId, "B")
            XCTAssertEqual(model.globalSelectedSessionId, "b1")
            XCTAssertEqual(model.project("A")?.selectedSessionId, "a1")
            XCTAssertEqual(model.project("A")?.sessions.last?.cwd, selectedTabCwd,
                           "same folder as local PR Start, without taking the selected tab")
            XCTAssertEqual(windows, 0)
            XCTAssertEqual(model.project("A")?.sessions.last?.pullRequestKeys, ["github/github#1", "github/github#2"])
            XCTAssertEqual(host.launches()[0].prompt, PullRequestsOverviewProvider.startingPrompt(
                for: ["github/github#1", "github/github#2"]))
            XCTAssertEqual(model.performRemotePullRequestSession(prRequest()), .conflict,
                           "a second UUID cannot start another tab for the linked PR")
            XCTAssertEqual(model.performRemotePullRequestSession(prRequest(request.requestId, keys: ["github/github#1"])),
                           .conflict)
            engine.show([], links: [:])
            XCTAssertEqual(model.performRemotePullRequestSession(request), .existing(created), "replay after PRs merge")
            let restarted = host.restart()
            XCTAssertEqual(restarted.performRemotePullRequestSession(request), .existing(created))
            XCTAssertEqual(restarted.project("A")?.sessions.last?.pullRequestKeys,
                           ["github/github#1", "github/github#2"])
            XCTAssertEqual(host.launches().count, 1)
            restarted.closeSession(projectId: "A", sessionId: created.sessionId)
            XCTAssertEqual(restarted.performRemotePullRequestSession(request), .gone)
            XCTAssertEqual(host.restart().performRemotePullRequestSession(request), .gone)
        }
    }

    func testRemotePullRequestResumeVerifiesSubsetReturnsActualOwnerAndPreservesOriginalBinding() throws {
        try withHost(projects: twoProjects, selectedProjectIndex: 1) { host in
            let home = try CopilotHomeFixture(root: host.root.appendingPathComponent("copilot"))
            let cid = try home.addSession(cwd: host.root.appendingPathComponent("work").path, transcript: "")
            let candidate = ResumableSession(copilotSessionId: cid, name: "Previous", cwd: host.root.path, lastActive: testNow)
            let first = makePR(1), other = makePR(2)
            let engine = overview(host, resumable: [first.key: candidate])
            let wrong = prRequest(kind: "resume", keys: [first.key.description, other.key.description], cid: cid)
            guard case .stale = host.model.performRemotePullRequestSession(wrong) else { return XCTFail("subset") }
            XCTAssertTrue(host.launches().isEmpty)
            let original = prRequest(kind: "resume", cid: cid)
            guard case .created(let created) = host.model.performRemotePullRequestSession(original) else {
                return XCTFail("Resume should create")
            }
            let fingerprint = host.model.project("A")?.sessions.last?.creationFingerprint
            XCTAssertEqual(host.model.selectedProjectId, "B")
            XCTAssertEqual(host.model.globalSelectedSessionId, "b1")
            XCTAssertEqual(host.model.project("A")?.selectedSessionId, "a1")
            XCTAssertEqual(host.model.project("A")?.sessions.last?.cwd, host.root.appendingPathComponent("work").path)
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: host.root.appendingPathComponent("\(created.sessionId).copilot-session").path))
            let second = prRequest(kind: "resume", project: "B", cid: cid.uppercased())
            guard case .existing(let existing) = host.model.performRemotePullRequestSession(second) else {
                return XCTFail("Resume existing tab")
            }
            XCTAssertEqual(existing.projectId, "A", "the owning project, not the requested destination")
            XCTAssertEqual(existing.sessionId, created.sessionId)
            XCTAssertEqual(host.model.project("A")?.sessions.last?.creationFingerprint, fingerprint)
            engine.show([], links: [:])
            XCTAssertEqual(host.model.performRemotePullRequestSession(original), .existing(created))
            guard case .existing(let third) = host.model.performRemotePullRequestSession(
                prRequest(kind: "resume", project: "B", cid: cid)
            ) else { return XCTFail("An existing tab's verified associations outlive the open PR list") }
            XCTAssertEqual(third.sessionId, created.sessionId)
            let restarted = host.restart()
            XCTAssertEqual(restarted.performRemotePullRequestSession(original), .existing(created))
            XCTAssertEqual(restarted.performRemotePullRequestSession(second), .existing(existing))
            XCTAssertEqual(host.launches().count, 1)
        }
    }

    func testRemotePullRequestResumeGoneInUseMissingCwdAndUnknownProject() throws {
        try withHost(projects: twoProjects) { host in
            let home = try CopilotHomeFixture(root: host.root.appendingPathComponent("copilot"))
            let held = try home.addSession(cwd: host.root.path, transcript: "")
            try home.lock(held)
            let missing = try home.addSession(cwd: host.root.appendingPathComponent("deleted").path, transcript: "")
            let gone = UUID().uuidString.lowercased()
            let good = try home.addSession(cwd: host.root.path, transcript: "")
            let engine = overview(host)
            for (cid, project, expected) in [
                (held, "A", RemotePullRequestSessionOutcome.inUse),
                (gone, "A", .gone),
                (missing, "A", .invalid("The session's working directory is no longer available.")),
                (good, "missing", .unknownProject),
            ] {
                engine.show([makePR()], links: [:], resumable: [
                    makePR().key: .init(copilotSessionId: cid, name: "Previous", cwd: "/not-used", lastActive: testNow),
                ])
                XCTAssertEqual(host.model.performRemotePullRequestSession(prRequest(kind: "resume", project: project,
                                                                                     cid: cid)), expected)
            }
            XCTAssertTrue(host.launches().isEmpty)
        }
    }

    func testRemotePullRequestPersistenceFailureRepairsAssociationsWithoutDuplicateLaunch() throws {
        try withHost(projects: twoProjects) { host in
            _ = overview(host)
            try Data(#"{"records":[]}"#.utf8).write(to: host.root.appendingPathComponent("ledger.json"))
            let request = prRequest()
            XCTAssertEqual(chmod(host.root.path, 0o500), 0)
            let unsaved = host.model.performRemotePullRequestSession(request)
            XCTAssertEqual(chmod(host.root.path, 0o700), 0)
            XCTAssertEqual(unsaved, .persistenceUnavailable)
            XCTAssertEqual(host.launches().count, 1)
            XCTAssertEqual(host.model.performRemotePullRequestSession(prRequest()), .conflict)
            guard case .existing(let response) = host.model.performRemotePullRequestSession(request) else {
                return XCTFail("Repair should succeed")
            }
            XCTAssertEqual(host.restart().performRemotePullRequestSession(request), .existing(response))
            XCTAssertEqual(host.restart().project("A")?.sessions.last?.pullRequestKeys, ["github/github#1"])
            XCTAssertEqual(host.launches().count, 1)
        }
    }

    func testRemotePullRequestSecondaryBindingRepairsSavedAssociationsAfterRestart() throws {
        try withHost(projects: twoProjects) { host in
            let cid = UUID().uuidString.lowercased()
            try Data(cid.utf8).write(to: host.root.appendingPathComponent("b1.copilot-session"))
            let candidate = ResumableSession(copilotSessionId: cid, name: "Previous", cwd: host.root.path, lastActive: testNow)
            _ = overview(host, resumable: [makePR().key: candidate])
            let request = prRequest(kind: "resume", cid: cid)
            // A directory where state.json was makes only workspace persistence fail.
            let state = host.root.appendingPathComponent("state.json")
            let oldState = try Data(contentsOf: state)
            try FileManager.default.removeItem(at: state)
            try FileManager.default.createDirectory(at: state, withIntermediateDirectories: false)
            XCTAssertEqual(host.model.performRemotePullRequestSession(request), .persistenceUnavailable)
            try FileManager.default.removeItem(at: state)
            try oldState.write(to: state)
            let restarted = host.restart()
            guard case .existing(let result) = restarted.performRemotePullRequestSession(request) else {
                return XCTFail("Ledger replay must repair the missing association")
            }
            XCTAssertEqual(result.projectId, "B")
            XCTAssertEqual(result.sessionId, "b1")
            XCTAssertEqual(restarted.project("B")?.sessions.first?.pullRequestKeys, ["github/github#1"])
            XCTAssertNil(restarted.project("B")?.sessions.first?.creationFingerprint)
            XCTAssertTrue(host.launches().isEmpty)
        }
    }

    func testRemotePullRequestRejectsStaleAndOversizedPromptBeforeLaunch() throws {
        try withHost(projects: twoProjects) { host in
            let engine = overview(host)
            guard case .stale = host.model.performRemotePullRequestSession(prRequest(keys: ["github/other#99"])) else {
                return XCTFail("Out of scope")
            }

            let longRepository = String(repeating: "r", count: 100)
            let prs = (1...100).map { makePR($0, repo: "\(String(repeating: "o", count: 39))/\(longRepository)") }
            engine.show(prs, links: [:])
            guard case .invalid = host.model.performRemotePullRequestSession(prRequest(keys: prs.map(\.key.description)))
            else { return XCTFail("Prompt must use the existing input limit") }
            XCTAssertTrue(host.launches().isEmpty)
        }
    }
}

extension PullRequestsHostCommandTests {
    func testRemotePullRequestAssociationMergeIsBoundedAndKeepsOriginalFingerprint() throws {
        try withHost(projects: { root in
            let session = Session(id: "tab", title: "Original", cwd: root.path, creationFingerprint: "original",
                                  pullRequestKeys: ["github/github#2", "GITHUB/GITHUB#1"])
            return [Project(id: "A", name: "A", cwd: root.path, sessions: [session], selectedSessionId: nil)]
        }) { host in
            let cid = UUID().uuidString.lowercased()
            try Data(cid.utf8).write(to: host.root.appendingPathComponent("tab.copilot-session"))
            let third = makePR(3)
            let engine = overview(host, prs: [third], resumable: [
                third.key: .init(copilotSessionId: cid, name: "Previous", cwd: host.root.path, lastActive: testNow),
            ])
            guard case .existing = host.model.performRemotePullRequestSession(
                prRequest(kind: "resume", keys: [third.key.description], cid: cid)
            ) else { return XCTFail("Merge") }
            XCTAssertEqual(host.model.project("A")?.sessions.first?.pullRequestKeys,
                           ["github/github#1", "github/github#2", "github/github#3"])
            XCTAssertEqual(host.model.project("A")?.sessions.first?.creationFingerprint, "original")
            // AppModel may repair an initially missing tab selection while restoring.
            let selection = host.model.project("A")?.selectedSessionId
            let additions = (4...101).map { makePR($0) }
            engine.show(additions, links: [:], resumable: Dictionary(uniqueKeysWithValues: additions.map {
                ($0.key, ResumableSession(copilotSessionId: cid, name: "Previous", cwd: host.root.path, lastActive: testNow))
            }))
            guard case .invalid = host.model.performRemotePullRequestSession(
                prRequest(kind: "resume", keys: additions.map(\.key.description), cid: cid)
            ) else { return XCTFail("Bound") }
            XCTAssertEqual(host.model.project("A")?.sessions.first?.pullRequestKeys?.count, 3)
            XCTAssertEqual(host.model.project("A")?.selectedSessionId, selection)
            XCTAssertTrue(host.launches().isEmpty)
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
