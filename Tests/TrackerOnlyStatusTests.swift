import XCTest
import AppKit
import CopilotProjectsCore
@testable import CopilotProjectsHost

/// A session's status and send-readiness when only its tracker decides.
@MainActor
final class TrackerOnlyStatusTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        _ = NSApplication.shared
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func snapshot(
        processing: Bool?, turn: Bool = false, scheduled: Bool = false, age: TimeInterval = 1,
        error: String? = nil, permissions: [String] = [], at now: Date
    ) -> AgentActivitySnapshot {
        let updated = now.addingTimeInterval(-age)
        return AgentActivitySnapshot(
            schemaVersion: 1,
            updatedAt: updated.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)),
            foregroundTurnActive: turn, scheduledTurnActive: scheduled, activeSubagents: [],
            schedules: [], idleGeneration: 1, lastIdleAborted: false, error: error,
            pendingPermissionRequestIds: permissions, copilotSessionId: "owner",
            conversationEpoch: "epoch",
            runtimeActivity: processing.map {
                RuntimeActivitySnapshot(
                    processing: $0,
                    observedAtMilliseconds: Int64(updated.timeIntervalSince1970 * 1_000),
                    idleAtMilliseconds: nil, error: nil)
            }
        )
    }

    func testAnUnusableReadingHoldsTheLastStatusAndOnlyAGoneTrackerIsIdle() {
        let now = Date()
        func result(
            _ snapshot: AgentActivitySnapshot?, held: SessionStatus = .running, gone: Bool = false
        ) -> String {
            let tracker = AppModel.trackerOnly(snapshot, held: held, gone: gone, now: now)
            return "\(tracker.state) \(tracker.status.rawValue) \(tracker.sendReady ? "ready" : "busy")"
        }
        // A usable reading decides, whatever was held.
        XCTAssertEqual(result(snapshot(processing: true, at: now), held: .idle), "alive running busy")
        XCTAssertEqual(result(snapshot(processing: false, at: now)), "alive idle ready")
        XCTAssertEqual(
            result(snapshot(processing: false, permissions: ["permission"], at: now)),
            "alive idle busy", "a pending question blocks a send")
        XCTAssertEqual(
            result(snapshot(processing: true, scheduled: true, at: now)),
            "alive idle busy", "a scheduled turn shows as idle but takes no prompt")
        XCTAssertEqual(
            result(snapshot(processing: nil, turn: true, at: now), held: .idle),
            "alive running busy", "on a CLI without isProcessing, turn events decide")

        // A stale heartbeat, a stale observation and a withdrawn reading all hold.
        XCTAssertEqual(result(snapshot(processing: false, age: 60, at: now)), "held running busy")
        XCTAssertEqual(result(nil, held: .waiting), "held waiting busy")
        var stale = snapshot(processing: false, at: now)
        stale.runtimeActivity?.observedAtMilliseconds = Int64(now.timeIntervalSince1970 * 1_000) - 20_000
        XCTAssertEqual(result(stale), "held running busy")
        var withdrawn = snapshot(processing: false, turn: true, at: now)
        withdrawn.runtimeActivity = RuntimeActivitySnapshot(
            processing: nil, observedAtMilliseconds: nil, idleAtMilliseconds: nil, error: "pending")
        XCTAssertEqual(
            result(withdrawn, held: .idle), "held idle busy",
            "turn events do not stand in for a reading the tracker withdrew")

        // Gone: the caller saw the process exit or the 45 s warning, or the connection closed.
        XCTAssertEqual(result(nil, gone: true), "gone idle busy")
        XCTAssertEqual(result(snapshot(processing: false, age: 60, at: now), gone: true), "gone idle busy")
        XCTAssertEqual(
            result(snapshot(processing: true, error: "Connection is closed.", at: now)), "gone idle busy")
        XCTAssertEqual(
            result(snapshot(processing: true, at: now), gone: true), "alive running busy",
            "a usable reading outranks a process list that is seconds old")
    }

    /// The shadow run compared send-readiness only where the footer was read, so
    /// this covers where the tracker's own reading decides.
    func testASendIsOfferedOnlyOnTheTrackersOwnIdleReading() throws {
        let session = Session(title: "send", cwd: root.path)
        let sid = session.id
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(
            projects: [Project(name: "send", cwd: root.path, sessions: [session])],
            selectedProjectId: nil))
        var live: Set<String> = [sid]
        let model = AppModel(
            stateRepository: repository, isAppActive: { false },
            agentActivityDirectory: root, resumeMarkerDirectory: root,
            remotePromptLiveSessions: { _ in live }
        )
        func promptable(at now: Date = Date()) -> Bool {
            model.remoteWorkspaceSnapshot(now: now).projects[0].sessions[0].promptable == true
        }
        func publish(_ snapshot: AgentActivitySnapshot, owner: String = "owner") throws {
            try Data(owner.utf8).write(to: root.appendingPathComponent("\(sid).copilot-session"))
            try JSONEncoder().encode(snapshot)
                .write(to: root.appendingPathComponent("\(sid).agent-activity.json"), options: .atomic)
            model.refreshAgentActivitySnapshots()
        }

        // A live Copilot with no tracker takes no send, though its status is idle.
        XCTAssertEqual(model.projects[0].sessions[0].status, .idle)
        XCTAssertFalse(promptable())

        // An idle reading is enough. No footer is read, and the process list, which
        // is seconds old, need not have the session yet.
        live = []
        try publish(snapshot(processing: false, at: Date()))
        XCTAssertTrue(promptable())
        var background = snapshot(processing: false, at: Date())
        background.activeSubagents = [
            TrackedSubagent(id: "agent", name: "reviewer", description: "", model: nil)
        ]
        try publish(background)
        XCTAssertTrue(promptable(), "a background agent does not make an idle coordinator busy")
        // A hook's status that trails the tracker changes nothing: on Nov 12 one stayed
        // on waiting for 73 s after its question was answered.
        model.setStatus(
            sessionId: sid, status: .waiting, text: nil,
            timestamp: SessionArtifacts.currentStatusTimestamp())
        XCTAssertTrue(promptable())

        try publish(snapshot(processing: false, permissions: ["permission"], at: Date()))
        XCTAssertFalse(promptable(), "pending input")
        try publish(snapshot(processing: true, turn: true, at: Date()))
        XCTAssertFalse(promptable(), "a working reading")
        try publish(snapshot(processing: true, scheduled: true, at: Date()))
        XCTAssertFalse(promptable(), "a scheduled turn")
        var withdrawn = snapshot(processing: false, at: Date())
        withdrawn.runtimeActivity = RuntimeActivitySnapshot(
            processing: nil, observedAtMilliseconds: nil, idleAtMilliseconds: nil, error: "pending")
        try publish(withdrawn)
        XCTAssertFalse(promptable(), "a reading the tracker withdrew as a turn began")

        let read = Date()
        try publish(snapshot(processing: false, at: read))
        XCTAssertTrue(promptable(at: read))
        XCTAssertFalse(promptable(at: read.addingTimeInterval(16)), "a reading older than 15 s")

        // Another Copilot owns the tab now, so that snapshot no longer speaks for it.
        try publish(snapshot(processing: false, at: Date()), owner: "another")
        XCTAssertFalse(promptable())
    }
}
