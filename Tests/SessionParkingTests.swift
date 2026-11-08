import AppKit
import XCTest
import CopilotProjectsCore
import CopilotProjectsProtocol
@testable import CopilotProjectsHost

@MainActor
final class SessionParkingTests: XCTestCase {
    /// Stands in for the session's dtach master, CLI and terminal.
    private final class Processes: @unchecked Sendable {
        var alive = true
        var master = true
        var stops: [[String]] = []
        var started: [String] = []
        var masterChecks = 0
    }

    @MainActor
    private final class Fixture {
        let root: URL
        let sessions: URL
        let copilotHome: URL
        let session: Session
        let copilotId = UUID().uuidString.lowercased()
        let defaults: UserDefaults
        let model: AppModel
        let processes = Processes()
        var snapshot: AgentActivitySnapshot

        var id: String { session.id }
        var marker: URL { sessions.appendingPathComponent("\(id).copilot-session") }
        var question: URL { sessions.appendingPathComponent("\(id).session-park-check.json") }

        init(parked: ParkedSession? = nil, others: [Session] = []) throws {
            _ = NSApplication.shared
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            sessions = root.appendingPathComponent("sessions")
            copilotHome = root.appendingPathComponent("copilot")
            var session = Session(title: "Parking", cwd: root.path)
            session.parked = parked
            self.session = session
            let events = copilotHome.appendingPathComponent("session-state/\(copilotId)")
            try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: events, withIntermediateDirectories: true)
            try Data("{}\n".utf8).write(to: events.appendingPathComponent("events.jsonl"))
            let repository = StateRepository(path: root.appendingPathComponent("state.json"))
            let project = Project(name: "Parking", cwd: root.path, sessions: [session] + others)
            try repository.save(PersistedState(projects: [project], selectedProjectId: project.id))
            let suite = "parking-\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: suite)!
            defaults.removePersistentDomain(forName: suite)
            defaults.set(SessionParking.manual, forKey: SessionParking.settingKey)
            let live = session.id
            model = AppModel(
                stateRepository: repository, persistPermissionStatus: { _, _, _, _ in },
                isAppActive: { false }, agentActivityDirectory: sessions, resumeMarkerDirectory: sessions,
                remotePromptLiveSessions: { _ in [live] },
                remoteSessionBackendAvailable: { true },
                kittyImageDiskStore: RemoteKittyImageDiskStore(root: root.appendingPathComponent("images")),
                alertPresenter: { _ in .alertFirstButtonReturn },
                defaults: defaults
            )
            let now = Date()
            snapshot = AgentActivitySnapshot(
                schemaVersion: 1, updatedAt: "", foregroundTurnActive: false, scheduledTurnActive: false,
                activeSubagents: [], schedules: [], idleGeneration: 0, lastIdleAborted: false,
                lastIdleTurnKind: nil, error: nil, pendingPermissionRequestIds: [],
                copilotSessionId: copilotId, conversationEpoch: "epoch-1", operationReceiptVersion: 1,
                operationReceipts: [],
                workflow: RemoteSessionWorkflow(
                    observedAtMilliseconds: Int64(now.timeIntervalSince1970 * 1_000),
                    capabilities: ["session-send", SessionParking.checkKind], sendReady: true,
                    bounceRequested: false
                )
            )
            let processes = processes
            let home = copilotHome.path
            let cli = TranscriptController.CloseProcessIdentity(pid: 4_242, startSeconds: 1, startMicroseconds: 2)
            model.parkingRuntime = ParkingRuntime(
                liveProcesses: { _ in processes.alive ? [cli] : [] },
                isAlive: { _ in processes.alive },
                terminate: {
                    processes.stops.append($0)
                    processes.alive = false
                    processes.master = false
                },
                hasMaster: { _ in
                    processes.masterChecks += 1
                    return processes.master
                },
                sessionStore: { CopilotSessionStore(environment: ["COPILOT_HOME": home]) },
                startTerminal: { _, sessionId in processes.started.append(sessionId) }
            )
            model.setLiveAgentSessionsForTesting([session.id])
            model.applySessionMemoryUsage([session.id: 170_000_000])
            try Data(copilotId.utf8).write(to: marker)
            try publish()
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        /// Writes the tracker's snapshot as of now, after `change`.
        func publish(
            at now: Date = Date(), _ change: (inout AgentActivitySnapshot) -> Void = { _ in }
        ) throws {
            let nowMs = Int64(now.timeIntervalSince1970 * 1_000)
            snapshot.updatedAt = now.ISO8601Format(.init(includingFractionalSeconds: true))
            snapshot.workflow?.observedAtMilliseconds = nowMs
            snapshot.runtimeActivity = RuntimeActivitySnapshot(processing: false, observedAtMilliseconds: nowMs)
            change(&snapshot)
            try JSONEncoder().encode(snapshot).write(
                to: sessions.appendingPathComponent("\(id).agent-activity.json")
            )
        }

