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
    private var _snapshotCalls = 0
    private var _revealCalls: [(projectId: String?, sessionId: String)] = []
    private var _startCalls: [(projectId: String, requestId: UUID, prompt: String)] = []

    init(snapshot: WorkspaceSnapshot? = nil) {
        fetches = [snapshot.map(WorkspaceFetch.snapshot) ?? .unreachable]
    }

    init(fetches: [WorkspaceFetch]) {
        self.fetches = fetches
    }

    func answer(fetches: [WorkspaceFetch]? = nil, reveals: [WorkspaceCommandResult]? = nil,
                starts: [WorkspaceCommandResult]? = nil) {
        lock.withLock {
            if let fetches { self.fetches = fetches }
            if let reveals { self.reveals = reveals }
            if let starts { self.starts = starts }
        }
    }

    var snapshotCalls: Int { lock.withLock { _snapshotCalls } }
    var revealCalls: [(projectId: String?, sessionId: String)] { lock.withLock { _revealCalls } }
    var startCalls: [(projectId: String, requestId: UUID, prompt: String)] { lock.withLock { _startCalls } }

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
    }

    func testAnOlderHostIsIncompatibleAndAMissingOneIsUnreachable() async throws {
        let server = try TestControlSocket { .failure("unknown command: \($0.command)") }
        let older = ControlWorkspaceBridge(socketPath: server.path, timeout: 2)
        let fetch = await older.snapshot()
        XCTAssertEqual(fetch, .incompatibleHost)
        let reveal = await older.revealSession(projectId: nil, sessionId: "s1")
        XCTAssertEqual(reveal, .incompatibleHost)
        let start = await older.startCopilotSession(projectId: "p", requestId: UUID(), prompt: "go")
        XCTAssertEqual(start, .incompatibleHost)

        let garbled = try TestControlSocket { _ in .success("not a snapshot") }
        let unreadable = await ControlWorkspaceBridge(socketPath: garbled.path, timeout: 2).snapshot()
        XCTAssertEqual(unreadable, .incompatibleHost)

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
            loadAccounts: { [] }, isVisible: { true },
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

    func testAnOlderHostIsIncompatibleAndMatchesNothing() async {
        let model = makeModel(FakeWorkspace(fetches: [.incompatibleHost]))
        let pr = makePR(1, branch: "me/ship-it-branch")
        model.show([pr], links: [pr.key: "s1"])
        await model.pollWorkspace()
        XCTAssertEqual(model.workspace, .incompatibleHost)
        XCTAssertTrue(model.liveSessions.isEmpty)
        XCTAssertFalse(model.sessionsKnown)
        XCTAssertEqual(model.goals(now: testNow).flatMap(\.items).flatMap(\.assessment.reasons), [])
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

        // A host that answered once and then can't be understood: its sessions are unknown again.
        let incompatible = FakeWorkspace(fetches: [.snapshot(fixtureSnapshot), .incompatibleHost])
        let later = makeModel(incompatible)
        await later.pollWorkspace()
        await later.pollWorkspace()
        XCTAssertEqual(later.workspace, .incompatibleHost)
        later.refresh()
        try await waitUntil { !later.isRefreshing && later.lastUpdated != nil }
        XCTAssertEqual(try Data(contentsOf: index), saved, "an incompatible host must not empty the index")
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
