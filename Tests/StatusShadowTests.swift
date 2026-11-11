import XCTest
import AppKit
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

    func testTrackerOnlyStatusUsesTheFooterOnlyWhenTheTrackerIsDead() {
        let now = Date()
        func result(
            _ snapshot: AgentActivitySnapshot?, footer: FooterActivity? = nil, live: Bool = true
        ) -> String {
            let tracker = StatusShadow.trackerOnly(snapshot, footer: footer, live: live, now: now)
            return "\(tracker.alive ? "alive" : "dead") \(tracker.status.rawValue)"
                + " \(tracker.sendReady ? "ready" : "busy")"
        }
        // A live tracker decides, whatever the footer reads.
        XCTAssertEqual(result(snapshot(processing: true, at: now), footer: .idle), "alive running busy")
        XCTAssertEqual(result(snapshot(processing: false, at: now), footer: .working), "alive idle ready")
        XCTAssertEqual(
            result(snapshot(processing: false, permissions: ["permission"], at: now)),
            "alive idle busy", "a pending question blocks a send")
        XCTAssertEqual(
            result(snapshot(processing: true, scheduled: true, at: now)),
            "alive idle busy", "a scheduled turn shows as idle but takes no prompt")
        XCTAssertEqual(
            result(snapshot(processing: nil, turn: true, at: now)),
            "alive running busy", "without an isProcessing reading, turn events decide")
        // A stale heartbeat or a closed connection leaves only the footer.
        XCTAssertEqual(result(snapshot(processing: true, age: 60, at: now), footer: .idle), "dead idle ready")
        XCTAssertEqual(
            result(nil, footer: .idle, live: false), "dead idle busy",
            "an exited terminal reads as an idle footer but has no agent to prompt")
        XCTAssertEqual(
            result(snapshot(processing: false, error: "Connection is closed.", at: now), footer: .working),
            "dead running busy")
        XCTAssertEqual(result(nil, footer: .unknown), "dead idle busy")
        XCTAssertEqual(result(nil), "dead idle busy")
    }

    func testALastingDisagreementIsOneLineAndOneMoreWhenItEnds() throws {
        let session = Session(title: "shadow", cwd: root.path)
        let sid = session.id
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(
            projects: [Project(name: "shadow", cwd: root.path, sessions: [session])],
            selectedProjectId: nil))
        var footerReads = 0
        let model = AppModel(
            stateRepository: repository, isAppActive: { false },
            agentActivityDirectory: root, resumeMarkerDirectory: root,
            remotePromptLiveSessions: { _ in [sid] },
            remotePromptTarget: { _ in
                footerReads += 1
                return RemotePromptTarget(activity: .idle)
            }
        )
        func lines(_ what: String) throws -> [[String: Any]] {
            try logged(model.statusShadow).filter { $0["what"] as? String == what }
        }
        let hook = SessionArtifacts.currentStatusTimestamp() - 10_000

        // A hook says running, there is no tracker, and the footer reads idle.
        model.setStatus(sessionId: sid, status: .running, text: nil, timestamp: hook)
        for _ in 0..<3 { model.reconcileAgentFooters() }
        XCTAssertEqual(footerReads, 3, "the shadow reads no footer beyond the poll's own")
        XCTAssertEqual(model.projects[0].sessions[0].displayStatus, .running, "the shadow changes nothing shown")
        var status = try lines("status")
        XCTAssertEqual(status.count, 1, "polls that find the same disagreement log nothing")
        XCTAssertEqual(status[0]["shown"] as? String, "Running")
        XCTAssertEqual(status[0]["tracker"] as? String, "Idle")
        XCTAssertEqual(status[0]["alive"] as? Bool, false)
        XCTAssertEqual(status[0]["footer"] as? String, "idle")
        XCTAssertEqual(status[0]["gate"] as? String, "none")
        XCTAssertEqual(status[0]["status"] as? String, "running")
        XCTAssertEqual(status[0]["statusAt"] as? Int64, hook)
        XCTAssertEqual(try lines("send").map { "\($0["shown"]!) \($0["tracker"]!)" }, ["busy ready"])

        model.setStatus(sessionId: sid, status: .idle, text: nil, timestamp: hook + 1)
        for _ in 0..<2 { model.reconcileAgentFooters() }
        status = try lines("status")
        XCTAssertEqual(status.count, 2)
        XCTAssertEqual(status[1]["shown"] as? String, status[1]["tracker"] as? String)
        XCTAssertEqual(try lines("send").map { "\($0["shown"]!) \($0["tracker"]!)" }, ["busy ready", "ready ready"])

        // A hook says waiting for a permission the live tracker doesn't list.
        model.setStatus(sessionId: sid, status: .waiting, text: nil, timestamp: hook + 2)
        try Data("owner".utf8).write(to: root.appendingPathComponent("\(sid).copilot-session"))
        try JSONEncoder().encode(snapshot(processing: true, turn: true, at: Date()))
            .write(to: root.appendingPathComponent("\(sid).agent-activity.json"), options: .atomic)
        model.refreshAgentActivitySnapshots()
        footerReads = 0
        model.reconcileAgentFooters()
        XCTAssertEqual(footerReads, 0, "the poll reads no footer while the tracker's reading decides")
        XCTAssertEqual(model.projects[0].sessions[0].displayStatus, .waiting)
        status = try lines("status")
        XCTAssertEqual(status.count, 3)
        XCTAssertEqual(status[2]["shown"] as? String, "Waiting for input")
        XCTAssertEqual(status[2]["tracker"] as? String, "Running")
        XCTAssertEqual(status[2]["alive"] as? Bool, true)
        XCTAssertEqual((status[2]["runtime"] as? [String: Any])?["processing"] as? Bool, true)
        XCTAssertNil(status[2]["footer"])

        // Another Copilot now owns the tab, so that snapshot no longer speaks for it.
        try Data("another".utf8).write(to: root.appendingPathComponent("\(sid).copilot-session"))
        model.refreshAgentActivitySnapshots()
        model.reconcileAgentFooters()
        status = try lines("status")
        XCTAssertEqual(status.count, 4)
        XCTAssertEqual(status[3]["alive"] as? Bool, false)
        XCTAssertEqual(status[3]["tracker"] as? String, "Idle")
        XCTAssertEqual(status[3]["gate"] as? String, "unknown")
    }

    func testAFooterChangeUnderADeadTrackerIsANewLine() throws {
        var shadow = StatusShadow(directory: root)
        let session = Session(title: "footer", cwd: root.path)
        for (alive, footer) in [(false, FooterActivity.idle), (false, .idle), (false, .unknown), (true, .idle)] {
            shadow.note(
                "status", session: session, shown: "Running", tracker: "Idle", alive: alive,
                read: (nil, footer), live: true, statusAt: nil, now: Date())
        }
        shadow.note(
            "status", session: session, shown: "Running", tracker: "Idle", alive: true,
            read: (nil, .unknown), live: true, statusAt: nil, now: Date())
        XCTAssertEqual(
            try logged(shadow).map { "\($0["alive"] as? Bool == true ? "alive" : "dead") \($0["footer"]!)" },
            ["dead idle", "dead unknown", "alive idle"],
            "a live tracker's disagreement does not depend on the footer")
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
        // A hook says running, there is no tracker, and the footer reads idle.
        model.setStatus(
            sessionId: sid, status: .running, text: nil,
            timestamp: SessionArtifacts.currentStatusTimestamp() - 10_000)
        let start = Date()
        let awake = ProcessInfo.processInfo.systemUptime
        // Two passes a second apart, ten minutes with no pass while the Mac is
        // awake, then a ten-minute sleep: only the uptime clock tells them apart.
        let passes: [(wall: TimeInterval, uptime: TimeInterval)] = [(0, 0), (1, 1), (601, 601), (1_201, 602)]
        for pass in passes {
            model.recordStatusShadow(
                polled: [sid: (nil, .idle)], now: start.addingTimeInterval(pass.wall),
                uptime: awake + pass.uptime)
        }
        let status = try logged(model.statusShadow).filter { $0["what"] as? String == "status" }
        XCTAssertEqual(status.map { $0["over"] as? Bool == true }, [false, true, false])
        XCTAssertEqual(
            status.map { $0["t"] as? Int64 },
            [0, 601, 1_201].map { Int64(start.addingTimeInterval($0).timeIntervalSince1970 * 1_000) },
            "the disagreement ends at the last pass before the sleep and starts again after it")
    }

    func testAClosedSessionEndsItsDisagreementAndTheLogStaysBounded() throws {
        var shadow = StatusShadow(directory: root, maximumBytes: 2_000)
        let session = Session(title: "bounded", cwd: root.path)
        for index in 0...40 {
            shadow.note(
                "status", session: session, shown: index.isMultiple(of: 2) ? "Running" : "Idle",
                tracker: "Idle", alive: false, read: (nil, .idle), live: true, statusAt: nil, now: Date())
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
