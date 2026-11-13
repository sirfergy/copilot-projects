import AppKit
import Darwin
import Foundation
import XCTest
import CopilotProjectsCore
@testable import CopilotProjectsPullRequests

/// A scripted workspace: each list answers its calls in order and repeats its last answer.
final class FakeWorkspace: PullRequestsWorkspace, @unchecked Sendable {
    private let lock = NSLock()
    private var fetches: [WorkspaceFetch]
    private var reveals: [WorkspaceCommandResult] = [.done(code: "revealed", text: nil)]
    private var starts: [WorkspaceCommandResult] = [.done(code: "created", text: "started")]
    private var resumes: [WorkspaceCommandResult] = [.done(code: "created", text: "resumed")]
    private var reviews: [WorkspaceCommandResult] = [.done(code: "created", text: "reviewed")]
    private var prompts: [WorkspaceCommandResult] = [.done(code: "sent", text: "s1")]
    private var _snapshotCalls = 0
    private var _revealCalls: [(projectId: String?, sessionId: String)] = []
    private var _startCalls: [(projectId: String, requestId: UUID, prompt: String)] = []
    private var _resumeCalls: [(projectId: String, requestId: UUID, copilotSessionId: String)] = []
    private var _reviewCalls: [(projectId: String, requestId: UUID, pullRequestURL: String)] = []
    private var _promptCalls: [(projectId: String?, sessionId: String, requestId: UUID, prompt: String)] = []

    init(snapshot: WorkspaceSnapshot? = nil) {
        fetches = [snapshot.map(WorkspaceFetch.snapshot) ?? .unreachable]
    }

    init(fetches: [WorkspaceFetch]) {
        self.fetches = fetches
    }

    func answer(
        fetches: [WorkspaceFetch]? = nil, reveals: [WorkspaceCommandResult]? = nil,
        starts: [WorkspaceCommandResult]? = nil, resumes: [WorkspaceCommandResult]? = nil,
        reviews: [WorkspaceCommandResult]? = nil, prompts: [WorkspaceCommandResult]? = nil
    ) {
        lock.withLock {
            if let fetches { self.fetches = fetches }
            if let reveals { self.reveals = reveals }
            if let starts { self.starts = starts }
            if let resumes { self.resumes = resumes }
            if let reviews { self.reviews = reviews }
            if let prompts { self.prompts = prompts }
        }
    }

    var snapshotCalls: Int { lock.withLock { _snapshotCalls } }
    var revealCalls: [(projectId: String?, sessionId: String)] { lock.withLock { _revealCalls } }
    var startCalls: [(projectId: String, requestId: UUID, prompt: String)] { lock.withLock { _startCalls } }
    var resumeCalls: [(projectId: String, requestId: UUID, copilotSessionId: String)] {
        lock.withLock { _resumeCalls }
    }
    var reviewCalls: [(projectId: String, requestId: UUID, pullRequestURL: String)] {
        lock.withLock { _reviewCalls }
    }
    var promptCalls: [(projectId: String?, sessionId: String, requestId: UUID, prompt: String)] {
        lock.withLock { _promptCalls }
    }

    private static func next<T>(_ answers: inout [T]) -> T {
        answers.count > 1 ? answers.removeFirst() : answers[0]
    }

    func snapshot() async -> WorkspaceFetch {
        lock.withLock {
            _snapshotCalls += 1
            return Self.next(&fetches)
        }
    }

    func revealSession(projectId: String?, sessionId: String) async -> WorkspaceCommandResult {
        lock.withLock {
            _revealCalls.append((projectId, sessionId))
            return Self.next(&reveals)
        }
    }

    func startCopilotSession(projectId: String, requestId: UUID, prompt: String) async -> WorkspaceCommandResult {
        lock.withLock {
            _startCalls.append((projectId, requestId, prompt))
            return Self.next(&starts)
        }
    }

    func resumeCopilotSession(projectId: String, requestId: UUID, copilotSessionId: String) async -> WorkspaceCommandResult {
        lock.withLock {
            _resumeCalls.append((projectId, requestId, copilotSessionId))
            return Self.next(&resumes)
        }
    }

    func reviewPullRequest(projectId: String, requestId: UUID, pullRequestURL: String) async -> WorkspaceCommandResult {
        lock.withLock {
            _reviewCalls.append((projectId, requestId, pullRequestURL))
            return Self.next(&reviews)
        }
    }

    func sendSessionPrompt(
        projectId: String?, sessionId: String, requestId: UUID, prompt: String
    ) async -> WorkspaceCommandResult {
        lock.withLock {
            _promptCalls.append((projectId, sessionId, requestId, prompt))
            return Self.next(&prompts)
        }
    }
}

/// Activations, openings, and alerts the model asked for.
@MainActor
final class HostRecorder {
    var activations: [Int32] = []
    var opens = 0
    var alerts: [String] = []

    var host: PullRequestsHostApp {
        PullRequestsHostApp(activate: { self.activations.append($0) }, open: { self.opens += 1 })
    }
}

/// A Unix socket that either never answers or answers each request with `reply`.
final class TestControlSocket {
    let path: String
    private let fd: Int32
    private let stop = StopFlag()
    private let finished = DispatchSemaphore(value: 0)
    private let serves: Bool

    /// Shared with the server thread instead of the socket, so the thread never
    /// keeps the socket alive and `deinit` can stop it.
    private final class StopFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var stopping = false
        var isSet: Bool { lock.withLock { stopping } }
        func set() { lock.withLock { stopping = true } }
    }

    init(reply: (@Sendable (ControlRequest) -> ControlResponse)?) throws {
        path = FileManager.default.temporaryDirectory
            .appendingPathComponent("prq-\(UUID().uuidString.prefix(8)).sock").path
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutablePointer(to: &addr.sun_path) { raw in
            raw.withMemoryRebound(to: CChar.self, capacity: 104) { dst in
                for (i, b) in bytes.enumerated() { dst[i] = CChar(bitPattern: b) }
                dst[bytes.count] = 0
            }
        }
        let bound = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(fd, 8) == 0 else {
            close(fd)
            throw POSIXError(.EADDRINUSE)
        }
        self.fd = fd
        serves = reply != nil
        guard let reply else { return }
        let listener = fd
        Thread.detachNewThread { [stop, finished] in
            defer { finished.signal() }
            while !stop.isSet {
                var ready = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
                guard poll(&ready, 1, 50) > 0 else { continue }
                let client = accept(listener, nil, nil)
                guard client >= 0 else { continue }
                var data = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while !data.contains(0x0A) {
                    let count = read(client, &buffer, buffer.count)
                    guard count > 0 else { break }
                    data.append(contentsOf: buffer[0..<count])
                }
                let line = data.prefix { $0 != 0x0A }
                if let request = try? Wire.decode(ControlRequest.self, from: Data(line)),
                   let out = try? Wire.encodeLine(reply(request)) {
                    out.withUnsafeBytes { _ = write(client, $0.baseAddress, $0.count) }
                }
                close(client)
            }
        }
    }

    deinit {
        stop.set()
        // The server thread must be gone before its descriptor can be reused.
        if serves { finished.wait() }
        close(fd)
        unlink(path)
    }
}

let fixtureSnapshot = WorkspaceSnapshot(
    hostProcessIdentifier: 4242, selectedProjectId: "p",
    projects: [
        .init(id: "p", name: "Features", sessions: [
            .init(id: "s1", title: "Ship it - GitHub Copilot", status: .waiting, copilotSessionId: "abcdef12-0001"),
        ]),
        .init(id: "q", name: "Ops", sessions: []),
    ]
)

