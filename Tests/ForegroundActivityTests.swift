import XCTest
import AppKit
import CopilotProjectsCore
import CopilotProjectsProtocol
import Combine
@testable import CopilotProjectsHost

final class ForegroundActivityTests: XCTestCase {
    @MainActor
    private final class Fixture {
        final class Sends {
            var count = 0
            var succeeds = true
            var permissionRestores: [SessionStatusRecord] = []
        }

        let root: URL
        let directory: URL
        let owner: String
        let epoch = "\(UUID().uuidString.lowercased()):0"
        let session: Session
        let repository: StateRepository
        let model: AppModel
        let sends: Sends
        let base = Date().addingTimeInterval(-1)

        var baseMs: Int64 { Int64(base.timeIntervalSince1970 * 1_000) }
        var snapshotURL: URL {
            directory.appendingPathComponent("\(session.id).agent-activity.json")
        }

        init(
            root: URL? = nil, sessionId: String? = nil, owner: String? = nil,
            permissionDelayNanoseconds: UInt64 = 1_000_000_000
        ) throws {
            _ = NSApplication.shared
            let root = root ?? FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            self.root = root
            directory = root.appendingPathComponent("sessions", isDirectory: true)
            self.owner = owner ?? UUID().uuidString.lowercased()
            session = Session(id: sessionId ?? UUID().uuidString, title: "activity", cwd: root.path)
            repository = StateRepository(path: root.appendingPathComponent("state.json"))
            let sends = Sends()
            self.sends = sends
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(self.owner.utf8).write(
                to: directory.appendingPathComponent("\(session.id).copilot-session"))
            try repository.save(PersistedState(
                projects: [Project(name: "activity", cwd: root.path, sessions: [session])],
                selectedProjectId: nil))
            let sid = session.id
            let sessionsDirectory = directory
            model = AppModel(
                stateRepository: repository,
                permissionNotificationDelayNanoseconds: permissionDelayNanoseconds,
                persistPermissionStatus: { sessionId, status, timestamp, promptTimestamp in
                    sends.permissionRestores.append(
                        SessionStatusRecord(
                            status: status, statusTimestamp: timestamp,
                            promptStatusTimestamp: promptTimestamp))
                    XCTAssertTrue(SessionArtifacts.persistStatus(
                        sessionId: sessionId, status: status, timestamp: timestamp,
                        promptStatusTimestamp: promptTimestamp, sessionsDirectory: sessionsDirectory))
                },
                isAppActive: { false },
                agentActivityDirectory: directory,
                resumeMarkerDirectory: directory,
                remotePromptLiveSessions: { _ in [sid] },
                remotePromptTarget: { _ in
                    RemotePromptTarget(activity: .idle, send: { _ in
                        sends.count += 1
                        return sends.succeeds
                    })
                }
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
                    observedAtMilliseconds: baseMs, idleAtMilliseconds: nil, error: nil),
                inputCompletions: [:]
            )
        }

        func publish(_ snapshot: AgentActivitySnapshot, to target: AppModel? = nil) throws {
            try JSONEncoder().encode(snapshot).write(to: snapshotURL, options: .atomic)
            (target ?? model).refreshAgentActivitySnapshots()
        }

        func beginWait(sender: String, timestamp: Int64, kind: StatusNotificationKind? = .permission) throws {
            let record = SessionStatusRecord(
                status: .waiting, statusTimestamp: timestamp, promptStatusTimestamp: timestamp,
                inputWait: InputWaitContext(
                    senderSessionId: sender, rootSessionId: owner, conversationEpoch: epoch))
            try JSONEncoder().encode(record).write(
                to: directory.appendingPathComponent("\(session.id).status-record.json"), options: .atomic)
            model.setStatus(
                sessionId: session.id, status: .waiting, text: nil,
                timestamp: timestamp, copilotSessionId: sender, notification: kind)
        }

