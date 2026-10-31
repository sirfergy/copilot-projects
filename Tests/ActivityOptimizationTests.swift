import XCTest
@testable import CopilotProjectsHost
import CopilotProjectsCore
import CopilotProjectsProtocol
import AppKit
import Combine

final class ActivityOptimizationTests: XCTestCase {
    private func snapshot(at date: Date) -> AgentActivitySnapshot {
        AgentActivitySnapshot(
            schemaVersion: 1,
            updatedAt: date.ISO8601Format(.iso8601IncludingFractionalSeconds),
            foregroundTurnActive: false,
            foregroundTransitionAt: date.ISO8601Format(.iso8601IncludingFractionalSeconds),
            scheduledTurnActive: false,
            activeSubagents: [],
            schedules: [],
            idleGeneration: 1,
            lastIdleAborted: false,
            lastIdleTurnKind: "foreground",
            error: nil
        )
    }

    func testTimestampParsingPreservesWireFormatsAndFallbacks() throws {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        for value in [
            "2026-08-27T21:00:00.123Z", "2026-08-27T21:00:00Z",
            "2026-08-27T14:00:00.123-07:00", "2026-08-27T14:00:00-07:00",
            "2026-08-27T21:00:00.1Z", "2026-08-27T21:00:00.123456Z",
        ] {
            let expected = try XCTUnwrap(fractional.date(from: value) ?? plain.date(from: value))
            var activity = snapshot(at: expected)
            activity.updatedAt = value
            activity.foregroundTransitionAt = value
            XCTAssertTrue(activity.isFresh(at: expected.addingTimeInterval(14)))
            XCTAssertFalse(activity.isFresh(at: expected.addingTimeInterval(16)))
            XCTAssertEqual(
                Double(try XCTUnwrap(activity.updatedAtMilliseconds)),
                expected.timeIntervalSince1970 * 1_000,
                accuracy: 1
            )
            XCTAssertEqual(activity.foregroundTransitionMilliseconds, activity.updatedAtMilliseconds)
            let question = TrackedUserInput(
                requestId: "question", question: "Which?", choices: [],
                allowFreeform: true, requestedAt: value, agentId: nil
            )
            XCTAssertEqual(question.remoteRequest().requestedAt.timeIntervalSince(expected), 0, accuracy: 0.001)
            let elicitation = TrackedElicitation(
                requestId: "form", message: "Choose", requestedAt: value
            )
            XCTAssertEqual(elicitation.remoteRequest().requestedAt.timeIntervalSince(expected), 0, accuracy: 0.001)
        }
        var invalid = snapshot(at: Date())
        invalid.updatedAt = "not a timestamp"
        invalid.foregroundTransitionAt = "not a timestamp"
        XCTAssertFalse(invalid.isFresh())
        XCTAssertNil(invalid.updatedAtMilliseconds)
        XCTAssertNil(invalid.foregroundTransitionMilliseconds)
    }

