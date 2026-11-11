import XCTest
import AppKit
import CopilotProjectsCore
@testable import CopilotProjectsHost

/// Temporary, with StatusShadow.swift: both go when the other status sources do.
@MainActor
final class StatusShadowTests: XCTestCase {
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

    private func logged(_ shadow: StatusShadow) throws -> [[String: Any]] {
        shadow.queue.sync {}
        return try String(contentsOf: shadow.url, encoding: .utf8).split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
    }

    func testAnUnusableReadingHoldsTheLastStatusAndOnlyAGoneTrackerIsIdle() {
        let now = Date()
        func result(
            _ snapshot: AgentActivitySnapshot?, held: SessionStatus = .running, gone: Bool = false
        ) -> String {
            let tracker = StatusShadow.trackerOnly(snapshot, held: held, gone: gone, now: now)
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

    func testThePollLogsHeldAliveAndGoneWithoutReadingAnotherFooter() throws {
        let session = Session(title: "shadow", cwd: root.path)
        let sid = session.id
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(
            projects: [Project(name: "shadow", cwd: root.path, sessions: [session])],
            selectedProjectId: nil))
        var footerReads = 0
        var live: Set<String> = [sid]
        let model = AppModel(
            stateRepository: repository, isAppActive: { false },
            agentActivityDirectory: root, resumeMarkerDirectory: root,
            remotePromptLiveSessions: { _ in live },
            remotePromptTarget: { _ in
                footerReads += 1
                return RemotePromptTarget(activity: .idle)
            }
        )
        func lines(_ what: String) throws -> [[String: Any]] {
            try logged(model.statusShadow).filter { $0["what"] as? String == what }
        }
        func publish(_ snapshot: AgentActivitySnapshot) throws {
            try Data("owner".utf8).write(to: root.appendingPathComponent("\(sid).copilot-session"))
            try JSONEncoder().encode(snapshot)
                .write(to: root.appendingPathComponent("\(sid).agent-activity.json"), options: .atomic)
            model.refreshAgentActivitySnapshots()
        }
        let hook = SessionArtifacts.currentStatusTimestamp() - 10_000

        // A hook says running and there is no tracker: tracker-only holds the running
        // it first saw. Then a hook says idle, which tracker-only never hears.
        model.setStatus(sessionId: sid, status: .running, text: nil, timestamp: hook)
        model.reconcileAgentFooters()
        model.setStatus(sessionId: sid, status: .idle, text: nil, timestamp: hook + 1)
        for _ in 0..<3 { model.reconcileAgentFooters() }
        XCTAssertEqual(footerReads, 4, "the shadow reads no footer beyond the poll's own")
        XCTAssertEqual(model.projects[0].sessions[0].displayStatus, .idle, "the shadow changes nothing shown")
        var status = try lines("status")
        XCTAssertEqual(status.count, 1, "polls that find the same disagreement log nothing")
        XCTAssertEqual(status[0]["tracker"] as? String, "Running")
        XCTAssertEqual(status[0]["state"] as? String, "held")
        XCTAssertEqual(status[0]["footer"] as? String, "idle")
        XCTAssertEqual(status[0]["gate"] as? String, "none")
        XCTAssertEqual(status[0]["status"] as? String, "idle")
        XCTAssertEqual(status[0]["statusAt"] as? Int64, hook + 1)
        XCTAssertEqual(
            try lines("send").map { "\($0["shown"]!) \($0["tracker"]!)" }, ["ready busy"],
            "an idle footer does not make a held session ready")

        // The tracker reports idle: its reading decides, and the poll reads no footer.
        try publish(snapshot(processing: false, at: Date()))
        footerReads = 0
        model.reconcileAgentFooters()
        XCTAssertEqual(footerReads, 0)
        status = try lines("status")
        XCTAssertEqual(status.count, 2)
        XCTAssertEqual(status[1]["shown"] as? String, status[1]["tracker"] as? String)
        XCTAssertEqual(try lines("send").last?["over"] as? Bool, true)

        // The tracker lists a pending permission, then another Copilot takes the tab:
        // tracker-only keeps the waiting it last showed.
        try publish(snapshot(processing: false, permissions: ["permission"], at: Date()))
        model.reconcileAgentFooters()
        try Data("another".utf8).write(to: root.appendingPathComponent("\(sid).copilot-session"))
        model.refreshAgentActivitySnapshots()
        model.reconcileAgentFooters()
        XCTAssertEqual(model.projects[0].sessions[0].attentionLabel, "Waiting for input")
        XCTAssertEqual(try lines("status").count, 2, "a held status keeps a pending question's waiting")

        // A hook says waiting for a permission the live tracker doesn't list.
        model.setStatus(sessionId: sid, status: .waiting, text: nil, timestamp: hook + 2)
        try publish(snapshot(processing: true, turn: true, at: Date()))
        model.reconcileAgentFooters()
        XCTAssertEqual(model.projects[0].sessions[0].displayStatus, .waiting)
        status = try lines("status")
        XCTAssertEqual(status.count, 3)
        XCTAssertEqual(status[2]["shown"] as? String, "Waiting for input")
        XCTAssertEqual(status[2]["tracker"] as? String, "Running")
        XCTAssertEqual(status[2]["state"] as? String, "alive")
        XCTAssertEqual((status[2]["runtime"] as? [String: Any])?["processing"] as? Bool, true)
        XCTAssertNil(status[2]["footer"])

        // Another Copilot now owns the tab, so that snapshot no longer speaks for it;
        // then the agent process exits, comes back, and the 45 s warning goes up.
        try Data("another".utf8).write(to: root.appendingPathComponent("\(sid).copilot-session"))
        model.refreshAgentActivitySnapshots()
        model.reconcileAgentFooters()
        live = []
        model.reconcileAgentFooters()
        live = [sid]
        model.reconcileAgentFooters()
        model.projects[0].sessions[0].trackerWarning = "missing"
        model.reconcileAgentFooters()
        var gone = model.projects[0].sessions[0]
        gone.status = .idle
        gone.agentActivity = nil
        XCTAssertEqual(
            try lines("status").dropFirst(3).map { "\($0["state"]!) \($0["tracker"]!)" },
            ["held Running", "gone \(gone.attentionLabel)", "held \(gone.attentionLabel)",
             "gone \(gone.attentionLabel)"])
        XCTAssertEqual(try lines("status")[3]["gate"] as? String, "unknown")
    }

    func testASleepEndsADisagreementAtTheLastPassBeforeIt() throws {
        let session = Session(title: "sleep", cwd: root.path)
        let sid = session.id
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(
            projects: [Project(name: "sleep", cwd: root.path, sessions: [session])],
            selectedProjectId: nil))
        let model = AppModel(
            stateRepository: repository, isAppActive: { false },
            agentActivityDirectory: root, resumeMarkerDirectory: root,
            remotePromptLiveSessions: { _ in [sid] }
        )
        let start = Date()
        let awake = ProcessInfo.processInfo.systemUptime
        func pass(_ wall: TimeInterval, _ uptime: TimeInterval) {
            model.recordStatusShadow(
                polled: [sid: (nil, .idle)], now: start.addingTimeInterval(wall), uptime: awake + uptime)
        }
        // There is no tracker, so tracker-only holds the idle it first saw. Then a
        // hook says running.
        pass(0, 0)
        model.setStatus(
            sessionId: sid, status: .running, text: nil,
            timestamp: SessionArtifacts.currentStatusTimestamp() - 10_000)
        // Two passes a second apart, ten minutes with no pass while the Mac is
        // awake, then a ten-minute sleep: only the uptime clock tells them apart.
        pass(1, 1)
        pass(2, 2)
        pass(602, 602)
        pass(1_202, 603)
        let status = try logged(model.statusShadow).filter { $0["what"] as? String == "status" }
        XCTAssertEqual(status.map { $0["over"] as? Bool == true }, [false, true, false])
        XCTAssertEqual(
            status.map { $0["t"] as? Int64 },
            [1, 602, 1_202].map { Int64(start.addingTimeInterval($0).timeIntervalSince1970 * 1_000) },
            "the disagreement ends at the last pass before the sleep and starts again after it")
    }