        func cleanup() {
            SessionArtifacts.removeFiles(sessionId: session.id)
            try? FileManager.default.removeItem(at: root)
        }
    }

    func testReadyFooterVariantsDoNotBlockRemotePrompts() {
        for footer in [
            "/ commands · ? help · GPT-6 Astra",
            "autopilot · / commands · GPT-6 Astra",
            "autopilot (limited) · / commands · GPT-6 Astra",
            "ctrl+q enqueue · @ files · # issues · GPT-6 Astra",
            "esc again to stop agents · GPT-6 Astra",
        ] {
            let activity = TerminalController.classifyFooter(footer)
            XCTAssertEqual(activity, .idle, footer)
            XCTAssertEqual(AppModel.remotePromptEligibility(
                status: .idle,
                hasLiveAgent: true,
                footerActivity: activity
            ), .sent, footer)
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
        XCTAssertNil(fixture.model.projects[0].sessions[0].statusText)
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
        XCTAssertNil(fixture.model.remoteWorkspaceSnapshot().projects[0].sessions[0].statusText)
        try fixture.beginWait(sender: fixture.owner, timestamp: fixture.baseMs + 100)
        let remote = fixture.model.remoteWorkspaceSnapshot().projects[0].sessions[0]
        XCTAssertEqual(remote.status, "waiting")
        XCTAssertTrue(remote.background)
        XCTAssertNil(remote.statusText)
    }

    func testModalAndForegroundBusyHintsWinOverReadyHints() {
        for footer in [
            "/ commands · ? help · esc cancel",
            "autopilot · / commands · esc to interrupt",
            "@ files · # issues · esc again to cancel",
            "esc again to interrupt · GPT-6 Astra",
        ] {
            XCTAssertEqual(TerminalController.classifyFooter(footer), .working, footer)
        }
        XCTAssertEqual(TerminalController.classifyFooter("/ commands"), .unknown)
        XCTAssertEqual(TerminalController.classifyFooter("ordinary output"), .unknown)
        XCTAssertEqual(TerminalController.classifyFooterRows([
            "@ files · # issues", "model picker"
        ]), .unknown)
        XCTAssertEqual(TerminalController.classifyFooterRows([
            "autopilot · / commands", "esc cancel"
        ]), .working)
        XCTAssertEqual(TerminalController.classifyFooterRows([
            "autopilot · / commands", "  \u{0} "
        ]), .idle)
    }

    func testSeparateModalFooterRowVetoesIdleWithoutTreatingDraftAsBusy() {
        for hint in [
            "esc cancel", "esc to cancel", "esc interrupt", "esc to interrupt",
            "esc again to cancel", "esc again to interrupt",
        ] {
            let activity = TerminalController.classifyFooterRows([
                hint, "ctrl+q enqueue · @ files · # issues", "  \u{0} ",
            ])
            XCTAssertEqual(activity, .working, hint)
            XCTAssertEqual(
                AppModel.remotePromptEligibility(
                    status: .idle, hasLiveAgent: true, footerActivity: activity
                ), .busy, hint)
        }
        XCTAssertEqual(
            TerminalController.classifyFooterRows([
                "esc cancel · tab switch", "@ files · # issues",
            ]), .working)
        XCTAssertEqual(
            TerminalController.classifyFooterRows([
                "◎ Working   esc cancel", "ctrl+q enqueue · @ files · # issues",
            ]), .working)
        for draft in [
            "keep working on this", "esc cancel doesn't work",
            "remember to esc cancel", "press esc to interrupt",
            "esc again to stop agents", "esc stop agents",
        ] {
            XCTAssertEqual(
                TerminalController.classifyFooterRows([
                    draft, "@ files · # issues",
                ]), .idle, draft)
        }
        XCTAssertEqual(
            TerminalController.classifyFooterRows([
                "esc cancel", "model picker",
            ]), .unknown)
    }

    @MainActor
    func testSuppressedPermissionRetainsWaitUntilMatchingCompletion() async throws {
        let fixture = try Fixture(permissionDelayNanoseconds: 5_000_000)
        defer { fixture.cleanup() }
        let child = UUID().uuidString.lowercased()
        let waitAt = fixture.baseMs + 100
        var snapshot = fixture.snapshot()
        snapshot.updatedAt = fixture.base.addingTimeInterval(0.2)
            .formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        snapshot.runtimeActivity?.observedAtMilliseconds = waitAt + 100
        snapshot.inputCompletions = [fixture.owner: waitAt + 50]
        try fixture.publish(snapshot)
        try fixture.beginWait(sender: child, timestamp: waitAt)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(fixture.model.projects[0].sessions[0].status, .waiting)
        XCTAssertTrue(fixture.sends.permissionRestores.isEmpty)
        XCTAssertEqual(fixture.model.sendRemotePrompt(sessionId: fixture.session.id, value: "blocked"), .busy)

        snapshot.inputCompletions = [child: waitAt + 50]
        try fixture.publish(snapshot)
        XCTAssertEqual(fixture.model.projects[0].sessions[0].status, .idle)
        XCTAssertEqual(
            fixture.sends.permissionRestores,
            [
                SessionStatusRecord(status: .idle, statusTimestamp: waitAt, promptStatusTimestamp: waitAt)
            ])
        XCTAssertEqual(fixture.model.sendRemotePrompt(sessionId: fixture.session.id, value: "next"), .sent)
    }

    @MainActor
    func testPostedPermissionRequiresFreshSenderEvidenceBeforePersistingRestore() async throws {
        let fixture = try Fixture(permissionDelayNanoseconds: 5_000_000)
        defer { fixture.cleanup() }
        let child = UUID().uuidString.lowercased()
        let waitAt = fixture.baseMs + 100
        var snapshot = fixture.snapshot()
        snapshot.updatedAt = fixture.base.addingTimeInterval(0.2)
            .formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        snapshot.runtimeActivity?.observedAtMilliseconds = waitAt + 100
        try fixture.publish(snapshot)
        let notifications = PermissionNotificationSpy()
        let posted = expectation(description: "permission notification posted")
        notifications.onPost = { posted.fulfill() }
        fixture.model.attach(notifications: notifications)
        try fixture.beginWait(sender: child, timestamp: waitAt)
        snapshot.pendingPermissionRequestIds = ["child-request"]
        try fixture.publish(snapshot)
        await fulfillment(of: [posted], timeout: 1)
        snapshot.pendingPermissionRequestIds = []
        snapshot.inputCompletions = [fixture.owner: waitAt + 50]

        var invalidSnapshots = [snapshot]
        snapshot.inputCompletions = [child: waitAt + 50]
        var invalid = snapshot
        invalid.runtimeActivity?.observedAtMilliseconds = waitAt
        invalidSnapshots.append(invalid)
        invalid = snapshot
        invalid.runtimeActivity?.error = "Connection is closed."
        invalidSnapshots.append(invalid)
        invalid = snapshot
        invalid.conversationEpoch = "\(UUID().uuidString):0"
        invalidSnapshots.append(invalid)
        invalid = snapshot
        invalid.copilotSessionId = UUID().uuidString
        invalidSnapshots.append(invalid)
        invalid = snapshot
        invalid.inputCompletions = [child: waitAt + 20_000]
        invalidSnapshots.append(invalid)
        for invalidSnapshot in invalidSnapshots {
            try fixture.publish(invalidSnapshot)
            XCTAssertEqual(fixture.model.projects[0].sessions[0].status, .waiting)
            XCTAssertTrue(fixture.sends.permissionRestores.isEmpty)
            XCTAssertEqual(fixture.model.sendRemotePrompt(sessionId: fixture.session.id, value: "blocked"), .busy)
        }
        let recordURL = fixture.directory.appendingPathComponent("\(fixture.session.id).status-record.json")
        let record = try JSONDecoder().decode(SessionStatusRecord.self, from: Data(contentsOf: recordURL))
        XCTAssertEqual(record.status, .waiting)
        XCTAssertEqual(record.statusTimestamp, waitAt)
        XCTAssertEqual(record.promptStatusTimestamp, waitAt)
        XCTAssertEqual(record.inputWait?.senderSessionId, child)

        snapshot.inputCompletions = [:]
        snapshot.sessionIdleAtMilliseconds = waitAt + 50
        try fixture.publish(snapshot)
        XCTAssertEqual(fixture.model.projects[0].sessions[0].status, .idle)
        XCTAssertEqual(
            fixture.sends.permissionRestores,
            [
                SessionStatusRecord(status: .idle, statusTimestamp: waitAt, promptStatusTimestamp: waitAt)
            ])
    }

    @MainActor
    func testRepeatedSuppressedPermissionKeepsOriginalRestoreState() async throws {
        let fixture = try Fixture(permissionDelayNanoseconds: 5_000_000)
        defer { fixture.cleanup() }
        let child = UUID().uuidString.lowercased()
        let waitAt = fixture.baseMs + 100
        var snapshot = fixture.snapshot()
        snapshot.updatedAt = fixture.base.addingTimeInterval(0.3)
            .formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        snapshot.runtimeActivity?.observedAtMilliseconds = waitAt + 200
        try fixture.publish(snapshot)
        fixture.model.setStatus(
            sessionId: fixture.session.id, status: .idle,
            text: "before permission", timestamp: fixture.baseMs)
        try fixture.beginWait(sender: child, timestamp: waitAt)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(fixture.model.projects[0].sessions[0].status, .waiting)
        try fixture.beginWait(sender: child, timestamp: waitAt + 10)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(fixture.model.projects[0].sessions[0].status, .waiting)
        XCTAssertTrue(fixture.sends.permissionRestores.isEmpty)

        snapshot.inputCompletions = [child: waitAt + 100]
        try fixture.publish(snapshot)
        XCTAssertEqual(fixture.model.projects[0].sessions[0].status, .idle)
        XCTAssertEqual(fixture.model.projects[0].sessions[0].statusText, "before permission")
        XCTAssertEqual(
            fixture.sends.permissionRestores,
            [
                SessionStatusRecord(
                    status: .idle, statusTimestamp: waitAt + 10, promptStatusTimestamp: waitAt + 10)
            ])
    }

    @MainActor
    func testOverlappingPermissionNotificationsKeepLatestRestoreClocks() async throws {
        let fixture = try Fixture(permissionDelayNanoseconds: 5_000_000)
        defer { fixture.cleanup() }
        let waitAt = fixture.baseMs + 100
        try fixture.publish(fixture.snapshot())
        fixture.model.setStatus(
            sessionId: fixture.session.id, status: .idle,
            text: "before permission", timestamp: fixture.baseMs)
        for timestamp in [waitAt, waitAt + 10] {
            fixture.model.setStatus(
                sessionId: fixture.session.id, status: .waiting, text: nil,
                timestamp: timestamp, notification: .permission)
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(fixture.model.projects[0].sessions[0].status, .idle)
        XCTAssertEqual(fixture.model.projects[0].sessions[0].statusText, "before permission")
        XCTAssertEqual(fixture.sends.permissionRestores, [
            SessionStatusRecord(
                status: .idle, statusTimestamp: waitAt + 10, promptStatusTimestamp: waitAt + 10)
        ])
    }

    @MainActor
    private final class PermissionNotificationSpy: NotificationPosting {
        var onPost: (() -> Void)?
        var permissionCount = 0

        func post(_ event: NotificationEvent) {
            if event.kind == .permission {
                permissionCount += 1
                onPost?()
            }
        }
    }

    @MainActor
    func testBlankRepeatedPermissionHookRefreshesPersistenceWithoutAnotherBanner() async throws {
        let hook = try BackgroundHookTests.Fixture()
        let fixture = try Fixture(
            root: hook.root, sessionId: hook.tabId, owner: hook.ownerId,
            permissionDelayNanoseconds: 5_000_000)
        defer { fixture.cleanup() }
        let child = hook.childId
        let waitAt = fixture.baseMs + 100
        var snapshot = fixture.snapshot()
        snapshot.pendingPermissionRequestIds = ["permission"]
        snapshot.updatedAt = Date().formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        snapshot.runtimeActivity?.observedAtMilliseconds = waitAt + 300
        try fixture.publish(snapshot)
        let notifications = PermissionNotificationSpy()
        let posted = expectation(description: "first permission banner")
        notifications.onPost = { posted.fulfill() }
        fixture.model.attach(notifications: notifications)
        try hook.run("notify", payload:
            #"{"sessionId":"\#(child)","timestamp":\#(waitAt),"notificationType":"permission_prompt"}"#)
        fixture.model.setStatus(
            sessionId: fixture.session.id, status: .waiting, text: nil,
            timestamp: waitAt, copilotSessionId: child, notification: .permission)
        await fulfillment(of: [posted], timeout: 1)
        notifications.onPost = nil

        try hook.run("notify", payload:
            #"{"sessionId":"\#(child)","timestamp":\#(waitAt + 10),"notificationType":"permission_prompt"}"#)
        let repeatedIPC = try XCTUnwrap(
            String(contentsOf: hook.capture, encoding: .utf8).split(separator: "\n").last)
        XCTAssertFalse(repeatedIPC.contains("--notification"))
        fixture.model.setStatus(
            sessionId: fixture.session.id, status: .waiting, text: nil,
            timestamp: waitAt + 10, copilotSessionId: child)
        snapshot.pendingPermissionRequestIds = []
        snapshot.inputCompletions = [child: waitAt + 100]
        try fixture.publish(snapshot)
        let persisted = try JSONDecoder().decode(
            SessionStatusRecord.self,
            from: Data(contentsOf: hook.file("status-record.json")))
        XCTAssertEqual(persisted.status, .idle)
        XCTAssertEqual(persisted.statusTimestamp, waitAt + 10)
        XCTAssertEqual(persisted.promptStatusTimestamp, waitAt + 10)
        XCTAssertEqual(fixture.sends.permissionRestores.count, 1)
        XCTAssertEqual(notifications.permissionCount, 1)
    }

    @MainActor
    func testCompletionBeforeNotificationDelayPersistsAndAllowsAnotherWait() async throws {
        let fixture = try Fixture(permissionDelayNanoseconds: 200_000_000)
        defer { fixture.cleanup() }
        let child = UUID().uuidString.lowercased()
        let waitAt = fixture.baseMs + 100
        var snapshot = fixture.snapshot()
        snapshot.pendingPermissionRequestIds = ["first"]
        snapshot.runtimeActivity?.observedAtMilliseconds = waitAt + 300
        try fixture.publish(snapshot)
        try fixture.beginWait(sender: child, timestamp: waitAt)
        snapshot.pendingPermissionRequestIds = []
        snapshot.inputCompletions = [child: waitAt + 100]
        try fixture.publish(snapshot)
        let recordURL = fixture.directory.appendingPathComponent("\(fixture.session.id).status-record.json")
        var persisted = try JSONDecoder().decode(SessionStatusRecord.self, from: Data(contentsOf: recordURL))
        XCTAssertEqual(persisted.status, .idle)
        XCTAssertEqual(fixture.model.projects[0].sessions[0].status, .idle)
        XCTAssertEqual(fixture.sends.permissionRestores.count, 1)

        snapshot.pendingPermissionRequestIds = ["second"]
        try fixture.publish(snapshot)
        try fixture.beginWait(sender: child, timestamp: waitAt + 200)
        snapshot.pendingPermissionRequestIds = []
        snapshot.inputCompletions = [child: waitAt + 250]
        try fixture.publish(snapshot)
        persisted = try JSONDecoder().decode(SessionStatusRecord.self, from: Data(contentsOf: recordURL))
        XCTAssertEqual(persisted.status, .idle)
        XCTAssertEqual(persisted.statusTimestamp, waitAt + 200)
        XCTAssertEqual(fixture.sends.permissionRestores.count, 2)
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(fixture.sends.permissionRestores.count, 2)
    }

    @MainActor
    func testEarlyPermissionCompletionPersistsStillWorkingCoordinator() throws {
        let fixture = try Fixture(permissionDelayNanoseconds: 200_000_000)
        defer { fixture.cleanup() }
        let child = UUID().uuidString.lowercased()
        let waitAt = fixture.baseMs + 100
        var snapshot = fixture.snapshot(processing: true)
        snapshot.pendingPermissionRequestIds = ["permission"]
        snapshot.runtimeActivity?.observedAtMilliseconds = waitAt + 200
        try fixture.publish(snapshot)
        try fixture.beginWait(sender: child, timestamp: waitAt)
        snapshot.pendingPermissionRequestIds = []
        snapshot.inputCompletions = [child: waitAt + 100]
        try fixture.publish(snapshot)
        XCTAssertEqual(fixture.model.projects[0].sessions[0].status, .running)
        XCTAssertTrue(fixture.model.projects[0].sessions[0].statusIsRuntimeDerived)
        XCTAssertEqual(fixture.sends.permissionRestores, [
            SessionStatusRecord(status: .running, statusTimestamp: waitAt, promptStatusTimestamp: waitAt)
        ])
        XCTAssertEqual(fixture.model.sendRemotePrompt(sessionId: fixture.session.id, value: "blocked"), .busy)
    }

    @MainActor
    func testFutureLegacyOrUnsupportedObservationCannotReleaseWait() throws {
        for unsupported in [false, true] {
            let fixture = try Fixture()
            defer { fixture.cleanup() }
            let child = UUID().uuidString.lowercased()
            let waitAt = fixture.baseMs + 100
            var snapshot = fixture.snapshot()
            if unsupported {
                snapshot.runtimeActivity?.error = "unsupported"
            } else {
                snapshot.runtimeActivity = nil
                snapshot.inputCompletions = nil
            }
            try fixture.publish(snapshot)
            try fixture.beginWait(sender: child, timestamp: waitAt, kind: .elicitation)
            snapshot.updatedAt = Date().addingTimeInterval(60)
                .formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
            if unsupported { snapshot.inputCompletions = [child: waitAt + 10] }
            try fixture.publish(snapshot)
            XCTAssertEqual(fixture.model.projects[0].sessions[0].status, .waiting)
            XCTAssertEqual(fixture.model.sendRemotePrompt(
                sessionId: fixture.session.id, value: "must stay blocked"), .busy)
        }
    }

    @MainActor
    func testRuntimeActivityValidationDistinguishesLegacyFromUnknown() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        var snapshot = fixture.snapshot()
        let now = Date()
        XCTAssertEqual(snapshot.runtimeForegroundActivity(
            expectedSessionId: fixture.owner, now: now,
            minimumObservationMilliseconds: fixture.baseMs - 1), .idle)
        XCTAssertEqual(snapshot.runtimeForegroundActivity(
            expectedSessionId: fixture.owner, now: now,
            minimumObservationMilliseconds: fixture.baseMs), .unknown)
        XCTAssertEqual(snapshot.runtimeForegroundActivity(
            expectedSessionId: UUID().uuidString, now: now,
            minimumObservationMilliseconds: nil), .unknown)
        XCTAssertEqual(snapshot.runtimeForegroundActivity(
            expectedSessionId: fixture.owner, now: now,
            minimumObservationMilliseconds: fixture.baseMs + 1), .unknown)
        snapshot.runtimeActivity?.observedAtMilliseconds = fixture.baseMs - 20_000
        XCTAssertEqual(snapshot.runtimeForegroundActivity(
            expectedSessionId: fixture.owner, now: now,
            minimumObservationMilliseconds: nil), .unknown)
        snapshot.runtimeActivity?.observedAtMilliseconds = fixture.baseMs + 20_000
        XCTAssertEqual(snapshot.runtimeForegroundActivity(
            expectedSessionId: fixture.owner, now: now,
            minimumObservationMilliseconds: nil), .unknown)
        snapshot.runtimeActivity?.error = "unsupported"
        XCTAssertNil(snapshot.runtimeForegroundActivity(
            expectedSessionId: fixture.owner, now: now,
            minimumObservationMilliseconds: nil))
        snapshot.runtimeActivity = nil
        XCTAssertNil(snapshot.runtimeForegroundActivity(
            expectedSessionId: nil, now: now,
            minimumObservationMilliseconds: nil))
    }

    @MainActor
    func testRuntimeRestoresWorkingAfterAChildPoisonedTheOldClock() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.model.setStatus(
            sessionId: fixture.session.id, status: .idle, text: nil,
            timestamp: fixture.baseMs - 100, source: "agent-stop")
        var snapshot = fixture.snapshot(processing: true)
        snapshot.foregroundTransitionAt = fixture.base.addingTimeInterval(-10).ISO8601Format()
        try fixture.publish(snapshot)
        XCTAssertEqual(fixture.model.projects[0].sessions[0].status, .running)
        XCTAssertEqual(fixture.model.sendRemotePrompt(sessionId: fixture.session.id, value: "next"), .busy)
        XCTAssertEqual(fixture.sends.count, 0)
    }

    @MainActor
    func testRuntimeIdleRepairsOldBusyStateWithoutRewritingClocks() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let record = SessionStatusRecord(
            status: .running, statusTimestamp: fixture.baseMs - 100,
            promptStatusTimestamp: fixture.baseMs - 100)
        let recordURL = fixture.directory.appendingPathComponent("\(fixture.session.id).status-record.json")
        try JSONEncoder().encode(record).write(to: recordURL)
        fixture.model.setStatus(
            sessionId: fixture.session.id, status: .running,
            text: nil, timestamp: record.statusTimestamp)
        try fixture.publish(fixture.snapshot())
        XCTAssertEqual(fixture.model.projects[0].sessions[0].status, .idle)
        XCTAssertEqual(fixture.model.remoteWorkspaceSnapshot().projects[0].sessions[0].promptable, true)
        XCTAssertEqual(try JSONDecoder().decode(SessionStatusRecord.self, from: Data(contentsOf: recordURL)), record)
    }

    @MainActor
    func testPendingQuestionSurvivesNewerToolActivity() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        var snapshot = fixture.snapshot(processing: true)
        snapshot.trackedUserInputs = [
            TrackedUserInput(
                requestId: "question", question: "Continue?", choices: ["Yes", "No"],
                allowFreeform: false, requestedAt: snapshot.updatedAt, agentId: nil)
        ]
        try fixture.publish(snapshot)
        try fixture.beginWait(
            sender: fixture.owner, timestamp: fixture.baseMs + 100, kind: .elicitation)
        fixture.model.setStatus(
            sessionId: fixture.session.id, status: .running, text: nil,
            timestamp: fixture.baseMs + 200)
        XCTAssertEqual(fixture.model.projects[0].sessions[0].status, .running)
        XCTAssertEqual(fixture.model.projects[0].sessions[0].displayStatus, .waiting)
        fixture.model.refreshAgentActivitySnapshots()
        fixture.model.reconcileAgentFooters()
        let waiting = fixture.model.projects[0].sessions[0]
        XCTAssertEqual(waiting.displayStatus, .waiting)
        let row = SessionRow(session: waiting, isActive: true, onSelect: {}, onClose: {})
        XCTAssertEqual(row.stateLabel, "Waiting for input")
        XCTAssertEqual(row.accessibilityStatus, "Selected, Waiting for input, Unread, Background work active")
        XCTAssertEqual(fixture.model.totalWaiting, 1)
        XCTAssertEqual(fixture.model.totalRunning, 0)
        XCTAssertEqual(fixture.model.projects[0].aggregateStatus, .waiting)
        XCTAssertEqual(fixture.model.remoteWorkspaceSnapshot().projects[0].sessions[0].status, "waiting")
        XCTAssertEqual(fixture.model.sendRemotePrompt(sessionId: fixture.session.id, value: "next"), .busy)

        snapshot.trackedUserInputs = []
        snapshot.inputCompletions = [fixture.owner: fixture.baseMs + 300]
        snapshot.runtimeActivity?.observedAtMilliseconds = fixture.baseMs + 400
        try fixture.publish(snapshot)
        XCTAssertEqual(fixture.model.projects[0].sessions[0].status, .running)
        XCTAssertEqual(fixture.model.projects[0].sessions[0].displayStatus, .running)
        XCTAssertEqual(fixture.model.totalWaiting, 0)
        XCTAssertEqual(fixture.model.totalRunning, 1)
    }

    @MainActor
    func testPendingQuestionDoesNotRequireRuntimeObservation() throws {
        for runtimeError in [nil, "unsupported", "unavailable"] as [String?] {
            let fixture = try Fixture()
            defer { fixture.cleanup() }
            fixture.model.setStatus(
                sessionId: fixture.session.id, status: .running, text: nil,
                timestamp: fixture.baseMs - 100)
            var snapshot = fixture.snapshot(processing: true)
            if let runtimeError {
                snapshot.runtimeActivity?.error = runtimeError
                snapshot.runtimeActivity?.processing = nil
            } else {
                snapshot.runtimeActivity = nil
            }
            snapshot.trackedUserInputs = [
                TrackedUserInput(
                    requestId: "question", question: "Continue?", choices: ["Yes", "No"],
                    allowFreeform: false, requestedAt: snapshot.updatedAt, agentId: nil)
            ]
            try fixture.publish(snapshot)
            XCTAssertEqual(fixture.model.projects[0].sessions[0].status, .running)
            XCTAssertEqual(fixture.model.projects[0].sessions[0].displayStatus, .waiting, runtimeError ?? "legacy")
            XCTAssertEqual(fixture.model.totalWaiting, 1)
            snapshot.trackedUserInputs = []
            try fixture.publish(snapshot)
            XCTAssertEqual(fixture.model.projects[0].sessions[0].displayStatus, .running)
            XCTAssertEqual(fixture.model.totalWaiting, 0)
        }
    }

    @MainActor
    func testPendingQuestionDisplayClearsWhenTrackerExpires() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.model.setStatus(
            sessionId: fixture.session.id, status: .running, text: nil,
            timestamp: fixture.baseMs - 100)
        var snapshot = fixture.snapshot(processing: true)
        snapshot.runtimeActivity = nil
        snapshot.trackedUserInputs = [
            TrackedUserInput(
                requestId: "question", question: "Continue?", choices: ["Yes", "No"],
                allowFreeform: false, requestedAt: snapshot.updatedAt, agentId: nil)
        ]
        try fixture.publish(snapshot)
        XCTAssertEqual(fixture.model.projects[0].sessions[0].displayStatus, .waiting)
        fixture.model.refreshAgentActivitySnapshots(now: fixture.base.addingTimeInterval(16))
        XCTAssertNil(fixture.model.projects[0].sessions[0].agentActivity)
        XCTAssertEqual(fixture.model.projects[0].sessions[0].displayStatus, .running)
    }

    @MainActor
    func testAllPendingInputKindsTakePrecedenceInNativeIndicators() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        for kind in ["question", "elicitation", "permission", "budget"] {
            var snapshot = fixture.snapshot(background: false)
            switch kind {
            case "question":
                snapshot.trackedUserInputs = [
                    TrackedUserInput(
                        requestId: "question", question: "Continue?", choices: ["Yes", "No"],
                        allowFreeform: false, requestedAt: snapshot.updatedAt, agentId: nil)
                ]
            case "elicitation":
                snapshot.trackedElicitations = [
                    TrackedElicitation(
                        requestId: "form", message: "Continue?", mode: "form",
                        url: nil, schema: nil, elicitationSource: nil,
                        requestedAt: snapshot.updatedAt, agentId: nil)
                ]
            case "permission":
                snapshot.pendingPermissionRequestIds = ["permission"]
            default:
                snapshot.workflow = RemoteSessionWorkflow(
                    observedAtMilliseconds: fixture.baseMs, capabilities: [], sendReady: false,
                    budgetRequest: RemoteBudgetRequest(
                        requestId: "budget", maxAiCredits: 30, usedAiCredits: 30))
            }
            for status in [SessionStatus.idle, .running, .waiting] {
                var session = fixture.session
                session.status = status
                session.finishedUnseen = true
                session.hasUnread = true
                session.agentActivity = snapshot
                let row = SessionRow(session: session, isActive: false, onSelect: {}, onClose: {})
                XCTAssertEqual(row.stateLabel, "Waiting for input", kind)
                XCTAssertEqual(row.accessibilityStatus, "Waiting for input, Unread", kind)
                XCTAssertTrue(row.showsUnreadIndicator, kind)
                let project = Project(name: "Test", cwd: fixture.root.path, sessions: [session])
                XCTAssertEqual(project.aggregateStatus, .waiting, kind)
                XCTAssertEqual(project.waitingCount, 1, kind)
                XCTAssertEqual(project.runningCount, 0, kind)
                XCTAssertEqual(session.status, status, "Display must not rewrite lifecycle state")
                session.agentActivity = nil
                XCTAssertEqual(session.displayStatus, status, kind)
            }
        }
    }

    @MainActor
    func testPendingQuestionDisplayWaitsForLastAnswer() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.model.setStatus(
            sessionId: fixture.session.id, status: .running, text: nil,
            timestamp: fixture.baseMs - 100)
        var snapshot = fixture.snapshot(processing: true)
        snapshot.runtimeActivity = nil
        snapshot.trackedUserInputs = ["first", "second"].map {
            TrackedUserInput(
                requestId: $0, question: "Continue?", choices: ["Yes", "No"],
                allowFreeform: false, requestedAt: snapshot.updatedAt, agentId: nil)
        }
        try fixture.publish(snapshot)
        snapshot.trackedUserInputs?.removeFirst()
        try fixture.publish(snapshot)
        XCTAssertEqual(fixture.model.projects[0].sessions[0].displayStatus, .waiting)
        snapshot.trackedUserInputs = []
        try fixture.publish(snapshot)
        XCTAssertEqual(fixture.model.projects[0].sessions[0].displayStatus, .running)
    }

    @MainActor
    func testModernChildPermissionCanResolveWithoutARootHook() throws {
        let hook = try BackgroundHookTests.Fixture()
        let fixture = try Fixture(root: hook.root, sessionId: hook.tabId, owner: hook.ownerId)
        defer { fixture.cleanup() }
        var snapshot = fixture.snapshot()
        snapshot.pendingPermissionRequestIds = ["child-request"]
        try fixture.publish(snapshot)
        let waitAt = fixture.baseMs + 100
        try hook.run("notify", payload:
            #"{"sessionId":"\#(hook.childId)","timestamp":\#(waitAt),"notificationType":"permission_prompt"}"#)
        fixture.model.setStatus(
            sessionId: fixture.session.id, status: .waiting, text: nil,
            timestamp: waitAt, copilotSessionId: hook.childId, notification: .permission)
        XCTAssertEqual(fixture.model.sendRemotePrompt(sessionId: fixture.session.id, value: "blocked"), .busy)
        try hook.run("idle", payload:
            #"{"sessionId":"\#(hook.childId)","timestamp":\#(waitAt + 100)}"#)
        XCTAssertEqual(fixture.model.projects[0].sessions[0].status, .waiting)
        snapshot.pendingPermissionRequestIds = []
        snapshot.inputCompletions = [hook.childId: waitAt + 100]
        snapshot.runtimeActivity?.observedAtMilliseconds = waitAt + 200
        try fixture.publish(snapshot)
        XCTAssertEqual(fixture.model.projects[0].sessions[0].status, .idle)
        XCTAssertEqual(fixture.model.remoteWorkspaceSnapshot().projects[0].sessions[0].promptable, true)
        XCTAssertEqual(fixture.model.sendRemotePrompt(sessionId: fixture.session.id, value: "next"), .sent)
        XCTAssertEqual(fixture.sends.count, 1)
    }

    @MainActor
    func testOtherActorOrGenerationCannotClearAWait() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let child = UUID().uuidString.lowercased()
        let waitAt = fixture.baseMs + 100
        var snapshot = fixture.snapshot()
        try fixture.publish(snapshot)
        try fixture.beginWait(sender: child, timestamp: waitAt)
        snapshot.runtimeActivity?.observedAtMilliseconds = waitAt + 200
        snapshot.inputCompletions = [fixture.owner: waitAt + 100]
        try fixture.publish(snapshot)
        XCTAssertEqual(fixture.model.projects[0].sessions[0].status, .waiting)
        snapshot.inputCompletions = [child: waitAt + 100]
        snapshot.conversationEpoch = "\(UUID().uuidString):0"
        try fixture.publish(snapshot)
        XCTAssertEqual(fixture.model.projects[0].sessions[0].status, .waiting)
        snapshot.conversationEpoch = fixture.epoch
        snapshot.pendingPermissionRequestIds = ["another-actor"]
        try fixture.publish(snapshot)
        XCTAssertEqual(fixture.model.projects[0].sessions[0].status, .waiting)
    }

    @MainActor
    func testCompletedElicitationRepairsPersistedWaitOnAppRestart() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let child = UUID().uuidString.lowercased()
        let waitAt = fixture.baseMs + 100
        var snapshot = fixture.snapshot()
        try fixture.publish(snapshot)
        try fixture.beginWait(sender: child, timestamp: waitAt, kind: .elicitation)
        snapshot.inputCompletions = [child: waitAt + 100]
        snapshot.runtimeActivity?.observedAtMilliseconds = waitAt + 200
        let restarted = AppModel(
            stateRepository: fixture.repository,
            persistPermissionStatus: { sessionId, status, timestamp, promptTimestamp in
                XCTAssertTrue(SessionArtifacts.persistStatus(
                    sessionId: sessionId, status: status, timestamp: timestamp,
                    promptStatusTimestamp: promptTimestamp,
                    sessionsDirectory: fixture.directory))
            },
            isAppActive: { false },
            agentActivityDirectory: fixture.directory,
            resumeMarkerDirectory: fixture.directory)
        XCTAssertEqual(restarted.projects[0].sessions[0].status, .waiting)
        try fixture.publish(snapshot, to: restarted)
        XCTAssertEqual(restarted.projects[0].sessions[0].status, .idle)
        let record = try JSONDecoder().decode(
            SessionStatusRecord.self,
            from: Data(contentsOf: fixture.directory
                .appendingPathComponent("\(fixture.session.id).status-record.json")))
        XCTAssertEqual(record.status, .idle)
        XCTAssertEqual(record.statusTimestamp, waitAt)
    }

    @MainActor
    func testAcceptedPromptNeedsANewCoordinatorAcknowledgement() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        var snapshot = fixture.snapshot()
        try fixture.publish(snapshot)
        XCTAssertEqual(fixture.model.sendRemotePrompt(sessionId: fixture.session.id, value: "first"), .sent)
        Thread.sleep(forTimeInterval: 0.003)
        let observed = Int64(Date().timeIntervalSince1970 * 1_000)
        snapshot.runtimeActivity?.observedAtMilliseconds = observed
        try fixture.publish(snapshot)
        XCTAssertEqual(fixture.model.sendRemotePrompt(sessionId: fixture.session.id, value: "duplicate"), .busy)
        XCTAssertEqual(fixture.sends.count, 1)
        snapshot.runtimeActivity?.idleAtMilliseconds = observed
        try fixture.publish(snapshot)
        XCTAssertEqual(fixture.model.sendRemotePrompt(sessionId: fixture.session.id, value: "next"), .sent)
        XCTAssertEqual(fixture.sends.count, 2)
    }

    @MainActor
    func testFailedPromptDoesNotLeaveAnAdmissionFence() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.publish(fixture.snapshot())
        fixture.sends.succeeds = false
        XCTAssertEqual(fixture.model.sendRemotePrompt(sessionId: fixture.session.id, value: "first"), .invalid)
        fixture.sends.succeeds = true
        XCTAssertEqual(fixture.model.sendRemotePrompt(sessionId: fixture.session.id, value: "retry"), .sent)
    }

    @MainActor
    func testRuntimeLossDoesNotBecomeLegacyIdle() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.publish(fixture.snapshot())
        try FileManager.default.removeItem(at: fixture.snapshotURL)
        fixture.model.refreshAgentActivitySnapshots()
        XCTAssertEqual(fixture.model.sendRemotePrompt(sessionId: fixture.session.id, value: "next"), .busy)
    }

    @MainActor
    func testLegacyTrackerKeepsTheExistingPromptPath() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        var snapshot = fixture.snapshot()
        snapshot.runtimeActivity = nil
        snapshot.inputCompletions = nil
        try fixture.publish(snapshot)
        XCTAssertEqual(fixture.model.sendRemotePrompt(sessionId: fixture.session.id, value: "legacy"), .sent)
    }

    @MainActor
    func testExplicitUnsupportedRuntimeDoesNotInstallASendFence() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        var snapshot = fixture.snapshot()
        snapshot.runtimeActivity?.error = "unsupported"
        snapshot.runtimeActivity?.processing = nil
        try fixture.publish(snapshot)
        XCTAssertEqual(fixture.model.sendRemotePrompt(sessionId: fixture.session.id, value: "one"), .sent)
        XCTAssertEqual(fixture.model.sendRemotePrompt(sessionId: fixture.session.id, value: "two"), .sent)
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
        XCTAssertEqual(fixture.model.sendRemotePrompt(sessionId: fixture.session.id, value: "next"), .busy)
    }

    @MainActor
    func testWholeSessionIdleReleasesCancelledWaitButChildIdleDoesNot() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let waitAt = fixture.baseMs + 100
        var snapshot = fixture.snapshot(background: false)
        try fixture.publish(snapshot)
        try fixture.beginWait(sender: UUID().uuidString.lowercased(), timestamp: waitAt)
        snapshot.runtimeActivity?.observedAtMilliseconds = waitAt + 200
        snapshot.runtimeActivity?.idleAtMilliseconds = waitAt + 100
        try fixture.publish(snapshot)
        XCTAssertEqual(fixture.model.projects[0].sessions[0].status, .waiting)
        snapshot.sessionIdleAtMilliseconds = waitAt + 100
        try fixture.publish(snapshot)
        XCTAssertEqual(fixture.model.projects[0].sessions[0].status, .idle)
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
    func testDisconnectedRuntimeStillUsesTheDisplayBackstopButCannotAdmitInput() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.model.setStatus(
            sessionId: fixture.session.id, status: .running,
            text: nil, timestamp: fixture.baseMs - 100)
        var snapshot = fixture.snapshot()
        snapshot.error = "Connection is closed."
        snapshot.runtimeActivity?.error = snapshot.error
        snapshot.runtimeActivity?.processing = nil
        try fixture.publish(snapshot)
        fixture.model.reconcileAgentFooters()
        fixture.model.reconcileAgentFooters()
        XCTAssertEqual(fixture.model.projects[0].sessions[0].status, .idle)
        XCTAssertEqual(fixture.model.sendRemotePrompt(sessionId: fixture.session.id, value: "not ready"), .busy)
    }

    @MainActor
    func testLegacyTrackerCanReleaseElicitationAndRepeatedChildWaits() throws {
        for kind in [StatusNotificationKind.permission, .elicitation] {
            let fixture = try Fixture()
            defer { fixture.cleanup() }
            var snapshot = fixture.snapshot()
            snapshot.runtimeActivity = nil
            snapshot.inputCompletions = nil
            try fixture.publish(snapshot)
            let waitAt = fixture.baseMs + 100
            try fixture.beginWait(
                sender: UUID().uuidString.lowercased(), timestamp: waitAt, kind: kind)
            try fixture.beginWait(
                sender: UUID().uuidString.lowercased(), timestamp: waitAt + 100, kind: nil)
            snapshot.pendingPermissionRequestIds = ["another-request"]
            snapshot.updatedAt = Date().formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
            try fixture.publish(snapshot)
            XCTAssertEqual(fixture.model.projects[0].sessions[0].status, .waiting)
            snapshot.pendingPermissionRequestIds = []
            snapshot.conversationEpoch = "\(UUID().uuidString):0"
            try fixture.publish(snapshot)
            XCTAssertEqual(fixture.model.projects[0].sessions[0].status, .waiting)
            snapshot.conversationEpoch = fixture.epoch
            snapshot.updatedAt = Date().formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
            try fixture.publish(snapshot)
            XCTAssertEqual(fixture.model.projects[0].sessions[0].status, .idle)
            XCTAssertEqual(fixture.model.sendRemotePrompt(sessionId: fixture.session.id, value: "next"), .sent)
        }
    }
}
