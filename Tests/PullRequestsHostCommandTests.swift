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
    }

    private func withHost(
        projects: (URL) -> [Project], selectedProjectIndex: Int = 0,
        _ body: (Host) throws -> Void
    ) throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("work"), withIntermediateDirectories: true)
        let keys = ["SHELL", "COPILOT_PROJECTS_STATE_DIR", "COPILOT_PROJECTS_SOCKET", "COPILOT_PROJECTS_DTACH"]
        let previous = Dictionary(uniqueKeysWithValues: keys.map { ($0, ProcessInfo.processInfo.environment[$0]) })
        setenv("SHELL", "/bin/cat", 1)
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
        func makeModel() -> AppModel {
            let model = AppModel(
                stateRepository: repository, isAppActive: { false },
                agentActivityDirectory: root, resumeMarkerDirectory: root,
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
        try body(Host(model: model, root: root, launches: { launches }, restart: makeModel))
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
                         requestId: String? = nil, prompt: String? = nil) -> ControlRequest {
        var request = ControlRequest(command: command)
        request.projectId = project
        request.sessionId = session
        request.requestId = requestId
        request.prompt = prompt
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
        XCTAssertEqual(dispatched, ["list-sessions", "reveal-session:s", "start:\(uuid)"])
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