    func testAClosedSessionEndsItsDisagreementAndTheLogStaysBounded() throws {
        var shadow = StatusShadow(directory: root, maximumBytes: 2_000)
        let session = Session(title: "bounded", cwd: root.path)
        for index in 0...40 {
            shadow.note(
                "status", session: session, shown: index.isMultiple(of: 2) ? "Running" : "Idle",
                tracker: "Idle", state: .held, read: (nil, .idle), live: true, statusAt: nil, now: Date())
        }
        shadow.end(except: [], now: Date())
        shadow.end(except: [], now: Date())

        let last = try XCTUnwrap(logged(shadow).last)
        XCTAssertEqual(last["over"] as? Bool, true)
        XCTAssertEqual(last["sid"] as? String, session.id)
        XCTAssertNil(last["shown"])
        for url in [shadow.url, shadow.url.appendingPathExtension("1")] {
            let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
            XCTAssertGreaterThan(size, 0)
            XCTAssertLessThanOrEqual(size, 2_000)
        }
        let all = try [shadow.url.appendingPathExtension("1"), shadow.url]
            .map { try String(contentsOf: $0, encoding: .utf8) }.joined()
        XCTAssertEqual(all.components(separatedBy: "\"over\":true").count - 1, 1, "an ended session logs once")
    }
}