final class PullRequestsWorkspaceBridgeTests: XCTestCase {
    func testSnapshotsDecodeAndCommandsCarryTheirOutcomes() async throws {
        let encoded = String(data: try JSONEncoder().encode(fixtureSnapshot), encoding: .utf8)!
        let server = try TestControlSocket { request in
            switch request.command {
            case "list-sessions": return .success(encoded)
            case "reveal-session": return request.sessionId == "s1" ? .success("s1", code: "revealed")
                : .failure("the session has ended", code: "gone")
            case "start-copilot-session":
                return request.requestId.flatMap(UUID.init(uuidString:)) != nil && request.prompt == "go"
                    ? .success("new", code: "created") : .failure("bad", code: "bad-request")
            case "resume-copilot-session":
                return request.requestId.flatMap(UUID.init(uuidString:)) != nil && request.projectId == "p"
                    && request.copilotSessionId == "0f1e2d3c-4b5a-4000-8000-000000000002"
                    ? .success("back", code: "created") : .failure("bad", code: "bad-request")
            case "review-pull-request":
                return request.requestId.flatMap(UUID.init(uuidString:)) != nil && request.projectId == "p"
                    && request.path == "https://github.com/o/r/pull/42"
                    ? .success("rev", code: "created") : .failure("bad", code: "bad-request")
            case "send-session-prompt":
                return request.requestId.flatMap(UUID.init(uuidString:)) != nil && request.sessionId == "s1"
                    && request.prompt == "fix it"
                    ? .success("s1", code: "sent") : .failure("bad", code: "bad-request")
            default: return .failure("unknown command: \(request.command)")
            }
        }
        let bridge = ControlWorkspaceBridge(socketPath: server.path, timeout: 2)
        let fetch = await bridge.snapshot()
        XCTAssertEqual(fetch, .snapshot(fixtureSnapshot))
        let revealed = await bridge.revealSession(projectId: "p", sessionId: "s1")
        XCTAssertEqual(revealed, .done(code: "revealed", text: "s1"))
        let gone = await bridge.revealSession(projectId: "p", sessionId: "s2")
        XCTAssertEqual(gone, .refused(code: "gone", message: "the session has ended"))
        let started = await bridge.startCopilotSession(projectId: "p", requestId: UUID(), prompt: "go")
        XCTAssertEqual(started, .done(code: "created", text: "new"))
        let resumed = await bridge.resumeCopilotSession(
            projectId: "p", requestId: UUID(), copilotSessionId: "0f1e2d3c-4b5a-4000-8000-000000000002"
        )
        XCTAssertEqual(resumed, .done(code: "created", text: "back"))
        let reviewed = await bridge.reviewPullRequest(
            projectId: "p", requestId: UUID(), pullRequestURL: "https://github.com/o/r/pull/42"
        )
        XCTAssertEqual(reviewed, .done(code: "created", text: "rev"))
        let prompted = await bridge.sendSessionPrompt(
            projectId: "p", sessionId: "s1", requestId: UUID(), prompt: "fix it"
        )
        XCTAssertEqual(prompted, .done(code: "sent", text: "s1"))
    }

    func testAnUnreadableOrMissingHostIsUnreachable() async throws {
        let garbled = try TestControlSocket { _ in .success("not a snapshot") }
        let unreadable = await ControlWorkspaceBridge(socketPath: garbled.path, timeout: 2).snapshot()
        XCTAssertEqual(unreadable, .unreachable)

        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("prq-missing.sock").path
        let away = await ControlWorkspaceBridge(socketPath: missing, timeout: 2).snapshot()
        XCTAssertEqual(away, .unreachable)
    }

    @MainActor
    func testASilentHostNeverBlocksTheWindowAndReadsAsDisconnectedAfterTheTimeout() async throws {
        let silent = try TestControlSocket(reply: nil)
        let model = PullRequestsModel(
            workspace: ControlWorkspaceBridge(socketPath: silent.path, timeout: 0.6),
            defaults: UserDefaults(suiteName: UUID().uuidString)!, stateDirectory: nil, loadAccounts: { [] }
        )
        let started = Date()
        let poll = Task { await model.pollWorkspace() }
        try await Task.sleep(nanoseconds: 100_000_000)
        // The main actor ran this while the request was still waiting on the host.
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
        XCTAssertEqual(model.workspace, .connecting)
        model.owners = "github"
        XCTAssertEqual(model.ownerList, ["github"])
        await poll.value
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.55)
        XCTAssertEqual(model.workspace, .disconnected(lastGood: nil))
    }
}

@MainActor
final class PullRequestsWorkspaceModelTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeModel(_ workspace: FakeWorkspace, recorder: HostRecorder? = nil) -> PullRequestsModel {
        let recorder = recorder ?? HostRecorder()
        return PullRequestsModel(
            workspace: workspace, host: recorder.host,
            defaults: UserDefaults(suiteName: UUID().uuidString)!, stateDirectory: root,
            loadAccounts: { [] },
            resumableFinder: ResumableSessionFinder(
                store: CopilotSessionStore(environment: ["COPILOT_HOME": root.appendingPathComponent("copilot").path]),
                cacheURL: nil
            ),
            isVisible: { true },
            presentError: { title, message in recorder.alerts.append("\(title): \(message)") }
        )
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<300 where !condition() {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(condition())
    }

    private func savedLinks() throws -> [String: String] {
        let data = try Data(contentsOf: root.appendingPathComponent("goals.json"))
        return try JSONDecoder().decode(PullRequestGoalOverrides.self, from: data).sessionLinks
    }

    func testDisconnectedKeepsTheLastGoodGoalsButNotTheirStates() async {
        let workspace = FakeWorkspace(fetches: [.snapshot(fixtureSnapshot), .unreachable])
        let model = makeModel(workspace)
        let driven = makePR(1, branch: "me/ship-it-branch")
        let orphan = makePR(2, repo: "github/other", branch: "me/other-branch")
        model.show([driven, orphan], links: [driven.key: "s1"])

        await model.pollWorkspace()
        XCTAssertEqual(model.workspace, .connected(fixtureSnapshot))
        var goals = model.goals(now: testNow)
        XCTAssertEqual(goals.first?.name, "Ship it")
        XCTAssertEqual(goals.first?.items.first?.assessment.reasons.first, .sessionWaiting)
        XCTAssertTrue(goals.flatMap(\.items).contains { $0.assessment.reasons.contains(.noSession) })
        XCTAssertEqual(model.projects.map(\.id), ["p", "q"])
        XCTAssertEqual(model.defaultProjectId, "p")

        await model.pollWorkspace()
        XCTAssertEqual(model.workspace, .disconnected(lastGood: fixtureSnapshot))
        goals = model.goals(now: testNow)
        let lane = goals.first { $0.kind == .session }
        XCTAssertEqual(lane?.name, "Ship it", "the last good snapshot still groups the lanes")
        XCTAssertNotNil(lane?.session)
        XCTAssertNil(lane?.session?.status)
        XCTAssertEqual(lane?.session?.attentionLabel, "Status unknown")
        XCTAssertFalse(PullRequestSessionIndicator.shows(lane!.session!))
        let reasons = goals.flatMap(\.items).flatMap(\.assessment.reasons)
        XCTAssertFalse(reasons.contains(.sessionWaiting), "an unknown state isn't waiting")
        XCTAssertFalse(reasons.contains(.noSession), "no session isn't claimed while sessions are unknown")
        XCTAssertTrue(model.projects.isEmpty, "Start Session waits for Copilot Projects")
        XCTAssertFalse(model.isConnected)
    }

    func testGoToSessionRevealsBeforeActivatingSoTheRightSessionIsMarkedRead() async throws {
        let workspace = FakeWorkspace(fetches: [.snapshot(fixtureSnapshot)])
        let recorder = HostRecorder()
        var revealsWhenActivated: [Int] = []
        let host = PullRequestsHostApp(activate: { pid in
            recorder.activations.append(pid)
            revealsWhenActivated.append(workspace.revealCalls.count)
        }, open: nil)
        let model = PullRequestsModel(
            workspace: workspace, host: host, defaults: UserDefaults(suiteName: UUID().uuidString)!,
            stateDirectory: root, loadAccounts: { [] }, isVisible: { true }, presentError: { _, _ in }
        )
        await model.pollWorkspace()
        model.goToSession(try XCTUnwrap(model.liveSessions["s1"]))
        try await waitUntil { recorder.activations == [4242] }
        XCTAssertEqual(revealsWhenActivated, [1], "Copilot Projects shows the session before it becomes active")
    }

