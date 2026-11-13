import XCTest
import AppKit
import CopilotProjectsCore
import CopilotProjectsProtocol
import Combine
@testable import CopilotProjectsHost

final class ForegroundActivityTests: XCTestCase {
    @MainActor
    private final class Fixture {
        let root: URL
        let directory: URL
        let owner: String
        let epoch = "\(UUID().uuidString.lowercased()):0"
        let session: Session
        let repository: StateRepository
        let model: AppModel
        let base = Date().addingTimeInterval(-1)

        var baseMs: Int64 { Int64(base.timeIntervalSince1970 * 1_000) }
        var snapshotURL: URL {
            directory.appendingPathComponent("\(session.id).agent-activity.json")
        }
        /// Whether the workspace snapshot tells remote clients this session can take a message.
        var promptable: Bool {
            model.remoteWorkspaceSnapshot().projects[0].sessions[0].promptable == true
        }

        init() throws {
            _ = NSApplication.shared
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            directory = root.appendingPathComponent("sessions", isDirectory: true)
            owner = UUID().uuidString.lowercased()
            session = Session(title: "activity", cwd: root.path)
            repository = StateRepository(path: root.appendingPathComponent("state.json"))
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(owner.utf8).write(
                to: directory.appendingPathComponent("\(session.id).copilot-session"))
            try repository.save(PersistedState(
                projects: [Project(name: "activity", cwd: root.path, sessions: [session])],
                selectedProjectId: nil))
            let sid = session.id
            model = AppModel(
                stateRepository: repository,
                isAppActive: { false },
                agentActivityDirectory: directory,
                resumeMarkerDirectory: directory,
                remotePromptLiveSessions: { _ in [sid] }
            )
        }

