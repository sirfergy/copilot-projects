import XCTest
@testable import CopilotProjectsHost
import AppKit

/// Reads like `AgentActivityReader.read`, recording where it ran and, when asked,
/// holding the next read after it has read the files and before it returns.
private final class HeldReader: @unchecked Sendable {
    private let lock = NSLock()
    private var holdNext = false
    private var _onMain: [Bool] = []
    private var _returned = 0
    private let entered = DispatchSemaphore(value: 0)
    private let gate = DispatchSemaphore(value: 0)

    var onMain: [Bool] { lock.withLock { _onMain } }
    var returned: Int { lock.withLock { _returned } }

    func holdNextRead() { lock.withLock { holdNext = true } }
    func waitUntilHeld() { entered.wait() }
    func release() { gate.signal() }

    var read: AgentActivityReader.Read {
        { [self] sessionIds, directory, cached, clock in
            let hold = lock.withLock { () -> Bool in
                _onMain.append(Thread.isMainThread)
                defer { holdNext = false }
                return holdNext
            }
            let reads = AgentActivityReader.read(sessionIds, directory, cached, clock)
            if hold {
                entered.signal()
                gate.wait()
            }
            lock.withLock { _returned += 1 }
            return reads
        }
    }
}

@MainActor
final class AgentActivityBackgroundScanTests: XCTestCase {
    private var root: URL!
    private var session: Session!
    private var reader: HeldReader!
    private var scans = 0

    override func setUp() async throws {
        _ = NSApplication.shared
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        session = Session(title: "background", cwd: root.path)
        reader = HeldReader()
        scans = 0
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        SessionArtifacts.removeFiles(sessionId: session.id)
    }