        /// Plays the tracker: takes the host's question once it is asked, runs
        /// `beforeAnswering`, then answers with `state`.
        func answerParkCheck(
            _ state: RemoteOperationState,
            beforeAnswering: () throws -> Void = {},
            change: (inout AgentActivitySnapshot) -> Void = { _ in }
        ) async throws {
            var turns = 0
            while !FileManager.default.fileExists(atPath: question.path) {
                turns += 1
                guard turns < 100_000 else { throw CancellationError() }
                await Task.yield()
            }
            try beforeAnswering()
            let asked = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(contentsOf: question)) as? [String: Any]
            )
            try FileManager.default.removeItem(at: question)
            try publish {
                $0.operationReceipts = [TrackedOperationReceipt(
                    operationId: asked["operationId"] as? String, conversationEpoch: "epoch-1",
                    kind: SessionParking.checkKind, state: state,
                    updatedAtMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000),
                    payloadFingerprint: asked["payloadFingerprint"] as? String
                )]
                change(&$0)
            }
        }

        func savedParked() throws -> ParkedSession? {
            let state = try JSONDecoder().decode(
                PersistedState.self, from: Data(contentsOf: root.appendingPathComponent("state.json"))
            )
            return state.projects.flatMap(\.sessions).first { $0.id == id }?.parked
        }

        var wire: RemoteSessionSnapshot {
            get throws {
                try XCTUnwrap(model.remoteWorkspaceSnapshot().projects.flatMap(\.sessions).first { $0.id == id })
            }
        }
    }

    private let send = RemoteSessionAction(kind: .send, prompt: "hello", mode: .enqueue)

    func testParkClosesInputBeforeAskingThenStopsCopilotAndKeepsTheRow() async throws {
        let f = try Fixture()
        let id = f.id
        async let refusal = f.model.parkSession(id)
        try await f.answerParkCheck(.applied, beforeAnswering: {
            // The record is saved and every input path is closed before the answer.
            XCTAssertEqual(try f.savedParked()?.state, .parking)
            XCTAssertEqual(f.model.sendRemoteKey(sessionId: id, key: "enter"), .busy)
            XCTAssertEqual(f.model.sendRemoteInput(sessionId: id, value: "x"), .busy)
            XCTAssertEqual(f.model.sendRemoteCommand(sessionId: id, requestId: "r", value: "/help"), .busy)
            XCTAssertEqual(f.model.sendRemotePrompt(sessionId: id, value: "hello"), .busy)
            XCTAssertEqual(f.model.performSessionAction(
                sessionId: id, action: self.send,
                operation: CLIOperationRequest(operationId: "send", conversationEpoch: "epoch-1")
            ), .conflict)
            XCTAssertNil(try f.wire.workflow)
            XCTAssertEqual(f.processes.stops, [])
            XCTAssertEqual(f.processes.started, [], "input during parking must not start a resume")
        })
        let result = await refusal
        XCTAssertNil(result)
        XCTAssertEqual(f.processes.stops, [[id]])
        XCTAssertEqual(try f.savedParked()?.state, .parked)

        // The row, its marker and its place on the wire all outlive the stop.
        f.model.handleExit(sessionId: id)
        f.model.setStatus(
            sessionId: id, status: .idle, text: nil, source: "session-end", copilotSessionId: f.copilotId
        )
        XCTAssertEqual(f.model.parkedState(id), .parked)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.marker.path))
        XCTAssertNil(f.model.controller(for: id), "a parked session must not get a terminal")
        XCTAssertNil(f.model.controllers[id])
        let wire = try f.wire
        XCTAssertEqual(wire.parked?.state, "parked")
        XCTAssertEqual(wire.status, "idle")
        XCTAssertEqual(wire.promptable, false)
        XCTAssertNil(wire.workflow)
        XCTAssertNil(wire.trackerWarning)
        XCTAssertNil(wire.memoryUsageBytes)
        XCTAssertNil(wire.operationReceipts?.first { $0.kind == SessionParking.checkKind })
    }

    func testABusySessionIsLeftAloneAndItsInputReopens() async throws {
        // Busy when asked, a turn that starts between the answer and the stop, and the
        // rule no longer holding once Copilot answers: opened in the web or iOS app,
        // marked unread, parking switched off.
        let quiet: (Fixture) -> Void = { _ in }
        let answers: [(RemoteOperationState, Bool, (Fixture) -> Void)] = [
            (.rejected, false, quiet), (.applied, true, quiet),
            (.applied, false, { $0.model.noteRemoteClientHasOpen($0.id) }),
            (.applied, false, { $0.model.markSessionUnread(sessionId: $0.id) }),
            (.applied, false, { $0.defaults.set(SessionParking.off, forKey: SessionParking.settingKey) }),
        ]
        for (state, turnStarted, meanwhile) in answers {
            let f = try Fixture()
            async let refusal = f.model.parkSession(f.id)
            try await f.answerParkCheck(
                state, beforeAnswering: { meanwhile(f) },
                change: { $0.foregroundTurnActive = turnStarted }
            )
            let result = await refusal
            XCTAssertNotNil(result)
            XCTAssertNil(f.model.parkedState(f.id))
            XCTAssertNil(try f.savedParked())
            XCTAssertEqual(f.processes.stops, [], "a stand-down must not touch the session")
            XCTAssertNil(try f.wire.parked)
        }
    }

    func testNothingInTheNeverParkTableIsParked() throws {
        let child = Session(title: "Child", cwd: "/tmp")
        let cases: [(String, (Fixture) throws -> Void)] = [
            ("setting off", { $0.defaults.set(SessionParking.off, forKey: SessionParking.settingKey) }),
            ("no live Copilot", { $0.model.setLiveAgentSessionsForTesting([]) }),
            ("no tracker", { try FileManager.default.removeItem(
                at: $0.sessions.appendingPathComponent("\($0.id).agent-activity.json")
            ) }),
            ("tracker without the question", { try $0.publish {
                $0.workflow = RemoteSessionWorkflow(
                    observedAtMilliseconds: $0.workflow!.observedAtMilliseconds,
                    capabilities: ["session-send"], sendReady: true, bounceRequested: false
                )
            } }),
            ("another Copilot session", { try $0.publish { $0.copilotSessionId = UUID().uuidString } }),
            ("turn running", { try $0.publish { $0.foregroundTurnActive = true } }),
            ("scheduled turn", { try $0.publish { $0.scheduledTurnActive = true } }),
            ("permission request", { try $0.publish { $0.pendingPermissionRequestIds = ["p"] } }),
            ("queued message", { try $0.publish {
                $0.workflow = RemoteSessionWorkflow(
                    observedAtMilliseconds: $0.workflow!.observedAtMilliseconds,
                    capabilities: $0.workflow!.capabilities, sendReady: true, bounceRequested: false,
                    pendingMessages: [RemotePendingMessage(messageId: "m", text: "queued", mode: .enqueue)]
                )
            } }),
            ("request in flight", { try Data("{}".utf8).write(
                to: $0.sessions.appendingPathComponent("\($0.id).session-send.json")
            ) }),
            ("nothing saved to resume", { try FileManager.default.removeItem(at: $0.copilotHome) }),
            ("unread", { $0.model.markSessionUnread(sessionId: $0.id) }),
            ("open in a remote client", { $0.model.noteRemoteClientHasOpen($0.id) }),
            ("has a child", { fixture in
                let loc = try XCTUnwrap(fixture.model.locateIndex(child.id))
                fixture.model.projects[loc.p].sessions[loc.s].parentSessionId = fixture.id
            }),
        ]
        for (name, arrange) in cases {
            let f = try Fixture(others: [child])
            XCTAssertNil(f.model.parkBlocker(for: f.id), "the baseline must be parkable (\(name))")
            try arrange(f)
            XCTAssertNotNil(f.model.parkBlocker(for: f.id), name)
        }
    }

    func testAParkNobodyChoseSkipsTheVisibleTabAndACLIHoldingAnotherSession() async throws {
        let visible = Session(title: "Visible", cwd: "/tmp")
        let f = try Fixture(others: [visible])
        f.model.show(projectId: f.model.projects[0].id, sessionId: visible.id)
        XCTAssertNil(f.model.parkBlocker(for: f.id, unattended: true))
        let other = f.copilotHome.appendingPathComponent("session-state/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        // Its Copilot takes up another session while it is being asked: the park stands down.
        async let late = f.model.parkSession(f.id, unattended: true)
        try await f.answerParkCheck(.applied, beforeAnswering: {
            try Data().write(to: other.appendingPathComponent("inuse.4242.lock"))
        })
        let lateRefusal = await late
        XCTAssertNotNil(lateRefusal)
        XCTAssertEqual(f.processes.stops, [])
        // Holding it from the start, Copilot isn't asked at all.
        let refusal = await f.model.parkSession(f.id, unattended: true)
        XCTAssertNotNil(refusal)
        XCTAssertNil(f.model.parkedState(f.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.question.path), "the tracker was not asked")

        f.model.show(projectId: f.model.projects[0].id, sessionId: f.id)
        XCTAssertNotNil(f.model.parkBlocker(for: f.id, unattended: true))
        XCTAssertNil(f.model.parkBlocker(for: f.id), "Park Session may park the visible tab")
    }

    func testLaunchSettlesEveryStateTheLastRunLeft() throws {
        let cli = TranscriptController.CloseProcessIdentity(pid: 4_242, startSeconds: 1, startMicroseconds: 2)
        // state, recorded stop, dtach master, CLI alive -> state after launch
        let cases: [(ParkedSession.State, Bool, Bool, Bool, ParkedSession.State?)] = [
            (.parking, false, false, false, nil),
            (.parking, true, true, true, nil),
            (.parking, true, false, true, .parking),
            (.parking, true, false, false, .parked),
            (.parked, true, false, false, .parked),
            (.resuming, false, true, true, .resuming),
            (.resuming, false, false, false, .parked),
            (.failed, false, true, false, .failed),
            (.failed, false, false, false, .failed),
        ]
        for (state, recorded, master, alive, expected) in cases {
            let f = try Fixture(parked: ParkedSession(
                state: state, sinceMilliseconds: 1, processes: recorded ? [cli] : []
            ))
            f.processes.master = master
            f.processes.alive = alive
            f.model.reconcileParkedSessionsAtLaunch()
            XCTAssertEqual(f.model.parkedState(f.id), expected, "\(state) \(recorded) \(master) \(alive)")
            XCTAssertEqual(f.processes.started, [], "launch must not start Copilot in a parked session")
            XCTAssertEqual(f.processes.stops, [])
        }
    }

    func testResumeUsesTheSameRowAndFailsOnlyAfterTheTimeout() async throws {
        let f = try Fixture(parked: ParkedSession(state: .parked, sinceMilliseconds: 1))
        f.processes.alive = false
        f.processes.master = false
        f.model.setLiveAgentSessionsForTesting([])
        // Input addressed to a parked session starts the resume and answers busy.
        XCTAssertEqual(f.model.sendRemotePrompt(sessionId: f.id, value: "hello"), .busy)
        XCTAssertEqual(f.model.parkedState(f.id), .resuming)
        XCTAssertEqual(f.processes.started, [f.id])
        XCTAssertEqual(f.model.sendRemoteKey(sessionId: f.id, key: "enter"), .busy)
        XCTAssertEqual(f.processes.started, [f.id], "a resume under way is not started again")

        // The snapshot from before the stop is not the resumed Copilot.
        f.model.refreshAgentActivitySnapshots()
        XCTAssertEqual(f.model.parkedState(f.id), .resuming)
        f.model.refreshAgentActivitySnapshots(now: Date().addingTimeInterval(91))
        XCTAssertEqual(f.model.parkedState(f.id), .failed)
        XCTAssertEqual(try f.savedParked()?.state, .failed)
        f.model.refreshAgentActivitySnapshots()
        XCTAssertEqual(f.model.parkedState(f.id), .failed, "the old snapshot doesn't make it live")
        XCTAssertEqual(f.model.sendRemotePrompt(sessionId: f.id, value: "hello"), .busy)
        XCTAssertEqual(f.processes.started, [f.id], "a failed resume is retried only when asked")

        // Try Again first stops the shell the failed resume left under a live
        // master, then starts over once that master is gone.
        f.processes.master = true
        f.processes.masterChecks = 0
        f.model.resumeParkedSession(f.id)
        XCTAssertEqual(f.processes.stops, [[f.id]])
        var turns = 0
        while f.processes.started.count < 2, turns < 100_000 {
            turns += 1
            await Task.yield()
        }
        XCTAssertEqual(f.processes.started, [f.id, f.id])
        XCTAssertLessThan(f.processes.masterChecks, 5, "the wait ends as soon as the master is gone")
        // The tracker of the resumed Copilot reports in.
        let later = Date().addingTimeInterval(1)
        try f.publish(at: later)
        f.model.refreshAgentActivitySnapshots(now: later)
        XCTAssertNil(f.model.parkedState(f.id))
        XCTAssertNil(try f.savedParked())
        XCTAssertEqual(f.model.projects.flatMap(\.sessions).map(\.id), [f.id])
        XCTAssertEqual(try String(contentsOf: f.marker, encoding: .utf8), f.copilotId)
        XCTAssertNil(try f.wire.parked)
    }

    func testResumeNeverStopsACopilotThatIsAlreadyRunning() throws {
        // A resume that came up after the timeout, or a record a failed save left behind.
        // Either sign is enough: the process list, or the tracker's own processes.
        for (state, listed) in [(ParkedSession.State.parked, true), (.failed, false)] {
            let f = try Fixture(parked: ParkedSession(state: state, sinceMilliseconds: 1))
            if listed { f.processes.alive = false } else { f.model.setLiveAgentSessionsForTesting([]) }
            f.model.resumeParkedSession(f.id)
            XCTAssertNil(f.model.parkedState(f.id), "\(state)")
            XCTAssertEqual(f.processes.stops, [])
            XCTAssertEqual(f.processes.started, [])
        }
        // A failed resume whose Copilot reports in later is live again without a click.
        let f = try Fixture(parked: ParkedSession(state: .failed, sinceMilliseconds: 1))
        f.model.refreshAgentActivitySnapshots()
        XCTAssertNil(f.model.parkedState(f.id))
    }

    func testARemoteClientOpeningAParkedSessionResumesItOnTheSecondRefresh() throws {
        let f = try Fixture(parked: ParkedSession(state: .parked, sinceMilliseconds: 1))
        f.processes.master = false
        let start = Date()
        f.model.noteRemoteClientHasOpen(f.id, now: start)
        XCTAssertEqual(f.processes.started, [])
        f.model.noteRemoteClientHasOpen(f.id, now: start.addingTimeInterval(6))
        XCTAssertEqual(f.processes.started, [], "refreshes more than 5 s apart are not consecutive")
        f.model.noteRemoteClientHasOpen(f.id, now: start.addingTimeInterval(8))
        XCTAssertEqual(f.processes.started, [f.id])
    }

    func testTheWireSnapshotIsUnchangedUntilASessionIsParked() throws {
        let f = try Fixture()
        f.model.refreshAgentActivitySnapshots()
        let wire = try f.wire
        XCTAssertEqual(wire.workflow?.capabilities, ["session-send"])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(wire)) as? [String: Any])
        XCTAssertNil(json["parked"])
        // A record this build cannot read leaves an ordinary tab.
        let saved = Data(#"{"id":"a","title":"t","cwd":"/tmp","parked":{"state":"napping"}}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(Session.self, from: saved).parked)
    }
}