        func snapshot(processing: Bool = false, background: Bool = true) -> AgentActivitySnapshot {
            AgentActivitySnapshot(
                schemaVersion: 1,
                updatedAt: base.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)),
                foregroundTurnActive: processing,
                foregroundTransitionAt: base.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)),
                scheduledTurnActive: false,
                activeSubagents: background
                    ? [TrackedSubagent(id: session.id, name: "worker", description: "", model: nil)]
                    : [],
                schedules: [],
                idleGeneration: 1, lastIdleAborted: false, lastIdleTurnKind: nil, error: nil,
                trackedUserInputs: [], trackedElicitations: [], pendingPermissionRequestIds: [],
                copilotSessionId: owner, conversationEpoch: epoch,
                runtimeActivity: RuntimeActivitySnapshot(
                    processing: processing,
                    observedAtMilliseconds: baseMs, idleAtMilliseconds: nil, error: nil)
            )
        }

        func publish(_ snapshot: AgentActivitySnapshot, now: Date = Date()) throws {
            try JSONEncoder().encode(snapshot).write(to: snapshotURL, options: .atomic)
            model.refreshAgentActivitySnapshots(now: now)
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    @MainActor
    func testRemoteActivityTextTracksLiveSnapshotsWithoutChangingNativeStatus() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        var snapshot = fixture.snapshot(processing: true)
        snapshot.currentIntent = "Running tests"
        try fixture.publish(snapshot)
        var remote = fixture.model.remoteWorkspaceSnapshot()
        XCTAssertTrue(remote.protocolInfo?.supports("session-activity-text") == true)
        XCTAssertEqual(remote.projects[0].sessions[0].statusText, "Running tests")
        snapshot.currentIntent = "Reviewing results"
        try fixture.publish(snapshot)
        XCTAssertEqual(fixture.model.remoteWorkspaceSnapshot().projects[0].sessions[0].statusText, "Reviewing results")

        snapshot = fixture.snapshot(processing: false)
        snapshot.currentIntent = "Waiting for background agents"
        try fixture.publish(snapshot)
        remote = fixture.model.remoteWorkspaceSnapshot()
        XCTAssertTrue(remote.projects[0].sessions[0].background)
        XCTAssertEqual(remote.projects[0].sessions[0].statusText, "Waiting for background agents")

        snapshot = fixture.snapshot(processing: false, background: false)
        snapshot.currentIntent = "Stale completed work"
        try fixture.publish(snapshot)
        XCTAssertNil(fixture.model.remoteWorkspaceSnapshot().projects[0].sessions[0].statusText)
    }

    @MainActor
    func testRemoteActivityTextRejectsStaleDisconnectedAndUnrelatedSnapshots() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        for invalid in ["stale", "owner", "disconnect", "missing", "blank"] {
            var snapshot = fixture.snapshot(processing: true)
            snapshot.currentIntent = "Running tests"
            switch invalid {
            case "stale": snapshot.updatedAt = Date.distantPast.ISO8601Format()
            case "owner": snapshot.copilotSessionId = UUID().uuidString
            case "disconnect": snapshot.error = "Connection is closed."
            case "missing": snapshot.currentIntent = nil
            default: snapshot.currentIntent = " \n "
            }
            try fixture.publish(snapshot)
            XCTAssertNil(fixture.model.remoteWorkspaceSnapshot().projects[0].sessions[0].statusText, invalid)
        }
    }

    @MainActor
    func testRemoteActivityDoesNotReplacePermissionWaitWithBackgroundBlurb() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        var snapshot = fixture.snapshot(processing: true)
        snapshot.currentIntent = "Running tests"
        snapshot.pendingPermissionRequestIds = ["permission"]
        try fixture.publish(snapshot)
        let remote = fixture.model.remoteWorkspaceSnapshot().projects[0].sessions[0]
        XCTAssertEqual(remote.status, "waiting")
        XCTAssertTrue(remote.background)
        XCTAssertNil(remote.statusText)
    }

    func testStrictFooterRequiresCopilotLayout() {
        for shellLine in [
            "zsh ~/working %",
            "~/src % echo esc cancel",
            "% echo press esc to interrupt",
            "~/src % echo esc stop agents",
            "% echo tab next tab",
            "% cat notes # issues and @ files",
        ] {
            XCTAssertEqual(TerminalController.classifyCopilotFooterRows([shellLine]), .unknown, shellLine)
        }
        let cases: [([String], FooterActivity)] = [
            (["◎ Working   esc cancel"], .working),
            (["◎ Working   esc cancel  ┃"], .working),
            (["/ commands · ? help · tab next tab"], .idle),
            (["/ commands · ? help · tab next tab┃"], .idle),
            (["/ commands · ? help · GPT-6 Astra"], .idle),
            (["autopilot · / commands · GPT-6 Astra"], .idle),
            (["autopilot (limited) · / commands · GPT-6 Astra"], .idle),
            (["ctrl+q enqueue · @ files · # issues · GPT-6 Astra"], .idle),
            (["esc again to stop agents · GPT-6 Astra"], .idle),
            (["/ commands · ? help · esc cancel"], .working),
            (["autopilot · / commands · esc to interrupt"], .working),
            (["@ files · # issues · esc again to cancel"], .working),
            (["esc again to interrupt · GPT-6 Astra"], .working),
            (["autopilot · / commands", "esc cancel"], .working),
            (["◎ Working   esc cancel", "ctrl+q enqueue · @ files · # issues"], .working),
            (["keep working on this", "@ files · # issues"], .idle),
            (["esc cancel", "model picker"], .unknown),
        ]
        for (rows, expected) in cases {
            XCTAssertEqual(TerminalController.classifyCopilotFooterRows(rows), expected, "\(rows)")
        }
    }

    func testStrictFooterRecognizesDraftAndModelColumns() {
        let cases: [([String], FooterActivity)] = [
            (["Autopilot · Allow All    GPT-6.1 Sol · Max"], .idle),
            (["Autopilot · Allow All GPT-6.1 Sol · Max"], .idle),
            (["Autopilot (limited) · Manual Approval    GPT-6.1 Sol"], .idle),
            (["Plan · Assisted Permissions    GPT-6.1 Sol"], .idle),
            (["Shell · Manual Approval    GPT-6.1 Sol"], .idle),
            (["Interactive · Manual Approval · @ files · # issues    GPT-6.1 Sol"], .idle),
            (["@ files · # issues    GPT-6.1 Sol · Max┃"], .idle),
            (["@ files · # issues GPT-6.1 Sol · Max"], .idle),
            (["/ commands · ? help · tab next tab    GPT-6.1 Sol"], .idle),
            (["◎ Working   esc cancel    GPT-6.1 Sol · Max"], .working),
            (["◎ Working   esc cancel GPT-6.1 Sol · Max"], .working),
            (["◎ Working esc esc interrupt    GPT-6.1 Sol · Max"], .working),
            (["◎ Running tests esc esc interrupt · ctrl+q enqueue    GPT-6.1 Sol"], .working),
            (["◎ Running tests ctrl+c interrupt · ctrl+q enqueue GPT-6.1 Sol"], .working),
            (["◎ Working · 1.2 KB esc esc interrupt · enter enqueue GPT-6.1 Sol"], .working),
            (["-- INSERT -- · ◎ Running tests esc again to cancel GPT-6.1 Sol"], .working),
            (["esc to interrupt    GPT-6.1 Sol"], .working),
            (["esc again to clear input"], .idle),
            (["esc again to rewind GPT-6.1 Sol"], .idle),
            (["esc again to edit prompt GPT-6.1 Sol"], .idle),
            (["esc cancel", "Autopilot · Allow All    GPT-6.1 Sol"], .working),
            (["Autopilot · Allow All    GPT-6.1 Sol", "model picker"], .unknown),
            (["~/src % echo Autopilot · Allow All    GPT-6.1 Sol"], .unknown),
            (["~/src % echo @ files · # issues    GPT-6.1 Sol"], .unknown),
            (["~/src % echo working esc cancel    GPT-6.1 Sol"], .unknown),
            (["~/src % echo ◎ Running tests esc esc interrupt · ctrl+q enqueue"], .unknown),
            (["❯ echo esc cancel"], .unknown),
            (["➜  src git:(main) ✗ echo ctrl+c interrupt"], .unknown),
            (["Autopilot settings · Allow All"], .unknown),
            (["Autopilot · Allow Almost"], .unknown),
            (["esc cancel    doesn't work", "@ files · # issues"], .idle),
        ]
        for (rows, expected) in cases {
            XCTAssertEqual(TerminalController.classifyCopilotFooterRows(rows), expected, "\(rows)")
        }
        for spinner in ["∙", "∘", "●", "◉", "◎", "○"] {
            XCTAssertEqual(TerminalController.classifyCopilotFooterRows([
                "\(spinner) Running tests esc esc interrupt · ctrl+q enqueue GPT-6.1 Sol",
            ]), .working, spinner)
        }
    }

    /// The tracker reports turn starts and ends. With about 20 busy sessions, saving
    /// each one kept state.json over macOS's disk-write limit on Nov 10.
    @MainActor
    func testRuntimeDetectedTurnsDoNotWriteWorkspaceState() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let session = { fixture.model.projects[0].sessions[0] }
        func stateFile() throws -> NSNumber? {
            fixture.model.flushScheduledSaveForTesting()
            return try FileManager.default.attributesOfItem(atPath: fixture.repository.path.path)[.systemFileNumber]
                as? NSNumber
        }
        let untouched = try stateFile()
        // The snapshots carry the fixture's time, so the scans are judged at it too.
        let now = fixture.base.addingTimeInterval(1)

        var working = fixture.snapshot(processing: true, background: false)
        try fixture.publish(working, now: now)
        let firstStart = try XCTUnwrap(session().runningStartedAtMilliseconds)
        // The next scan records which request the start belongs to.
        working.currentIntent = "Running tests"
        try fixture.publish(working, now: now)
        XCTAssertNotNil(session().runningRequestIdentity)
        XCTAssertEqual(try stateFile(), untouched)

        // A new request with no idle between restarts the timer.
        working.idleGeneration += 1
        working.foregroundTransitionAt = fixture.base.addingTimeInterval(0.25)
            .formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        try fixture.publish(working, now: now)
        let start = try XCTUnwrap(session().runningStartedAtMilliseconds)
        XCTAssertGreaterThan(start, firstStart)
        XCTAssertEqual(try stateFile(), untouched)

        // Quitting saves the timer, and a relaunch keeps the turn's start for the request
        // a live tracker still shows on disk.
        fixture.model.save()
        let relaunched = AppModel(
            stateRepository: fixture.repository,
            isAppActive: { false },
            agentActivityDirectory: fixture.directory,
            resumeMarkerDirectory: fixture.directory)
        XCTAssertEqual(relaunched.projects[0].sessions[0].runningStartedAtMilliseconds, start)

        let saved = try stateFile()
        try fixture.publish(fixture.snapshot(background: false), now: now)
        XCTAssertEqual(session().status, .idle)
        XCTAssertNil(session().runningStartedAtMilliseconds)
        XCTAssertEqual(try stateFile(), saved)
    }

    @MainActor
    func testRuntimeLossDoesNotBecomeLegacyIdle() throws {
        for restarting in [false, true] {
            let fixture = try Fixture()
            defer { fixture.cleanup() }
            var snapshot = fixture.snapshot()
            snapshot.workflow = RemoteSessionWorkflow(
                observedAtMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000),
                capabilities: [], sendReady: false, restartRequested: restarting
            )
            try fixture.publish(snapshot)
            try FileManager.default.removeItem(at: fixture.snapshotURL)
            fixture.model.refreshAgentActivitySnapshots()
            XCTAssertFalse(fixture.promptable)
        }
    }

    @MainActor
    func testLegacyTrackerStaysPromptable() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        var snapshot = fixture.snapshot()
        snapshot.runtimeActivity = nil
        try fixture.publish(snapshot)
        XCTAssertTrue(fixture.promptable)
    }

    @MainActor
    func testExplicitUnsupportedRuntimeStaysPromptable() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        var snapshot = fixture.snapshot()
        snapshot.runtimeActivity?.error = "unsupported"
        snapshot.runtimeActivity?.processing = nil
        try fixture.publish(snapshot)
        XCTAssertTrue(fixture.promptable)
    }

    @MainActor
    func testScheduledCoordinatorStillBlocksSendingWhileProcessing() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        var snapshot = fixture.snapshot(processing: true)
        snapshot.scheduledTurnActive = true
        try fixture.publish(snapshot)
        XCTAssertEqual(fixture.model.projects[0].sessions[0].status, .idle)
        XCTAssertTrue(fixture.model.projects[0].sessions[0].hasBackgroundWork)
        XCTAssertFalse(fixture.promptable)
    }

    @MainActor
    func testUnchangedRuntimeObservationUpdatesFreshnessWithoutRedrawingProjects() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        var snapshot = fixture.snapshot()
        try fixture.publish(snapshot)
        var updates = 0
        let subscription = fixture.model.objectWillChange.sink { updates += 1 }
        defer { subscription.cancel() }
        snapshot.updatedAt = Date().formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        snapshot.runtimeActivity?.observedAtMilliseconds = fixture.baseMs + 100
        try fixture.publish(snapshot)
        XCTAssertEqual(updates, 0)
        XCTAssertEqual(
            fixture.model.projects[0].sessions[0].agentActivity?.runtimeActivity?.observedAtMilliseconds,
            fixture.baseMs + 100)
    }

    @MainActor
    func testADisconnectedTrackerIsIdleAndCannotAdmitInput() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        var snapshot = fixture.snapshot(processing: true)
        try fixture.publish(snapshot)
        XCTAssertEqual(fixture.model.projects[0].sessions[0].status, .running)
        snapshot.error = "Connection is closed."
        snapshot.runtimeActivity?.error = snapshot.error
        snapshot.runtimeActivity?.processing = nil
        try fixture.publish(snapshot)
        XCTAssertEqual(fixture.model.projects[0].sessions[0].status, .idle)
        XCTAssertFalse(fixture.promptable, "not ready")
    }
}
