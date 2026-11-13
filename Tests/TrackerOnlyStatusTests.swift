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

    func testAnUnusableReadingHoldsTheLastStatusAndOnlyAGoneTrackerIsIdle() {
        let now = Date()
        func result(
            _ snapshot: AgentActivitySnapshot?, held: SessionStatus = .running, gone: Bool = false
        ) -> String {
            let tracker = AppModel.trackerOnly(snapshot, held: held, gone: gone, now: now)
            return "\(tracker.state) \(tracker.status.rawValue) \(tracker.sendReady ? "ready" : "busy")"
        }
        // A usable reading decides, whatever was held.
        XCTAssertEqual(result(.tracker(processing: true, at: now), held: .idle), "alive running busy")
        XCTAssertEqual(result(.tracker(processing: false, at: now)), "alive idle ready")
        XCTAssertEqual(
            result(.tracker(processing: false, permissions: ["permission"], at: now)),
            "alive idle busy", "a pending question blocks a send")
        XCTAssertEqual(
            result(.tracker(processing: true, scheduled: true, at: now)),
            "alive idle busy", "a scheduled turn shows as idle but takes no prompt")
        XCTAssertEqual(
            result(.tracker(processing: nil, turn: true, at: now), held: .idle),
            "alive running busy", "on a CLI without isProcessing, turn events decide")

        // A stale heartbeat, a stale observation and a withdrawn reading all hold.
        XCTAssertEqual(result(.tracker(processing: false, age: 60, at: now)), "held running busy")
        XCTAssertEqual(result(nil, held: .waiting), "held waiting busy")
        var stale = AgentActivitySnapshot.tracker(processing: false, at: now)
        stale.runtimeActivity?.observedAtMilliseconds = Int64(now.timeIntervalSince1970 * 1_000) - 20_000
        XCTAssertEqual(result(stale), "held running busy")
        var withdrawn = AgentActivitySnapshot.tracker(processing: false, turn: true, at: now)
        withdrawn.runtimeActivity = RuntimeActivitySnapshot(
            processing: nil, observedAtMilliseconds: nil, idleAtMilliseconds: nil, error: "pending")
        XCTAssertEqual(
            result(withdrawn, held: .idle), "held idle busy",
            "turn events do not stand in for a reading the tracker withdrew")

        // Gone: the caller saw the process exit or the 45 s warning, or the connection closed.
        XCTAssertEqual(result(nil, gone: true), "gone idle busy")
        XCTAssertEqual(result(.tracker(processing: false, age: 60, at: now), gone: true), "gone idle busy")
        XCTAssertEqual(
            result(.tracker(processing: true, error: "Connection is closed.", at: now)), "gone idle busy")
        XCTAssertEqual(
            result(.tracker(processing: true, at: now), gone: true), "alive running busy",
            "a usable reading outranks a process list that is seconds old")
    }

    /// The shadow run compared send-readiness only where the footer was read, so
    /// this covers where the tracker's own reading decides.
    func testASendIsOfferedOnlyOnTheTrackersOwnIdleReading() throws {
        let tab = try makeTab()
        func promptable(at now: Date) -> Bool {
            tab.model.remoteWorkspaceSnapshot(now: now).projects[0].sessions[0].promptable == true
        }

        // A live Copilot with no tracker takes no send, though its status is idle.
        XCTAssertEqual(tab.session.status, .idle)
        XCTAssertFalse(tab.promptable)

        // An idle reading is enough. No footer is read, and the process list, which
        // is seconds old, need not have the session yet.
        tab.model.setLiveAgentSessionsForTesting([])
        try tab.publish(.tracker(processing: false, at: tab.now))
        XCTAssertTrue(tab.promptable)
        var background = AgentActivitySnapshot.tracker(processing: false, at: tab.now)
        background.activeSubagents = [
            TrackedSubagent(id: "agent", name: "reviewer", description: "", model: nil)
        ]
        try tab.publish(background)
        XCTAssertTrue(tab.promptable, "a background agent does not make an idle coordinator busy")

        try tab.publish(.tracker(processing: false, permissions: ["permission"], at: tab.now))
        XCTAssertFalse(tab.promptable, "pending input")
        try tab.publish(.tracker(processing: true, at: tab.now))
        XCTAssertFalse(tab.promptable, "a working reading")
        try tab.publish(.tracker(processing: true, scheduled: true, at: tab.now))
        XCTAssertFalse(tab.promptable, "a scheduled turn")
        var withdrawn = AgentActivitySnapshot.tracker(processing: false, at: tab.now)
        withdrawn.runtimeActivity = RuntimeActivitySnapshot(
            processing: nil, observedAtMilliseconds: nil, idleAtMilliseconds: nil, error: "pending")
        try tab.publish(withdrawn)
        XCTAssertFalse(tab.promptable, "a reading the tracker withdrew as a turn began")

        try tab.publish(.tracker(processing: false, at: tab.now))
        XCTAssertTrue(tab.promptable)
        XCTAssertFalse(promptable(at: tab.now.addingTimeInterval(16)), "a reading older than 15 s")

        // Another Copilot owns the tab now, so that snapshot no longer speaks for it.
        try tab.publish(.tracker(processing: false, at: tab.now), tabOwner: UUID().uuidString)
        XCTAssertFalse(tab.promptable)
    }

    // MARK: - Replays of what the Nov 11 and Nov 12 shadow runs recorded

    @MainActor
    private final class AlertSpy: NotificationPosting {
        var events: [NotificationEvent] = []
        var onPost: ((NotificationEvent) -> Void)?
        func post(_ event: NotificationEvent) {
            events.append(event)
            onPost?(event)
        }
    }

    /// One session in a background app, with its Copilot in the process list.
    @MainActor
    private struct Tab {
        let model: AppModel
        let sid: String
        let alerts: AlertSpy
        /// Every snapshot carries this one time, so no turn has a span to summarize
        /// and its Finished alert posts without a transcript read.
        let now: Date

        var session: Session { model.projects[0].sessions[0] }
        var label: String { session.attentionLabel }
        var promptable: Bool {
            model.remoteWorkspaceSnapshot(now: now).projects[0].sessions[0].promptable == true
        }

        func publish(_ snapshot: AgentActivitySnapshot, tabOwner: String? = nil) throws {
            try model.publishTracker(snapshot, sessionId: sid, tabOwner: tabOwner, now: now)
        }

        /// What a turn's end does once its wait for the background-agent title is over.
        func completeIfReady() { model.postCompletionIfReady(sessionId: sid) }
    }

    private func makeTab(
        permissionDelay: UInt64 = 1_000_000, others: [Session] = []
    ) throws -> Tab {
        let session = Session(title: "tracker", cwd: root.path)
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(
            projects: [Project(name: "tracker", cwd: root.path, sessions: [session] + others)],
            selectedProjectId: nil))
        let model = AppModel(
            stateRepository: repository,
            completionNotificationDelayNanoseconds: 5_000_000,
            permissionNotificationDelayNanoseconds: permissionDelay,
            elicitationReplyRetryDelaysNanoseconds: [],
            isAppActive: { false },
            agentActivityDirectory: root, resumeMarkerDirectory: root
        )
        model.setLiveAgentSessionsForTesting(Set(([session] + others).map(\.id)))
        let alerts = AlertSpy()
        model.attach(notifications: alerts)
        return Tab(model: model, sid: session.id, alerts: alerts, now: Date())
    }

    /// E20681F3 on Nov 12, at 04:33Z and 18:09Z: a schedule's message landed in a
    /// foreground turn.
    func testAScheduledMessageMidTurnShowsIdleAndPostsNoFinishedAlert() throws {
        let tab = try makeTab()
        try tab.publish(.tracker(processing: true, at: tab.now))
        XCTAssertEqual(tab.label, "Running")
        XCTAssertNotNil(tab.session.effectiveRunningStartedAtMilliseconds)

        try tab.publish(.tracker(processing: true, scheduled: true, at: tab.now))
        XCTAssertEqual(tab.label, "Idle")
        XCTAssertFalse(tab.promptable)
        XCTAssertNil(tab.session.runningStartedAtMilliseconds)
        var ended = AgentActivitySnapshot.tracker(processing: false, idleGeneration: 2, at: tab.now)
        ended.lastIdleTurnKind = "scheduled"
        try tab.publish(ended)
        tab.completeIfReady()
        XCTAssertEqual(tab.label, "Idle")
        XCTAssertTrue(tab.promptable)
        XCTAssertTrue(tab.alerts.events.isEmpty)

        // That idle describes the scheduled turn only. A foreground turn the tracker
        // ends at its second idle reading has no idle event of its own, and alerts.
        var next = AgentActivitySnapshot.tracker(processing: true, idleGeneration: 2, at: tab.now)
        next.lastIdleTurnKind = "scheduled"
        try tab.publish(next)
        try tab.publish(ended)
        tab.completeIfReady()
        XCTAssertEqual(tab.alerts.events.map(\.kind), [.completed])
        XCTAssertEqual(tab.label, "Finished")
    }

    func testATurnThatEndsWithABackgroundAgentRunningAlertsWhenTheAgentIsDone() throws {
        let tab = try makeTab()
        try tab.publish(.tracker(processing: true, at: tab.now))
        var ended = AgentActivitySnapshot.tracker(processing: false, idleGeneration: 2, at: tab.now)
        ended.activeSubagents = [
            TrackedSubagent(id: "agent", name: "reviewer", description: "", model: nil)
        ]
        try tab.publish(ended)
        tab.completeIfReady()
        XCTAssertEqual(tab.label, "Idle")
        XCTAssertTrue(tab.promptable, "the coordinator takes a prompt while its agent runs")
        XCTAssertTrue(tab.alerts.events.isEmpty)

        // A scan that finds no snapshot cannot see the agent, so the alert waits.
        try tab.model.removeTracker(sessionId: tab.sid, now: tab.now)
        XCTAssertTrue(tab.alerts.events.isEmpty)

        ended.activeSubagents = []
        try tab.publish(ended)
        XCTAssertEqual(tab.alerts.events.map(\.kind), [.completed])
        XCTAssertEqual(tab.label, "Finished")
    }

    /// On Nov 12 five idle readings fell inside a request, for up to 2.5 s.
    func testOneIdleReadingInsideARequestChangesOnlyTheLabel() throws {
        let tab = try makeTab()
        try tab.publish(.tracker(processing: true, at: tab.now))
        let started = try XCTUnwrap(tab.session.runningStartedAtMilliseconds)

        try tab.publish(.tracker(processing: false, turn: true, at: tab.now))
        tab.completeIfReady()
        XCTAssertEqual(tab.label, "Idle")
        XCTAssertEqual(tab.session.runningStartedAtMilliseconds, started)
        try tab.publish(.tracker(processing: true, at: tab.now))
        XCTAssertEqual(tab.session.effectiveRunningStartedAtMilliseconds, started)
        XCTAssertTrue(tab.alerts.events.isEmpty)

        try tab.publish(.tracker(processing: false, idleGeneration: 2, at: tab.now))
        tab.completeIfReady()
        XCTAssertEqual(tab.alerts.events.map(\.kind), [.completed])
    }

    func testAnAbortedTurnLeavesTheDotWithoutAnAlertAndDoesNotSilenceTheNextTurn() throws {
        let tab = try makeTab()
        try tab.publish(.tracker(processing: true, at: tab.now))
        var aborted = AgentActivitySnapshot.tracker(processing: false, idleGeneration: 2, at: tab.now)
        aborted.lastIdleAborted = true
        try tab.publish(aborted)
        tab.completeIfReady()
        XCTAssertEqual(tab.label, "Finished")
        XCTAssertTrue(tab.alerts.events.isEmpty)

        // The next turn ends at the tracker's second idle reading, so the snapshot
        // still carries the abort before it.
        var next = AgentActivitySnapshot.tracker(processing: true, idleGeneration: 2, at: tab.now)
        next.lastIdleAborted = true
        try tab.publish(next)
        XCTAssertEqual(tab.label, "Running")
        try tab.publish(aborted)
        tab.completeIfReady()
        XCTAssertEqual(tab.alerts.events.map(\.kind), [.completed])
    }

    /// The idle the app compares against is the one before the request it is timing.
    func testAQueuedMessageAfterAnAbortedRequestStillAlerts() async throws {
        let tab = try makeTab()
        let finished = expectation(description: "the queued request's Finished alert")
        tab.alerts.onPost = { if $0.kind == .completed { finished.fulfill() } }
        func stamp(_ offset: TimeInterval) -> String {
            tab.now.addingTimeInterval(offset)
                .formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        }
        var first = AgentActivitySnapshot.tracker(processing: true, at: tab.now)
        first.foregroundTransitionAt = stamp(-10)
        try tab.publish(first)

        // The request is aborted and the queued message starts the next one before
        // the app reads a snapshot in between.
        var queued = AgentActivitySnapshot.tracker(processing: true, idleGeneration: 2, at: tab.now)
        queued.lastIdleAborted = true
        queued.foregroundTransitionAt = stamp(-5)
        try tab.publish(queued)
        XCTAssertEqual(tab.session.runningStartedAtMilliseconds, queued.foregroundTransitionMilliseconds)

        // It ends at the tracker's second idle reading, with no idle event of its own.
        var ended = AgentActivitySnapshot.tracker(processing: false, idleGeneration: 2, at: tab.now)
        ended.lastIdleAborted = true
        try tab.publish(ended)
        await fulfillment(of: [finished], timeout: 5)
    }

    /// 8D8F0B8E on Nov 13: a schedule's turn read working for a heartbeat before
    /// its tracker marked it scheduled.
    func testAScheduledTurnThatReadsWorkingBeforeItIsMarkedKeepsTheFinishedDot() throws {
        let tab = try makeTab()
        try tab.model.finishTurn(sessionId: tab.sid)
        XCTAssertEqual(tab.label, "Finished")

        try tab.publish(.tracker(processing: true, turn: false, at: tab.now))
        XCTAssertEqual(tab.label, "Running")
        XCTAssertNil(tab.session.runningStartedAtMilliseconds)
        try tab.publish(.tracker(processing: true, scheduled: true, at: tab.now))
        var ended = AgentActivitySnapshot.tracker(processing: false, idleGeneration: 2, at: tab.now)
        ended.lastIdleTurnKind = "scheduled"
        try tab.publish(ended)
        tab.completeIfReady()
        XCTAssertEqual(tab.label, "Finished")
        XCTAssertEqual(tab.alerts.events.map(\.kind), [.completed], "only the first turn's alert")
    }

    /// 9740ED6E on Nov 12: the hooks still said Waiting after the question was answered.
    func testAnAnsweredQuestionIsRunningAtOnce() throws {
        let tab = try makeTab()
        try tab.publish(.tracker(processing: true, question: "Deploy?", at: tab.now))
        XCTAssertEqual(tab.label, "Waiting for input")
        XCTAssertFalse(tab.promptable)
        XCTAssertEqual(tab.alerts.events.map(\.kind), [.elicitation])

        try tab.publish(.tracker(processing: true, at: tab.now))
        XCTAssertEqual(tab.label, "Running")
        XCTAssertFalse(tab.promptable)
        XCTAssertEqual(tab.alerts.events.count, 1)
    }

    func testAQuestionPendingAtLaunchIsNotAlertedAgain() throws {
        let tab = try makeTab()
        // As launch leaves it until the first scan is applied.
        tab.model.launchScanPending = true
        try tab.publish(.tracker(processing: true, question: "Deploy?", at: tab.now))
        XCTAssertEqual(tab.label, "Waiting for input")
        XCTAssertTrue(tab.alerts.events.isEmpty, "it was asked before the app relaunched")

        try tab.publish(.tracker(processing: true, at: tab.now))
        try tab.publish(.tracker(processing: true, question: "Ship?", at: tab.now))
        XCTAssertEqual(tab.alerts.events.map(\.kind), [.elicitation], "the next wait alerts")
    }

    func testAListedQuestionShowsWaitingUnlessItsTrackerIsGone() throws {
        let tab = try makeTab()
        // The tracker withdrew its reading as the turn began, and lists the question.
        var asking = AgentActivitySnapshot.tracker(processing: true, question: "Deploy?", at: tab.now)
        asking.runtimeActivity = RuntimeActivitySnapshot(
            processing: nil, observedAtMilliseconds: nil, idleAtMilliseconds: nil, error: "pending")
        try tab.publish(asking)
        XCTAssertEqual(tab.label, "Waiting for input")
        XCTAssertFalse(tab.promptable)

        // Another Copilot's snapshot in the tab's file is not read, so that holds.
        try tab.publish(.tracker(processing: false, at: tab.now), tabOwner: UUID().uuidString)
        XCTAssertEqual(tab.label, "Waiting for input")
        XCTAssertFalse(tab.promptable)

        // A tracker that lost its connection keeps republishing a question it can
        // no longer see answered.
        try tab.publish(.tracker(
            processing: true, error: "Connection is closed.", question: "Deploy?", at: tab.now))
        XCTAssertEqual(tab.label, "Idle")
        XCTAssertFalse(tab.promptable)
    }

    func testATrackerThatStopsWritingHoldsItsStatusUntilTheMissingTrackerWarning() throws {
        let tab = try makeTab()
        try tab.publish(.tracker(processing: true, at: tab.now))

        // Its Copilot is still running, so the status holds and no send is offered.
        tab.model.refreshAgentActivitySnapshots(now: tab.now.addingTimeInterval(20))
        XCTAssertEqual(tab.label, "Running")
        XCTAssertFalse(tab.promptable)

        // The warning goes up 45 s later, and the tracker counts as gone. Nothing
        // will say how the turn ended, so it leaves the dot and posts no alert.
        tab.model.refreshAgentActivitySnapshots(now: tab.now.addingTimeInterval(66))
        XCTAssertNotNil(tab.session.trackerWarning)
        XCTAssertEqual(tab.label, "Finished")
        XCTAssertFalse(tab.promptable)
        XCTAssertTrue(tab.alerts.events.isEmpty)
    }

    func testATrackerWhoseCopilotExitsGoesIdle() throws {
        let tab = try makeTab()
        try tab.publish(.tracker(processing: true, at: tab.now))

        // The snapshot goes with the process, a few seconds before the process list
        // shows it gone.
        try tab.model.removeTracker(sessionId: tab.sid, now: tab.now)
        XCTAssertEqual(tab.label, "Running")
        tab.model.setLiveAgentSessionsForTesting([])
        tab.model.reconcileStatus(now: tab.now)
        XCTAssertEqual(tab.label, "Finished")
        XCTAssertFalse(tab.promptable)
        XCTAssertTrue(tab.alerts.events.isEmpty)
    }

    func testWithTheProcessCheckOffAnAbsentProcessIsNotTakenAsGone() throws {
        let key = "COPILOT_PROJECTS_LIVENESS"
        let previous = ProcessInfo.processInfo.environment[key]
        setenv(key, "0", 1)
        defer { if let previous { setenv(key, previous, 1) } else { unsetenv(key) } }
        let tab = try makeTab()
        tab.model.setLiveAgentSessionsForTesting([])
        try tab.publish(.tracker(processing: true, at: tab.now))

        tab.model.refreshAgentActivitySnapshots(now: tab.now.addingTimeInterval(20))
        XCTAssertEqual(tab.label, "Running")
    }

    func testAPermissionPromptAlertsOnceItHasStayedUp() async throws {
        let tab = try makeTab()
        let posted = expectation(description: "permission alert")
        tab.alerts.onPost = { _ in posted.fulfill() }
        try tab.publish(.tracker(processing: true, permissions: ["request"], at: tab.now))
        XCTAssertEqual(tab.label, "Waiting for input")
        XCTAssertTrue(tab.alerts.events.isEmpty, "a prompt approved automatically goes within the delay")

        await fulfillment(of: [posted], timeout: 5)
        XCTAssertEqual(tab.alerts.events.map(\.kind), [.permission])
    }

    func testAPermissionAnsweredBeforeTheNextScanPostsNoAlert() async throws {
        let other = Session(title: "other", cwd: root.path)
        let tab = try makeTab(others: [other])
        let posted = expectation(description: "the other session's alert")
        tab.alerts.onPost = { if $0.sessionId == other.id { posted.fulfill() } }
        try tab.publish(.tracker(processing: true, permissions: ["request"], at: tab.now))
        try tab.model.publishTracker(
            .tracker(processing: true, permissions: ["request"], at: tab.now),
            sessionId: other.id, now: tab.now)

        // The prompt is answered, and the tracker's write has not been scanned yet.
        try JSONEncoder().encode(AgentActivitySnapshot.tracker(processing: true)).write(
            to: root.appendingPathComponent("\(tab.sid).agent-activity.json"), options: .atomic)

        // The other session's prompt was listed later, so its alert posts after this
        // session's delay is over.
        await fulfillment(of: [posted], timeout: 5)
        XCTAssertEqual(tab.alerts.events.map(\.sessionId), [other.id])
    }

    func testAQuestionThatFollowsAnAutoApprovedPermissionAlerts() async throws {
        let tab = try makeTab()
        let posted = expectation(description: "the question's alert")
        tab.alerts.onPost = { _ in posted.fulfill() }
        try tab.publish(.tracker(processing: true, permissions: ["request"], at: tab.now))

        // The permission is approved and a question raised before the next scan,
        // so no scan sees the session stop waiting.
        try tab.publish(.tracker(processing: true, question: "Deploy?", at: tab.now))
        XCTAssertTrue(tab.alerts.events.isEmpty)
        await fulfillment(of: [posted], timeout: 5)
        XCTAssertEqual(tab.alerts.events.map(\.kind), [.elicitation])
    }

    func testAnAutoApprovedPermissionPostsNoAlert() async throws {
        let tab = try makeTab()
        let finished = expectation(description: "the turn's Finished alert")
        tab.alerts.onPost = { if $0.kind == .completed { finished.fulfill() } }
        try tab.publish(.tracker(processing: true, permissions: ["request"], at: tab.now))
        try tab.publish(.tracker(processing: true, at: tab.now))

        // The turn's own alert waits longer than a permission alert does, so by the
        // time it posts the prompt's delay is over.
        try tab.publish(.tracker(processing: false, idleGeneration: 2, at: tab.now))
        await fulfillment(of: [finished], timeout: 5)
        XCTAssertEqual(tab.alerts.events.map(\.kind), [.completed])
    }
}