    private func makeModel() throws -> AppModel {
        let project = Project(name: "background", cwd: root.path, sessions: [session])
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(projects: [project], selectedProjectId: project.id))
        return AppModel(
            stateRepository: repository,
            agentActivityDirectory: root,
            agentActivityScanObserver: { [unowned self] in self.scans += 1 },
            agentActivityReader: reader.read
        )
    }

    private var snapshotURL: URL { root.appendingPathComponent("\(session.id).agent-activity.json") }

    private func publish(generation: Int, scheduled: Bool = false, age: TimeInterval = 0) throws {
        let now = Date().addingTimeInterval(-age)
            .formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        let activity = AgentActivitySnapshot(
            schemaVersion: 1, updatedAt: now, foregroundTurnActive: false,
            foregroundTransitionAt: now, scheduledTurnActive: scheduled, activeSubagents: [],
            schedules: [], idleGeneration: generation, lastIdleAborted: false,
            lastIdleTurnKind: "foreground", error: nil
        )
        try JSONEncoder().encode(activity).write(to: snapshotURL, options: .atomic)
    }

    private var activity: AgentActivitySnapshot? { modelUnderTest?.projects[0].sessions[0].agentActivity }
    private weak var modelUnderTest: AppModel?

    /// Lets a released read reach the main actor, then a little longer.
    private func settle(afterReads count: Int) async throws {
        let deadline = Date().addingTimeInterval(5)
        while reader.returned < count {
            guard Date() < deadline else { return XCTFail("the read never returned") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try await Task.sleep(nanoseconds: 150_000_000)
    }

    func testStartAgentActivityTrackingScansOffTheMainThread() async throws {
        try publish(generation: 1)
        let model = try makeModel()
        modelUnderTest = model
        reader.holdNextRead()
        model.startAgentActivityTracking()
        defer { model.beginTermination() }
        XCTAssertEqual(scans, 1)
        XCTAssertNil(activity, "startup tracking must not block the main thread on a synchronous read")
        reader.waitUntilHeld()
        XCTAssertEqual(reader.onMain, [false])
        XCTAssertNil(activity)
        reader.release()
        try await settle(afterReads: 1)
        XCTAssertEqual(activity?.idleGeneration, 1)
        XCTAssertEqual(reader.onMain, [false])
    }

    func testWatcherScansReadFilesOffTheMainThread() async throws {
        try publish(generation: 1)
        let model = try makeModel()
        modelUnderTest = model
        model.scanAgentActivityInBackground()
        XCTAssertEqual(scans, 1)
        XCTAssertNil(activity, "applied only once the read comes back")
        try await settle(afterReads: 1)
        XCTAssertEqual(activity?.idleGeneration, 1)
        XCTAssertEqual(reader.onMain, [false])
    }

    func testAStaleReadNeverOverwritesALaterScan() async throws {
        try publish(generation: 1)
        let model = try makeModel()
        modelUnderTest = model
        reader.holdNextRead()
        model.scanAgentActivityInBackground()
        reader.waitUntilHeld()
        try publish(generation: 2)
        model.refreshAgentActivitySnapshots()
        XCTAssertEqual(activity?.idleGeneration, 2)
        reader.release()
        try await settle(afterReads: 2)
        XCTAssertEqual(activity?.idleGeneration, 2, "the held read saw generation 1 before the later scan")
    }

    func testAStaleReadNeverRestoresASnapshotALaterScanFoundGone() async throws {
        try publish(generation: 1)
        let model = try makeModel()
        modelUnderTest = model
        reader.holdNextRead()
        model.scanAgentActivityInBackground()
        reader.waitUntilHeld()
        try FileManager.default.removeItem(at: snapshotURL)
        model.refreshAgentActivitySnapshots()
        XCTAssertNil(activity)
        reader.release()
        try await settle(afterReads: 2)
        XCTAssertNil(activity, "the held read saw the file before the later scan found it gone")
    }

    func testASnapshotThatExpiresBeforeItsReadIsAppliedIsDropped() async throws {
        try publish(generation: 1, age: 14)
        let model = try makeModel()
        modelUnderTest = model
        reader.holdNextRead()
        model.scanAgentActivityInBackground()
        reader.waitUntilHeld()
        try await Task.sleep(nanoseconds: 1_500_000_000)
        reader.release()
        try await settle(afterReads: 1)
        XCTAssertNil(activity, "fresh when read, past the 15s limit when applied")
    }

    func testAScheduledTurnThatStartsDuringAReadStaysScheduled() async throws {
        try publish(generation: 1)
        let model = try makeModel()
        modelUnderTest = model
        reader.holdNextRead()
        model.scanAgentActivityInBackground()
        reader.waitUntilHeld()
        // The scheduled-start hook drops its marker and reports while the read is out.
        try Data().write(to: root.appendingPathComponent("\(session.id).scheduled-turn"))
        model.setStatus(
            sessionId: session.id, status: .idle, text: nil,
            timestamp: Int64(Date().timeIntervalSince1970 * 1_000), source: "scheduled-start"
        )
        XCTAssertTrue(model.projects[0].sessions[0].scheduledTurnActive)
        reader.release()
        try await settle(afterReads: 1)
        XCTAssertTrue(model.projects[0].sessions[0].scheduledTurnActive, "the marker is checked when applied")
    }

    func testAForegroundTurnThatStartsDuringAReadIsNotMadeScheduled() async throws {
        try publish(generation: 1, scheduled: true)
        let model = try makeModel()
        modelUnderTest = model
        reader.holdNextRead()
        model.scanAgentActivityInBackground()
        reader.waitUntilHeld()
        // The scheduled turn ends and a foreground turn starts while the read is out.
        try publish(generation: 1)
        model.setStatus(
            sessionId: session.id, status: .running, text: nil,
            timestamp: Int64(Date().timeIntervalSince1970 * 1_000)
        )
        XCTAssertFalse(model.projects[0].sessions[0].scheduledTurnActive)
        reader.release()
        try await settle(afterReads: 1)
        XCTAssertFalse(model.projects[0].sessions[0].scheduledTurnActive, "the held read saw the scheduled turn")
    }

    func testAScheduledTurnThatEndsDuringAReadStaysEnded() async throws {
        try publish(generation: 1)
        let model = try makeModel()
        modelUnderTest = model
        reader.holdNextRead()
        model.scanAgentActivityInBackground()
        reader.waitUntilHeld()
        // A scheduled turn starts and ends while the read is out, and the tracker
        // still reports it until session.idle.
        try publish(generation: 1, scheduled: true)
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        model.setStatus(sessionId: session.id, status: .idle, text: nil, timestamp: now, source: "scheduled-start")
        model.setStatus(sessionId: session.id, status: .idle, text: nil, timestamp: now + 1, source: "scheduled-idle")
        XCTAssertFalse(model.projects[0].sessions[0].scheduledTurnActive)
        reader.release()
        try await settle(afterReads: 1)
        model.refreshAgentActivitySnapshots()
        XCTAssertFalse(
            model.projects[0].sessions[0].scheduledTurnActive,
            "the held read from before the turn must not lift the ended turn's suppression"
        )
    }

    func testAReadThatFinishesAfterTerminationIsDropped() async throws {
        try publish(generation: 1)
        let model = try makeModel()
        modelUnderTest = model
        reader.holdNextRead()
        model.scanAgentActivityInBackground()
        reader.waitUntilHeld()
        model.scanAgentActivityInBackground()
        model.beginTermination()
        reader.release()
        try await settle(afterReads: 1)
        XCTAssertNil(activity)
        XCTAssertEqual(reader.onMain.count, 1, "no follow-up read after termination")
    }

    func testScansAskedForDuringAReadRunOnceAfterIt() async throws {
        try publish(generation: 1)
        let model = try makeModel()
        modelUnderTest = model
        reader.holdNextRead()
        model.scanAgentActivityInBackground()
        reader.waitUntilHeld()
        try publish(generation: 2)
        model.scanAgentActivityInBackground()
        model.scanAgentActivityInBackground()
        XCTAssertEqual(scans, 3)
        reader.release()
        try await settle(afterReads: 2)
        XCTAssertEqual(reader.onMain, [false, false], "one follow-up for both")
        XCTAssertEqual(activity?.idleGeneration, 2)
    }
}

/// Holds each load until `width` of them are waiting at once, so only a reader
/// whose loads overlap gets past it.
private final class LoadBarrier {
    private let condition = NSCondition()
    private let width: Int
    private var waiting = 0
    private var open = false
    private var _overlapped = false

    init(width: Int) { self.width = width }

    var overlapped: Bool { condition.withLock { _overlapped } }

    func wait() {
        condition.lock()
        defer { condition.unlock() }
        waiting += 1
        if waiting == width, !open {
            _overlapped = true
            open = true
            condition.broadcast()
        }
        // A reader that loads one file at a time never fills the barrier. The deadline
        // only turns that hang into a failure; a passing run never waits for it.
        let deadline = Date().addingTimeInterval(30)
        while !open {
            if !condition.wait(until: deadline) {
                open = true
                condition.broadcast()
            }
        }
    }
}

final class AgentActivityReaderTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private func url(_ sessionId: String) -> URL {
        root.appendingPathComponent("\(sessionId).agent-activity.json")
    }

    private func publish(_ sessionId: String, generation: Int) throws {
        let now = Date().formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        let activity = AgentActivitySnapshot(
            schemaVersion: 1, updatedAt: now, foregroundTurnActive: false,
            foregroundTransitionAt: now, scheduledTurnActive: false, activeSubagents: [],
            schedules: [], idleGeneration: generation, lastIdleAborted: false,
            lastIdleTurnKind: "foreground", error: nil
        )
        try JSONEncoder().encode(activity).write(to: url(sessionId), options: .atomic)
    }

    private func signature(_ sessionId: String) throws -> FileSignature {
        FileSignature(attributes: try FileManager.default.attributesOfItem(atPath: url(sessionId).path))
    }

    private func describe(_ read: AgentActivityRead) -> String {
        switch read.outcome {
        case .missing: return "missing"
        case .unchanged: return "unchanged"
        case .unreadable: return "unreadable"
        case .read(_, let snapshot): return "read \(snapshot.map { String($0.idleGeneration) } ?? "nil")"
        }
    }

    func testChangedFilesAreReadConcurrently() throws {
        let sessionIds = (0..<8).map { "session-\($0)" }
        for (generation, sessionId) in sessionIds.enumerated() {
            try publish(sessionId, generation: generation)
        }
        let barrier = LoadBarrier(width: 4)
        let reads = AgentActivityReader.read(sessionIds, root, [:], { Date() }) { url in
            barrier.wait()
            return try Data(contentsOf: url)
        }
        XCTAssertTrue(barrier.overlapped, "four loads were never in flight together")
        XCTAssertEqual(
            reads.mapValues(describe),
            Dictionary(uniqueKeysWithValues: sessionIds.enumerated().map { ($1, "read \($0)") }),
            "each session gets its own file"
        )
    }

    func testOutcomesAndReadTimesMatchAOneByOneRead() throws {
        for (generation, sessionId) in ["unchanged", "changed", "new", "unreadable"].enumerated() {
            try publish(sessionId, generation: generation)
        }
        try Data("{".utf8).write(to: url("malformed"))
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url("unreadable").path)
        let cached = ["unchanged": try signature("unchanged"), "changed": try signature("malformed")]

        // One counter for the loads and the clock places each read time against its load.
        let lock = NSLock()
        var tick = 0.0
        var loadedAt: [String: Double] = [:]
        let next = { lock.withLock { tick += 1; return tick } }
        let reads = AgentActivityReader.read(
            ["missing", "unchanged", "changed", "new", "malformed", "unreadable"], root, cached,
            { Date(timeIntervalSince1970: next()) }
        ) { url in
            let at = next()
            let sessionId = url.deletingPathExtension().deletingPathExtension().lastPathComponent
            lock.withLock { loadedAt[sessionId] = at }
            return try Data(contentsOf: url)
        }

        XCTAssertEqual(reads.mapValues(describe), [
            "missing": "missing", "unchanged": "unchanged", "changed": "read 1", "new": "read 2",
            "malformed": "read nil", "unreadable": "unreadable",
        ])
        guard case .read(let newSignature, _) = reads["new"]?.outcome else {
            return XCTFail("new was not read")
        }
        XCTAssertEqual(newSignature, try signature("new"))
        XCTAssertEqual(
            Set(loadedAt.keys), ["changed", "new", "malformed", "unreadable"], "only changed files are opened"
        )
        for (sessionId, loaded) in loadedAt {
            XCTAssertGreaterThan(
                try XCTUnwrap(reads[sessionId]).readAt.timeIntervalSince1970, loaded,
                "\(sessionId) was timed before it was read"
            )
        }
    }
}