    @MainActor
    func testHeartbeatUpdatesAuthoritativeSnapshotWithoutPublishingAndStillExpires() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = Session(title: "heartbeat", cwd: root.path)
        let project = Project(name: "heartbeat", cwd: root.path, sessions: [session])
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(projects: [project], selectedProjectId: project.id))
        let path = root.appendingPathComponent("\(session.id).agent-activity.json")
        let now = Date(timeIntervalSince1970: 1_787_865_600)
        var activity = snapshot(at: now)
        activity.error = "connection is closed"
        try JSONEncoder().encode(activity).write(to: path, options: .atomic)
        let model = AppModel(stateRepository: repository, agentActivityDirectory: root)
        model.refreshAgentActivitySnapshots(now: now)
        var publications = 0
        let observation = model.objectWillChange.sink { publications += 1 }
        defer { withExtendedLifetime(observation) {} }

        activity.updatedAt = now.addingTimeInterval(5).ISO8601Format(.iso8601IncludingFractionalSeconds)
        try JSONEncoder().encode(activity).write(to: path, options: .atomic)
        model.refreshAgentActivitySnapshots(now: now.addingTimeInterval(5))
        XCTAssertEqual(publications, 0)
        let refreshed = try XCTUnwrap(model.projects[0].sessions[0].agentActivity)
        XCTAssertEqual(refreshed.updatedAt, activity.updatedAt)
        XCTAssertEqual(refreshed.updatedAtMilliseconds, Int64(now.addingTimeInterval(5).timeIntervalSince1970 * 1_000))
        XCTAssertEqual(refreshed.foregroundTransitionAt, activity.foregroundTransitionAt)
        XCTAssertTrue(refreshed.reportsTerminalDisconnect)
        model.refreshAgentActivitySnapshots(now: now.addingTimeInterval(16))
        XCTAssertNotNil(model.projects[0].sessions[0].agentActivity)
        XCTAssertEqual(publications, 0)
        model.refreshAgentActivitySnapshots(now: now.addingTimeInterval(21))
        XCTAssertNil(model.projects[0].sessions[0].agentActivity)
        XCTAssertEqual(publications, 1)

        model.renameProject(project.id, name: "renamed")
        XCTAssertGreaterThan(publications, 1)
        XCTAssertEqual(model.projects[0].name, "renamed")
        let beforeHint = publications
        model.setNumberHint(.projects)
        XCTAssertGreaterThan(publications, beforeHint)
    }

    @MainActor
    func testSnapshotPublishedDuringScanIsJudgedWhenRead() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = Session(title: "mid-scan", cwd: root.path)
        let project = Project(name: "mid-scan", cwd: root.path, sessions: [session])
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(projects: [project], selectedProjectId: project.id))
        let path = root.appendingPathComponent("\(session.id).agent-activity.json")
        var publishDuringScan = false
        let model = AppModel(
            stateRepository: repository,
            agentActivityDirectory: root,
            agentActivityScanObserver: {
                guard publishDuringScan else { return }
                // The tracker publishes after the scan took its `now`.
                Thread.sleep(forTimeInterval: 0.02)
                let published = Date()
                var activity = self.snapshot(at: published)
                activity.copilotSessionId = "copilot-session"
                activity.conversationEpoch = "epoch"
                activity.operationReceiptVersion = 1
                activity.workflow = RemoteSessionWorkflow(
                    observedAtMilliseconds: Int64(published.timeIntervalSince1970 * 1_000),
                    capabilities: [RemoteSessionActionKind.send.rawValue],
                    sendReady: true
                )
                try? JSONEncoder().encode(activity).write(to: path, options: .atomic)
            }
        )
        publishDuringScan = true
        model.refreshAgentActivitySnapshots()
        XCTAssertNotNil(model.projects[0].sessions[0].agentActivity)
        let remote = model.remoteWorkspaceSnapshot().projects[0].sessions[0]
        XCTAssertEqual(remote.operationSupport, .receipts)
        XCTAssertNotNil(remote.workflow)
    }

    func testOperationReadJudgesSnapshotPublishedAfterTheCallerTookTheTime() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionId = UUID().uuidString
        let path = root.appendingPathComponent("\(sessionId).agent-activity.json")
        func publish(generation: Int) {
            var activity = snapshot(at: Date())
            activity.idleGeneration = generation
            try? JSONEncoder().encode(activity).write(to: path, options: .atomic)
        }
        let requestTime = Date()
        let clock = advancingClock(from: requestTime)
        // The tracker publishes between the request taking the time and the read.
        Thread.sleep(forTimeInterval: 0.02)
        publish(generation: 1)
        let adapter = CLIOperationAdapter(activityDirectory: root, resumeMarkerDirectory: root)
        // The clock is consulted only after the read, so a publish from inside
        // it can't be the snapshot that was read.
        let loaded = adapter.loadFreshSnapshot(sessionId: sessionId, now: {
            publish(generation: 2)
            return clock()
        })
        XCTAssertEqual(loaded?.idleGeneration, 1)
        XCTAssertNil(adapter.loadFreshSnapshot(sessionId: sessionId, now: { requestTime }))
    }

    @MainActor
    func testActivityScanPublishesOneBatchAndDoesNotSuppressCausalChanges() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = [Session(title: "one", cwd: root.path), Session(title: "two", cwd: root.path)]
        let project = Project(name: "batch", cwd: root.path, sessions: sessions)
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(projects: [project], selectedProjectId: project.id))
        let model = AppModel(stateRepository: repository, agentActivityDirectory: root)
        let now = Date()
        var activity = snapshot(at: now)
        func writeSnapshots() throws {
            for session in sessions {
                try JSONEncoder().encode(activity).write(
                    to: root.appendingPathComponent("\(session.id).agent-activity.json"), options: .atomic
                )
            }
        }
        try writeSnapshots()
        var publications = 0
        let observation = model.objectWillChange.sink { publications += 1 }
        defer { withExtendedLifetime(observation) {} }
        model.refreshAgentActivitySnapshots(now: now)
        XCTAssertEqual(publications, 1)
        activity.foregroundTransitionAt = now.addingTimeInterval(1).ISO8601Format(.iso8601IncludingFractionalSeconds)
        try writeSnapshots()
        model.refreshAgentActivitySnapshots(now: now)
        XCTAssertEqual(publications, 2)
        XCTAssertEqual(model.projects[0].sessions[1].agentActivity?.foregroundTransitionAt, activity.foregroundTransitionAt)
        activity.trackedUserInputs = [TrackedUserInput(
            requestId: "question", question: "Which?", choices: ["one", "two"],
            allowFreeform: false, requestedAt: activity.updatedAt, agentId: nil
        )]
        try writeSnapshots()
        model.refreshAgentActivitySnapshots(now: now)
        XCTAssertEqual(publications, 3)
        XCTAssertTrue(model.projects[0].sessions[1].hasPendingQuestions)
        try FileManager.default.removeItem(at: root.appendingPathComponent("\(sessions[0].id).agent-activity.json"))
        model.refreshAgentActivitySnapshots(now: now)
        XCTAssertEqual(publications, 4)
        XCTAssertNil(model.projects[0].sessions[0].agentActivity)
        XCTAssertNotNil(model.projects[0].sessions[1].agentActivity)
    }

    @MainActor
    func testRuntimeReconciliationCoalescesPublicationsAndSkipsNoOpStatusUpdates() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = [Session(title: "one", cwd: root.path), Session(title: "two", cwd: root.path)]
        defer {
            for session in sessions {
                SessionArtifacts.removeFiles(sessionId: session.id)
            }
        }
        let project = Project(
            name: "runtime",
            cwd: root.path,
            sessions: sessions,
            selectedSessionId: sessions[0].id
        )
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(projects: [project], selectedProjectId: project.id))
        for session in sessions {
            try Data("copilot-\(session.id)".utf8).write(
                to: root.appendingPathComponent("\(session.id).copilot-session"),
                options: .atomic
            )
        }
        let model = AppModel(
            stateRepository: repository,
            isAppActive: { false },
            agentActivityDirectory: root,
            resumeMarkerDirectory: root
        )
        let base = Date()
        let baseMs = Int64(base.timeIntervalSince1970 * 1_000)

        func writeRuntimeSnapshots(
            at date: Date,
            processing: Bool,
            observedAtMs: Int64,
            sessionIdleAtMs: Int64? = nil
        ) throws {
            for session in sessions {
                var activity = snapshot(at: date)
                activity.copilotSessionId = "copilot-\(session.id)"
                activity.conversationEpoch = "epoch-1"
                activity.foregroundTurnActive = processing
                activity.runtimeActivity = RuntimeActivitySnapshot(
                    processing: processing,
                    observedAtMilliseconds: observedAtMs,
                    idleAtMilliseconds: processing ? nil : observedAtMs,
                    error: nil
                )
                activity.sessionIdleAtMilliseconds = sessionIdleAtMs
                try JSONEncoder().encode(activity).write(
                    to: root.appendingPathComponent("\(session.id).agent-activity.json"),
                    options: .atomic
                )
            }
        }

        var publications = 0
        let observation = model.objectWillChange.sink { publications += 1 }
        defer { withExtendedLifetime(observation) {} }

        // Both sessions flip idle -> running via runtimeActivity in one scan:
        // applyAgentActivityReads + reconcileRuntimeActivity must publish once total.
        try writeRuntimeSnapshots(at: base, processing: true, observedAtMs: baseMs)
        model.refreshAgentActivitySnapshots(now: base)
        XCTAssertEqual(publications, 1)
        XCTAssertEqual(model.projects[0].sessions[0].status, .running)
        XCTAssertEqual(model.projects[0].sessions[1].status, .running)
        XCTAssertTrue(model.projects[0].sessions[0].statusIsRuntimeDerived)

        // A hook that reports the already-current status with nil text is a no-op
        // for UI state: it clears statusIsRuntimeDerived without publishing.
        model.setStatus(
            sessionId: sessions[0].id,
            status: .running,
            text: nil,
            timestamp: baseMs + 10
        )
        XCTAssertEqual(publications, 1)
        XCTAssertFalse(model.projects[0].sessions[0].statusIsRuntimeDerived)

        // Arm session 0 with backgroundAgentsActive + a deferred completion, while
        // session 1 remains running. Finishing both in one scan exercises
        // applyAgentActivityReads + reconcileRuntimeActivity + setBackgroundAgentsActive
        // + postCompletionIfReady + postNotification and must publish once total.
        model.setBackgroundAgentsActive(sessionId: sessions[0].id, active: true)
        model.setStatus(
            sessionId: sessions[0].id,
            status: .idle,
            text: nil,
            timestamp: baseMs + 20,
            source: "agent-stop",
            notification: .completed
        )
        XCTAssertFalse(model.projects[0].sessions[0].turnCompleted)
        XCTAssertEqual(model.projects[0].sessions[1].status, .running)

        let beforeFinish = publications
        let finishDate = base.addingTimeInterval(1)
        let finishMs = baseMs + 1_000
        try writeRuntimeSnapshots(
            at: finishDate,
            processing: false,
            observedAtMs: finishMs,
            sessionIdleAtMs: finishMs
        )
        model.refreshAgentActivitySnapshots(now: finishDate)
        XCTAssertEqual(publications, beforeFinish + 1)
        XCTAssertEqual(model.projects[0].sessions[0].status, .idle)
        XCTAssertFalse(model.projects[0].sessions[0].backgroundAgentsActive)
        XCTAssertTrue(model.projects[0].sessions[0].turnCompleted)
        XCTAssertTrue(model.projects[0].sessions[0].finishedUnseen)
        XCTAssertEqual(model.projects[0].sessions[1].status, .idle)
    }

    func testProjectRowAndSessionRowEquatableScopeInvalidationToRenderedFields() {
        var first = Session(id: "s-1", title: "Alpha", cwd: "/tmp")
        var second = Session(id: "s-2", title: "Beta", cwd: "/tmp")
        let now = Date(timeIntervalSince1970: 1_787_865_600)
        var firstActivity = snapshot(at: now)
        firstActivity.currentIntent = "Inspecting files"
        firstActivity.activeSubagents = [
            TrackedSubagent(id: "sub-1", name: "explore", description: "Search", model: nil)
        ]
        first.agentActivity = firstActivity

        var updatedFirst = first
        var updatedActivity = firstActivity
        updatedActivity.updatedAt = now.addingTimeInterval(5).ISO8601Format(.iso8601IncludingFractionalSeconds)
        updatedActivity.foregroundTransitionAt = updatedActivity.updatedAt
        updatedActivity.currentIntent = "Still inspecting"
        updatedActivity.idleGeneration = 2
        updatedActivity.model = TrackedModel(name: "gpt-6.1-sol", reasoningEffort: "high", contextTier: nil)
        updatedActivity.activeSubagents.append(
            TrackedSubagent(id: "sub-2", name: "review", description: "Check", model: nil)
        )
        updatedFirst.agentActivity = updatedActivity

        let rowA = SessionRow(
            session: first, isActive: true, number: 1, showNumber: false, onSelect: {}, onClose: {}
        )
        let rowB = SessionRow(
            session: updatedFirst, isActive: true, number: 1, showNumber: false, onSelect: {}, onClose: {}
        )
        XCTAssertEqual(rowA, rowB)
        XCTAssertEqual(SessionStateIndicator(session: first), SessionStateIndicator(session: updatedFirst))

        var runningFirst = updatedFirst
        runningFirst.status = .running
        let rowRunning = SessionRow(
            session: runningFirst, isActive: true, number: 1, showNumber: false, onSelect: {}, onClose: {}
        )
        XCTAssertNotEqual(rowA, rowRunning)
        XCTAssertNotEqual(SessionStateIndicator(session: first), SessionStateIndicator(session: runningFirst))

        let projectA = Project(
            id: "p-1", name: "Repo", cwd: "/tmp",
            sessions: [first, second], selectedSessionId: first.id
        )
        let projectSelectionChanged = Project(
            id: "p-1", name: "Repo", cwd: "/tmp",
            sessions: [updatedFirst, second], selectedSessionId: second.id
        )
        XCTAssertEqual(
            ProjectRow(project: projectA, number: 1, showNumber: false, isDropTarget: false),
            ProjectRow(project: projectSelectionChanged, number: 1, showNumber: false, isDropTarget: false)
        )

        let projectWithRunning = Project(
            id: "p-1", name: "Repo", cwd: "/tmp",
            sessions: [runningFirst, second], selectedSessionId: first.id
        )
        XCTAssertNotEqual(
            ProjectRow(project: projectA, number: 1, showNumber: false, isDropTarget: false),
            ProjectRow(project: projectWithRunning, number: 1, showNumber: false, isDropTarget: false)
        )
    }

    func testSessionStateIndicatorSymbolNamesReflectDisplayStatusAndAttention() {
        var session = Session(id: "s-1", title: "Alpha", cwd: "/tmp")
        XCTAssertEqual(SessionStateIndicator.symbolName(for: session), "terminal.fill")

        session.finishedUnseen = true
        XCTAssertEqual(SessionStateIndicator.symbolName(for: session), "checkmark.circle.fill")

        var failedActivity = snapshot(at: Date(timeIntervalSince1970: 1_787_865_600))
        failedActivity.lastTurnError = TrackedTurnError(message: "Request timed out")
        session.agentActivity = failedActivity
        XCTAssertEqual(SessionStateIndicator.symbolName(for: session), "exclamationmark.triangle.fill")

        session.status = .waiting
        XCTAssertEqual(SessionStateIndicator.symbolName(for: session), "questionmark.bubble.fill")

        session.status = .running
        XCTAssertEqual(SessionStateIndicator.symbolName(for: session), "waveform")

        var pendingQuestionActivity = failedActivity
        pendingQuestionActivity.trackedUserInputs = [
            TrackedUserInput(
                requestId: "q-1", question: "Proceed?", choices: ["Yes", "No"],
                allowFreeform: false, requestedAt: pendingQuestionActivity.updatedAt, agentId: nil
            )
        ]
        session.agentActivity = pendingQuestionActivity
        XCTAssertEqual(SessionStateIndicator.symbolName(for: session), "questionmark.bubble.fill")
    }
}

private extension Date.ISO8601FormatStyle {
    static var iso8601IncludingFractionalSeconds: Self {
        Self(includingFractionalSeconds: true)
    }
}