    func testARefreshThatKnowsNoSessionsKeepsTheTranscriptIndex() async throws {
        let index = root.appendingPathComponent("transcript-index.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let saved = Data(#"{"version":1,"entries":{"/x/events.jsonl":{"device":1,"inode":2,"scannedBytes":10,"branchMentions":{},"urlMentions":{}}}}"#.utf8)
        try saved.write(to: index)
        let workspace = FakeWorkspace(fetches: [.unreachable])
        let model = makeModel(workspace)
        model.refresh()
        try await waitUntil { !model.isRefreshing && model.lastUpdated != nil }
        XCTAssertEqual(try Data(contentsOf: index), saved, "matching against no sessions must not empty the index")
    }

    func testGoToSessionDoesNotActivateForAnEndedSessionAndRereadsIt() async throws {
        let ended = WorkspaceSnapshot(
            hostProcessIdentifier: 4242, selectedProjectId: "p",
            projects: [.init(id: "p", name: "Features", sessions: [])]
        )
        let workspace = FakeWorkspace(fetches: [.snapshot(fixtureSnapshot), .snapshot(ended)])
        workspace.answer(reveals: [.refused(code: "gone", message: "the session has ended")])
        let recorder = HostRecorder()
        let model = makeModel(workspace, recorder: recorder)
        await model.pollWorkspace()
        let session = try XCTUnwrap(model.liveSessions["s1"])

        model.goToSession(session)
        try await waitUntil { workspace.snapshotCalls == 2 }
        XCTAssertTrue(recorder.activations.isEmpty, "an ended session doesn't bring Copilot Projects forward")
        XCTAssertEqual(workspace.revealCalls.map(\.sessionId), ["s1"])
        XCTAssertEqual(workspace.revealCalls.map(\.projectId), ["p"])
        try await waitUntil { model.liveSessions["s1"] == nil }
        XCTAssertTrue(recorder.alerts.isEmpty, "an ended session isn't an error")
    }

    func testAMovedSessionIsRevealedWhereItIsNow() async throws {
        var moved = fixtureSnapshot
        moved.projects[1].sessions = moved.projects[0].sessions
        moved.projects[0].sessions = []
        let workspace = FakeWorkspace(fetches: [.snapshot(fixtureSnapshot), .snapshot(moved)])
        workspace.answer(reveals: [.refused(code: "conflict", message: "moved"), .done(code: "revealed", text: "s1")])
        let model = makeModel(workspace)
        await model.pollWorkspace()
        model.goToSession(try XCTUnwrap(model.liveSessions["s1"]))
        try await waitUntil { workspace.revealCalls.count == 2 }
        XCTAssertEqual(workspace.revealCalls.map(\.projectId), ["p", "q"])
    }

    func testWithoutCopilotProjectsGoToSessionOpensIt() async throws {
        let recorder = HostRecorder()
        let workspace = FakeWorkspace(fetches: [.snapshot(fixtureSnapshot), .unreachable])
        let model = makeModel(workspace, recorder: recorder)
        await model.pollWorkspace()
        let session = try XCTUnwrap(model.liveSessions["s1"])
        await model.pollWorkspace()
        model.goToSession(session)
        XCTAssertEqual(recorder.opens, 1)
        XCTAssertTrue(recorder.activations.isEmpty)
        XCTAssertTrue(workspace.revealCalls.isEmpty)
        XCTAssertTrue(model.canOpenHost)
        XCTAssertNil(PullRequestsHostApp.none.open, "a copy outside Copilot Projects has nothing to open")
    }

    func testStartSessionRetriesWithTheSameRequestIdUntilCopilotProjectsAnswers() async throws {
        let workspace = FakeWorkspace(fetches: [.snapshot(fixtureSnapshot)])
        workspace.answer(starts: [.unreachable, .unreachable, .done(code: "existing", text: "s1")])
        let recorder = HostRecorder()
        let model = makeModel(workspace, recorder: recorder)
        let pr = makePR(1, branch: "me/needs-a-session")
        model.show([pr], links: [:])
        await model.pollWorkspace()
        let goal = try XCTUnwrap(model.goals(now: testNow).first)

        model.startSession(for: goal, projectId: "q")
        XCTAssertTrue(model.startingGoals.contains(goal.id))
        try await waitUntil { model.startingGoals.isEmpty }
        XCTAssertEqual(workspace.startCalls.count, 2, "a lost answer is asked again once")
        XCTAssertEqual(recorder.alerts.count, 1)
        XCTAssertTrue(recorder.alerts[0].contains("won’t start twice"))
        XCTAssertNil(model.overrides.sessionLinks[pr.key.description])

        model.startSession(for: goal, projectId: "q")
        try await waitUntil { model.startingGoals.isEmpty }
        let calls = workspace.startCalls
        XCTAssertEqual(calls.count, 3)
        XCTAssertEqual(Set(calls.map(\.requestId)).count, 1, "trying again replays the same request")
        XCTAssertEqual(calls.map(\.projectId), ["q", "q", "q"])
        XCTAssertEqual(calls[0].prompt, PullRequestsModel.startingPrompt(for: [pr]))
        XCTAssertEqual(model.overrides.sessionLinks[pr.key.description], "s1")
        XCTAssertEqual(recorder.activations, [4242])
        XCTAssertEqual(workspace.revealCalls.last?.sessionId, "s1")
        XCTAssertEqual(workspace.revealCalls.last?.projectId, "q")

        // A new click after success is a new request.
        workspace.answer(starts: [.refused(code: "unavailable", message: "Install the Copilot CLI")])
        model.startSession(for: goal, projectId: "q")
        try await waitUntil { model.startingGoals.isEmpty }
        XCTAssertNotEqual(workspace.startCalls.last?.requestId, calls[0].requestId)
        XCTAssertEqual(recorder.alerts.last, "Could Not Start Copilot: Install the Copilot CLI")

        // Copilot Projects couldn't save a session it may have started: trying again replays it.
        workspace.answer(starts: [
            .refused(code: "persistence-unavailable", message: "could not persist the session"),
            .done(code: "existing", text: "s2"),
        ])
        model.startSession(for: goal, projectId: "q")
        try await waitUntil { model.startingGoals.isEmpty }
        let unsaved = try XCTUnwrap(workspace.startCalls.last?.requestId)
        XCTAssertNotEqual(unsaved, calls[0].requestId)
        model.startSession(for: goal, projectId: "q")
        try await waitUntil { model.startingGoals.isEmpty }
        XCTAssertEqual(workspace.startCalls.last?.requestId, unsaved)
        XCTAssertEqual(model.overrides.sessionLinks[pr.key.description], "s2")

        // Starting a session with a conflict-resolution prompt dispatches that prompt directly.
        let conflictedPR = makePR(
            9,
            branch: "me/conflicted-branch",
            mergeable: .conflicting,
            mergeState: .dirty,
            review: .approved
        )
        model.show([conflictedPR], links: [:])
        let conflictedGoal = try XCTUnwrap(model.goals(now: testNow).first)
        let resolveAction = try XCTUnwrap(conflictedGoal.primaryStartDispatchActions.first)
        XCTAssertEqual(resolveAction.kind, .resolveConflicts)
        workspace.answer(starts: [.done(code: "created", text: "s-conflict")])
        model.startSession(for: conflictedGoal, projectId: "p", prompt: resolveAction.prompt)
        try await waitUntil { model.startingGoals.isEmpty }
        // Starting a session for a single unlinked PR in a manual goal preserves sibling session links.
        let unlinkedPR = makePR(
            10,
            branch: "me/unlinked-conflict",
            mergeable: .conflicting,
            mergeState: .dirty,
            review: .approved
        )
        let siblingPR = makePR(11, branch: "me/sibling-branch", mergeState: .clean, review: .approved)
        model.moveToNewGoal(unlinkedPR.key, named: "Mixed Goal")
        let manualGoalId = try XCTUnwrap(model.overrides.goalId(for: unlinkedPR.key))
        model.move(siblingPR.key, toGoal: manualGoalId)
        model.show([unlinkedPR, siblingPR], links: [siblingPR.key: "s1"])
        let mixedGoal = try XCTUnwrap(model.goals(now: testNow).first { $0.id == manualGoalId })
        workspace.answer(starts: [.done(code: "created", text: "s-only-conflict")])
        model.startSession(
            for: mixedGoal,
            projectId: "p",
            prompt: resolveAction.prompt,
            keys: [unlinkedPR.key]
        )
        try await waitUntil { model.startingGoals.isEmpty }
        XCTAssertEqual(model.overrides.sessionLinks[unlinkedPR.key.description], "s-only-conflict")
        XCTAssertNil(
            model.overrides.sessionLinks[siblingPR.key.description],
            "starting for one unlinked PR must not overwrite a sibling PR's live session"
        )
    }

    func testResumeSessionShowsTheTabItOpenedAndItsPullRequestsFollowItOnceLive() async throws {
        let copilotId = "0f1e2d3c-4b5a-4000-8000-0000000000aa"
        let workspace = FakeWorkspace(fetches: [.snapshot(fixtureSnapshot)])
        let recorder = HostRecorder()
        var revealsWhenActivated: [Int] = []
        let host = PullRequestsHostApp(activate: { pid in
            recorder.activations.append(pid)
            revealsWhenActivated.append(workspace.revealCalls.count)
        }, open: nil)
        let model = PullRequestsModel(
            workspace: workspace, host: host, defaults: UserDefaults(suiteName: UUID().uuidString)!,
            stateDirectory: root, loadAccounts: { [] },
            resumableFinder: ResumableSessionFinder(store: CopilotSessionStore(environment: ["COPILOT_HOME": root.path]),
                                                    cacheURL: nil),
            isVisible: { true }, presentError: { title, message in recorder.alerts.append("\(title): \(message)") }
        )
        let pr = makePR(1, branch: "me/needs-a-session")
        let candidate = ResumableSession(copilotSessionId: copilotId, name: "Ship it", cwd: "/work", lastActive: testNow)
        model.show([pr], links: [:], resumable: [pr.key: candidate])
        await model.pollWorkspace()
        XCTAssertEqual(model.goals(now: testNow).first?.resumable, candidate)

        var opened = fixtureSnapshot
        opened.projects[1].sessions.append(.init(id: "back", title: "Copilot", status: .running))
        workspace.answer(fetches: [.snapshot(opened)], resumes: [.done(code: "created", text: "back")])
        model.resume(candidate, projectId: "q")
        XCTAssertTrue(model.resumingSessions.contains(copilotId))
        model.resume(candidate, projectId: "q")
        try await waitUntil { recorder.activations == [4242] }
        XCTAssertEqual(workspace.resumeCalls.count, 1, "a second click while it resumes does nothing")
        XCTAssertEqual(workspace.resumeCalls.first?.projectId, "q")
        XCTAssertEqual(workspace.resumeCalls.first?.copilotSessionId, copilotId)
        XCTAssertEqual(revealsWhenActivated, [1], "Copilot Projects shows the tab before it becomes active")
        XCTAssertEqual(workspace.revealCalls.last?.sessionId, "back")
        XCTAssertEqual(workspace.revealCalls.last?.projectId, "q")
        XCTAssertTrue(model.resumingSessions.contains(copilotId), "busy until Copilot reports the session")
        XCTAssertTrue(recorder.alerts.isEmpty)

        var live = opened
        live.projects[1].sessions[0].copilotSessionId = copilotId.uppercased()
        workspace.answer(fetches: [.snapshot(live)])
        await model.pollWorkspace()
        XCTAssertTrue(model.resumingSessions.isEmpty)
        let goal = try XCTUnwrap(model.goals(now: testNow).first)
        XCTAssertEqual(goal.session?.id, "back", "its pull requests follow it to its new tab")
        XCTAssertNil(goal.resumable)
        XCTAssertTrue(model.overrides.sessionLinks.isEmpty, "resuming binds nothing by hand")
    }

    func testResumeSessionRetriesWithTheSameRequestIdAndStopsOfferingASessionThatIsGone() async throws {
        let copilotId = "0f1e2d3c-4b5a-4000-8000-0000000000bb"
        let workspace = FakeWorkspace(fetches: [.snapshot(fixtureSnapshot)])
        workspace.answer(resumes: [
            .unreachable, .unreachable,
            .refused(code: "persistence-unavailable", message: "Copilot Projects couldn’t save the session."),
            .refused(code: "gone", message: "That Copilot session no longer exists."),
        ])
        let recorder = HostRecorder()
        let model = makeModel(workspace, recorder: recorder)
        let pr = makePR(1, branch: "me/needs-a-session")
        let candidate = ResumableSession(copilotSessionId: copilotId, name: "Ship it", cwd: "/work", lastActive: testNow)
        model.show([pr], links: [:], resumable: [pr.key: candidate])
        await model.pollWorkspace()

        model.resume(candidate, projectId: "p")
        try await waitUntil { model.resumingSessions.isEmpty }
        XCTAssertEqual(workspace.resumeCalls.count, 2, "a lost answer is asked again once")
        XCTAssertEqual(recorder.alerts.count, 1)
        XCTAssertTrue(recorder.alerts[0].contains("won’t open twice"))
        XCTAssertEqual(model.goals(now: testNow).first?.resumable, candidate)

        model.resume(candidate, projectId: "p")
        try await waitUntil { model.resumingSessions.isEmpty }
        XCTAssertEqual(workspace.resumeCalls.count, 3)
        XCTAssertEqual(recorder.alerts.last, "Could Not Resume Session: Copilot Projects couldn’t save the session.")
        XCTAssertEqual(model.resumable[pr.key], candidate, "a resume it couldn't save is still offered")

        model.resume(candidate, projectId: "p")
        try await waitUntil { model.resumingSessions.isEmpty }
        XCTAssertEqual(workspace.resumeCalls.count, 4)
        XCTAssertEqual(Set(workspace.resumeCalls.map(\.requestId)).count, 1, "trying again replays the same request")
        XCTAssertEqual(recorder.alerts.last, "Could Not Resume Session: That Copilot session no longer exists.")
        XCTAssertTrue(model.resumable.isEmpty)
        XCTAssertNil(model.goals(now: testNow).first?.resumable, "a session that's gone is no longer offered")
        XCTAssertTrue(recorder.activations.isEmpty)
    }

    func testSessionLinksArePrunedOnlyWhileConnected() async throws {
        var overrides = PullRequestGoalOverrides()
        overrides.sessionLinks["o/r#9"] = "ended"
        try JSONEncoder().encode(overrides).write(to: root.appendingPathComponent("goals.json"))
        let workspace = FakeWorkspace(fetches: [.snapshot(fixtureSnapshot)])
        workspace.answer(starts: [.done(code: "created", text: "new")])
        let model = makeModel(workspace)
        let first = makePR(1, branch: "me/first-branch")
        let second = makePR(2, repo: "github/other", branch: "me/second-branch")
        model.show([first, second], links: [:])
        await model.pollWorkspace()
        let goals = model.goals(now: testNow)
        let firstGoal = try XCTUnwrap(goals.first { $0.items.contains { $0.pr.key == first.key } })
        let secondGoal = try XCTUnwrap(goals.first { $0.items.contains { $0.pr.key == second.key } })

        // Copilot Projects stops answering right after it starts the session.
        workspace.answer(fetches: [.unreachable])
        model.startSession(for: firstGoal, projectId: "p")
        try await waitUntil { model.startingGoals.isEmpty }
        XCTAssertEqual(model.workspace, .disconnected(lastGood: fixtureSnapshot))
        XCTAssertEqual(try savedLinks(), ["o/r#9": "ended", first.key.description: "new"])

        var current = fixtureSnapshot
        current.projects[0].sessions.append(.init(id: "new", title: "Copilot", status: .running))
        workspace.answer(fetches: [.snapshot(current)], starts: [.done(code: "created", text: "newer")])
        await model.pollWorkspace()
        model.startSession(for: secondGoal, projectId: "p")
        try await waitUntil { model.startingGoals.isEmpty }
        XCTAssertEqual(try savedLinks(), [first.key.description: "new", second.key.description: "newer"],
                       "links to ended sessions go once the sessions are known")
    }

    func testSendPromptDispatchesRetriesWithSameRequestIdAndRevealsSession() async throws {
        var idleSnapshot = fixtureSnapshot
        idleSnapshot.projects[0].sessions[0].status = .idle
        let workspace = FakeWorkspace(fetches: [.snapshot(idleSnapshot)])
        let recorder = HostRecorder()
        let model = makeModel(workspace, recorder: recorder)
        let pr = makePR(7, checks: .failure, requiredFailing: ["lint", "unit-tests"])
        model.show([pr], links: [pr.key: "s1"])
        await model.pollWorkspace()

        let goal = try XCTUnwrap(model.goals(now: testNow).first)
        let session = try XCTUnwrap(goal.session)
        let action = try XCTUnwrap(goal.items.first?.dispatchActions.first)
        XCTAssertEqual(action.kind, .fixChecks)
        XCTAssertTrue(action.prompt.contains("lint, unit-tests"))

        // First dispatch succeeds, reveals the session, and activates Copilot Projects.
        model.sendPrompt(to: session, prompt: action.prompt)
        try await waitUntil { model.sendingSessions.isEmpty }
        XCTAssertEqual(workspace.promptCalls.count, 1)
        XCTAssertEqual(workspace.promptCalls[0].sessionId, "s1")
        XCTAssertNil(workspace.promptCalls[0].projectId)
        XCTAssertEqual(workspace.promptCalls[0].prompt, action.prompt)
        XCTAssertEqual(workspace.revealCalls.last?.sessionId, "s1")
        XCTAssertEqual(recorder.activations, [4242])

        // Lost answer retries once with the identical requestId, and a subsequent user retry
        // after the session moved projects still reuses that requestId.
        var movedSnapshot = idleSnapshot
        let movedSession = movedSnapshot.projects[0].sessions.removeFirst()
        movedSnapshot.projects[1].sessions.append(movedSession)
        workspace.answer(
            fetches: [.snapshot(movedSnapshot)],
            prompts: [.unreachable, .unreachable, .done(code: "existing", text: "s1")]
        )
        let customPrompt = "For https://github.com/github/github/pull/7:\n\nre-run lint"
        model.sendPrompt(to: session, prompt: customPrompt)
        try await waitUntil { model.sendingSessions.isEmpty }
        XCTAssertEqual(workspace.promptCalls.count, 3)
        let firstRetryId = workspace.promptCalls[1].requestId
        XCTAssertEqual(workspace.promptCalls[2].requestId, firstRetryId)
        XCTAssertEqual(recorder.alerts.count, 1)

        let movedGoalSession = try XCTUnwrap(model.goals(now: testNow).first?.session)
        XCTAssertEqual(movedGoalSession.projectId, "q")
        model.sendPrompt(to: movedGoalSession, prompt: customPrompt)
        try await waitUntil { model.sendingSessions.isEmpty }
        XCTAssertEqual(workspace.promptCalls.count, 4)
        XCTAssertEqual(workspace.promptCalls[3].requestId, firstRetryId, "retrying after a project move keeps the requestId")

        // An indeterminate native outcome retains the original requestId until resolved,
        // whereas a definite refusal clears it so the next attempt gets a fresh requestId.
        workspace.answer(
            fetches: [.snapshot(movedSnapshot), .snapshot(movedSnapshot)],
            prompts: [
                .refused(code: "indeterminate", message: "Outcome unknown."),
                .done(code: "applied", text: "s1"),
                .refused(code: "rejected", message: "Rejected."),
                .done(code: "applied", text: "s1"),
            ]
        )
        let uncertainPrompt = "For https://github.com/github/github/pull/7:\n\ncheck status"
        model.sendPrompt(to: movedGoalSession, prompt: uncertainPrompt)
        try await waitUntil { model.sendingSessions.isEmpty }
        let uncertainId = try XCTUnwrap(workspace.promptCalls.last?.requestId)

        model.sendPrompt(to: movedGoalSession, prompt: uncertainPrompt)
        try await waitUntil { model.sendingSessions.isEmpty }
        XCTAssertEqual(workspace.promptCalls.last?.requestId, uncertainId, "indeterminate outcome retains requestId")

        model.sendPrompt(to: movedGoalSession, prompt: uncertainPrompt)
        try await waitUntil { model.sendingSessions.isEmpty }
        let rejectedId = try XCTUnwrap(workspace.promptCalls.last?.requestId)
        XCTAssertNotEqual(rejectedId, uncertainId, "completed dispatch cleared the previous requestId")

        model.sendPrompt(to: movedGoalSession, prompt: uncertainPrompt)
        try await waitUntil { model.sendingSessions.isEmpty }
        XCTAssertNotEqual(workspace.promptCalls.last?.requestId, rejectedId, "rejected outcome clears requestId")

        // Sending a second prompt B while prompt A is indeterminate restores A as the
        // session's retry target once B settles, and a predefined action without a draft
        // never clears a retained custom prompt draft.
        workspace.answer(
            fetches: [.snapshot(movedSnapshot), .snapshot(movedSnapshot)],
            prompts: [
                .refused(code: "indeterminate", message: "Outcome unknown."),
                .done(code: "sent", text: "s1"),
                .done(code: "applied", text: "s1"),
            ]
        )
        let rawDraft = "investigate flaky login test"
        model.sendCustomPrompt(rawDraft, for: pr, to: movedGoalSession)
        try await waitUntil { model.sendingSessions.isEmpty }
        XCTAssertEqual(model.promptDraft(for: pr, session: movedGoalSession), rawDraft)
        XCTAssertTrue(model.retryablePromptSessions.contains(movedGoalSession.id))
        let composer = PullRequestPromptComposer(
            session: movedGoalSession,
            pr: pr,
            initialText: model.promptDraft(for: pr, session: movedGoalSession)
        )
        XCTAssertEqual(composer.textView.string, rawDraft)
        let customDraftRequestId = try XCTUnwrap(workspace.promptCalls.last?.requestId)

        // Predefined action B on the same PR succeeds: it must not clear rawDraft or lose A's retry target.
        model.sendPrompt(to: movedGoalSession, prompt: action.prompt, pullRequestKey: pr.key)
        try await waitUntil { model.sendingSessions.isEmpty }
        XCTAssertEqual(model.promptDraft(for: pr, session: movedGoalSession), rawDraft)
        XCTAssertTrue(model.retryablePromptSessions.contains(movedGoalSession.id))

        model.retryPendingPrompt(for: movedGoalSession)
        try await waitUntil { model.sendingSessions.isEmpty }
        XCTAssertEqual(workspace.promptCalls.last?.requestId, customDraftRequestId)
        XCTAssertEqual(model.promptDraft(for: pr, session: movedGoalSession), "")
        XCTAssertFalse(model.retryablePromptSessions.contains(movedGoalSession.id))

        // A queued native handoff (`code == "queued"`) retains its draft and requestId
        // until workspace polling reconciles the terminal receipt (`applied`).
        workspace.answer(
            fetches: [.snapshot(movedSnapshot)],
            prompts: [
                .done(code: "queued", text: "s1"),
                .done(code: "applied", text: "s1"),
            ]
        )
        let queuedDraft = "verify queued reconciliation"
        model.sendCustomPrompt(queuedDraft, for: pr, to: movedGoalSession)
        try await waitUntil { model.sendingSessions.isEmpty }
        let queuedRequestId = try XCTUnwrap(workspace.promptCalls.last?.requestId)
        XCTAssertEqual(model.promptDraft(for: pr, session: movedGoalSession), queuedDraft,
                       "draft stays until the queued handoff is confirmed applied")
        await model.pollWorkspace()
        XCTAssertEqual(workspace.promptCalls.last?.requestId, queuedRequestId)
        XCTAssertEqual(model.promptDraft(for: pr, session: movedGoalSession), "")
    }

    func testRefreshAsksForTheWorkspaceFirstAndMatchesAgainWhenItArrives() async throws {
        let workspace = FakeWorkspace(fetches: [.unreachable])
        let model = makeModel(workspace)
        model.refresh()
        try await waitUntil { !model.isRefreshing && model.lastUpdated != nil }
        XCTAssertEqual(workspace.snapshotCalls, 1, "the first refresh asked before matching")
        XCTAssertFalse(model.sessionsKnown)

        workspace.answer(fetches: [.snapshot(fixtureSnapshot)])
        let updated = model.lastUpdated
        await model.pollWorkspace()
        try await waitUntil { !model.isRefreshing && model.lastUpdated != updated }
        XCTAssertTrue(model.sessionsKnown, "sessions arriving later are matched by another refresh")
    }

    func testWorkspaceLoopRefreshesImmediatelyOnStateAndSessionsEventsAndSkipsUnchangedPolls() async throws {
        let stateDir = root.appendingPathComponent("workspace-state", isDirectory: true)
        let sessionsDir = stateDir.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        try Data(#"{"schemaVersion":1}"#.utf8).write(to: stateDir.appendingPathComponent("state.json"), options: .atomic)

        var addedSessionSnapshot = fixtureSnapshot
        addedSessionSnapshot.projects[0].sessions.append(
            .init(id: "s2", title: "New session", status: .running, copilotSessionId: "abcdef12-0002")
        )
        var idleSessionSnapshot = addedSessionSnapshot
        idleSessionSnapshot.projects[0].sessions[1].status = .idle
        var unseenClearedSnapshot = idleSessionSnapshot
        unseenClearedSnapshot.projects[0].sessions[0].status = .idle

        let workspace = FakeWorkspace(fetches: [
            .snapshot(fixtureSnapshot),
            .snapshot(addedSessionSnapshot),
            .snapshot(idleSessionSnapshot),
            .snapshot(unseenClearedSnapshot),
        ])
        var now = testNow
        let model = PullRequestsModel(
            workspace: workspace,
            defaults: UserDefaults(suiteName: UUID().uuidString)!,
            stateDirectory: root.appendingPathComponent("pr-state", isDirectory: true),
            workspaceStateDirectory: stateDir,
            workspacePollInterval: 30,
            workspaceUnchangedPollInterval: 15,
            workspaceWatchDebounce: 0.02,
            loadAccounts: { [] },
            clock: { now },
            isVisible: { true },
            presentError: { _, _ in }
        )
        let loop = Task { await model.runWorkspaceLoop() }
        defer { loop.cancel() }

        try await waitUntil { workspace.snapshotCalls == 1 && model.workspace == .connected(fixtureSnapshot) }

        // Unchanged state and sessions directories skip redundant list-sessions polls.
        await model.pollWorkspaceIfNeeded()
        await model.pollWorkspaceIfNeeded()
        XCTAssertEqual(workspace.snapshotCalls, 1)

        // Excluded transcript/staging/helper/ledger files do not invalidate the signature.
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: sessionsDir.appendingPathComponent("s1.transcript-live.json"), options: .atomic)
        try Data("{}".utf8).write(to: sessionsDir.appendingPathComponent("s1.transcript.json"), options: .atomic)
        try Data("{}".utf8).write(to: sessionsDir.appendingPathComponent(".staging.tmp"), options: .atomic)
        try Data("{}".utf8).write(to: stateDir.appendingPathComponent("session-creation-ledger.json"), options: .atomic)
        try FileManager.default.createDirectory(
            at: stateDir.appendingPathComponent("pull-requests", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("{}".utf8).write(to: stateDir.appendingPathComponent("pull-requests/goals.json"), options: .atomic)
        try await Task.sleep(nanoseconds: 80_000_000)
        await model.pollWorkspaceIfNeeded()
        XCTAssertEqual(workspace.snapshotCalls, 1, "excluded transcript and helper files must not trigger a poll")

        // Updating state.json triggers an immediate event-driven refresh well before the 30s poll interval.
        try Data(#"{"schemaVersion":1,"updated":2}"#.utf8).write(
            to: stateDir.appendingPathComponent("state.json"),
            options: .atomic
        )
        try await waitUntil { model.workspace == .connected(addedSessionSnapshot) }
        XCTAssertEqual(workspace.snapshotCalls, 2)
        await model.pollWorkspaceIfNeeded()
        XCTAssertEqual(workspace.snapshotCalls, 2, "settled state.json update skips redundant polls")

        // Updating a tracked file in sessions/ triggers an immediate event-driven refresh.
        try Data(#"{"schemaVersion":1,"foregroundTurnActive":false}"#.utf8).write(
            to: sessionsDir.appendingPathComponent("s2.agent-activity.json"),
            options: .atomic
        )
        try await waitUntil { model.workspace == .connected(idleSessionSnapshot) }
        XCTAssertEqual(workspace.snapshotCalls, 3)
        await model.pollWorkspaceIfNeeded()
        XCTAssertEqual(workspace.snapshotCalls, 3)

        // Advancing past the staleness cap forces a backstop poll even without disk changes.
        now = now.addingTimeInterval(16)
        await model.pollWorkspaceIfNeeded()
        XCTAssertEqual(workspace.snapshotCalls, 4)
        XCTAssertEqual(model.workspace, .connected(unseenClearedSnapshot))
    }

    func testDiskChangeBeforeHostAppliesInMemoryUpdateAllowsOneFollowUpPoll() async throws {
        let stateDir = root.appendingPathComponent("lagged-state", isDirectory: true)
        let sessionsDir = stateDir.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)

        var partiallyUpdatedSnapshot = fixtureSnapshot
        partiallyUpdatedSnapshot.projects[0].sessions[0].copilotSessionId = "abcdef12-0009"
        var fullyUpdatedSnapshot = partiallyUpdatedSnapshot
        fullyUpdatedSnapshot.projects[0].sessions[0].status = .idle
        // First connection poll receives one delayed follow-up poll in case the helper connected
        // after a session file changed on disk but before the host applied it in memory.
        let workspace = FakeWorkspace(fetches: [
            .unreachable,
            .snapshot(fixtureSnapshot),
            .snapshot(fixtureSnapshot),
            .snapshot(partiallyUpdatedSnapshot),
            .snapshot(fullyUpdatedSnapshot),
        ])
        var now = testNow
        let model = PullRequestsModel(
            workspace: workspace,
            defaults: UserDefaults(suiteName: UUID().uuidString)!,
            stateDirectory: root.appendingPathComponent("pr-state", isDirectory: true),
            workspaceStateDirectory: stateDir,
            loadAccounts: { [] },
            clock: { now },
            isVisible: { true },
            presentError: { _, _ in }
        )

        // While disconnected, unchanged filesystem wakeups are rate-limited to workspacePollPeriod.
        await model.pollWorkspace()
        XCTAssertEqual(workspace.snapshotCalls, 1)
        await model.pollWorkspaceIfNeeded()
        XCTAssertEqual(workspace.snapshotCalls, 1, "unchanged wakeups while disconnected wait for workspacePollPeriod")
        now = now.addingTimeInterval(2.1)
        await model.pollWorkspaceIfNeeded()
        XCTAssertEqual(workspace.snapshotCalls, 2)
        await model.pollWorkspaceIfNeeded()
        XCTAssertEqual(workspace.snapshotCalls, 2)
        now = now.addingTimeInterval(1.2)
        await model.pollWorkspaceIfNeeded()
        XCTAssertEqual(workspace.snapshotCalls, 3)
        await model.pollWorkspaceIfNeeded()
        XCTAssertEqual(workspace.snapshotCalls, 3, "settled initial signature skips unchanged polls")

        // The tracker writes session files before the host finishes its throttled scan.
        try Data("copilot-session".utf8).write(
            to: sessionsDir.appendingPathComponent("s1.copilot-session"),
            options: .atomic
        )
        await model.pollWorkspaceIfNeeded()
        XCTAssertEqual(workspace.snapshotCalls, 4)
        XCTAssertEqual(model.workspace, .connected(partiallyUpdatedSnapshot))

        // An early excluded-file wakeup before workspaceSettleFollowUpDelay must not consume
        // the follow-up poll while the host is still within its completion/throttle window.
        now = now.addingTimeInterval(0.4)
        await model.pollWorkspaceIfNeeded()
        XCTAssertEqual(workspace.snapshotCalls, 4)

        // Once the settle delay elapses, one follow-up poll is allowed and picks up the host update.
        now = now.addingTimeInterval(0.8)
        await model.pollWorkspaceIfNeeded()
        XCTAssertEqual(workspace.snapshotCalls, 5)
        XCTAssertEqual(model.workspace, .connected(fullyUpdatedSnapshot))

        // Once settled, subsequent polls with no further disk change are skipped.
        await model.pollWorkspaceIfNeeded()
        XCTAssertEqual(workspace.snapshotCalls, 5)
    }

    func testActivityHeartbeatsDoNotTriggerPollsUntilWorkspaceFieldsChange() async throws {
        let stateDir = root.appendingPathComponent("heartbeat-state", isDirectory: true)
        let sessionsDir = stateDir.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)

        func writeActivity(
            _ sessionId: String,
            updatedAt: String,
            observedAt: Int64,
            processing: Bool = false,
            questionId: String? = nil,
            budgetRequestId: String? = nil
        ) throws {
            let questions = questionId.map { #"[{"requestId":"\#($0)","question":"Proceed?"}]"# } ?? "[]"
            let workflow = budgetRequestId.map {
                #"{"version":1,"observedAtMilliseconds":\#(observedAt),"capabilities":[],"sendReady":true,"limitsKnown":true,"budgetRequest":{"requestId":"\#($0)","maxAiCredits":50,"usedAiCredits":50},"agents":[],"schedules":[]}"#
            } ?? "null"
            let json = """
            {
              "schemaVersion": 1,
              "copilotSessionId": "abcdef12-0001",
              "conversationEpoch": "abcdef12-0001:1",
              "updatedAt": "\(updatedAt)",
              "foregroundTurnActive": false,
              "scheduledTurnActive": false,
              "activeSubagents": [],
              "trackedUserInputs": \(questions),
              "workflow": \(workflow),
              "runtimeActivity": {"processing": \(processing), "observedAtMilliseconds": \(observedAt), "idleAtMilliseconds": 500}
            }
            """
            try Data(json.utf8).write(
                to: sessionsDir.appendingPathComponent("\(sessionId).agent-activity.json"),
                options: .atomic
            )
        }

        try writeActivity("s1", updatedAt: "2026-10-27T12:00:00.000Z", observedAt: 1_000)
        try writeActivity("s2", updatedAt: "2026-10-27T12:00:01.000Z", observedAt: 2_000)

        var runningSnapshot = fixtureSnapshot
        runningSnapshot.projects[0].sessions[0].status = .running
        var waitingQuestionSnapshot = runningSnapshot
        waitingQuestionSnapshot.projects[0].sessions[0].status = .waiting
        waitingQuestionSnapshot.projects[0].sessions[0].hasPendingInput = true
        var budgetRequestSnapshot = waitingQuestionSnapshot
        budgetRequestSnapshot.projects[0].sessions[0].title = "Budget approval"
        var clearedBudgetSnapshot = fixtureSnapshot
        let workspace = FakeWorkspace(fetches: [
            .snapshot(fixtureSnapshot),
            .snapshot(runningSnapshot),
            .snapshot(waitingQuestionSnapshot),
            .snapshot(budgetRequestSnapshot),
            .snapshot(clearedBudgetSnapshot),
        ])
        let model = PullRequestsModel(
            workspace: workspace,
            defaults: UserDefaults(suiteName: UUID().uuidString)!,
            stateDirectory: root.appendingPathComponent("pr-state", isDirectory: true),
            workspaceStateDirectory: stateDir,
            loadAccounts: { [] },
            clock: { testNow },
            isVisible: { true },
            presentError: { _, _ in }
        )

        await model.pollWorkspace()
        XCTAssertEqual(workspace.snapshotCalls, 1)

        // Staggered 5s heartbeats that only advance updatedAt and observedAtMilliseconds
        // across multiple sessions must not invalidate the workspace signature.
        try writeActivity("s1", updatedAt: "2026-10-27T12:00:05.000Z", observedAt: 6_000)
        try writeActivity("s2", updatedAt: "2026-10-27T12:00:06.000Z", observedAt: 7_000)
        await model.pollWorkspaceIfNeeded()
        XCTAssertEqual(workspace.snapshotCalls, 1)

        // A runtimeActivity.processing transition triggers a poll.
        try writeActivity(
            "s1",
            updatedAt: "2026-10-27T12:00:07.000Z",
            observedAt: 8_000,
            processing: true
        )
        await model.pollWorkspaceIfNeeded()
        XCTAssertEqual(workspace.snapshotCalls, 2)
        XCTAssertEqual(model.workspace, .connected(runningSnapshot))

        // A change to trackedUserInputs triggers a poll.
        try writeActivity(
            "s1",
            updatedAt: "2026-10-27T12:00:08.000Z",
            observedAt: 9_000,
            processing: true,
            questionId: "q-1"
        )
        await model.pollWorkspaceIfNeeded()
        XCTAssertEqual(workspace.snapshotCalls, 3)
        XCTAssertEqual(model.workspace, .connected(waitingQuestionSnapshot))

        // Adding and removing workflow.budgetRequest triggers polls.
        try writeActivity(
            "s1",
            updatedAt: "2026-10-27T12:00:09.000Z",
            observedAt: 10_000,
            budgetRequestId: "budget-1"
        )
        await model.pollWorkspaceIfNeeded()
        XCTAssertEqual(workspace.snapshotCalls, 4)
        XCTAssertEqual(model.workspace, .connected(budgetRequestSnapshot))

        try writeActivity(
            "s1",
            updatedAt: "2026-10-27T12:00:10.000Z",
            observedAt: 11_000,
            budgetRequestId: nil
        )
        await model.pollWorkspaceIfNeeded()
        XCTAssertEqual(workspace.snapshotCalls, 5)
        XCTAssertEqual(model.workspace, .connected(clearedBudgetSnapshot))

        // ControlWorkspaceBridge only infers Paths.stateDir for the conventional socket in Paths.stateDir.
        let externalBridge = ControlWorkspaceBridge(socketPath: "/tmp/external-copilot.sock")
        XCTAssertNil(externalBridge.stateDirectory)
        let defaultSocketBridge = ControlWorkspaceBridge(
            socketPath: Paths.stateDir.appendingPathComponent("control.sock").path
        )
        XCTAssertEqual(defaultSocketBridge.stateDirectory, Paths.stateDir)
    }
}

final class PullRequestsAppSupportTests: XCTestCase {
    func testOnlyOneCopyHoldsTheLockAndItsPidIsRecorded() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let lockPath = root.appendingPathComponent("pull-requests/app.lock").path
        let pidPath = root.appendingPathComponent("pull-requests/app.pid").path
        let first = PullRequestsAppLock(lockPath: lockPath, pidPath: pidPath)
        XCTAssertEqual(first.acquire(), .acquired)
        XCTAssertEqual(PullRequestsAppLock.recordedProcessIdentifier(at: pidPath), getpid())
        let second = PullRequestsAppLock(lockPath: lockPath, pidPath: pidPath)
        XCTAssertEqual(second.acquire(), .heldElsewhere, "a second copy must not write the state")
        second.release()
        XCTAssertEqual(PullRequestsAppLock.recordedProcessIdentifier(at: pidPath), getpid())
        first.release()
        XCTAssertNil(PullRequestsAppLock.recordedProcessIdentifier(at: pidPath))
        XCTAssertEqual(second.acquire(), .acquired)
        second.release()
    }

    func testALockThatCannotBeOpenedIsAFailureNotAnotherCopy() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // A file where the state folder should be: nothing can be locked, and no copy holds it.
        try Data().write(to: root.appendingPathComponent("pull-requests"))
        let lock = PullRequestsAppLock(
            lockPath: root.appendingPathComponent("pull-requests/app.lock").path,
            pidPath: root.appendingPathComponent("pull-requests/app.pid").path
        )
        XCTAssertEqual(lock.acquire(), .failed(errno: ENOTDIR))
        XCTAssertFalse(lock.isHeld)
        XCTAssertTrue(PullRequestsAppLock.failureNote(errno: ENOTDIR).contains("Not a directory"))
    }

