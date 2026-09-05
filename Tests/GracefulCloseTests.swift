import XCTest
import AppKit
import CopilotProjectsCore
@testable import copilot_projects

private typealias CloseIdentity = TranscriptController.CloseProcessIdentity

private final class CloseWaitClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = ContinuousClock.now
    private var tick = 0

    var now: ContinuousClock.Instant {
        lock.lock()
        defer { lock.unlock() }
        return instant
    }

    var step: Int {
        lock.lock()
        defer { lock.unlock() }
        return tick
    }

    func advance(_ duration: Duration) {
        lock.lock()
        defer { lock.unlock() }
        instant = instant.advanced(by: duration)
        tick += 1
    }
}

private actor CloseGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var opened = false

    func wait() async {
        if opened { return }
        await withCheckedContinuation { continuations.append($0) }
    }

    func open() {
        opened = true
        continuations.forEach { $0.resume() }
        continuations.removeAll()
    }
}

final class GracefulCloseTests: XCTestCase {
    func testCloseStartupAndLivenessUseSameAgentProcessConfiguration() {
        XCTAssertEqual(Env.agentProcessNames([:]), ["copilot"])
        XCTAssertEqual(Env.agentProcessNames(["COPILOT_PROJECTS_AGENT_PROCESSES": "copilot-dev, other"]),
                       ["copilot-dev", "other"])
        XCTAssertEqual(Env.agentProcessNames(["COPILOT_PROJECTS_AGENT_PROCESSES": " , "]), ["copilot"])
    }

    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root
    }

    private func fixture(_ root: URL) throws -> (StateRepository, Project) {
        let session = Session(title: "close", cwd: root.path)
        let project = Project(name: "project", cwd: root.path, sessions: [session],
                              selectedSessionId: session.id)
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(projects: [project], selectedProjectId: project.id))
        return (repository, project)
    }

    private func loaded(_ repository: StateRepository) throws -> PersistedState {
        switch repository.load() {
        case .loaded(let state), .recovered(let state, _):
            return state
        default:
            XCTFail("Expected recoverable state")
            throw NSError(domain: "GracefulCloseTests", code: 1)
        }
    }

    func testAcceptedCloseWinsOverPrimaryAndBackupBeforeAnyTeardown() throws {
        let (repository, project) = try fixture(root())
        let sessionId = project.sessions[0].id
        try repository.save(PersistedState(projects: [project], selectedProjectId: project.id))
        try repository.acceptCloses(sessionIds: [sessionId])
        XCTAssertTrue(try loaded(repository).projects[0].sessions.isEmpty)

        // Crash before row save, then recovery from the prior primary.
        try Data("corrupt".utf8).write(to: repository.path)
        XCTAssertTrue(try loaded(repository).projects[0].sessions.isEmpty)
        let state = try loaded(repository)
        try repository.finishCloses(state)
        XCTAssertFalse(FileManager.default.fileExists(atPath: repository.closeIntentPath.path))
        try Data("corrupt again".utf8).write(to: repository.path)
        XCTAssertTrue(try loaded(repository).projects[0].sessions.isEmpty)
    }

    func testCloseIntentSurvivesPrimaryAndBackupWriteFailures() throws {
        let (repository, project) = try fixture(root())
        try repository.save(PersistedState(projects: [project], selectedProjectId: project.id))
        try repository.acceptCloses(sessionIds: project.sessions.map(\.id), projectIds: [project.id])
        let state = try loaded(repository)
        XCTAssertTrue(state.projects.isEmpty)

        try FileManager.default.removeItem(at: repository.path)
        try FileManager.default.createDirectory(at: repository.path, withIntermediateDirectories: true)
        XCTAssertThrowsError(try repository.finishCloses(state))
        XCTAssertTrue(try loaded(repository).projects.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: repository.closeIntentPath.path))

        try FileManager.default.removeItem(at: repository.path)
        try FileManager.default.removeItem(at: repository.backupPath)
        try FileManager.default.createDirectory(at: repository.backupPath, withIntermediateDirectories: true)
        XCTAssertThrowsError(try repository.finishCloses(state))
        XCTAssertTrue(try loaded(repository).projects.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: repository.closeIntentPath.path))

        try FileManager.default.removeItem(at: repository.backupPath)
        try repository.finishCloses(state)
        XCTAssertFalse(FileManager.default.fileExists(atPath: repository.closeIntentPath.path))
        try FileManager.default.removeItem(at: repository.path)
        XCTAssertTrue(try loaded(repository).projects.isEmpty)
    }

    func testUnreadableIntentFailsClosedInsteadOfRestoringRows() throws {
        let (repository, _) = try fixture(root())
        try Data("invalid".utf8).write(to: repository.closeIntentPath)
        guard case .failed = repository.load() else { return XCTFail("Must not restore unknown closes") }
    }

    @MainActor
    func testRemoteCloseRejectsIntentWriteFailureWithoutRemovingOrDestroying() throws {
        let root = try root()
        let (repository, project) = try fixture(root)
        var destroyed = false
        let model = AppModel(stateRepository: repository, isAppActive: { false },
            agentActivityDirectory: root,
            kittyImageDiskStore: RemoteKittyImageDiskStore(root: root.appendingPathComponent("images")),
            gracefulSessionDestroyer: { _, _ in destroyed = true; return Task {} })
        try FileManager.default.createDirectory(at: repository.closeIntentPath, withIntermediateDirectories: true)
        XCTAssertEqual(model.closeRemoteSession(sessionId: project.sessions[0].id), .failed)
        XCTAssertEqual(model.projects[0].sessions.map(\.id), project.sessions.map(\.id))
        XCTAssertFalse(destroyed)
    }

    @MainActor
    func testProjectCloseAcceptsWholeBatchBeforeSideEffectsAndRecoversSaveFailure() async throws {
        let root = try root()
        let (repository, project) = try fixture(root)
        let gate = CloseGate()
        var batches: [[String]] = []
        let model = AppModel(stateRepository: repository, isAppActive: { false },
            agentActivityDirectory: root,
            kittyImageDiskStore: RemoteKittyImageDiskStore(root: root.appendingPathComponent("images")),
            gracefulSessionDestroyer: { ids, _ in
                XCTAssertEqual(try? repository.pendingCloses().sessionIds, Set(ids))
                XCTAssertEqual(try? repository.pendingCloses().projectIds, [project.id])
                batches.append(ids)
                return Task { await gate.wait() }
            }, forcedSessionDestroyer: { _ in })
        try repository.save(PersistedState(projects: [project], selectedProjectId: project.id))
        try FileManager.default.removeItem(at: repository.path)
        try FileManager.default.createDirectory(at: repository.path, withIntermediateDirectories: true)
        model.closeProject(project.id)
        XCTAssertTrue(model.projects.isEmpty)
        XCTAssertEqual(batches, [project.sessions.map(\.id)])
        XCTAssertTrue(try loaded(repository).projects.isEmpty)
        model.forcePendingSessionDestroys()
        XCTAssertTrue(FileManager.default.fileExists(atPath: repository.closeIntentPath.path))
        await gate.open()
    }

    @MainActor
    func testStartupReplaysLegacyMarkerEvenWithPersistedRow() throws {
        let root = try root()
        let (repository, project) = try fixture(root)
        let sessions = root.appendingPathComponent("sessions")
        XCTAssertTrue(SessionArtifacts.writeCloseSessionRequest(
            sessionId: project.sessions[0].id, sessionsDirectory: sessions))
        var destroyed: [String] = []
        let model = AppModel(stateRepository: repository, isAppActive: { false },
            agentActivityDirectory: root,
            kittyImageDiskStore: RemoteKittyImageDiskStore(root: root.appendingPathComponent("images")),
            forcedSessionDestroyer: { destroyed += $0 })
        model.finishInterruptedSessionDestroys(sessionsDirectory: sessions)
        XCTAssertEqual(destroyed, project.sessions.map(\.id))
        XCTAssertTrue(model.projects[0].sessions.isEmpty)
        try Data("corrupt".utf8).write(to: repository.path)
        XCTAssertTrue(try loaded(repository).projects[0].sessions.isEmpty)
    }

    @MainActor
    func testUnreadableLegacyRequestsDoNotSilentlyCancelUnknownCloseIntent() throws {
        let root = try root()
        let (repository, project) = try fixture(root)
        let requests = root.appendingPathComponent("not-a-directory")
        try Data().write(to: requests)
        let original = try Data(contentsOf: repository.path)
        let model = AppModel(stateRepository: repository, isAppActive: { false },
            agentActivityDirectory: root,
            kittyImageDiskStore: RemoteKittyImageDiskStore(root: root.appendingPathComponent("images")),
            forcedSessionDestroyer: { _ in XCTFail("Unknown recovery must not destroy sessions") })
        model.finishInterruptedSessionDestroys(sessionsDirectory: requests)
        XCTAssertEqual(model.closeRemoteSession(sessionId: project.sessions[0].id), .failed)
        model.save()
        XCTAssertEqual(try Data(contentsOf: repository.path), original)
    }

    func testWaitTracksRestartedOwnerAndWaitsForTrackerAfterCLIExit() async {
        let clock = CloseWaitClock()
        let cli = CloseIdentity(pid: 1, startSeconds: 1, startMicroseconds: 0)
        let oldTracker = CloseIdentity(pid: 2, startSeconds: 2, startMicroseconds: 0)
        let newTracker = CloseIdentity(pid: 2, startSeconds: 3, startMicroseconds: 0)
        let owners: [Set<CloseIdentity>] = [[cli, oldTracker], [], [cli, newTracker], [newTracker], []]
        let live: [Set<CloseIdentity>] = [[cli, oldTracker], [cli], [cli, newTracker], [newTracker], []]
        let result = await SessionArtifacts.waitForLiveCLIExit(
            sessionId: "fixture", initialProcesses: owners[0],
            deadline: clock.now.advanced(by: .seconds(20)),
            discoveryDeadline: clock.now.advanced(by: .seconds(2)),
            liveCLIProcesses: { _ in owners[min(clock.step, 4)] },
            processIsAlive: { live[min(clock.step, 4)].contains($0) },
            now: { clock.now }, sleep: { clock.advance($0) })
        XCTAssertTrue(result)
        XCTAssertEqual(clock.step, 4)
    }

    func testNoOwnerGetsDiscoveryBudgetAndLateOwnerGetsFullGrace() async {
        let shellClock = CloseWaitClock()
        let shellStart = shellClock.now
        let missing = await SessionArtifacts.waitForLiveCLIExit(
            sessionId: "shell", initialProcesses: [],
            deadline: shellStart.advanced(by: .seconds(20)),
            discoveryDeadline: shellStart.advanced(by: .seconds(2)),
            liveCLIProcesses: { _ in [] }, now: { shellClock.now },
            sleep: { shellClock.advance($0) })
        XCTAssertFalse(missing)
        XCTAssertEqual(shellStart.duration(to: shellClock.now), .seconds(2))

        let clock = CloseWaitClock()
        let start = clock.now
        let cli = CloseIdentity(pid: 1, startSeconds: 1, startMicroseconds: 0)
        let result = await SessionArtifacts.waitForLiveCLIExit(
            sessionId: "starting", initialProcesses: [],
            deadline: start.advanced(by: .seconds(20)),
            discoveryDeadline: start.advanced(by: .seconds(2)),
            liveCLIProcesses: { _ in clock.step > 0 && clock.step < 30 ? [cli] : [] },
            processIsAlive: { _ in clock.step < 30 },
            now: { clock.now }, sleep: { clock.advance($0) })
        XCTAssertTrue(result)
        XCTAssertEqual(start.duration(to: clock.now), .seconds(3))
    }

    func testSlowProbeConsumesWallClockDeadlineNotPollBudget() async {
        let clock = CloseWaitClock()
        let start = clock.now
        let cli = CloseIdentity(pid: 1, startSeconds: 1, startMicroseconds: 0)
        let result = await SessionArtifacts.waitForLiveCLIExit(
            sessionId: "slow", initialProcesses: [cli],
            deadline: start.advanced(by: .seconds(1)),
            discoveryDeadline: start.advanced(by: .seconds(1)),
            liveCLIProcesses: { _ in clock.advance(.seconds(1)); return [cli] },
            processIsAlive: { _ in true }, now: { clock.now },
            sleep: { _ in XCTFail("Must not sleep past the deadline") })
        XCTAssertFalse(result)
        XCTAssertEqual(clock.step, 1)
    }

    func testKnownCLIStartupRetainsFullOwnerDiscoveryGrace() async {
        let clock = CloseWaitClock()
        let start = clock.now
        let cli = CloseIdentity(pid: 1, startSeconds: 1, startMicroseconds: 0)
        let result = await SessionArtifacts.waitForLiveCLIExit(
            sessionId: "slow-starting", initialProcesses: [],
            deadline: start.advanced(by: .seconds(20)),
            discoveryDeadline: start.advanced(by: .seconds(20)),
            liveCLIProcesses: { _ in clock.step >= 30 && clock.step < 40 ? [cli] : [] },
            processIsAlive: { _ in clock.step < 40 },
            now: { clock.now }, sleep: { clock.advance($0) })
        XCTAssertTrue(result)
        XCTAssertEqual(start.duration(to: clock.now), .seconds(4))
    }

    @MainActor
    func testQuitBoundsUncooperativeConcurrentClosesWithoutDestroyingActiveSession() async throws {
        let root = try root()
        let (repository, project) = try fixture(root)
        var state = try loaded(repository)
        let other = Session(title: "other close", cwd: root.path)
        let active = Session(title: "survives restart", cwd: root.path)
        state.projects[0].sessions += [other, active]
        try repository.save(state)
        let gate = CloseGate()
        var forced: [String] = []
        let model = AppModel(stateRepository: repository, isAppActive: { false },
            agentActivityDirectory: root,
            kittyImageDiskStore: RemoteKittyImageDiskStore(root: root.appendingPathComponent("images")),
            gracefulSessionDestroyer: { _, _ in Task { await gate.wait() } },
            forcedSessionDestroyer: { forced += $0 })
        XCTAssertEqual(model.closeRemoteSession(sessionId: project.sessions[0].id), .closed)
        XCTAssertEqual(model.closeRemoteSession(sessionId: other.id), .closed)
        model.beginTermination()
        let start = ContinuousClock.now
        await model.detachAllClientsAndDrain(closeTimeout: .milliseconds(40))
        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
        XCTAssertEqual(Set(forced), Set([project.sessions[0].id, other.id]))
        XCTAssertEqual(model.projects[0].sessions.map(\.id), [active.id])
        await gate.open()
    }
}