    @MainActor
    func testActivationFollowsARestartedCopilotProjectsOnlyToItsOwnBundle() throws {
        let ended = Process()
        ended.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try ended.run()
        ended.waitUntilExit()
        let gone = ended.processIdentifier
        XCTAssertNil(PullRequestsHostApp.runningHost(gone, hostURL: nil), "a development build has no bundle to look for")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Copilot Projects.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": "com.example.not-running.\(UUID().uuidString)"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        XCTAssertNil(PullRequestsHostApp.runningHost(gone, hostURL: app))

        let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder")
        if finder.count == 1 {
            let live = finder[0].processIdentifier
            XCTAssertEqual(PullRequestsHostApp.runningHost(live, hostURL: nil)?.processIdentifier, live)
            XCTAssertNil(PullRequestsHostApp.runningHost(live, hostURL: app), "a reused pid isn't Copilot Projects")
            XCTAssertEqual(
                PullRequestsHostApp.runningHost(gone, hostURL: URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"))?
                    .processIdentifier,
                finder[0].processIdentifier,
                "a host that restarted is found again by its bundle"
            )
        }
    }

    func testAMissingPidStillHandsOffToTheOnlyOtherCopyOfThisApp() {
        let bring = PullRequestsAppDelegate.copyToBringForward
        XCTAssertEqual(bring(7, [(7, false), (8, true)]), 7, "the recorded lock holder wins, wherever it lives")
        XCTAssertEqual(bring(nil, [(7, false), (8, true)]), 8)
        XCTAssertEqual(bring(99, [(8, true)]), 8, "a stale pid falls back too")
        XCTAssertNil(bring(nil, [(7, true), (8, true)]), "never guess between two copies")
        XCTAssertNil(bring(nil, [(7, false)]))
        XCTAssertNil(bring(nil, []))
    }

    func testASocketMovedOutOfItsStateDirectoryGetsItsOwnPullRequestsState() {
        let state = URL(fileURLWithPath: "/Users/me/.local/state/copilot-projects", isDirectory: true)
        let base = state.appendingPathComponent("pull-requests").path
        let state1 = Paths.pullRequestsStateDir(stateDir: state, socketPath: state.appendingPathComponent("control.sock").path)
        XCTAssertEqual(state1.path, base)
        XCTAssertEqual(Paths.pullRequestsStateDir(stateDir: state, socketPath: state.path + "/./control.sock").path, base)
        let moved = Paths.pullRequestsStateDir(stateDir: state, socketPath: "/Users/me/isolated.sock")
        XCTAssertEqual(moved.deletingLastPathComponent().path, base)
        XCTAssertTrue(moved.lastPathComponent.hasPrefix("socket-"), moved.path)
        XCTAssertEqual(moved, Paths.pullRequestsStateDir(stateDir: state, socketPath: "/Users/me/isolated.sock"))
        XCTAssertNotEqual(moved, Paths.pullRequestsStateDir(stateDir: state, socketPath: "/Users/me/other.sock"))
    }

    func testATimedOutGhTakesEverythingItStartedWithIt() async throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/perl"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let pids = root.appendingPathComponent("pids")
        // Both children ignore SIGTERM and hold the output open; one has left gh's process group.
        let script = """
        trap '' TERM
        /bin/sleep 30 &
        echo $! >> "$1"
        /usr/bin/perl -e 'setpgrp(0, 0); exec "/bin/sleep", "30"' &
        echo $! >> "$1"
        /bin/sleep 30
        """
        let started = Date()
        do {
            _ = try await GitHubCLIProcess.run(
                executable: "/bin/sh", arguments: ["-c", script, "sh", pids.path], environment: [:],
                directory: root, timeout: 0.5, terminationGrace: 0.3
            )
            XCTFail("Expected a timeout")
        } catch {
            XCTAssertTrue(error is GitHubCLIProcess.TimedOut, "\(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        let children = try String(contentsOf: pids, encoding: .utf8)
            .split(separator: "\n").compactMap { pid_t($0) }
        XCTAssertEqual(children.count, 2)
        let deadline = Date().addingTimeInterval(3)
        while children.contains(where: { kill($0, 0) == 0 }), Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        for pid in children {
            XCTAssertNotEqual(kill(pid, 0), 0, "pid \(pid) outlived the timed-out gh")
        }
    }

    func testOwnersLiveInCopilotProjectsDefaultsAndAMissingKeyIsVisible() {
        let host = "com.example.copilot-projects.\(UUID().uuidString)"
        let helperURL = URL(fileURLWithPath: "/Applications/Copilot Projects.app/Contents/Helpers/Copilot Pull Requests.app")
        let shared = PullRequestsSettings.defaults(
            bundleURL: helperURL, bundleIdentifier: host + ".pull-requests", hostBundleIdentifier: host
        )
        XCTAssertNil(shared.note)
        shared.defaults.set("github", forKey: PullRequestsModel.ownersKey)
        defer { UserDefaults(suiteName: host)?.removePersistentDomain(forName: host) }
        XCTAssertEqual(UserDefaults(suiteName: host)?.string(forKey: PullRequestsModel.ownersKey), "github")

        let missing = PullRequestsSettings.defaults(
            bundleURL: helperURL, bundleIdentifier: host + ".pull-requests", hostBundleIdentifier: nil
        )
        XCTAssertTrue(missing.defaults === UserDefaults.standard)
        XCTAssertEqual(missing.note, PullRequestsSettings.unsharedNote)

        let development = PullRequestsSettings.defaults(
            bundleURL: URL(fileURLWithPath: "/repo/.build/debug"), bundleIdentifier: nil, hostBundleIdentifier: nil
        )
        XCTAssertTrue(development.defaults === UserDefaults.standard)
        XCTAssertNil(development.note, "an unbundled development build uses its own defaults quietly")
    }

    func testTheTitleStripStartsPastTheTrafficLights() {
        XCTAssertTrue(TitleStrip.contains(NSPoint(x: 200, y: 740), windowHeight: 760))
        XCTAssertFalse(TitleStrip.contains(NSPoint(x: 40, y: 740), windowHeight: 760))
        XCTAssertFalse(TitleStrip.contains(NSPoint(x: 200, y: 700), windowHeight: 760))
    }

    @MainActor
    func testTheTitleStripIsOnlyTheMainWindows() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: true
        )
        XCTAssertFalse(window.isVisible)
        XCTAssertTrue(TitleStrip.applies(to: window), "a minimized or hidden window is still the app's")
        let borderless = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless],
            backing: .buffered, defer: true
        )
        XCTAssertFalse(TitleStrip.applies(to: borderless))
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: true
        )
        XCTAssertFalse(TitleStrip.applies(to: panel), "an alert or popover keeps its double-clicks")
    }
}
