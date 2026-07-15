import XCTest
@testable import copilot_projects
import CopilotProjectsCore
import CopilotProjectsProtocol
import AppKit
import Security
import WebPush
import CryptoKit
#if canImport(Darwin)
import Darwin
#endif

final class AppLogicTests: XCTestCase {
    func testFooterClassification() {
        XCTAssertEqual(
            TerminalController.classifyFooter("◎ Working   esc cancel"),
            .working
        )
        XCTAssertEqual(
            TerminalController.classifyFooter("/ commands · ? help · tab next tab"),
            .idle
        )
        XCTAssertEqual(TerminalController.classifyFooter("ordinary output"), .unknown)
    }

    func testRemotePromptBytesAreSanitizedAndSubmittedAtomically() throws {
        let bytes = try XCTUnwrap(
            ProjectsTerminalView.remotePromptBytes("first line\nsecond line")
        )
        XCTAssertEqual(Array(bytes.prefix(2)), [0x1b, 0x1b])
        XCTAssertTrue(bytes.starts(with: [0x1b, 0x1b] + Array("\u{1b}[200~".utf8)))
        XCTAssertEqual(bytes.last, 0x0d)
        XCTAssertEqual(
            String(decoding: bytes, as: UTF8.self),
            "\u{1b}\u{1b}\u{1b}[200~first line\nsecond line\u{1b}[201~\r"
        )
        XCTAssertNil(ProjectsTerminalView.remotePromptBytes("unsafe\u{1b}[201~input"))
        XCTAssertNil(ProjectsTerminalView.remotePromptBytes("unsafe\u{009b}31m"))
        XCTAssertNil(ProjectsTerminalView.remotePromptBytes("unsafe\u{0}input"))
        XCTAssertNil(ProjectsTerminalView.remotePromptBytes("   \n"))
    }

    func testRemotePromptPasteBytesExcludeSubmitCarriageReturn() throws {
        let paste = try XCTUnwrap(
            ProjectsTerminalView.remotePromptPasteBytes("hello")
        )
        // The paste carries no submit CR; the Enter is delivered separately after
        // the TUI commits the paste.
        XCTAssertNotEqual(paste.last, 0x0d)
        XCTAssertFalse(paste.contains(0x0d))
        XCTAssertEqual(
            ProjectsTerminalView.remotePromptBytes("hello"),
            paste + [0x0d]
        )
        XCTAssertNil(ProjectsTerminalView.remotePromptPasteBytes("   \n"))
    }

    func testPromptSubmitTimingScalesWithSizeAndIsBounded() {
        // Small prompts get the base floor; large ones wait longer, but bounded.
        XCTAssertEqual(ProjectsTerminalView.promptSubmitFloorTicks(byteCount: 0), 10)
        XCTAssertEqual(ProjectsTerminalView.promptSubmitFloorTicks(byteCount: 1_024), 10)
        XCTAssertGreaterThan(
            ProjectsTerminalView.promptSubmitFloorTicks(byteCount: 8_192),
            ProjectsTerminalView.promptSubmitFloorTicks(byteCount: 1_024)
        )
        XCTAssertLessThanOrEqual(
            ProjectsTerminalView.promptSubmitFloorTicks(byteCount: 1_000_000),
            20
        )
        // The floor must comfortably exceed the old 150ms fixed delay (5 ticks).
        XCTAssertGreaterThan(ProjectsTerminalView.promptSubmitFloorTicks(byteCount: 0), 5)
        // The cap always leaves room for the settle extension past the floor.
        for bytes in [0, 1_024, 8_192, 1_000_000] {
            XCTAssertGreaterThan(
                ProjectsTerminalView.promptSubmitMaxTicks(byteCount: bytes),
                ProjectsTerminalView.promptSubmitFloorTicks(byteCount: bytes)
            )
        }
        // A submit can fire at the floor when output is already quiet.
        XCTAssertLessThan(
            ProjectsTerminalView.promptSubmitSettleTicks,
            ProjectsTerminalView.promptSubmitFloorTicks(byteCount: 0)
        )
    }

    func testRemotePromptEligibilityRequiresSettledLiveCopilot() {
        XCTAssertEqual(
            AppModel.remotePromptEligibility(
                status: .idle,
                hasBackgroundWork: false,
                hasLiveAgent: true,
                footerActivity: .idle
            ),
            .sent
        )
        XCTAssertEqual(
            AppModel.remotePromptEligibility(
                status: .idle,
                hasBackgroundWork: true,
                hasLiveAgent: true,
                footerActivity: .idle
            ),
            .busy
        )
        XCTAssertEqual(
            AppModel.remotePromptEligibility(
                status: .running,
                hasBackgroundWork: false,
                hasLiveAgent: true,
                footerActivity: .working
            ),
            .busy
        )
        XCTAssertEqual(
            AppModel.remotePromptEligibility(
                status: .idle,
                hasBackgroundWork: false,
                hasLiveAgent: false,
                footerActivity: .idle
            ),
            .noLiveCopilot
        )
        XCTAssertEqual(
            AppModel.remotePromptEligibility(
                status: .idle,
                hasBackgroundWork: false,
                hasLiveAgent: true,
                footerActivity: .unknown
            ),
            .noLiveCopilot
        )
    }

    @MainActor
    func testRemotePromptOrchestrationRechecksAndSendsExactlyOnce() throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/remote-prompt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = Session(title: "prompt", cwd: root.path)
        defer { SessionArtifacts.removeFiles(sessionId: session.id) }
        let project = Project(
            name: "project",
            cwd: root.path,
            sessions: [session],
            selectedSessionId: session.id
        )
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(
            projects: [project],
            selectedProjectId: project.id
        ))

        var liveSessions: Set<String> = [session.id]
        var activity = FooterActivity.idle
        var sendSucceeds = true
        var sentValues: [String] = []
        let model = AppModel(
            stateRepository: repository,
            remotePromptLiveSessions: { _ in liveSessions },
            remotePromptTarget: { requestedSessionId in
                guard requestedSessionId == session.id else { return nil }
                return RemotePromptTarget(
                    activity: activity,
                    send: { value in
                        sentValues.append(value)
                        return sendSucceeds
                    }
                )
            }
        )

        XCTAssertEqual(model.sendRemotePrompt(sessionId: session.id, value: "hello"), .sent)
        XCTAssertEqual(sentValues, ["hello"])

        XCTAssertEqual(
            model.sendRemotePrompt(sessionId: "missing", value: "ignored"),
            .invalid
        )
        XCTAssertEqual(
            model.sendRemotePrompt(sessionId: session.id, value: "bad\u{0}value"),
            .invalid
        )
        XCTAssertEqual(sentValues, ["hello"])

        model.setStatus(sessionId: session.id, status: .running, text: nil, timestamp: 1)
        XCTAssertEqual(model.sendRemotePrompt(sessionId: session.id, value: "busy"), .busy)
        XCTAssertEqual(sentValues, ["hello"])
        model.setStatus(sessionId: session.id, status: .idle, text: nil, timestamp: 2)

        model.setBackgroundAgentsActive(sessionId: session.id, active: true)
        XCTAssertEqual(
            model.sendRemotePrompt(sessionId: session.id, value: "background"),
            .busy
        )
        XCTAssertEqual(sentValues, ["hello"])
        model.setBackgroundAgentsActive(sessionId: session.id, active: false)

        liveSessions = []
        XCTAssertEqual(
            model.sendRemotePrompt(sessionId: session.id, value: "no process"),
            .noLiveCopilot
        )
        XCTAssertEqual(sentValues, ["hello"])
        liveSessions = [session.id]

        activity = .working
        XCTAssertEqual(
            model.sendRemotePrompt(sessionId: session.id, value: "working"),
            .noLiveCopilot
        )
        XCTAssertEqual(sentValues, ["hello"])
        activity = .idle

        sendSucceeds = false
        XCTAssertEqual(
            model.sendRemotePrompt(sessionId: session.id, value: "not sent"),
            .invalid
        )
        XCTAssertEqual(sentValues, ["hello", "not sent"])
    }

    func testActivityTrackerRequiresObservedWorkAndTwoIdleTicks() {
        let sessionId = UUID().uuidString
        var tracker = ActivityTracker()
        XCTAssertFalse(tracker.observeFooter(
            sessionId: sessionId, currentStatus: .running, activity: .idle))
        XCTAssertFalse(tracker.observeFooter(
            sessionId: sessionId, currentStatus: .running, activity: .working))
        XCTAssertFalse(tracker.observeFooter(
            sessionId: sessionId, currentStatus: .running, activity: .idle))
        XCTAssertTrue(tracker.observeFooter(
            sessionId: sessionId, currentStatus: .running, activity: .idle))
    }

    func testActivityTrackerRequiresTwoWorkingTicksToPromoteIdleSession() {
        let sessionId = UUID().uuidString
        var tracker = ActivityTracker()
        XCTAssertFalse(tracker.shouldPromoteFromFooter(
            sessionId: sessionId, currentStatus: .idle, activity: .unknown))
        XCTAssertFalse(tracker.shouldPromoteFromFooter(
            sessionId: sessionId, currentStatus: .idle, activity: .working))
        XCTAssertTrue(tracker.shouldPromoteFromFooter(
            sessionId: sessionId, currentStatus: .idle, activity: .working))
        XCTAssertFalse(tracker.observeFooter(
            sessionId: sessionId, currentStatus: .running, activity: .idle))
        XCTAssertTrue(tracker.observeFooter(
            sessionId: sessionId, currentStatus: .running, activity: .idle))
    }

    func testFooterDoesNotPromoteWhileBackgroundAgentsAreActive() {
        XCTAssertFalse(ActivityTracker.canPromoteIdleFromFooter(
            backgroundAgentsActive: true,
            hasLiveAgent: true,
            supportsSessionIdleHook: false
        ))
        XCTAssertTrue(ActivityTracker.canPromoteIdleFromFooter(
            backgroundAgentsActive: false,
            hasLiveAgent: true,
            supportsSessionIdleHook: false
        ))
        XCTAssertFalse(ActivityTracker.canPromoteIdleFromFooter(
            backgroundAgentsActive: false,
            hasLiveAgent: false,
            supportsSessionIdleHook: false
        ))
        XCTAssertFalse(ActivityTracker.canPromoteIdleFromFooter(
            backgroundAgentsActive: false,
            hasLiveAgent: true,
            supportsSessionIdleHook: true
        ))
    }

    func testStatusEventClockRejectsLateHookEvents() {
        let sessionId = UUID().uuidString
        var clock = StatusEventClock()
        XCTAssertTrue(clock.shouldApply(sessionId: sessionId, timestamp: 200))
        XCTAssertFalse(clock.shouldApply(sessionId: sessionId, timestamp: 100))
        XCTAssertTrue(clock.shouldApply(sessionId: sessionId, timestamp: 300))
        XCTAssertTrue(clock.shouldApply(sessionId: sessionId, timestamp: nil))
    }

    @MainActor
    func testActiveStatusClearsStaleReadyMarker() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let targetSession = Session(title: "target", cwd: "/tmp")
        let targetProject = Project(name: "target", cwd: "/tmp", sessions: [targetSession])
        let selectedProject = Project(name: "selected", cwd: "/tmp")
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(
            projects: [targetProject, selectedProject],
            selectedProjectId: selectedProject.id
        ))

        let model = AppModel(
            stateRepository: repository,
            completionNotificationDelayNanoseconds: 10_000_000
        )
        model.setStatus(sessionId: targetSession.id, status: .running, text: nil, timestamp: 100)
        model.setStatus(sessionId: targetSession.id, status: .idle, text: nil, timestamp: 200)

        XCTAssertTrue(model.projects[0].sessions[0].finishedUnseen)
        XCTAssertFalse(model.projects[0].sessions[0].hasUnread)
        XCTAssertEqual(model.totalReady, 1)

        model.setStatus(sessionId: targetSession.id, status: .running, text: nil, timestamp: 300)

        XCTAssertFalse(model.projects[0].sessions[0].finishedUnseen)
        XCTAssertEqual(model.totalReady, 0)

        model.setStatus(sessionId: targetSession.id, status: .idle, text: nil, timestamp: 400)
        XCTAssertTrue(model.projects[0].sessions[0].finishedUnseen)

        model.setStatus(sessionId: targetSession.id, status: .waiting, text: nil, timestamp: 500)

        XCTAssertFalse(model.projects[0].sessions[0].finishedUnseen)
        XCTAssertEqual(model.totalReady, 0)
    }

    @MainActor
    func testSessionEndClearsResumeMarkerOnlyWhileAppIsRunning() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let session = Session(title: "target", cwd: "/tmp")
        let project = Project(name: "target", cwd: "/tmp", sessions: [session])
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(projects: [project], selectedProjectId: project.id))

        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        let marker = sessions.appendingPathComponent("\(session.id).copilot-session")
        try FileManager.default.createDirectory(
            at: marker.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: marker) }

        let model = AppModel(
            stateRepository: repository,
            resumeMarkerDirectory: sessions
        )
        let firstCopilotSession = UUID().uuidString
        try Data(firstCopilotSession.utf8).write(to: marker)
        model.setStatus(
            sessionId: session.id,
            status: .idle,
            text: nil,
            timestamp: 100,
            source: "session-end",
            copilotSessionId: firstCopilotSession
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))

        let powerOffCopilotSession = UUID().uuidString
        try Data(powerOffCopilotSession.utf8).write(to: marker)
        model.prepareForSystemPowerOff()
        model.setStatus(
            sessionId: session.id,
            status: .idle,
            text: nil,
            timestamp: 150,
            source: "session-end",
            copilotSessionId: powerOffCopilotSession
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))

        model.beginTermination()
        model.setStatus(
            sessionId: session.id,
            status: .idle,
            text: nil,
            timestamp: 200,
            source: "session-end",
            copilotSessionId: powerOffCopilotSession
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }

    @MainActor
    func testStaleSessionEndDoesNotClearResumeMarkers() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let session = Session(title: "target", cwd: "/tmp")
        let project = Project(name: "target", cwd: "/tmp", sessions: [session])
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(projects: [project], selectedProjectId: project.id))

        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let markers = ["copilot-session", "copilot-allow-all"].map {
            sessions.appendingPathComponent("\(session.id).\($0)")
        }
        let ownerCopilotSession = UUID().uuidString
        for marker in markers {
            try Data(ownerCopilotSession.utf8).write(to: marker)
        }

        let model = AppModel(
            stateRepository: repository,
            resumeMarkerDirectory: sessions
        )
        model.setStatus(sessionId: session.id, status: .running, text: nil, timestamp: 200)
        model.setStatus(
            sessionId: session.id,
            status: .idle,
            text: nil,
            timestamp: 100,
            source: "session-end",
            copilotSessionId: ownerCopilotSession
        )

        for marker in markers {
            XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        }

        model.setStatus(
            sessionId: session.id,
            status: .idle,
            text: nil,
            timestamp: 300,
            source: "session-end",
            copilotSessionId: UUID().uuidString
        )

        for marker in markers {
            XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        }
    }

    @MainActor
    func testPowerOffProtectionExpiresAfterCancelledShutdown() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let model = AppModel(
            stateRepository: StateRepository(path: root.appendingPathComponent("state.json"))
        )
        model.prepareForSystemPowerOff(protectionInterval: 0)
        XCTAssertTrue(model.isPoweringOff)
        XCTAssertTrue(AppModel.shouldPreserveSessionAfterTerminalExit(
            isTerminating: false,
            isPoweringOff: true
        ))
        XCTAssertTrue(AppModel.shouldPreserveSessionAfterTerminalExit(
            isTerminating: true,
            isPoweringOff: false
        ))
        XCTAssertFalse(AppModel.shouldPreserveSessionAfterTerminalExit(
            isTerminating: false,
            isPoweringOff: false
        ))

        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(model.isPoweringOff)
    }

    @MainActor
    func testCompletionNotificationUsesAgentStopAndWaitsForBackgroundAgents() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let immediateSession = Session(title: "immediate", cwd: "/tmp")
        let backgroundSession = Session(title: "background", cwd: "/tmp")
        let targetProject = Project(
            name: "target",
            cwd: "/tmp",
            sessions: [immediateSession, backgroundSession]
        )
        let selectedProject = Project(name: "selected", cwd: "/tmp")
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(
            projects: [targetProject, selectedProject],
            selectedProjectId: selectedProject.id
        ))

        let model = AppModel(
            stateRepository: repository,
            completionNotificationDelayNanoseconds: 10_000_000
        )
        let notifications = NotificationSpy()
        let immediateCompletion = expectation(description: "agentStop posts completion")
        notifications.onPost = { call in
            if call.sessionId == immediateSession.id {
                immediateCompletion.fulfill()
            }
        }
        model.attach(notifications: notifications)
        model.setStatus(
            sessionId: immediateSession.id,
            status: .running,
            text: nil,
            timestamp: 100
        )
        model.setStatus(
            sessionId: immediateSession.id,
            status: .idle,
            text: nil,
            timestamp: 200,
            source: "agent-stop"
        )
        await fulfillment(of: [immediateCompletion], timeout: 1)
        XCTAssertTrue(model.projects[0].sessions[0].hasUnread)
        XCTAssertEqual(notifications.calls, [
            NotificationSpy.Call(
                title: StatusNotificationKind.completed.title,
                subtitle: "target · immediate",
                body: nil,
                projectId: targetProject.id,
                sessionId: immediateSession.id
            )
        ])
        XCTAssertEqual(notifications.events.first?.kind, .completed)
        XCTAssertNotNil(notifications.events.first?.sentAt)
        XCTAssertTrue(
            notifications.events.first?.displayedBody.contains("Sent at ") == true
        )

        let prematureCompletion = expectation(description: "background agents suppress completion")
        prematureCompletion.isInverted = true
        notifications.onPost = { call in
            if call.sessionId == backgroundSession.id {
                prematureCompletion.fulfill()
            }
        }
        model.setBackgroundAgentsActive(sessionId: backgroundSession.id, active: true)
        model.setStatus(
            sessionId: backgroundSession.id,
            status: .running,
            text: nil,
            timestamp: 300
        )
        model.setStatus(
            sessionId: backgroundSession.id,
            status: .idle,
            text: nil,
            timestamp: 400,
            source: "agent-stop"
        )
        await fulfillment(of: [prematureCompletion], timeout: 0.1)
        XCTAssertFalse(model.projects[0].sessions[1].hasUnread)
        XCTAssertEqual(notifications.calls.count, 1)

        notifications.onPost = nil
        model.setBackgroundAgentsActive(sessionId: backgroundSession.id, active: false)
        XCTAssertTrue(model.projects[0].sessions[1].hasUnread)
        XCTAssertEqual(notifications.calls, [
            NotificationSpy.Call(
                title: StatusNotificationKind.completed.title,
                subtitle: "target · immediate",
                body: nil,
                projectId: targetProject.id,
                sessionId: immediateSession.id
            ),
            NotificationSpy.Call(
                title: StatusNotificationKind.completed.title,
                subtitle: "target · background",
                body: nil,
                projectId: targetProject.id,
                sessionId: backgroundSession.id
            )
        ])
    }

    @MainActor
    func testMarkSessionReadClearsUnreadWithoutMovingSelection() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let target = Session(title: "target", cwd: "/tmp")
        let visible = Session(title: "visible", cwd: "/tmp")
        // The project is selected on `visible`, so `target` completes while it is
        // not the on-screen session and picks up unread/finished flags.
        let project = Project(
            name: "p",
            cwd: "/tmp",
            sessions: [target, visible],
            selectedSessionId: visible.id
        )
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(
            projects: [project],
            selectedProjectId: project.id
        ))

        let model = AppModel(
            stateRepository: repository,
            completionNotificationDelayNanoseconds: 10_000_000
        )
        model.setStatus(sessionId: target.id, status: .running, text: nil, timestamp: 100)
        model.setStatus(
            sessionId: target.id,
            status: .idle,
            text: nil,
            timestamp: 111,
            source: "session-idle",
            notification: .completed
        )
        XCTAssertTrue(model.projects[0].sessions[0].hasUnread)
        XCTAssertTrue(model.projects[0].sessions[0].finishedUnseen)

        // A remote read (e.g. the iOS session screen appearing) clears the flags…
        model.markSessionRead(sessionId: target.id)
        XCTAssertFalse(model.projects[0].sessions[0].hasUnread)
        XCTAssertFalse(model.projects[0].sessions[0].finishedUnseen)

        // …without moving the Mac's selection or touching the other session.
        XCTAssertEqual(model.selectedProjectId, project.id)
        XCTAssertEqual(model.projects[0].selectedSessionId, visible.id)

        // Unknown ids are a no-op rather than a crash.
        model.markSessionRead(sessionId: "does-not-exist")
    }

    @MainActor
    func testCompletionSignalsSurviveEitherTimestampArrivalOrder() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let agentStopFirst = Session(title: "agent-stop-first", cwd: "/tmp")
        let sessionIdleFirst = Session(title: "session-idle-first", cwd: "/tmp")
        let targetProject = Project(
            name: "target",
            cwd: "/tmp",
            sessions: [agentStopFirst, sessionIdleFirst]
        )
        let selectedProject = Project(name: "selected", cwd: "/tmp")
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(
            projects: [targetProject, selectedProject],
            selectedProjectId: selectedProject.id
        ))

        let model = AppModel(
            stateRepository: repository,
            completionNotificationDelayNanoseconds: 10_000_000
        )
        let notifications = NotificationSpy()
        model.attach(notifications: notifications)
        model.setStatus(
            sessionId: agentStopFirst.id,
            status: .running,
            text: nil,
            timestamp: 100
        )
        model.setStatus(
            sessionId: agentStopFirst.id,
            status: .idle,
            text: nil,
            timestamp: 110,
            source: "agent-stop"
        )
        model.setStatus(
            sessionId: agentStopFirst.id,
            status: .idle,
            text: nil,
            timestamp: 111,
            source: "session-idle",
            notification: .completed
        )

        model.setStatus(
            sessionId: sessionIdleFirst.id,
            status: .running,
            text: nil,
            timestamp: 200
        )
        model.setStatus(
            sessionId: sessionIdleFirst.id,
            status: .idle,
            text: nil,
            timestamp: 211,
            source: "session-idle",
            notification: .completed
        )
        model.setStatus(
            sessionId: sessionIdleFirst.id,
            status: .idle,
            text: nil,
            timestamp: 210,
            source: "agent-stop"
        )

        XCTAssertTrue(model.projects[0].sessions[0].hasUnread)
        XCTAssertTrue(model.projects[0].sessions[1].hasUnread)
        XCTAssertEqual(notifications.calls, [
            NotificationSpy.Call(
                title: StatusNotificationKind.completed.title,
                subtitle: "target · agent-stop-first",
                body: nil,
                projectId: targetProject.id,
                sessionId: agentStopFirst.id
            ),
            NotificationSpy.Call(
                title: StatusNotificationKind.completed.title,
                subtitle: "target · session-idle-first",
                body: nil,
                projectId: targetProject.id,
                sessionId: sessionIdleFirst.id
            )
        ])
    }

    @MainActor
    func testVisibleCompletionPostsNoNotificationAcrossAgentStopAndSessionIdle() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let session = Session(title: "visible", cwd: "/tmp")
        let project = Project(
            name: "selected",
            cwd: "/tmp",
            sessions: [session],
            selectedSessionId: session.id
        )
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(
            projects: [project],
            selectedProjectId: project.id
        ))

        let model = AppModel(
            stateRepository: repository,
            completionNotificationDelayNanoseconds: 10_000_000,
            isAppActive: { true }
        )
        let notifications = NotificationSpy()
        let unexpectedCompletion = expectation(description: "visible completion remains suppressed")
        unexpectedCompletion.isInverted = true
        notifications.onPost = { _ in unexpectedCompletion.fulfill() }
        model.attach(notifications: notifications)
        model.setStatus(sessionId: session.id, status: .running, text: nil, timestamp: 100)
        model.setStatus(
            sessionId: session.id,
            status: .idle,
            text: nil,
            timestamp: 110,
            source: "agent-stop"
        )

        await fulfillment(of: [unexpectedCompletion], timeout: 0.1)
        notifications.onPost = nil
        XCTAssertTrue(model.projects[0].sessions[0].turnCompleted)
        XCTAssertFalse(model.projects[0].sessions[0].hasUnread)
        XCTAssertFalse(model.projects[0].sessions[0].finishedUnseen)
        XCTAssertTrue(notifications.calls.isEmpty)

        model.setStatus(
            sessionId: session.id,
            status: .idle,
            text: nil,
            timestamp: 111,
            source: "session-idle",
            notification: .completed
        )
        XCTAssertTrue(notifications.calls.isEmpty)
    }

    @MainActor
    private final class NotificationSpy: NotificationPosting {
        struct Call: Equatable {
            let title: String
            let subtitle: String?
            let body: String?
            let projectId: String?
            let sessionId: String?
        }

        private(set) var calls: [Call] = []
        private(set) var events: [NotificationEvent] = []
        var onPost: ((Call) -> Void)?

        func post(_ event: NotificationEvent) {
            let call = Call(
                title: event.title,
                subtitle: event.subtitle,
                body: event.body,
                projectId: event.projectId,
                sessionId: event.sessionId
            )
            calls.append(call)
            events.append(event)
            onPost?(call)
        }
    }

    private actor WebPushSenderSpy: WebPushSending {
        private(set) var payloads: [Data] = []
        private(set) var endpoints: [URL] = []

        func send(
            data: Data,
            to subscriber: Subscriber,
            eventID: UUID
        ) async throws {
            payloads.append(data)
            endpoints.append(subscriber.endpoint)
        }

        func firstPayload() -> Data? { payloads.first }
        func sentPayloads() -> [Data] { payloads }
        func sentEndpoints() -> [URL] { endpoints }
    }

    private actor APNsSenderSpy: APNsSending {
        private(set) var devices: [StoredAPNsDevice] = []
        private(set) var payloads: [RemoteNotificationPayload] = []
        var result: APNsDelivery = .delivered
        var showDelayNanoseconds: UInt64 = 0

        func send(
            payload: RemoteNotificationPayload,
            device: StoredAPNsDevice
        ) async -> APNsDelivery {
            if payload.action == .show, showDelayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: showDelayNanoseconds)
            }
            devices.append(device)
            payloads.append(payload)
            return result
        }

        func setShowDelayNanoseconds(_ value: UInt64) {
            showDelayNanoseconds = value
        }

        func firstDevice() -> StoredAPNsDevice? { devices.first }
        func sentPayloads() -> [RemoteNotificationPayload] { payloads }
        func sentDevices() -> [StoredAPNsDevice] { devices }
    }

    func testDesktopActivityUsesTwoMinuteThreshold() {
        XCTAssertTrue(DesktopActivity.wasRecentlyActive(
            secondsSinceLastInput: { 119.9 }
        ))
        XCTAssertFalse(DesktopActivity.wasRecentlyActive(
            secondsSinceLastInput: { 120 }
        ))
    }

    func testRemoteNotificationPayloadDecodesLegacyShowPayloads() throws {
        let id = UUID()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(RemoteNotificationPayload.self, from: Data("""
        {
          "id": "\(id.uuidString)",
          "kind": "completed",
          "title": "Complete",
          "body": "Done",
          "projectId": "project",
          "sessionId": "session",
          "sentAt": "2026-07-13T05:45:00Z"
        }
        """.utf8))

        XCTAssertEqual(payload.action, .show)
        XCTAssertEqual(payload.id, id)
    }

    @MainActor
    func testRoutedNotificationsSuppressRemoteDeliveryWhileDesktopIsActive() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let webStore = WebPushSubscriptionStore(
            url: root.appendingPathComponent("subscriptions.json")
        )
        try webStore.add(JSONDecoder().decode(
            WebPushRegistration.self,
            from: webPushRegistrationData(
                endpoint: "https://wns2-by3p.notify.windows.com/sub/active"
            )
        ))
        let webSender = WebPushSenderSpy()
        let webPush = WebPushService(
            publicKey: VAPID.Key().id.description,
            store: webStore,
            sender: webSender
        )

        let apnsStore = APNsDeviceStore(url: root.appendingPathComponent("devices.json"))
        try apnsStore.add(APNsRegistration(
            token: String(repeating: "ab", count: 32),
            environment: .sandbox,
            label: "Phone"
        ))
        let apnsSender = APNsSenderSpy()
        let apns = APNsService(store: apnsStore, provider: apnsSender)
        let sync = NotificationSyncService(
            ledger: NotificationLedger(url: root.appendingPathComponent("ledger.json")),
            webPushService: webPush,
            apnsService: apns
        )
        let native = NotificationSpy()
        var active = true
        let router = RoutedNotificationPoster(
            native: native,
            sync: sync,
            isDesktopRecentlyActive: { active }
        )

        router.post(NotificationEvent(
            kind: .completed,
            title: "Complete",
            subtitle: "Project · Session",
            body: nil,
            projectId: "project",
            sessionId: "session"
        ))
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(native.events.count, 1)
        let suppressedWebPayload = await webSender.firstPayload()
        let suppressedAPNsPayloads = await apnsSender.sentPayloads()
        XCTAssertNil(suppressedWebPayload)
        XCTAssertTrue(suppressedAPNsPayloads.isEmpty)

        active = false
        router.post(NotificationEvent(
            kind: .permission,
            title: "Permission",
            subtitle: "Project · Session",
            body: nil,
            projectId: "project",
            sessionId: "session"
        ))
        for _ in 0 ..< 25 {
            if await webSender.firstPayload() != nil,
               await apnsSender.sentPayloads().count >= 1 {
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(native.events.count, 2)
        let firstWebPayload = await webSender.firstPayload()
        let webPayload = try XCTUnwrap(firstWebPayload)
        let sentAPNsPayloads = await apnsSender.sentPayloads()
        let payloadDecoder = JSONDecoder()
        payloadDecoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(
            try payloadDecoder.decode(RemoteNotificationPayload.self, from: webPayload).action,
            .show
        )
        XCTAssertEqual(sentAPNsPayloads.map(\.action), [.show])
    }

    func testNotificationDismissalFansOutOnceAndExcludesOriginDevice() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let firstToken = String(repeating: "ab", count: 32)
        let secondToken = String(repeating: "cd", count: 32)
        let apnsStore = APNsDeviceStore(url: root.appendingPathComponent("devices.json"))
        for token in [firstToken, secondToken] {
            try apnsStore.add(APNsRegistration(
                token: token,
                environment: .sandbox,
                label: token == firstToken ? "First" : "Second"
            ))
        }
        let sender = APNsSenderSpy()
        let apns = APNsService(store: apnsStore, provider: sender)
        let sync = NotificationSyncService(
            ledger: NotificationLedger(url: root.appendingPathComponent("ledger.json")),
            webPushService: nil,
            apnsService: apns
        )
        let event = NotificationEvent(
            kind: .elicitation,
            title: "Question",
            subtitle: "Project · Session",
            body: nil,
            projectId: "project",
            sessionId: "session"
        )
        sync.post(event, sendRemote: true)

        let request = NotificationDismissRequest(
            id: event.id,
            apnsToken: firstToken,
            apnsEnvironment: .sandbox
        )
        sync.dismiss(request)
        sync.dismiss(request)
        for _ in 0 ..< 25 {
            if await sender.sentPayloads().count >= 3 { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        let payloads = await sender.sentPayloads()
        let devices = await sender.sentDevices()
        XCTAssertEqual(payloads.map(\.action), [.show, .show, .clear])
        XCTAssertEqual(devices.last?.token, secondToken)
        XCTAssertEqual(sync.dismissalSnapshot().ids, [event.id])
    }

    func testNotificationDismissalFansOutWebPushClear() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let webStore = WebPushSubscriptionStore(
            url: root.appendingPathComponent("subscriptions.json")
        )
        try webStore.add(JSONDecoder().decode(
            WebPushRegistration.self,
            from: webPushRegistrationData(
                endpoint: "https://wns2-by3p.notify.windows.com/sub/clear"
            )
        ))
        let webSender = WebPushSenderSpy()
        let webPush = WebPushService(
            publicKey: VAPID.Key().id.description,
            store: webStore,
            sender: webSender
        )
        let sync = NotificationSyncService(
            ledger: NotificationLedger(url: root.appendingPathComponent("ledger.json")),
            webPushService: webPush,
            apnsService: nil
        )
        let event = NotificationEvent(
            kind: .permission,
            title: "Permission",
            subtitle: "Project · Session",
            body: nil,
            projectId: "project",
            sessionId: "session"
        )

        sync.post(event, sendRemote: true)
        sync.dismiss(NotificationDismissRequest(id: event.id))
        for _ in 0 ..< 25 {
            if await webSender.sentPayloads().count >= 2 { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let webPayloads = await webSender.sentPayloads()
        let actions = try webPayloads.map {
            try decoder.decode(RemoteNotificationPayload.self, from: $0).action
        }
        XCTAssertEqual(actions, [.show, .clear])
    }

    func testNotificationDismissalWaitsForInFlightShow() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let token = String(repeating: "ab", count: 32)
        let apnsStore = APNsDeviceStore(url: root.appendingPathComponent("devices.json"))
        try apnsStore.add(APNsRegistration(
            token: token,
            environment: .sandbox,
            label: "Phone"
        ))
        let sender = APNsSenderSpy()
        await sender.setShowDelayNanoseconds(100_000_000)
        let apns = APNsService(store: apnsStore, provider: sender)
        let sync = NotificationSyncService(
            ledger: NotificationLedger(url: root.appendingPathComponent("ledger.json")),
            webPushService: nil,
            apnsService: apns
        )
        let event = NotificationEvent(
            kind: .elicitation,
            title: "Question",
            subtitle: "Project · Session",
            body: nil,
            projectId: "project",
            sessionId: "session"
        )

        sync.post(event, sendRemote: true)
        sync.dismiss(NotificationDismissRequest(
            id: event.id,
            apnsToken: nil,
            apnsEnvironment: nil
        ))
        for _ in 0 ..< 20 {
            if await sender.sentPayloads().count >= 2 { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        let payloads = await sender.sentPayloads()
        XCTAssertEqual(payloads.map(\.action), [.show, .clear])
    }

    func testFocusDeepLinkParsing() throws {
        XCTAssertEqual(
            AppDeepLink(url: try XCTUnwrap(URL(
                string: "copilot-projects://focus?project=project-1"
            ))),
            AppDeepLink(projectId: "project-1", sessionId: nil)
        )
        XCTAssertEqual(
            AppDeepLink(url: try XCTUnwrap(URL(
                string: "copilot-projects://focus?session=session%202"
            ))),
            AppDeepLink(projectId: nil, sessionId: "session 2")
        )
        XCTAssertEqual(
            AppDeepLink(url: try XCTUnwrap(URL(
                string: "copilot-projects://focus?project=&project=project-2&session=session-2"
            ))),
            AppDeepLink(projectId: "project-2", sessionId: "session-2")
        )
    }

    func testFocusDeepLinkRejectsUnsupportedOrEmptyURLs() throws {
        XCTAssertNil(AppDeepLink(url: try XCTUnwrap(URL(
            string: "https://focus?session=session-1"
        ))))
        XCTAssertNil(AppDeepLink(url: try XCTUnwrap(URL(
            string: "copilot-projects://notify?session=session-1"
        ))))
        XCTAssertNil(AppDeepLink(url: try XCTUnwrap(URL(
            string: "copilot-projects://focus?project=&session=%20"
        ))))
    }

    func testFocusDeepLinkBuildsRequestAndLocatesParentApplication() throws {
        let deepLink = AppDeepLink(projectId: "project-1", sessionId: "session-1")
        XCTAssertEqual(deepLink.focusRequest.command, "focus")
        XCTAssertEqual(deepLink.focusRequest.projectId, "project-1")
        XCTAssertEqual(deepLink.focusRequest.sessionId, "session-1")

        let helperURL = URL(fileURLWithPath:
            "/Applications/Copilot Projects.app/Contents/Helpers/Copilot Projects Link.app")
        XCTAssertEqual(
            AppDeepLink.parentApplicationURL(forHelperBundleURL: helperURL)?.path,
            "/Applications/Copilot Projects.app"
        )
        XCTAssertNil(AppDeepLink.parentApplicationURL(
            forHelperBundleURL: URL(fileURLWithPath: "/Applications/Other.app")
        ))
    }

    func testCopilotHookHandlesSessionIdleAndCapabilityLifecycle() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let hookURL = root.appendingPathComponent("copilot-projects-hook.sh")
        try CopilotHooks.script.write(to: hookURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookURL.path)

        let capture = root.appendingPathComponent("cli-args.txt")
        let fakeCLI = bin.appendingPathComponent("copilot-projects")
        try """
        #!/bin/sh
        printf '%s\n' "$*" >> "$CAPTURE_FILE"
        """.write(to: fakeCLI, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCLI.path)

        let tabId = UUID().uuidString
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        let capability = sessions.appendingPathComponent("\(tabId).session-idle-hook")
        let backgroundAgents = sessions.appendingPathComponent("\(tabId).background-agents")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try Data().write(to: backgroundAgents)

        try runHook(
            hookURL: hookURL,
            action: "notify",
            payload: #"{"timestamp":200,"notification_type":"session_idle","aborted":true}"#,
            tabId: tabId,
            root: root,
            bin: bin,
            capture: capture
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: capability.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backgroundAgents.path))
        XCTAssertEqual(
            try String(contentsOf: sessions.appendingPathComponent("\(tabId).status"), encoding: .utf8),
            "idle"
        )
        XCTAssertEqual(
            try String(
                contentsOf: sessions.appendingPathComponent("\(tabId).status-timestamp"),
                encoding: .utf8
            ),
            "200"
        )
        XCTAssertTrue(
            try String(contentsOf: capture, encoding: .utf8)
                .contains("set-status idle --timestamp 200 --source session-idle")
        )

        try Data().write(to: backgroundAgents)
        try runHook(
            hookURL: hookURL,
            action: "start",
            payload: #"{"timestamp":300}"#,
            tabId: tabId,
            root: root,
            bin: bin,
            capture: capture
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: capability.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backgroundAgents.path))
    }

    func testCopilotHookDelegatesSessionEndResumeCleanupToApp() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let hookURL = root.appendingPathComponent("copilot-projects-hook.sh")
        try CopilotHooks.script.write(to: hookURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: hookURL.path
        )

        let capture = root.appendingPathComponent("cli-args.txt")
        let fakeCLI = bin.appendingPathComponent("copilot-projects")
        try """
        #!/bin/sh
        printf '%s\n' "$*" >> "$CAPTURE_FILE"
        """.write(to: fakeCLI, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fakeCLI.path
        )

        let tabId = UUID().uuidString
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let marker = sessions.appendingPathComponent("\(tabId).copilot-session")
        try Data(UUID().uuidString.utf8).write(to: marker)

        try runHook(
            hookURL: hookURL,
            action: "end",
            payload: #"{"timestamp":200,"reason":"user_exit"}"#,
            tabId: tabId,
            root: root,
            bin: bin,
            capture: capture
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertEqual(
            try cliCallLines(in: capture),
            ["set-status idle --timestamp 200 --source session-end"]
        )

        let copilotSessionId = UUID().uuidString
        try runHook(
            hookURL: hookURL,
            action: "end",
            payload: #"{"timestamp":210,"reason":"user_exit","sessionId":"\#(copilotSessionId)"}"#,
            tabId: tabId,
            root: root,
            bin: bin,
            capture: capture
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertEqual(
            try cliCallLines(in: capture).last,
            "set-status idle --timestamp 210 --source session-end --copilot-session \(copilotSessionId)"
        )
    }

    func testCopilotHookDoesNotOverwriteResumeMarkerFromInheritedHelper() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let hookURL = root.appendingPathComponent("copilot-projects-hook.sh")
        try CopilotHooks.script.write(to: hookURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookURL.path)

        let capture = root.appendingPathComponent("cli-args.txt")
        let fakeCLI = bin.appendingPathComponent("copilot-projects")
        try """
        #!/bin/sh
        printf '%s\n' "$*" >> "$CAPTURE_FILE"
        """.write(to: fakeCLI, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCLI.path)

        let tabId = UUID().uuidString
        let ownerCopilotSession = UUID().uuidString
        let helperCopilotSession = UUID().uuidString
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let marker = sessions.appendingPathComponent("\(tabId).copilot-session")
        try Data(ownerCopilotSession.utf8).write(to: marker)

        try runHook(
            hookURL: hookURL,
            action: "pre",
            payload: #"{"timestamp":200,"sessionId":"\#(helperCopilotSession)"}"#,
            tabId: tabId,
            root: root,
            bin: bin,
            capture: capture
        )

        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), ownerCopilotSession)
    }

    func testCopilotHookRoutesNativeNotificationsForWaitingAndCompletedTurns() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let hookURL = root.appendingPathComponent("copilot-projects-hook.sh")
        try CopilotHooks.script.write(to: hookURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookURL.path)

        let capture = root.appendingPathComponent("cli-args.txt")
        let fakeCLI = bin.appendingPathComponent("copilot-projects")
        try """
        #!/bin/sh
        printf '%s\n' "$*" >> "$CAPTURE_FILE"
        """.write(to: fakeCLI, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCLI.path)

        let tabId = UUID().uuidString
        try runHook(
            hookURL: hookURL,
            action: "start",
            payload: #"{"timestamp":100}"#,
            tabId: tabId,
            root: root,
            bin: bin,
            capture: capture
        )
        try runHook(
            hookURL: hookURL,
            action: "notify",
            payload: #"{"timestamp":110,"notification_type":"session_idle","aborted":false}"#,
            tabId: tabId,
            root: root,
            bin: bin,
            capture: capture
        )

        try runHook(
            hookURL: hookURL,
            action: "notify",
            payload: #"{"timestamp":120,"notification_type":"elicitation_dialog"}"#,
            tabId: tabId,
            root: root,
            bin: bin,
            capture: capture
        )
        var cliCalls = try cliCallLines(in: capture)
        XCTAssertEqual(cliCalls, [
            "set-status idle --timestamp 100",
            "set-status idle --timestamp 110 --source session-idle",
            "set-status waiting --timestamp 120 --notification elicitation",
        ])

        try runHook(
            hookURL: hookURL,
            action: "notify",
            payload: #"{"timestamp":125,"notification_type":"permission_prompt"}"#,
            tabId: tabId,
            root: root,
            bin: bin,
            capture: capture
        )
        cliCalls = try cliCallLines(in: capture)
        XCTAssertEqual(cliCalls.last, "set-status waiting --timestamp 125")

        try runHook(
            hookURL: hookURL,
            action: "running",
            payload: #"{"timestamp":130}"#,
            tabId: tabId,
            root: root,
            bin: bin,
            capture: capture
        )
        try runHook(
            hookURL: hookURL,
            action: "idle",
            payload: #"{"timestamp":135}"#,
            tabId: tabId,
            root: root,
            bin: bin,
            capture: capture
        )
        cliCalls = try cliCallLines(in: capture)
        XCTAssertEqual(cliCalls.suffix(2), [
            "set-status running --timestamp 130",
            "set-status idle --timestamp 135 --source agent-stop",
        ])
        try runHook(
            hookURL: hookURL,
            action: "notify",
            payload: #"{"timestamp":140,"notification_type":"session_idle","aborted":false}"#,
            tabId: tabId,
            root: root,
            bin: bin,
            capture: capture
        )
        cliCalls = try cliCallLines(in: capture)
        XCTAssertEqual(
            cliCalls.last,
            "set-status idle --timestamp 140 --source session-idle --notification completed"
        )
        XCTAssertEqual(completionSignals(in: cliCalls), 2)

        try runHook(
            hookURL: hookURL,
            action: "running",
            payload: #"{"timestamp":150}"#,
            tabId: tabId,
            root: root,
            bin: bin,
            capture: capture
        )
        try runHook(
            hookURL: hookURL,
            action: "notify",
            payload: #"{"timestamp":160,"notification_type":"session_idle","aborted":false}"#,
            tabId: tabId,
            root: root,
            bin: bin,
            capture: capture
        )
        cliCalls = try cliCallLines(in: capture)
        XCTAssertEqual(
            cliCalls.last,
            "set-status idle --timestamp 160 --source session-idle --notification completed"
        )
        let completionSignalCount = completionSignals(in: cliCalls)
        XCTAssertEqual(completionSignalCount, 3)

        try runHook(
            hookURL: hookURL,
            action: "running",
            payload: #"{"timestamp":170}"#,
            tabId: tabId,
            root: root,
            bin: bin,
            capture: capture
        )
        try runHook(
            hookURL: hookURL,
            action: "notify",
            payload: #"{"timestamp":180,"notification_type":"session_idle","unaborted":true,"aborted":true}"#,
            tabId: tabId,
            root: root,
            bin: bin,
            capture: capture
        )
        cliCalls = try cliCallLines(in: capture)
        XCTAssertEqual(completionSignals(in: cliCalls), completionSignalCount)
        XCTAssertEqual(
            cliCalls.last,
            "set-status idle --timestamp 180 --source session-idle"
        )

        try runHook(
            hookURL: hookURL,
            action: "running",
            payload: #"{"timestamp":190}"#,
            tabId: tabId,
            root: root,
            bin: bin,
            capture: capture
        )
        try runHook(
            hookURL: hookURL,
            action: "idle",
            payload: #"{"timestamp":195,"aborted":true}"#,
            tabId: tabId,
            root: root,
            bin: bin,
            capture: capture
        )
        cliCalls = try cliCallLines(in: capture)
        XCTAssertEqual(completionSignals(in: cliCalls), completionSignalCount)
        XCTAssertEqual(cliCalls.suffix(2), [
            "set-status running --timestamp 190",
            "set-status idle --timestamp 195",
        ])
        XCTAssertEqual(cliCalls.count, 13)
    }

    func testCopilotHookKeepsScheduledTurnsOutOfForegroundStatus() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let hookURL = root.appendingPathComponent("copilot-projects-hook.sh")
        try CopilotHooks.script.write(to: hookURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookURL.path)

        let capture = root.appendingPathComponent("cli-args.txt")
        let fakeCLI = bin.appendingPathComponent("copilot-projects")
        try """
        #!/bin/sh
        printf '%s\n' "$*" >> "$CAPTURE_FILE"
        """.write(to: fakeCLI, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCLI.path)

        let tabId = UUID().uuidString
        try runHook(
            hookURL: hookURL,
            action: "running",
            payload: #"{"timestamp":100,"prompt":"[Scheduled prompt #16] Check PRs"}"#,
            tabId: tabId,
            root: root,
            bin: bin,
            capture: capture
        )
        try runHook(
            hookURL: hookURL,
            action: "pre",
            payload: #"{"timestamp":110}"#,
            tabId: tabId,
            root: root,
            bin: bin,
            capture: capture
        )
        try runHook(
            hookURL: hookURL,
            action: "idle",
            payload: #"{"timestamp":115}"#,
            tabId: tabId,
            root: root,
            bin: bin,
            capture: capture
        )
        try runHook(
            hookURL: hookURL,
            action: "notify",
            payload: #"{"timestamp":120,"notification_type":"session_idle","aborted":false}"#,
            tabId: tabId,
            root: root,
            bin: bin,
            capture: capture
        )

        let calls = try cliCallLines(in: capture)
        XCTAssertTrue(calls.contains("set-status idle --timestamp 100 --source scheduled-start"))
        XCTAssertTrue(calls.contains("set-status idle --timestamp 110 --source scheduled-active"))
        XCTAssertTrue(calls.contains("set-status idle --timestamp 115 --source scheduled-idle"))
        XCTAssertTrue(calls.contains("set-status idle --timestamp 120 --source session-idle"))
        XCTAssertFalse(calls.contains { $0.contains("--notification completed") })
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("sessions/\(tabId).scheduled-turn").path
        ))
    }

    @MainActor
    func testAgentActivitySnapshotTracksSchedulesAndBackgroundWork() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let activityDirectory = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(
            at: activityDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let targetSession = Session(title: "target", cwd: "/tmp")
        defer { SessionArtifacts.removeFiles(sessionId: targetSession.id) }
        let targetProject = Project(name: "target", cwd: "/tmp", sessions: [targetSession])
        let selectedProject = Project(name: "selected", cwd: "/tmp")
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(
            projects: [targetProject, selectedProject],
            selectedProjectId: selectedProject.id
        ))

        let snapshot = AgentActivitySnapshot(
            schemaVersion: 1,
            updatedAt: ISO8601DateFormatter().string(from: Date()),
            foregroundTurnActive: false,
            scheduledTurnActive: true,
            activeSubagents: [
                TrackedSubagent(
                    id: "agent-1",
                    name: "reviewer",
                    description: "Reviews the PR",
                    model: "gpt"
                ),
            ],
            schedules: [
                TrackedSchedule(
                    id: 16,
                    intervalMs: 600_000,
                    cron: nil,
                    tz: nil,
                    at: nil,
                    prompt: "Check PRs",
                    recurring: true,
                    displayPrompt: "/my-prs-status",
                    nextRunAt: ISO8601DateFormatter().string(
                        from: Date().addingTimeInterval(600)
                    )
                ),
            ],
            idleGeneration: 0,
            lastIdleAborted: false,
            lastIdleTurnKind: nil,
            error: nil
        )
        let path = activityDirectory
            .appendingPathComponent("\(targetSession.id).agent-activity.json")
        try JSONEncoder().encode(snapshot).write(to: path)

        let model = AppModel(
            stateRepository: repository,
            agentActivityDirectory: activityDirectory
        )
        model.refreshAgentActivitySnapshots()

        XCTAssertEqual(model.projects[0].sessions[0].status, .idle)
        XCTAssertTrue(model.projects[0].sessions[0].scheduledTurnActive)
        XCTAssertEqual(model.projects[0].sessions[0].activeSubagentCount, 1)
        XCTAssertEqual(model.projects[0].sessions[0].schedules.first?.id, 16)
        XCTAssertTrue(model.projects[0].sessions[0].schedules[0].helpText.contains(
            "Every 10m"
        ))
        XCTAssertTrue(model.projects[0].sessions[0].schedules[0].helpText.contains(
            "Runs next at"
        ))
        XCTAssertEqual(model.totalScheduled, 1)

        var stale = snapshot
        stale.updatedAt = "2000-01-01T00:00:00Z"
        try JSONEncoder().encode(stale).write(to: path)
        model.refreshAgentActivitySnapshots()

        XCTAssertNil(model.projects[0].sessions[0].agentActivity)
        XCTAssertFalse(model.projects[0].sessions[0].scheduledTurnActive)
    }

    @MainActor
    func testAnswerUserInputEnforcesChoiceFreeformSizeAndSession() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let directory = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let session = Session(id: "session-ui", title: "target", cwd: "/tmp")
        let project = Project(name: "target", cwd: "/tmp", sessions: [session])
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(projects: [project], selectedProjectId: project.id))

        let snapshotURL = directory.appendingPathComponent("\(session.id).agent-activity.json")
        let responseURL = directory
            .appendingPathComponent("\(session.id).user-input-response.json")
        let markerURL = directory.appendingPathComponent("\(session.id).copilot-session")

        func writeSnapshot(updatedAt: Date) throws {
            let snapshot = AgentActivitySnapshot(
                schemaVersion: 1,
                updatedAt: ISO8601DateFormatter().string(from: updatedAt),
                foregroundTurnActive: false,
                scheduledTurnActive: false,
                activeSubagents: [],
                schedules: [],
                idleGeneration: 0,
                lastIdleAborted: false,
                lastIdleTurnKind: nil,
                error: nil,
                trackedUserInputs: [
                    TrackedUserInput(
                        requestId: "req-choice",
                        question: "Deploy?",
                        choices: ["Yes, deploy", "No"],
                        allowFreeform: false,
                        requestedAt: ISO8601DateFormatter().string(from: updatedAt),
                        agentId: nil
                    ),
                    TrackedUserInput(
                        requestId: "req-free",
                        question: "Name it",
                        choices: [],
                        allowFreeform: true,
                        requestedAt: ISO8601DateFormatter().string(from: updatedAt),
                        agentId: "agent-2"
                    ),
                ]
            )
            try JSONEncoder().encode(snapshot).write(to: snapshotURL)
        }
        try writeSnapshot(updatedAt: Date())
        try Data("copilot-session".utf8).write(to: markerURL)

        let model = AppModel(
            stateRepository: repository,
            agentActivityDirectory: directory,
            resumeMarkerDirectory: directory
        )

        // Unknown request id → no valid question.
        XCTAssertEqual(
            model.answerUserInput(
                sessionId: session.id,
                answer: RemoteUserInputAnswer(
                    requestId: "missing", answer: "Yes, deploy", wasFreeform: false
                )
            ),
            .invalid
        )
        // A selectable answer must match a choice verbatim.
        XCTAssertEqual(
            model.answerUserInput(
                sessionId: session.id,
                answer: RemoteUserInputAnswer(
                    requestId: "req-choice", answer: "yes, deploy", wasFreeform: false
                )
            ),
            .invalid
        )
        // Freeform is rejected when the request does not allow it.
        XCTAssertEqual(
            model.answerUserInput(
                sessionId: session.id,
                answer: RemoteUserInputAnswer(
                    requestId: "req-choice", answer: "Yes, deploy", wasFreeform: true
                )
            ),
            .invalid
        )
        // Oversized answers are rejected.
        XCTAssertEqual(
            model.answerUserInput(
                sessionId: session.id,
                answer: RemoteUserInputAnswer(
                    requestId: "req-free",
                    answer: String(repeating: "a", count: 8_193),
                    wasFreeform: true
                )
            ),
            .invalid
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: responseURL.path))

        // A valid verbatim-choice answer is accepted and atomically written 0600.
        XCTAssertEqual(
            model.answerUserInput(
                sessionId: session.id,
                answer: RemoteUserInputAnswer(
                    requestId: "req-choice", answer: "Yes, deploy", wasFreeform: false
                )
            ),
            .accepted
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: responseURL.path))
        let attributes = try FileManager.default.attributesOfItem(atPath: responseURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let written = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: responseURL))
                as? [String: Any]
        )
        XCTAssertEqual(written["schemaVersion"] as? Int, 1)
        XCTAssertEqual(written["copilotSessionId"] as? String, "copilot-session")
        XCTAssertEqual(written["requestId"] as? String, "req-choice")
        XCTAssertEqual(written["answer"] as? String, "Yes, deploy")
        XCTAssertEqual(written["wasFreeform"] as? Bool, false)

        // A second answer conflicts while the prior response is still awaiting pickup.
        XCTAssertEqual(
            model.answerUserInput(
                sessionId: session.id,
                answer: RemoteUserInputAnswer(
                    requestId: "req-free", answer: "hello", wasFreeform: true
                )
            ),
            .conflict
        )

        // Once the extension consumes the response, a fresh freeform answer is accepted.
        try FileManager.default.removeItem(at: responseURL)
        XCTAssertEqual(
            model.answerUserInput(
                sessionId: session.id,
                answer: RemoteUserInputAnswer(
                    requestId: "req-free", answer: "hello", wasFreeform: true
                )
            ),
            .accepted
        )
        try FileManager.default.removeItem(at: responseURL)

        // A stale heartbeat can no longer be answered.
        try writeSnapshot(updatedAt: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(
            model.answerUserInput(
                sessionId: session.id,
                answer: RemoteUserInputAnswer(
                    requestId: "req-choice", answer: "Yes, deploy", wasFreeform: false
                )
            ),
            .invalid
        )

        // Without a live Copilot session marker the answer cannot be bound to context.
        try writeSnapshot(updatedAt: Date())
        try FileManager.default.removeItem(at: markerURL)
        XCTAssertEqual(
            model.answerUserInput(
                sessionId: session.id,
                answer: RemoteUserInputAnswer(
                    requestId: "req-choice", answer: "Yes, deploy", wasFreeform: false
                )
            ),
            .invalid
        )
    }

    @MainActor
    func testAnswerElicitationValidatesActionContentAndSession() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let directory = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let session = Session(id: "session-elicit", title: "target", cwd: "/tmp")
        let project = Project(name: "target", cwd: "/tmp", sessions: [session])
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(projects: [project], selectedProjectId: project.id))

        let snapshotURL = directory.appendingPathComponent("\(session.id).agent-activity.json")
        let responseURL = directory
            .appendingPathComponent("\(session.id).elicitation-response.json")
        let markerURL = directory.appendingPathComponent("\(session.id).copilot-session")

        func writeSnapshot(updatedAt: Date) throws {
            let snapshot = AgentActivitySnapshot(
                schemaVersion: 1,
                updatedAt: ISO8601DateFormatter().string(from: updatedAt),
                foregroundTurnActive: false,
                scheduledTurnActive: false,
                activeSubagents: [],
                schedules: [],
                idleGeneration: 0,
                lastIdleAborted: false,
                lastIdleTurnKind: nil,
                error: nil,
                trackedUserInputs: nil,
                trackedElicitations: [
                    TrackedElicitation(
                        requestId: "req-form",
                        message: "Pick a fruit",
                        mode: "form",
                        url: nil,
                        schema: .object([
                            "type": .string("object"),
                            "required": .array([.string("fruit")]),
                            "properties": .object([
                                "fruit": .object([
                                    "type": .string("string"),
                                    "oneOf": .array([
                                        .object([
                                            "const": .string("apple"),
                                            "title": .string("Apple"),
                                        ]),
                                        .object([
                                            "const": .string("pear"),
                                            "title": .string("Pear"),
                                        ]),
                                    ]),
                                ]),
                                "ripe": .object(["type": .string("boolean")]),
                                "count": .object([
                                    "type": .string("number"),
                                    "minimum": .number(1),
                                    "maximum": .number(3),
                                ]),
                                "colors": .object([
                                    "type": .string("array"),
                                    "items": .object([
                                        "anyOf": .array([
                                            .object(["const": .string("red")]),
                                            .object(["const": .string("green")]),
                                        ]),
                                    ]),
                                ]),
                                "nickname": .object([
                                    "type": .string("string"),
                                    "minLength": .number(1e300),
                                ]),
                                "emojiCodepoints": .object([
                                    "type": .string("string"),
                                    "minLength": .number(2),
                                ]),
                                "email": .object([
                                    "type": .string("string"),
                                    "format": .string("email"),
                                ]),
                                "uri": .object([
                                    "type": .string("string"),
                                    "format": .string("uri"),
                                ]),
                                "date": .object([
                                    "type": .string("string"),
                                    "format": .string("date"),
                                ]),
                                "dateTime": .object([
                                    "type": .string("string"),
                                    "format": .string("date-time"),
                                ]),
                                "tokens": .object([
                                    "type": .string("array"),
                                    "minItems": .number(1e300),
                                ]),
                            ]),
                        ]),
                        elicitationSource: nil,
                        requestedAt: ISO8601DateFormatter().string(from: updatedAt),
                        agentId: nil
                    ),
                    TrackedElicitation(
                        requestId: "req-url",
                        message: "Open this URL?",
                        mode: nil,
                        url: "https://example.com/elicit",
                        schema: nil,
                        elicitationSource: nil,
                        requestedAt: ISO8601DateFormatter().string(from: updatedAt),
                        agentId: nil
                    )
                ]
            )
            try JSONEncoder().encode(snapshot).write(to: snapshotURL)
        }
        try writeSnapshot(updatedAt: Date())
        try Data("copilot-session".utf8).write(to: markerURL)

        let model = AppModel(
            stateRepository: repository,
            agentActivityDirectory: directory,
            resumeMarkerDirectory: directory
        )

        // Unknown request id → invalid.
        XCTAssertEqual(
            model.answerElicitation(
                sessionId: session.id,
                answer: RemoteElicitationAnswer(
                    requestId: "missing", action: .accept,
                    content: ["fruit": .string("apple")]
                )
            ),
            .invalid
        )
        // accept without content → invalid.
        XCTAssertEqual(
            model.answerElicitation(
                sessionId: session.id,
                answer: RemoteElicitationAnswer(requestId: "req-form", action: .accept)
            ),
            .invalid
        )
        // decline WITH content → invalid.
        XCTAssertEqual(
            model.answerElicitation(
                sessionId: session.id,
                answer: RemoteElicitationAnswer(
                    requestId: "req-form", action: .decline,
                    content: ["fruit": .string("apple")]
                )
            ),
            .invalid
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: responseURL.path))

        let unsupportedContents: [[String: RemoteJSONValue]] = [
            ["fruit": .null],
            ["fruit": .number(2)],
            ["fruit": .string("banana")],
            ["fruit": .object(["name": .string("apple")])],
            ["fruit": .array([.number(1)])],
            ["fruit": .array([.array([.string("apple")])])],
            ["ripe": .bool(true)],
            ["fruit": .string("apple"), "count": .number(4)],
            ["fruit": .string("apple"), "colors": .array([.string("blue")])],
            ["fruit": .string("apple"), "nickname": .string("a")],
            ["fruit": .string("apple"), "tokens": .array([])],
            ["fruit": .string("apple"), "email": .string("not an email")],
            ["fruit": .string("apple"), "uri": .string("not a uri")],
            ["fruit": .string("apple"), "date": .string("2026-99-99")],
            ["fruit": .string("apple"), "dateTime": .string("tomorrow")],
            ["fruit": .string("apple"), "extra": .string("x")],
        ]
        for unsupportedContent in unsupportedContents {
            XCTAssertEqual(
                model.answerElicitation(
                    sessionId: session.id,
                    answer: RemoteElicitationAnswer(
                        requestId: "req-form", action: .accept,
                        content: unsupportedContent
                    )
                ),
                .invalid
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: responseURL.path))

        // Valid accept with content is written 0600 with the expected payload.
        XCTAssertEqual(
            model.answerElicitation(
                sessionId: session.id,
                answer: RemoteElicitationAnswer(
                    requestId: "req-form", action: .accept,
                    content: [
                        "fruit": .string("apple"),
                        "ripe": .bool(true),
                        "count": .number(2),
                        "colors": .array([.string("red"), .string("green")]),
                        "emojiCodepoints": .string("👨‍👩‍👧‍👦"),
                        "email": .string("user@example.com"),
                        "uri": .string("https://example.com/elicit"),
                        "date": .string("2026-07-13"),
                        "dateTime": .string("2026-07-13T21:00:00.123Z"),
                    ]
                )
            ),
            .accepted
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: responseURL.path))
        let attributes = try FileManager.default.attributesOfItem(atPath: responseURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let written = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: responseURL))
                as? [String: Any]
        )
        XCTAssertEqual(written["schemaVersion"] as? Int, 1)
        XCTAssertEqual(written["copilotSessionId"] as? String, "copilot-session")
        XCTAssertEqual(written["requestId"] as? String, "req-form")
        XCTAssertEqual(written["action"] as? String, "accept")
        XCTAssertEqual((written["content"] as? [String: Any])?["fruit"] as? String, "apple")
        XCTAssertEqual((written["content"] as? [String: Any])?["ripe"] as? Bool, true)
        XCTAssertEqual((written["content"] as? [String: Any])?["count"] as? Double, 2)
        XCTAssertEqual(
            (written["content"] as? [String: Any])?["colors"] as? [String],
            ["red", "green"]
        )
        XCTAssertEqual(
            (written["content"] as? [String: Any])?["emojiCodepoints"] as? String,
            "👨‍👩‍👧‍👦"
        )
        XCTAssertEqual((written["content"] as? [String: Any])?["email"] as? String,
                       "user@example.com")
        XCTAssertEqual((written["content"] as? [String: Any])?["uri"] as? String,
                       "https://example.com/elicit")
        XCTAssertEqual((written["content"] as? [String: Any])?["date"] as? String,
                       "2026-07-13")
        XCTAssertEqual((written["content"] as? [String: Any])?["dateTime"] as? String,
                       "2026-07-13T21:00:00.123Z")

        // A second answer conflicts while the prior response awaits pickup.
        XCTAssertEqual(
            model.answerElicitation(
                sessionId: session.id,
                answer: RemoteElicitationAnswer(requestId: "req-form", action: .cancel)
            ),
            .conflict
        )

        // After the extension consumes it, a decline (no content) is accepted.
        try FileManager.default.removeItem(at: responseURL)
        XCTAssertEqual(
            model.answerElicitation(
                sessionId: session.id,
                answer: RemoteElicitationAnswer(requestId: "req-form", action: .decline)
            ),
            .accepted
        )
        try FileManager.default.removeItem(at: responseURL)

        XCTAssertEqual(
            model.answerElicitation(
                sessionId: session.id,
                answer: RemoteElicitationAnswer(
                    requestId: "req-url", action: .accept,
                    content: ["ignored": .string("value")]
                )
            ),
            .invalid
        )
        XCTAssertEqual(
            model.answerElicitation(
                sessionId: session.id,
                answer: RemoteElicitationAnswer(requestId: "req-url", action: .accept)
            ),
            .accepted
        )
        let writtenURLAccept = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: responseURL))
                as? [String: Any]
        )
        XCTAssertEqual(writtenURLAccept["requestId"] as? String, "req-url")
        XCTAssertEqual(writtenURLAccept["action"] as? String, "accept")
        XCTAssertNil(writtenURLAccept["content"])
        try FileManager.default.removeItem(at: responseURL)

        // A stale heartbeat can no longer be answered.
        try writeSnapshot(updatedAt: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(
            model.answerElicitation(
                sessionId: session.id,
                answer: RemoteElicitationAnswer(requestId: "req-form", action: .cancel)
            ),
            .invalid
        )

        // Without a live Copilot session marker the answer cannot be bound.
        try writeSnapshot(updatedAt: Date())
        try FileManager.default.removeItem(at: markerURL)
        XCTAssertEqual(
            model.answerElicitation(
                sessionId: session.id,
                answer: RemoteElicitationAnswer(requestId: "req-form", action: .cancel)
            ),
            .invalid
        )
    }

    @MainActor
    func testScheduledIdleTurnDoesNotPostCompletionNotification() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let activityDirectory = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(
            at: activityDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let targetSession = Session(title: "scheduled", cwd: "/tmp")
        let targetProject = Project(name: "target", cwd: "/tmp", sessions: [targetSession])
        let selectedProject = Project(name: "selected", cwd: "/tmp")
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(
            projects: [targetProject, selectedProject],
            selectedProjectId: selectedProject.id
        ))

        let snapshot = AgentActivitySnapshot(
            schemaVersion: 1,
            updatedAt: ISO8601DateFormatter().string(from: Date()),
            foregroundTurnActive: false,
            scheduledTurnActive: false,
            activeSubagents: [],
            schedules: [],
            idleGeneration: 1,
            lastIdleAborted: false,
            lastIdleTurnKind: "scheduled",
            error: nil
        )
        let path = activityDirectory
            .appendingPathComponent("\(targetSession.id).agent-activity.json")
        try JSONEncoder().encode(snapshot).write(to: path)

        let model = AppModel(
            stateRepository: repository,
            completionNotificationDelayNanoseconds: 10_000_000,
            agentActivityDirectory: activityDirectory
        )
        let notifications = NotificationSpy()
        model.attach(notifications: notifications)
        model.refreshAgentActivitySnapshots()
        model.setStatus(
            sessionId: targetSession.id,
            status: .idle,
            text: nil,
            timestamp: 100,
            source: "scheduled-start"
        )
        model.setStatus(
            sessionId: targetSession.id,
            status: .idle,
            text: nil,
            timestamp: 200,
            source: "agent-stop"
        )
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertTrue(notifications.calls.isEmpty)
    }

    @MainActor
    func testStaleScheduledIdleDoesNotSuppressNextForegroundCompletion() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let activityDirectory = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(
            at: activityDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let targetSession = Session(title: "foreground", cwd: "/tmp")
        let targetProject = Project(name: "target", cwd: "/tmp", sessions: [targetSession])
        let selectedProject = Project(name: "selected", cwd: "/tmp")
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(
            projects: [targetProject, selectedProject],
            selectedProjectId: selectedProject.id
        ))

        let snapshot = AgentActivitySnapshot(
            schemaVersion: 1,
            updatedAt: ISO8601DateFormatter().string(from: Date()),
            foregroundTurnActive: false,
            scheduledTurnActive: false,
            activeSubagents: [],
            schedules: [],
            idleGeneration: 1,
            lastIdleAborted: false,
            lastIdleTurnKind: "scheduled",
            error: nil
        )
        let path = activityDirectory
            .appendingPathComponent("\(targetSession.id).agent-activity.json")
        try JSONEncoder().encode(snapshot).write(to: path)

        let model = AppModel(
            stateRepository: repository,
            completionNotificationDelayNanoseconds: 10_000_000,
            agentActivityDirectory: activityDirectory
        )
        let notifications = NotificationSpy()
        model.attach(notifications: notifications)
        model.refreshAgentActivitySnapshots()
        model.setStatus(
            sessionId: targetSession.id,
            status: .running,
            text: nil,
            timestamp: 100
        )
        model.setStatus(
            sessionId: targetSession.id,
            status: .idle,
            text: nil,
            timestamp: 200,
            source: "agent-stop"
        )
        for _ in 0 ..< 50 {
            if notifications.calls.count == 1 { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertEqual(notifications.calls.count, 1)
        XCTAssertEqual(
            notifications.calls.first?.title,
            StatusNotificationKind.completed.title
        )
    }

    func testAgentStopAndSessionIdleAtomicallyClaimCompletion() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let hookURL = root.appendingPathComponent("copilot-projects-hook.sh")
        try CopilotHooks.script.write(to: hookURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookURL.path)

        let capture = root.appendingPathComponent("cli-args.txt")
        let fakeCLI = bin.appendingPathComponent("copilot-projects")
        try """
        #!/bin/sh
        printf '%s\n' "$*" >> "$CAPTURE_FILE"
        """.write(to: fakeCLI, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCLI.path)

        let tabId = UUID().uuidString
        try runHook(
            hookURL: hookURL,
            action: "running",
            payload: #"{"timestamp":100}"#,
            tabId: tabId,
            root: root,
            bin: bin,
            capture: capture
        )

        let agentStop = try startHook(
            hookURL: hookURL,
            action: "idle",
            payload: #"{"timestamp":110}"#,
            tabId: tabId,
            root: root,
            bin: bin,
            capture: capture
        )
        let sessionIdle = try startHook(
            hookURL: hookURL,
            action: "notify",
            payload: #"{"timestamp":111,"notification_type":"session_idle","aborted":false}"#,
            tabId: tabId,
            root: root,
            bin: bin,
            capture: capture
        )
        agentStop.waitUntilExit()
        sessionIdle.waitUntilExit()
        XCTAssertEqual(agentStop.terminationStatus, 0)
        XCTAssertEqual(sessionIdle.terminationStatus, 0)

        let cliCalls = try cliCallLines(in: capture)
        XCTAssertEqual(cliCalls.count, 3)
        XCTAssertTrue(cliCalls.contains("set-status running --timestamp 100"))
        XCTAssertEqual(cliCalls.filter { $0.contains("--timestamp 110") }.count, 1)
        XCTAssertEqual(cliCalls.filter { $0.contains("--timestamp 111") }.count, 1)
        XCTAssertTrue((1...2).contains(completionSignals(in: cliCalls)))
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: sessions.appendingPathComponent("\(tabId).active-turn").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: sessions.appendingPathComponent("\(tabId).agent-stop-completion").path
        ))
    }

    func testStatusNotificationTitlesDescribeWhyCopilotNeedsAttention() {
        XCTAssertEqual(StatusNotificationKind.elicitation.title, "Copilot has a question")
        XCTAssertEqual(StatusNotificationKind.permission.title, "Copilot needs permission")
        XCTAssertEqual(StatusNotificationKind.completed.title, "Copilot finished a task")
        XCTAssertEqual(
            AppModel.notificationSubtitle(projectName: "Checkout", sessionTitle: "Fix taxes"),
            "Checkout · Fix taxes"
        )
        XCTAssertTrue(AppModel.isSessionVisible(
            appIsActive: true,
            selectedProjectId: "project",
            projectId: "project",
            selectedSessionId: "session",
            sessionId: "session"
        ))
        XCTAssertFalse(AppModel.isSessionVisible(
            appIsActive: false,
            selectedProjectId: "project",
            projectId: "project",
            selectedSessionId: "session",
            sessionId: "session"
        ))
        XCTAssertFalse(AppModel.canPostCompletion(status: .running, activity: .idle))
        XCTAssertFalse(AppModel.canPostCompletion(status: .idle, activity: .working))
        XCTAssertTrue(AppModel.canPostCompletion(status: .idle, activity: .idle))
        XCTAssertTrue(AppModel.canPostCompletion(status: .idle, activity: .unknown))
        XCTAssertTrue(AppModel.canPostCompletion(status: .idle, activity: nil))
        XCTAssertFalse(AppModel.shouldClearPendingCompletion(status: .running, source: "footer"))
        XCTAssertTrue(AppModel.shouldClearPendingCompletion(status: .running, source: nil))
        XCTAssertTrue(AppModel.shouldClearPendingCompletion(status: .waiting, source: "hook"))
    }

    func testScrollbarGutterStrippingKeepsAdjacentContent() {
        let bars: Set<Character> = ["┃"]
        XCTAssertEqual(
            ProjectsTerminalView.strippingScrollbarGutter("hello  ┃\nworld  ┃", bars: bars),
            "hello\nworld"
        )
        XCTAssertEqual(
            ProjectsTerminalView.strippingScrollbarGutter("table ┃", bars: bars),
            "table"
        )
        XCTAssertEqual(
            ProjectsTerminalView.strippingScrollbarGutter("table┃", bars: bars),
            "table┃"
        )
    }

    func testSessionIdAndShellQuoting() {
        let sessionId = UUID().uuidString
        XCTAssertTrue(TerminalController.isSafeSessionId(sessionId))
        XCTAssertFalse(TerminalController.isSafeSessionId("../../bad"))
        XCTAssertEqual(TerminalController.shellSingleQuote("a'b"), "'a'\\''b'")
        XCTAssertEqual(
            TerminalController.resumeCommand(sessionId: sessionId, allowAll: false),
            "copilot --resume=\(sessionId)"
        )
        XCTAssertEqual(
            TerminalController.resumeCommand(sessionId: sessionId, allowAll: true),
            "copilot --allow-all --resume=\(sessionId)"
        )
        XCTAssertTrue(AppModel.shouldResumeWithAllowAll(
            copilotSessionId: sessionId,
            allowAllSessionId: sessionId
        ))
        XCTAssertFalse(AppModel.shouldResumeWithAllowAll(
            copilotSessionId: sessionId,
            allowAllSessionId: UUID().uuidString
        ))
        XCTAssertFalse(AppModel.shouldResumeWithAllowAll(
            copilotSessionId: nil,
            allowAllSessionId: sessionId
        ))
    }

    func testStartupProgramPrecedenceAndLaunchCommand() {
        let shell = "/bin/zsh"
        let executable = "/opt/my copilot/copilot"
        // Local sessions (addSession, CLI new-session, the Mac UI) pass no launch
        // executable, so their dtach program stays a plain login shell.
        XCTAssertEqual(
            TerminalController.startupProgram(
                shell: shell,
                copilotSessionId: nil,
                copilotSessionAllowAll: false,
                launchCopilotExecutable: nil
            ),
            [shell, "-l"]
        )
        // A freshly-created remote session launches the quoted absolute executable once.
        XCTAssertEqual(
            TerminalController.startupProgram(
                shell: shell,
                copilotSessionId: nil,
                copilotSessionAllowAll: false,
                launchCopilotExecutable: executable
            ),
            [shell, "-l", "-c",
             TerminalController.launchCommand(executable: executable, shell: shell)]
        )
        XCTAssertEqual(
            TerminalController.launchCommand(executable: executable, shell: shell),
            "'/opt/my copilot/copilot'"
                + " || printf '\\n[Copilot Projects] could not launch Copilot\\n';"
                + " exec '/bin/zsh' -l"
        )
        // A remote (phone) session launches with allow-all so it runs unattended.
        XCTAssertEqual(
            TerminalController.launchCommand(
                executable: executable, shell: shell, allowAll: true
            ),
            "'/opt/my copilot/copilot' --allow-all"
                + " || printf '\\n[Copilot Projects] could not launch Copilot\\n';"
                + " exec '/bin/zsh' -l"
        )
        XCTAssertEqual(
            TerminalController.startupProgram(
                shell: shell,
                copilotSessionId: nil,
                copilotSessionAllowAll: true,
                launchCopilotExecutable: executable
            ),
            [shell, "-l", "-c",
             TerminalController.launchCommand(
                executable: executable, shell: shell, allowAll: true
             )]
        )
        // A recorded resume session ALWAYS wins over a one-shot launch executable.
        let sessionId = UUID().uuidString
        let resumeProgram = TerminalController.startupProgram(
            shell: shell,
            copilotSessionId: sessionId,
            copilotSessionAllowAll: false,
            launchCopilotExecutable: executable
        )
        let joined = resumeProgram.joined(separator: " ")
        XCTAssertTrue(joined.contains("copilot --resume=\(sessionId)"))
        XCTAssertFalse(joined.contains("my copilot/copilot"))
    }

    func testSessionCreationLedgerIdempotencyTombstoneAndPersistence() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("nested/session-creation-ledger.json")

        let ledger = SessionCreationLedger(url: url)
        let requestId = UUID()
        XCTAssertNil(ledger.record(for: requestId))

        let created = Date(timeIntervalSince1970: 1_900_000_000)
        ledger.remember(SessionCreationRecord(
            requestId: requestId.uuidString,
            projectId: "project-1",
            sessionId: requestId.uuidString,
            createdAt: created
        ))

        // Tombstone survives a fresh ledger instance (persisted to disk).
        let reopened = SessionCreationLedger(url: url)
        let record = try XCTUnwrap(reopened.record(for: requestId))
        XCTAssertEqual(record.projectId, "project-1")
        XCTAssertEqual(record.sessionId, requestId.uuidString)

        // Atomic persistence must land at 0600.
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[
            .posixPermissions
        ] as? NSNumber
        XCTAssertEqual(permissions?.int16Value, 0o600)
    }

    func testSessionCreationLedgerPrunesByTTLAndBound() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        func record(_ id: String, _ createdAt: Date) -> SessionCreationRecord {
            SessionCreationRecord(
                requestId: id, projectId: "p", sessionId: id, createdAt: createdAt)
        }
        // TTL: anything older than a week is dropped, fresher entries kept.
        let fresh = record("fresh", now.addingTimeInterval(-60))
        let expired = record("expired", now.addingTimeInterval(-SessionCreationLedger.ttl - 60))
        XCTAssertEqual(
            SessionCreationLedger.prune([expired, fresh], now: now).map(\.requestId),
            ["fresh"]
        )
        // Bound: only the most recent maxRecords survive.
        let overflow = SessionCreationLedger.maxRecords + 10
        let many = (0 ..< overflow).map { index in
            record("r\(index)", now.addingTimeInterval(Double(index)))
        }
        let bounded = SessionCreationLedger.prune(many, now: now.addingTimeInterval(Double(overflow)))
        XCTAssertEqual(bounded.count, SessionCreationLedger.maxRecords)
        XCTAssertFalse(bounded.contains { $0.requestId == "r0" })
        XCTAssertTrue(bounded.contains { $0.requestId == "r\(overflow - 1)" })
    }

    func testSessionStatusMarkersPersistAsAPair() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionId = UUID().uuidString

        XCTAssertTrue(SessionArtifacts.persistStatus(
            sessionId: sessionId,
            status: .running,
            timestamp: 123_456,
            sessionsDirectory: root
        ))
        XCTAssertEqual(
            try String(
                contentsOf: root.appendingPathComponent("\(sessionId).status"),
                encoding: .utf8
            ),
            "running"
        )
        XCTAssertEqual(
            try String(
                contentsOf: root.appendingPathComponent("\(sessionId).status-timestamp"),
                encoding: .utf8
            ),
            "123456"
        )
    }

    func testBackgroundAgentMarkerLifecycle() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionId = UUID().uuidString
        let marker = root.appendingPathComponent("\(sessionId).background-agents")

        XCTAssertTrue(SessionArtifacts.setBackgroundAgentsActive(
            sessionId: sessionId,
            active: true,
            sessionsDirectory: root
        ))
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertTrue(SessionArtifacts.setBackgroundAgentsActive(
            sessionId: sessionId,
            active: false,
            sessionsDirectory: root
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    @MainActor
    func testTranscriptControllerLoadsJavaScriptTimestampsForDesktopAndRemote() async throws {
        let sessionId = UUID().uuidString
        defer { SessionArtifacts.removeFiles(sessionId: sessionId) }
        Paths.ensureStateDir()
        let data = Data("""
        {
          "schemaVersion": 3,
          "updatedAt": "2026-07-12T03:09:00.123Z",
          "copilotSessionId": "copilot-session",
          "turns": [{
            "id": "turn-1",
            "startedAt": "2026-07-12T03:09:01Z",
            "endedAt": "2026-07-12T03:09:02.456Z",
            "kind": "foreground",
            "userContent": "Explain the failure",
            "assistantMessages": [{
              "id": "message-1",
              "timestamp": "2026-07-12T03:09:01.789Z",
              "content": "The failure is caused by the timeout."
            }],
            "tools": [{
              "id": "tool-1",
              "name": "bash",
              "title": "Run tests",
              "success": true
            }],
            "isAborted": true
          }]
        }
        """.utf8)
        try data.write(
            to: URL(fileURLWithPath: Paths.transcriptSnapshotPath(sessionId: sessionId)),
            options: .atomic
        )

        let controller = TranscriptController(sessionId: sessionId)
        controller.start()
        for _ in 0 ..< 50 {
            if controller.snapshot != nil { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        let loaded = try XCTUnwrap(controller.snapshot)
        XCTAssertEqual(loaded.turns[0].userContent, "Explain the failure")
        XCTAssertEqual(loaded.turns[0].assistantMessages[0].content,
                       "The failure is caused by the timeout.")
        XCTAssertEqual(loaded.turns[0].tools[0].success, true)
        XCTAssertTrue(loaded.turns[0].isAborted)

        let remote = TranscriptController.loadRemoteSnapshot(sessionId: sessionId)
        XCTAssertEqual(remote, loaded)
    }

    @MainActor
    func testTranscriptControllerRejectsLegacySchemaForDesktopAndRemote() async throws {
        let sessionId = UUID().uuidString
        defer { SessionArtifacts.removeFiles(sessionId: sessionId) }
        Paths.ensureStateDir()
        let snapshotURL = URL(
            fileURLWithPath: Paths.transcriptSnapshotPath(sessionId: sessionId)
        )
        let currentData = Data("""
        {
          "schemaVersion": 3,
          "updatedAt": "2026-07-12T03:09:00.123Z",
          "copilotSessionId": "copilot-session",
          "turns": []
        }
        """.utf8)
        try currentData.write(to: snapshotURL, options: .atomic)

        let controller = TranscriptController(sessionId: sessionId)
        controller.start()
        for _ in 0 ..< 50 {
            if controller.snapshot != nil { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertNotNil(controller.snapshot)

        let legacyData = Data("""
        {
          "schemaVersion": 2,
          "updatedAt": "2026-07-12T03:10:00.123Z",
          "copilotSessionId": "legacy-copilot-session",
          "turns": [{
            "id": "legacy-turn",
            "startedAt": "2026-07-12T03:10:01Z",
            "endedAt": "2026-07-12T03:10:02Z",
            "kind": "foreground",
            "userContent": "legacy transcript content",
            "assistantMessages": [],
            "tools": [],
            "isAborted": false
          }]
        }
        """.utf8)
        try legacyData.write(to: snapshotURL, options: .atomic)

        for _ in 0 ..< 120 {
            if controller.snapshot == nil { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertNil(controller.snapshot)

        let remote = TranscriptController.loadRemoteSnapshot(sessionId: sessionId)
        XCTAssertEqual(remote.schemaVersion, 3)
        XCTAssertTrue(remote.copilotSessionId.isEmpty)
        XCTAssertTrue(remote.turns.isEmpty)
    }

    func testSessionArtifactCleanupRemovesTranscriptArtifacts() throws {
        let sessionId = UUID().uuidString
        Paths.ensureStateDir()
        let paths = [
            Paths.transcriptSnapshotPath(sessionId: sessionId),
            Paths.transcriptOwnerPath(sessionId: sessionId),
            Paths.transcriptOwnerLockPath(sessionId: sessionId),
        ]
        for path in paths {
            try Data("{}".utf8).write(to: URL(fileURLWithPath: path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        }

        SessionArtifacts.removeFiles(sessionId: sessionId)

        for path in paths {
            XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        }
    }

    func testSessionArtifactCleanupRemovesResponseArtifacts() throws {
        let sessionId = UUID().uuidString
        Paths.ensureStateDir()
        let paths = [
            Paths.userInputResponsePath(sessionId: sessionId),
            Paths.elicitationResponsePath(sessionId: sessionId),
        ]
        for path in paths {
            try Data("{}".utf8).write(to: URL(fileURLWithPath: path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        }

        SessionArtifacts.removeFiles(sessionId: sessionId)

        for path in paths {
            XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        }
    }

    @MainActor
    func testTranscriptDrawerRequiresExplicitOpen() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = Session(title: "shell", cwd: "/tmp")
        let project = Project(
            name: "test",
            cwd: "/tmp",
            sessions: [session],
            selectedSessionId: session.id
        )
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(
            projects: [project],
            selectedProjectId: project.id
        ))
        let model = AppModel(
            stateRepository: repository,
            agentActivityDirectory: root
        )

        XCTAssertFalse(model.isTranscriptDrawerOpen(sessionId: session.id))
        model.openTranscriptDrawer(sessionId: session.id)
        XCTAssertTrue(model.isTranscriptDrawerOpen(sessionId: session.id))
        model.closeTranscriptDrawer(sessionId: session.id)
        XCTAssertFalse(model.isTranscriptDrawerOpen(sessionId: session.id))
    }

    func testCompletionCoordinationStateIsNotPersisted() throws {
        let session = Session(title: "test", cwd: "/tmp")
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(session)) as? [String: Any]
        )
        XCTAssertEqual(Set(object.keys), ["id", "title", "cwd"])
    }

    func testStateRepositoryRecoversBackupAndNormalizesSelection() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("state.json")
        let repository = StateRepository(path: path)
        let session = Session(title: "shell", cwd: "/tmp")
        let project = Project(
            name: "test", cwd: "/tmp", sessions: [session], selectedSessionId: "missing")
        try repository.save(PersistedState(projects: [project], selectedProjectId: "missing"))
        try repository.save(PersistedState(projects: [project], selectedProjectId: project.id))
        try Data("not json".utf8).write(to: path)

        guard case .recovered(let recovered, _) = repository.load() else {
            return XCTFail("expected backup recovery")
        }
        XCTAssertEqual(recovered.selectedProjectId, project.id)
        XCTAssertEqual(recovered.projects[0].selectedSessionId, session.id)
    }

    func testStateRepositoryRecoversWhenPrimaryIsMissing() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("state.json")
        let repository = StateRepository(path: path)
        let project = Project(name: "test", cwd: "/tmp")
        try repository.save(PersistedState(projects: [project], selectedProjectId: project.id))
        try repository.save(PersistedState(projects: [project], selectedProjectId: project.id))
        try FileManager.default.removeItem(at: path)

        guard case .recovered(let recovered, _) = repository.load() else {
            return XCTFail("expected missing-primary backup recovery")
        }
        XCTAssertEqual(recovered.selectedProjectId, project.id)
    }

    func testStateRepositoryRefusesFutureSchemaInsteadOfDowngrading() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("state.json")
        let repository = StateRepository(path: path)
        let project = Project(name: "test", cwd: "/tmp")
        var future = PersistedState(projects: [project], selectedProjectId: project.id)
        future.schemaVersion = PersistedState.currentSchemaVersion + 1
        try JSONEncoder().encode(future).write(to: path)
        try JSONEncoder().encode(
            PersistedState(projects: [project], selectedProjectId: project.id)
        ).write(to: repository.backupPath)

        guard case .failed = repository.load() else {
            return XCTFail("future schema must block writes rather than recover an older backup")
        }
    }

    func testControlCommandRouterValidatesBeforeDispatch() {
        var didSetStatus = false
        let router = ControlCommandRouter(actions: .init(
            listProjects: { "" },
            listStatus: { "" },
            setStatus: { _, _, _ in didSetStatus = true; return .success() },
            notify: { _, _, _ in .success() },
            newProject: { _ in .success() },
            newSession: { _ in .success() },
            renameProject: { _, _ in .success() },
            focus: { _ in .success() },
            screenshot: { _ in .success() },
            diagnostics: { "" },
            remote: { _ in .success() }
        ))
        XCTAssertFalse(router.handle(ControlRequest(command: "set-status")).ok)
        XCTAssertFalse(didSetStatus)
        XCTAssertFalse(router.handle(ControlRequest(command: "unknown")).ok)
    }

    func testCloudflareAccessVerifierValidatesSignatureAndClaims() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let config = CloudflareAccessConfig(
            teamDomain: "team.cloudflareaccess.com",
            audTag: "expected-aud",
            allowedEmail: "user@example.com"
        )
        let verifier = CloudflareAccessVerifier(
            config: config,
            now: { now },
            fetch: { _ in nil }
        )
        let (privateKey, publicKey) = try makeRSAKeyPair()
        verifier.installKey(kid: "test-key", key: publicKey)

        let claims: [String: Any] = [
            "iss": config.issuer,
            "aud": [config.audTag],
            "email": "USER@example.com",
            "exp": now.timeIntervalSince1970 + 3_600,
            "nbf": now.timeIntervalSince1970 - 60,
        ]
        let validToken = try accessToken(
            kid: "test-key", claims: claims, privateKey: privateKey
        )
        XCTAssertTrue(verifier.verify(token: validToken))
        XCTAssertEqual(
            verifier.verifiedExpiration(token: validToken),
            Date(timeIntervalSince1970: now.timeIntervalSince1970 + 3_600)
        )

        var wrongAudience = claims
        wrongAudience["aud"] = ["wrong"]
        XCTAssertFalse(verifier.verify(token: try accessToken(
            kid: "test-key", claims: wrongAudience, privateKey: privateKey
        )))

        var wrongEmail = claims
        wrongEmail["email"] = "attacker@example.com"
        XCTAssertFalse(verifier.verify(token: try accessToken(
            kid: "test-key", claims: wrongEmail, privateKey: privateKey
        )))

        var expired = claims
        expired["exp"] = now.timeIntervalSince1970
        XCTAssertFalse(verifier.verify(token: try accessToken(
            kid: "test-key", claims: expired, privateKey: privateKey
        )))

        var notYetValid = claims
        notYetValid["nbf"] = now.timeIntervalSince1970 + 60
        XCTAssertFalse(verifier.verify(token: try accessToken(
            kid: "test-key", claims: notYetValid, privateKey: privateKey
        )))

        let (otherPrivateKey, _) = try makeRSAKeyPair()
        XCTAssertFalse(verifier.verify(token: try accessToken(
            kid: "test-key", claims: claims, privateKey: otherPrivateKey
        )))
        XCTAssertFalse(verifier.verify(token: try accessToken(
            kid: "unknown-key", claims: claims, privateKey: privateKey
        )))
        XCTAssertFalse(verifier.verify(token: String(repeating: "x", count: 16_385)))
    }

    func testRemoteRequestAuthFailsClosed() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let config = CloudflareAccessConfig(
            teamDomain: "team.cloudflareaccess.com",
            audTag: "expected-aud",
            allowedEmail: "user@example.com"
        )
        let verifier = CloudflareAccessVerifier(
            config: config,
            now: { now },
            fetch: { _ in nil }
        )
        let (privateKey, publicKey) = try makeRSAKeyPair()
        verifier.installKey(kid: "test-key", key: publicKey)
        let token = try accessToken(
            kid: "test-key",
            claims: [
                "iss": config.issuer,
                "aud": config.audTag,
                "email": config.allowedEmail,
                "exp": now.timeIntervalSince1970 + 3_600,
            ],
            privateKey: privateKey
        )
        let auth = RemoteRequestAuth(
            expectedHost: "projects.example.com",
            expectedOrigin: "https://projects.example.com",
            verifier: verifier
        )

        XCTAssertTrue(auth.authorize(
            host: "projects.example.com",
            token: token,
            origin: "https://projects.example.com",
            originPolicy: .requireMatch
        ))
        XCTAssertTrue(auth.authorize(
            host: "PROJECTS.EXAMPLE.COM",
            token: token,
            origin: "HTTPS://PROJECTS.EXAMPLE.COM",
            originPolicy: .requireMatch
        ))
        XCTAssertFalse(auth.authorize(
            host: "projects.example.com",
            token: nil,
            origin: "https://projects.example.com",
            originPolicy: .requireMatch
        ))
        XCTAssertFalse(auth.authorize(
            host: "evil.example.com",
            token: token,
            origin: "https://projects.example.com",
            originPolicy: .requireMatch
        ))
        XCTAssertFalse(auth.authorize(
            host: "projects.example.com",
            token: token,
            origin: "https://evil.example.com",
            originPolicy: .requireMatch
        ))
        XCTAssertFalse(auth.authorize(
            host: "projects.example.com",
            token: token,
            origin: nil,
            originPolicy: .requireMatch
        ))
        XCTAssertTrue(auth.authorize(
            host: "projects.example.com",
            token: token,
            origin: nil,
            originPolicy: .matchIfPresent
        ))
        XCTAssertEqual(auth.normalizedPath("/events?s=session%2Fid"), "/events")
        XCTAssertEqual(auth.normalizedPath("/app.js"), "/app.js")
        XCTAssertNil(auth.normalizedPath("app.js"))
    }

    func testRemoteAccessConfigurationRequiresAllSettings() throws {
        let suiteName = "RemoteAccessConfigurationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertNil(RemoteAccessConfiguration.load(defaults: defaults))
        defaults.set("projects.example.com", forKey: RemoteAccessConfiguration.hostnameKey)
        defaults.set(
            "team.cloudflareaccess.com",
            forKey: RemoteAccessConfiguration.teamDomainKey
        )
        defaults.set("audience", forKey: RemoteAccessConfiguration.audienceKey)
        XCTAssertNil(RemoteAccessConfiguration.load(defaults: defaults))

        defaults.set("user@example.com", forKey: RemoteAccessConfiguration.allowedEmailKey)
        let configuration = try XCTUnwrap(
            RemoteAccessConfiguration.load(defaults: defaults)
        )
        XCTAssertEqual(configuration.hostname, "projects.example.com")
        XCTAssertEqual(configuration.localPort, 49_272)
        XCTAssertEqual(configuration.access.teamDomain, "team.cloudflareaccess.com")
        XCTAssertEqual(configuration.access.audTag, "audience")
        XCTAssertEqual(configuration.access.allowedEmail, "user@example.com")

        defaults.set("%", forKey: RemoteAccessConfiguration.teamDomainKey)
        XCTAssertNil(RemoteAccessConfiguration.load(defaults: defaults))
    }

    @MainActor
    func testRemoteGatewayAnswerUserInputRequiresLeaseAndReportsStatuses() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        let sessionId = "session-answer"
        let session = Session(id: sessionId, title: "Test Session", cwd: "/")
        let project = Project(id: "pid", name: "Project", cwd: "/", sessions: [session])
        try repository.save(PersistedState(projects: [project], selectedProjectId: "pid"))

        let model = AppModel(
            stateRepository: repository,
            isAppActive: { false },
            agentActivityDirectory: root,
            resumeMarkerDirectory: root
        )
        let config = CloudflareAccessConfig(
            teamDomain: "team.cloudflareaccess.com",
            audTag: "expected-aud",
            allowedEmail: "user@example.com"
        )
        let verifier = CloudflareAccessVerifier(
            config: config,
            now: { Date() },
            fetch: { _ in nil }
        )
        let (privateKey, publicKey) = try makeRSAKeyPair()
        verifier.installKey(kid: "test-key", key: publicKey)
        let token = try accessToken(
            kid: "test-key",
            claims: [
                "iss": config.issuer,
                "aud": config.audTag,
                "email": config.allowedEmail,
                "exp": Date().timeIntervalSince1970 + 3_600,
            ],
            privateKey: privateKey
        )
        let gateway = RemoteGateway()
        let port = try gateway.start(
            bridge: RemoteModelBridge(model: model),
            expectedHost: "127.0.0.1",
            expectedOrigin: "https://projects.example.com",
            verifier: verifier,
            port: 0
        )

        func answerBody(
            requestId: String,
            answer: String,
            wasFreeform: Bool,
            rawData: String? = nil
        ) throws -> Data {
            let payload: String
            if let rawData {
                payload = rawData
            } else {
                payload = String(
                    decoding: try JSONEncoder().encode(RemoteUserInputAnswer(
                        requestId: requestId, answer: answer, wasFreeform: wasFreeform
                    )),
                    as: UTF8.self
                )
            }
            return try JSONEncoder().encode(RemoteClientMessage(
                type: "answer-user-input",
                clientId: "phone",
                sessionId: sessionId,
                data: payload
            ))
        }

        do {
            // No writer lease yet → forbidden.
            let withoutLease = try await remoteHTTPStatus(
                port: port,
                path: "/control",
                method: "POST",
                token: token,
                origin: "https://projects.example.com",
                body: try answerBody(requestId: "req-1", answer: "Go", wasFreeform: false)
            )
            XCTAssertEqual(withoutLease, 403)

            let acquire = try await remoteHTTPStatus(
                port: port,
                path: "/control",
                method: "POST",
                token: token,
                origin: "https://projects.example.com",
                body: try JSONEncoder().encode(RemoteClientMessage(
                    type: "acquire", clientId: "phone", sessionId: sessionId, data: nil
                ))
            )
            XCTAssertEqual(acquire, 204)

            // Malformed answer payload → bad request.
            let malformed = try await remoteHTTPStatus(
                port: port,
                path: "/control",
                method: "POST",
                token: token,
                origin: "https://projects.example.com",
                body: try answerBody(
                    requestId: "", answer: "", wasFreeform: false, rawData: "{"
                )
            )
            XCTAssertEqual(malformed, 400)

            // No live question yet → unprocessable.
            let noQuestion = try await remoteHTTPStatus(
                port: port,
                path: "/control",
                method: "POST",
                token: token,
                origin: "https://projects.example.com",
                body: try answerBody(requestId: "req-1", answer: "Go", wasFreeform: false)
            )
            XCTAssertEqual(noQuestion, 422)

            // Publish a fresh question and Copilot-session marker.
            let snapshot = AgentActivitySnapshot(
                schemaVersion: 1,
                updatedAt: ISO8601DateFormatter().string(from: Date()),
                foregroundTurnActive: false,
                scheduledTurnActive: false,
                activeSubagents: [],
                schedules: [],
                idleGeneration: 0,
                lastIdleAborted: false,
                lastIdleTurnKind: nil,
                error: nil,
                trackedUserInputs: [
                    TrackedUserInput(
                        requestId: "req-1",
                        question: "Ready?",
                        choices: ["Go", "Wait"],
                        allowFreeform: false,
                        requestedAt: ISO8601DateFormatter().string(from: Date()),
                        agentId: nil
                    ),
                    TrackedUserInput(
                        requestId: "req-escaped",
                        question: "Explain?",
                        choices: [],
                        allowFreeform: true,
                        requestedAt: ISO8601DateFormatter().string(from: Date()),
                        agentId: nil
                    ),
                ]
            )
            try JSONEncoder().encode(snapshot).write(
                to: root.appendingPathComponent("\(sessionId).agent-activity.json")
            )
            try Data("copilot-session".utf8).write(
                to: root.appendingPathComponent("\(sessionId).copilot-session")
            )

            let escapedAnswer = String(repeating: "\u{1}", count: 8_192)
            let escapedAnswerBody = try answerBody(
                requestId: "req-escaped",
                answer: escapedAnswer,
                wasFreeform: true
            )
            XCTAssertGreaterThan(escapedAnswerBody.count, 24 * 1_024)
            let escapedAccepted = try await remoteHTTPStatus(
                port: port,
                path: "/control",
                method: "POST",
                token: token,
                origin: "https://projects.example.com",
                body: escapedAnswerBody
            )
            XCTAssertEqual(escapedAccepted, 204)
            try FileManager.default.removeItem(
                at: root.appendingPathComponent("\(sessionId).user-input-response.json")
            )

            let accepted = try await remoteHTTPStatus(
                port: port,
                path: "/control",
                method: "POST",
                token: token,
                origin: "https://projects.example.com",
                body: try answerBody(requestId: "req-1", answer: "Go", wasFreeform: false)
            )
            XCTAssertEqual(accepted, 204)

            // A second answer while the response awaits pickup → conflict.
            let conflict = try await remoteHTTPStatus(
                port: port,
                path: "/control",
                method: "POST",
                token: token,
                origin: "https://projects.example.com",
                body: try answerBody(requestId: "req-1", answer: "Wait", wasFreeform: false)
            )
            XCTAssertEqual(conflict, 409)
        } catch {
            await gateway.stop()
            throw error
        }
        await gateway.stop()
        SessionArtifacts.removeFiles(sessionId: sessionId)
    }

    @MainActor
    func testRemoteGatewayAnswerElicitationRequiresLeaseAndReportsStatuses() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        let sessionId = "session-elicit-gateway"
        let session = Session(id: sessionId, title: "Test Session", cwd: "/")
        let project = Project(id: "pid", name: "Project", cwd: "/", sessions: [session])
        try repository.save(PersistedState(projects: [project], selectedProjectId: "pid"))

        let model = AppModel(
            stateRepository: repository,
            isAppActive: { false },
            agentActivityDirectory: root,
            resumeMarkerDirectory: root
        )
        let config = CloudflareAccessConfig(
            teamDomain: "team.cloudflareaccess.com",
            audTag: "expected-aud",
            allowedEmail: "user@example.com"
        )
        let verifier = CloudflareAccessVerifier(
            config: config,
            now: { Date() },
            fetch: { _ in nil }
        )
        let (privateKey, publicKey) = try makeRSAKeyPair()
        verifier.installKey(kid: "test-key", key: publicKey)
        let token = try accessToken(
            kid: "test-key",
            claims: [
                "iss": config.issuer,
                "aud": config.audTag,
                "email": config.allowedEmail,
                "exp": Date().timeIntervalSince1970 + 3_600,
            ],
            privateKey: privateKey
        )
        let gateway = RemoteGateway()
        let port = try gateway.start(
            bridge: RemoteModelBridge(model: model),
            expectedHost: "127.0.0.1",
            expectedOrigin: "https://projects.example.com",
            verifier: verifier,
            port: 0
        )

        func answerBody(
            requestId: String,
            action: RemoteElicitationAction,
            content: [String: RemoteJSONValue]? = nil,
            rawData: String? = nil
        ) throws -> Data {
            let payload: String
            if let rawData {
                payload = rawData
            } else {
                payload = String(
                    decoding: try JSONEncoder().encode(RemoteElicitationAnswer(
                        requestId: requestId, action: action, content: content
                    )),
                    as: UTF8.self
                )
            }
            return try JSONEncoder().encode(RemoteClientMessage(
                type: "answer-elicitation",
                clientId: "phone",
                sessionId: sessionId,
                data: payload
            ))
        }

        do {
            // No writer lease yet → forbidden.
            let withoutLease = try await remoteHTTPStatus(
                port: port,
                path: "/control",
                method: "POST",
                token: token,
                origin: "https://projects.example.com",
                body: try answerBody(
                    requestId: "req-form", action: .accept,
                    content: ["fruit": .string("apple")]
                )
            )
            XCTAssertEqual(withoutLease, 403)

            let acquire = try await remoteHTTPStatus(
                port: port,
                path: "/control",
                method: "POST",
                token: token,
                origin: "https://projects.example.com",
                body: try JSONEncoder().encode(RemoteClientMessage(
                    type: "acquire", clientId: "phone", sessionId: sessionId, data: nil
                ))
            )
            XCTAssertEqual(acquire, 204)

            // Malformed answer payload → bad request.
            let malformed = try await remoteHTTPStatus(
                port: port,
                path: "/control",
                method: "POST",
                token: token,
                origin: "https://projects.example.com",
                body: try answerBody(
                    requestId: "req-form", action: .accept, rawData: "{"
                )
            )
            XCTAssertEqual(malformed, 400)

            // No live elicitation yet → unprocessable.
            let noQuestion = try await remoteHTTPStatus(
                port: port,
                path: "/control",
                method: "POST",
                token: token,
                origin: "https://projects.example.com",
                body: try answerBody(
                    requestId: "req-form", action: .accept,
                    content: ["fruit": .string("apple")]
                )
            )
            XCTAssertEqual(noQuestion, 422)

            let snapshot = AgentActivitySnapshot(
                schemaVersion: 1,
                updatedAt: ISO8601DateFormatter().string(from: Date()),
                foregroundTurnActive: false,
                scheduledTurnActive: false,
                activeSubagents: [],
                schedules: [],
                idleGeneration: 0,
                lastIdleAborted: false,
                lastIdleTurnKind: nil,
                error: nil,
                trackedUserInputs: nil,
                trackedElicitations: [
                    TrackedElicitation(
                        requestId: "req-form",
                        message: "Pick a fruit",
                        mode: "form",
                        url: nil,
                        schema: .object([
                            "type": .string("object"),
                            "properties": .object([
                                "fruit": .object(["type": .string("string")])
                            ]),
                        ]),
                        elicitationSource: nil,
                        requestedAt: ISO8601DateFormatter().string(from: Date()),
                        agentId: nil
                    ),
                    TrackedElicitation(
                        requestId: "req-url",
                        message: "Open this URL?",
                        mode: nil,
                        url: "https://example.com/elicit",
                        schema: nil,
                        elicitationSource: nil,
                        requestedAt: ISO8601DateFormatter().string(from: Date()),
                        agentId: nil
                    )
                ]
            )
            try JSONEncoder().encode(snapshot).write(
                to: root.appendingPathComponent("\(sessionId).agent-activity.json")
            )
            try Data("copilot-session".utf8).write(
                to: root.appendingPathComponent("\(sessionId).copilot-session")
            )

            let unsupportedContent = try await remoteHTTPStatus(
                port: port,
                path: "/control",
                method: "POST",
                token: token,
                origin: "https://projects.example.com",
                body: try answerBody(
                    requestId: "req-form", action: .accept,
                    content: ["fruit": .number(2)]
                )
            )
            XCTAssertEqual(unsupportedContent, 422)

            let urlWithContent = try await remoteHTTPStatus(
                port: port,
                path: "/control",
                method: "POST",
                token: token,
                origin: "https://projects.example.com",
                body: try answerBody(
                    requestId: "req-url", action: .accept,
                    content: ["ignored": .string("value")]
                )
            )
            XCTAssertEqual(urlWithContent, 422)

            let urlAccepted = try await remoteHTTPStatus(
                port: port,
                path: "/control",
                method: "POST",
                token: token,
                origin: "https://projects.example.com",
                body: try answerBody(requestId: "req-url", action: .accept)
            )
            XCTAssertEqual(urlAccepted, 204)
            try FileManager.default.removeItem(
                at: root.appendingPathComponent("\(sessionId).elicitation-response.json")
            )

            let accepted = try await remoteHTTPStatus(
                port: port,
                path: "/control",
                method: "POST",
                token: token,
                origin: "https://projects.example.com",
                body: try answerBody(
                    requestId: "req-form", action: .accept,
                    content: ["fruit": .string("apple")]
                )
            )
            XCTAssertEqual(accepted, 204)

            // A second answer while the response awaits pickup → conflict.
            let conflict = try await remoteHTTPStatus(
                port: port,
                path: "/control",
                method: "POST",
                token: token,
                origin: "https://projects.example.com",
                body: try answerBody(requestId: "req-form", action: .cancel)
            )
            XCTAssertEqual(conflict, 409)
        } catch {
            await gateway.stop()
            throw error
        }
        await gateway.stop()
        SessionArtifacts.removeFiles(sessionId: sessionId)
    }

    @MainActor
    func testRemoteGatewayTranscriptSuccess() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        let sessionId = UUID().uuidString
        defer { SessionArtifacts.removeFiles(sessionId: sessionId) }
        let session = Session(id: sessionId, title: "Test Session", cwd: "/")
        let project = Project(id: "pid", name: "Project", cwd: "/", sessions: [session])
        try repository.save(PersistedState(projects: [project], selectedProjectId: "pid"))

        let model = AppModel(
            stateRepository: repository,
            isAppActive: { false },
            agentActivityDirectory: root
        )
        let config = CloudflareAccessConfig(
            teamDomain: "team.cloudflareaccess.com",
            audTag: "expected-aud",
            allowedEmail: "user@example.com"
        )
        let verifier = CloudflareAccessVerifier(
            config: config,
            now: { Date() },
            fetch: { _ in nil }
        )
        let (privateKey, publicKey) = try makeRSAKeyPair()
        verifier.installKey(kid: "test-key", key: publicKey)
        let token = try accessToken(
            kid: "test-key",
            claims: [
                "iss": config.issuer,
                "aud": config.audTag,
                "email": config.allowedEmail,
                "exp": Date().timeIntervalSince1970 + 3_600,
            ],
            privateKey: privateKey
        )
        let gateway = RemoteGateway()
        let port = try gateway.start(
            bridge: RemoteModelBridge(model: model),
            expectedHost: "127.0.0.1",
            expectedOrigin: "https://projects.example.com",
            verifier: verifier,
            port: 0,
            webPushService: nil,
            apnsService: nil
        )

        let mockSnapshot = TranscriptSnapshot(
            schemaVersion: 3,
            updatedAt: Date(),
            copilotSessionId: "test-copilot",
            turns: []
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let mockData = try encoder.encode(mockSnapshot)
        Paths.ensureStateDir()
        try mockData.write(to: URL(
            fileURLWithPath: Paths.transcriptSnapshotPath(sessionId: sessionId)
        ))

        do {
            let response = try await remoteHTTPResponse(
                port: port,
                path: "/transcript?s=\(sessionId)",
                token: token
            )
            XCTAssertEqual(response.statusCode, 200)
            XCTAssertEqual(
                response.value(forHTTPHeaderField: "Content-Type"),
                "application/json"
            )

            let bodyData = try await remoteHTTPData(
                port: port,
                path: "/transcript?s=\(sessionId)",
                token: token
            )
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let decoded = try decoder.decode(TranscriptSnapshot.self, from: bodyData)
            XCTAssertEqual(decoded.copilotSessionId, "test-copilot")
        } catch {
            await gateway.stop()
            throw error
        }
        await gateway.stop()
    }

    @MainActor
    func testRemoteGatewayRoutesFailClosed() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(projects: [], selectedProjectId: nil))
        let model = AppModel(
            stateRepository: repository,
            isAppActive: { false },
            agentActivityDirectory: root
        )
        let config = CloudflareAccessConfig(
            teamDomain: "team.cloudflareaccess.com",
            audTag: "expected-aud",
            allowedEmail: "user@example.com"
        )
        let verifier = CloudflareAccessVerifier(
            config: config,
            now: { Date() },
            fetch: { _ in nil }
        )
        let (privateKey, publicKey) = try makeRSAKeyPair()
        verifier.installKey(kid: "test-key", key: publicKey)
        let token = try accessToken(
            kid: "test-key",
            claims: [
                "iss": config.issuer,
                "aud": config.audTag,
                "email": config.allowedEmail,
                "exp": Date().timeIntervalSince1970 + 3_600,
            ],
            privateKey: privateKey
        )
        let subscriptionURL = root.appendingPathComponent("subscriptions.json")
        let webPushService = WebPushService(
            publicKey: "test-public-key",
            store: WebPushSubscriptionStore(url: subscriptionURL),
            sender: WebPushSenderSpy()
        )
        let apnsService = APNsService(
            store: APNsDeviceStore(
                url: root.appendingPathComponent("apns-devices.json")
            ),
            provider: APNsSenderSpy()
        )
        let notificationSync = NotificationSyncService(
            ledger: NotificationLedger(url: root.appendingPathComponent("ledger.json")),
            webPushService: webPushService,
            apnsService: apnsService
        )

        let gateway = RemoteGateway()
        let port = try gateway.start(
            bridge: RemoteModelBridge(model: model),
            expectedHost: "127.0.0.1",
            expectedOrigin: "https://projects.example.com",
            verifier: verifier,
            port: 0,
            webPushService: webPushService,
            apnsService: apnsService,
            notificationSync: notificationSync
        )
        do {
            let missingToken = try await remoteHTTPStatus(port: port, path: "/")
            XCTAssertEqual(missingToken, 403)
            let invalidToken = try await remoteHTTPStatus(
                port: port,
                path: "/",
                token: "invalid"
            )
            XCTAssertEqual(invalidToken, 403)
            let allowedAsset = try await remoteHTTPResponse(
                port: port,
                path: "/app.js",
                token: token
            )
            XCTAssertEqual(allowedAsset.statusCode, 200)
            XCTAssertEqual(
                allowedAsset.value(forHTTPHeaderField: "Content-Security-Policy"),
                "default-src 'self'; connect-src 'self'; style-src 'self'; "
                    + "script-src 'self'; worker-src 'self'; manifest-src 'self'; "
                    + "img-src 'self'; frame-ancestors 'none'; base-uri 'none'"
            )
            let manifestStatus = try await remoteHTTPStatus(
                port: port,
                path: "/manifest.webmanifest",
                token: token
            )
            XCTAssertEqual(manifestStatus, 200)
            let pushKey = try await remoteHTTPData(
                port: port,
                path: "/push/public-key",
                token: token
            )
            XCTAssertTrue(String(decoding: pushKey, as: UTF8.self).contains(
                "test-public-key"
            ))
            let pushStatus = try await remoteHTTPData(
                port: port,
                path: "/push/status",
                token: token
            )
            XCTAssertEqual(
                (try JSONSerialization.jsonObject(with: pushStatus)
                    as? [String: Any])?["subscriptions"] as? Int,
                0
            )
            let missingPath = try await remoteHTTPStatus(
                port: port,
                path: "/missing",
                token: token
            )
            XCTAssertEqual(missingPath, 404)
            let wrongGetOrigin = try await remoteHTTPStatus(
                port: port,
                path: "/app.js",
                token: token,
                origin: "https://evil.example.com"
            )
            XCTAssertEqual(wrongGetOrigin, 403)
            let controlBody = try JSONEncoder().encode(RemoteClientMessage(
                type: "acquire",
                clientId: "phone",
                sessionId: "session",
                data: nil
            ))
            let missingPostOrigin = try await remoteHTTPStatus(
                port: port,
                path: "/control",
                method: "POST",
                token: token,
                body: controlBody
            )
            XCTAssertEqual(missingPostOrigin, 403)
            let allowedControl = try await remoteHTTPStatus(
                port: port,
                path: "/control",
                method: "POST",
                token: token,
                origin: "https://projects.example.com",
                body: controlBody
            )
            XCTAssertEqual(allowedControl, 204)
            let notificationID = UUID()
            let dismissalBody = try JSONEncoder().encode(
                NotificationDismissRequest(id: notificationID)
            )
            let missingDismissOrigin = try await remoteHTTPStatus(
                port: port,
                path: "/\(NotificationSyncContract.dismissPath)",
                method: "POST",
                token: token,
                body: dismissalBody
            )
            XCTAssertEqual(missingDismissOrigin, 403)
            let dismissalStatus = try await remoteHTTPStatus(
                port: port,
                path: "/\(NotificationSyncContract.dismissPath)",
                method: "POST",
                token: token,
                origin: "https://projects.example.com",
                body: dismissalBody
            )
            XCTAssertEqual(dismissalStatus, 204)
            XCTAssertEqual(notificationSync.dismissalSnapshot().ids, [notificationID])
            let promptBody = try JSONEncoder().encode(RemoteClientMessage(
                type: "prompt",
                clientId: "phone",
                sessionId: "session",
                data: "Hello from the phone"
            ))
            let promptStatus = try await remoteHTTPStatus(
                port: port,
                path: "/control",
                method: "POST",
                token: token,
                origin: "https://projects.example.com",
                body: promptBody
            )
            XCTAssertEqual(promptStatus, 400)
            let transcriptStatus = try await remoteHTTPStatus(
                port: port,
                path: "/transcript?s=session",
                token: token
            )
            XCTAssertEqual(transcriptStatus, 404)

            let keyBody = try JSONEncoder().encode(RemoteClientMessage(
                type: "key",
                clientId: "phone",
                sessionId: "session",
                data: "enter"
            ))
            let keyStatus = try await remoteHTTPStatus(
                port: port,
                path: "/control",
                method: "POST",
                token: token,
                origin: "https://projects.example.com",
                body: keyBody
            )
            XCTAssertEqual(keyStatus, 204)
            let invalidKeyBody = try JSONEncoder().encode(RemoteClientMessage(
                type: "key",
                clientId: "phone",
                sessionId: "session",
                data: "home"
            ))
            let invalidKeyStatus = try await remoteHTTPStatus(
                port: port,
                path: "/control",
                method: "POST",
                token: token,
                origin: "https://projects.example.com",
                body: invalidKeyBody
            )
            XCTAssertEqual(invalidKeyStatus, 400)
            let scrollBody = try JSONEncoder().encode(RemoteClientMessage(
                type: "scroll",
                clientId: "phone",
                sessionId: "session",
                delta: 2
            ))
            let scrollStatus = try await remoteHTTPStatus(
                port: port,
                path: "/control",
                method: "POST",
                token: token,
                origin: "https://projects.example.com",
                body: scrollBody
            )
            XCTAssertEqual(scrollStatus, 204)
            let subscriptionBody = try webPushRegistrationData(
                endpoint: "https://wns2-by3p.notify.windows.com/sub/route"
            )
            let missingSubscriptionOrigin = try await remoteHTTPStatus(
                port: port,
                path: "/push/subscribe",
                method: "POST",
                token: token,
                body: subscriptionBody
            )
            XCTAssertEqual(missingSubscriptionOrigin, 403)
            let malformedSubscription = try await remoteHTTPStatus(
                port: port,
                path: "/push/subscribe",
                method: "POST",
                token: token,
                origin: "https://projects.example.com",
                body: Data("{".utf8)
            )
            XCTAssertEqual(malformedSubscription, 400)
            let subscriptionStatus = try await remoteHTTPStatus(
                port: port,
                path: "/push/subscribe",
                method: "POST",
                token: token,
                origin: "https://projects.example.com",
                body: subscriptionBody
            )
            XCTAssertEqual(subscriptionStatus, 204)
            let apnsBody = try JSONEncoder().encode(APNsRegistration(
                token: String(repeating: "ab", count: 32),
                environment: .sandbox,
                label: "Simulator"
            ))
            let apnsStatus = try await remoteHTTPStatus(
                port: port,
                path: "/apns/subscribe",
                method: "POST",
                token: token,
                origin: "https://projects.example.com",
                body: apnsBody
            )
            XCTAssertEqual(apnsStatus, 204)
            try FileManager.default.removeItem(at: subscriptionURL)
            try FileManager.default.createDirectory(
                at: subscriptionURL,
                withIntermediateDirectories: false
            )
            let unavailableSubscription = try await remoteHTTPStatus(
                port: port,
                path: "/push/subscribe",
                method: "POST",
                token: token,
                origin: "https://projects.example.com",
                body: try webPushRegistrationData(
                    endpoint: "https://wns2-by3p.notify.windows.com/sub/retry"
                )
            )
            XCTAssertEqual(unavailableSubscription, 503)
        } catch {
            await gateway.stop()
            throw error
        }
        await gateway.stop()
    }

    // MARK: - Remote session creation (AppModel)

    @MainActor
    private func makeRemoteCreateModel(
        root: URL,
        projects: [Project],
        selectedProjectId: String?,
        copilotExecutable: @escaping () -> String? = { "/opt/copilot/bin/copilot" },
        reposDirectory: @escaping () -> String?,
        backendAvailable: @escaping () -> Bool = { true },
        ledger: SessionCreationLedger,
        onLaunch: @escaping (String, String) -> Void
    ) throws -> AppModel {
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(
            projects: projects, selectedProjectId: selectedProjectId))
        return AppModel(
            stateRepository: repository,
            isAppActive: { false },
            agentActivityDirectory: root,
            resumeMarkerDirectory: root,
            remoteCopilotExecutable: copilotExecutable,
            remoteReposDirectory: reposDirectory,
            remoteSessionBackendAvailable: backendAvailable,
            remoteSessionLauncher: onLaunch,
            sessionCreationLedger: ledger
        )
    }

    @MainActor
    func testCreateRemoteSessionCreatesLaunchesAndIsIdempotent() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let repos = root.appendingPathComponent("Repos", isDirectory: true)
        try FileManager.default.createDirectory(at: repos, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // The Mac already has a selected tab in this project; it must be preserved.
        let existing = Session(id: "existing", title: "shell", cwd: "/tmp")
        let project = Project(
            id: "p1", name: "First", cwd: "/tmp",
            sessions: [existing], selectedSessionId: "existing")
        let ledger = SessionCreationLedger(url: root.appendingPathComponent("ledger.json"))
        var launches: [(sessionId: String, executable: String)] = []
        let model = try makeRemoteCreateModel(
            root: root,
            projects: [project],
            selectedProjectId: "p1",
            reposDirectory: { repos.path },
            ledger: ledger,
            onLaunch: { launches.append(($0, $1)) }
        )

        let requestId = UUID()
        let request = RemoteCreateSessionRequest(requestId: requestId, projectId: "p1")
        let outcome = model.createRemoteSession(request)

        let expected = RemoteCreateSessionResponse(
            requestId: requestId, projectId: "p1", sessionId: requestId.uuidString)
        XCTAssertEqual(outcome, .created(expected))

        let created = try XCTUnwrap(
            model.project("p1")?.sessions.first { $0.id == requestId.uuidString })
        XCTAssertEqual(created.title, "Copilot")
        XCTAssertEqual(created.cwd, repos.path)
        XCTAssertTrue(created.cwd.hasPrefix("/"))
        // Mac selection is not stolen.
        XCTAssertEqual(model.project("p1")?.selectedSessionId, "existing")
        XCTAssertEqual(launches.map(\.sessionId), [requestId.uuidString])
        XCTAssertEqual(launches.first?.executable, "/opt/copilot/bin/copilot")
        XCTAssertNotNil(ledger.record(for: requestId))

        // Idempotent replay: existing, no new session, no relaunch.
        XCTAssertEqual(model.createRemoteSession(request), .existing(expected))
        XCTAssertEqual(
            model.project("p1")?.sessions.filter { $0.id == requestId.uuidString }.count, 1)
        XCTAssertEqual(launches.count, 1)
    }

    @MainActor
    func testCreateRemoteSessionSelectsOnlyWhenProjectEmpty() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let repos = root.appendingPathComponent("Repos", isDirectory: true)
        try FileManager.default.createDirectory(at: repos, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let project = Project(id: "p1", name: "Empty", cwd: "/tmp", sessions: [])
        let ledger = SessionCreationLedger(url: root.appendingPathComponent("ledger.json"))
        let model = try makeRemoteCreateModel(
            root: root, projects: [project], selectedProjectId: "p1",
            reposDirectory: { repos.path }, ledger: ledger, onLaunch: { _, _ in })

        let requestId = UUID()
        _ = model.createRemoteSession(
            RemoteCreateSessionRequest(requestId: requestId, projectId: "p1"))
        // An empty project adopts the new session as its selection.
        XCTAssertEqual(model.project("p1")?.selectedSessionId, requestId.uuidString)
    }

    @MainActor
    func testCreateRemoteSessionCrossProjectConflict() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let repos = root.appendingPathComponent("Repos", isDirectory: true)
        try FileManager.default.createDirectory(at: repos, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let ledger = SessionCreationLedger(url: root.appendingPathComponent("ledger.json"))
        let model = try makeRemoteCreateModel(
            root: root,
            projects: [
                Project(id: "p1", name: "First", cwd: "/tmp", sessions: []),
                Project(id: "p2", name: "Second", cwd: "/tmp", sessions: []),
            ],
            selectedProjectId: "p1",
            reposDirectory: { repos.path },
            ledger: ledger,
            onLaunch: { _, _ in })

        let requestId = UUID()
        _ = model.createRemoteSession(
            RemoteCreateSessionRequest(requestId: requestId, projectId: "p1"))
        // The same deterministic id requested for a different project collides.
        XCTAssertEqual(
            model.createRemoteSession(
                RemoteCreateSessionRequest(requestId: requestId, projectId: "p2")),
            .conflict
        )
        XCTAssertTrue(model.project("p2")?.sessions.isEmpty == true)
    }

    @MainActor
    func testCreateRemoteSessionGoneTombstoneNeverRecreates() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let repos = root.appendingPathComponent("Repos", isDirectory: true)
        try FileManager.default.createDirectory(at: repos, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let ledger = SessionCreationLedger(url: root.appendingPathComponent("ledger.json"))
        let requestId = UUID()
        // A tombstone exists but the session is gone from the workspace.
        ledger.remember(SessionCreationRecord(
            requestId: requestId.uuidString, projectId: "p1",
            sessionId: requestId.uuidString, createdAt: Date()))

        var launches = 0
        let model = try makeRemoteCreateModel(
            root: root,
            projects: [Project(id: "p1", name: "First", cwd: "/tmp", sessions: [])],
            selectedProjectId: "p1",
            reposDirectory: { repos.path },
            ledger: ledger,
            onLaunch: { _, _ in launches += 1 })

        XCTAssertEqual(
            model.createRemoteSession(
                RemoteCreateSessionRequest(requestId: requestId, projectId: "p1")),
            .gone
        )
        XCTAssertTrue(model.project("p1")?.sessions.isEmpty == true)
        XCTAssertEqual(launches, 0)
    }

    @MainActor
    func testCreateRemoteSessionUnknownUnavailableAndInvalid() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let repos = root.appendingPathComponent("Repos", isDirectory: true)
        try FileManager.default.createDirectory(at: repos, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var copilot: String? = "/opt/copilot/bin/copilot"
        var reposPath: String? = repos.path
        let ledger = SessionCreationLedger(url: root.appendingPathComponent("ledger.json"))
        var launches = 0
        let model = try makeRemoteCreateModel(
            root: root,
            projects: [Project(id: "p1", name: "First", cwd: "/tmp", sessions: [])],
            selectedProjectId: "p1",
            copilotExecutable: { copilot },
            reposDirectory: { reposPath },
            ledger: ledger,
            onLaunch: { _, _ in launches += 1 })

        // Unknown project → nothing created.
        XCTAssertEqual(
            model.createRemoteSession(
                RemoteCreateSessionRequest(requestId: UUID(), projectId: "nope")),
            .unknownProject)

        // Copilot unresolved → service unavailable, nothing created, no tombstone.
        copilot = nil
        let unavailableId = UUID()
        XCTAssertEqual(
            model.createRemoteSession(
                RemoteCreateSessionRequest(requestId: unavailableId, projectId: "p1")),
            .unavailable)
        XCTAssertNil(ledger.record(for: unavailableId))

        // Missing dtach backend also fails closed instead of returning a shell-only
        // session that violated the automatic-Copilot contract.
        copilot = "/opt/copilot/bin/copilot"
        let noBackendId = UUID()
        let noBackendModel = try makeRemoteCreateModel(
            root: root,
            projects: [Project(id: "p1", name: "First", cwd: "/tmp", sessions: [])],
            selectedProjectId: "p1",
            copilotExecutable: { copilot },
            reposDirectory: { reposPath },
            backendAvailable: { false },
            ledger: ledger,
            onLaunch: { _, _ in }
        )
        XCTAssertEqual(
            noBackendModel.createRemoteSession(
                RemoteCreateSessionRequest(requestId: noBackendId, projectId: "p1")),
            .unavailable
        )
        XCTAssertNil(ledger.record(for: noBackendId))

        // Repos missing → unprocessable, nothing created.
        reposPath = nil
        let invalidId = UUID()
        XCTAssertEqual(
            model.createRemoteSession(
                RemoteCreateSessionRequest(requestId: invalidId, projectId: "p1")),
            .invalid)
        XCTAssertNil(ledger.record(for: invalidId))

        XCTAssertTrue(model.project("p1")?.sessions.isEmpty == true)
        XCTAssertEqual(launches, 0)
    }

    @MainActor
    func testRemoteGatewayCreateSessionMapsOutcomes() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let repos = root.appendingPathComponent("Repos", isDirectory: true)
        try FileManager.default.createDirectory(at: repos, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var copilot: String? = "/opt/copilot/bin/copilot"
        var reposPath: String? = repos.path
        let ledger = SessionCreationLedger(url: root.appendingPathComponent("ledger.json"))
        var launched: [String] = []
        let model = try makeRemoteCreateModel(
            root: root,
            projects: [
                Project(id: "p1", name: "First", cwd: "/tmp", sessions: []),
                Project(id: "p2", name: "Second", cwd: "/tmp", sessions: []),
            ],
            selectedProjectId: "p1",
            copilotExecutable: { copilot },
            reposDirectory: { reposPath },
            ledger: ledger,
            onLaunch: { sessionId, _ in launched.append(sessionId) })

        let config = CloudflareAccessConfig(
            teamDomain: "team.cloudflareaccess.com",
            audTag: "expected-aud",
            allowedEmail: "user@example.com"
        )
        let verifier = CloudflareAccessVerifier(
            config: config, now: { Date() }, fetch: { _ in nil })
        let (privateKey, publicKey) = try makeRSAKeyPair()
        verifier.installKey(kid: "test-key", key: publicKey)
        let token = try accessToken(
            kid: "test-key",
            claims: [
                "iss": config.issuer,
                "aud": config.audTag,
                "email": config.allowedEmail,
                "exp": Date().timeIntervalSince1970 + 3_600,
            ],
            privateKey: privateKey
        )
        let gateway = RemoteGateway()
        let port = try gateway.start(
            bridge: RemoteModelBridge(model: model),
            expectedHost: "127.0.0.1",
            expectedOrigin: "https://projects.example.com",
            verifier: verifier,
            port: 0
        )
        let origin = "https://projects.example.com"
        func createBody(_ requestId: UUID, _ projectId: String) throws -> Data {
            try JSONEncoder().encode(
                RemoteCreateSessionRequest(requestId: requestId, projectId: projectId))
        }
        do {
            // Same-origin is required for the write.
            let noOrigin = try await remoteHTTPStatus(
                port: port, path: "/sessions/create", method: "POST",
                token: token, body: try createBody(UUID(), "p1"))
            XCTAssertEqual(noOrigin, 403)
            // Malformed body → bad request.
            let badBody = try await remoteHTTPStatus(
                port: port, path: "/sessions/create", method: "POST",
                token: token, origin: origin, body: Data("{".utf8))
            XCTAssertEqual(badBody, 400)
            // Unknown project → 422.
            let unknown = try await remoteHTTPStatus(
                port: port, path: "/sessions/create", method: "POST",
                token: token, origin: origin, body: try createBody(UUID(), "nope"))
            XCTAssertEqual(unknown, 422)
            // Created → 201 with a JSON response echoing the deterministic id.
            let requestId = UUID()
            let created = try await remoteHTTPResponseWithBody(
                port: port, path: "/sessions/create", method: "POST",
                token: token, origin: origin, body: try createBody(requestId, "p1"))
            XCTAssertEqual(created.0.statusCode, 201)
            let response = try JSONDecoder().decode(
                RemoteCreateSessionResponse.self, from: created.1)
            XCTAssertEqual(response.requestId, requestId)
            XCTAssertEqual(response.projectId, "p1")
            XCTAssertEqual(response.sessionId, requestId.uuidString)
            XCTAssertEqual(launched, [requestId.uuidString])
            // Idempotent replay → 200, never relaunched.
            let replay = try await remoteHTTPStatus(
                port: port, path: "/sessions/create", method: "POST",
                token: token, origin: origin, body: try createBody(requestId, "p1"))
            XCTAssertEqual(replay, 200)
            XCTAssertEqual(launched, [requestId.uuidString])
            // Same id, different project → 409.
            let conflict = try await remoteHTTPStatus(
                port: port, path: "/sessions/create", method: "POST",
                token: token, origin: origin, body: try createBody(requestId, "p2"))
            XCTAssertEqual(conflict, 409)
            // Copilot unavailable → 503.
            copilot = nil
            let unavailable = try await remoteHTTPStatus(
                port: port, path: "/sessions/create", method: "POST",
                token: token, origin: origin, body: try createBody(UUID(), "p1"))
            XCTAssertEqual(unavailable, 503)
            copilot = "/opt/copilot/bin/copilot"
            // Repos unavailable → 422.
            reposPath = nil
            let invalid = try await remoteHTTPStatus(
                port: port, path: "/sessions/create", method: "POST",
                token: token, origin: origin, body: try createBody(UUID(), "p1"))
            XCTAssertEqual(invalid, 422)
            reposPath = repos.path
            // Processed-but-closed tombstone → 410, never recreated.
            let goneId = UUID()
            ledger.remember(SessionCreationRecord(
                requestId: goneId.uuidString, projectId: "p1",
                sessionId: goneId.uuidString, createdAt: Date()))
            let gone = try await remoteHTTPStatus(
                port: port, path: "/sessions/create", method: "POST",
                token: token, origin: origin, body: try createBody(goneId, "p1"))
            XCTAssertEqual(gone, 410)
            // An unrelated POST route (as an old host would treat create) is 404.
            let unsupported = try await remoteHTTPStatus(
                port: port, path: "/sessions/other", method: "POST",
                token: token, origin: origin, body: Data("{}".utf8))
            XCTAssertEqual(unsupported, 404)
        } catch {
            await gateway.stop()
            throw error
        }
        await gateway.stop()
    }

    @MainActor
    func testRemoteWorkspaceSnapshotPreservesModelContract() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let waiting = Session(id: "session-1", title: "waiting", cwd: "/one")
        let completed = Session(id: "session-2", title: "completed", cwd: "/two")
        let selected = Project(
            id: "project-1",
            name: "selected",
            cwd: "/one",
            sessions: [waiting, completed],
            selectedSessionId: waiting.id
        )
        let other = Project(id: "project-2", name: "other", cwd: "/other")
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(
            projects: [selected, other],
            selectedProjectId: selected.id
        ))
        let model = AppModel(
            stateRepository: repository,
            isAppActive: { false },
            agentActivityDirectory: root
        )
        model.setStatus(
            sessionId: waiting.id,
            status: .waiting,
            text: "needs input",
            timestamp: 100,
            source: "scheduled-start"
        )
        model.setStatus(
            sessionId: completed.id,
            status: .running,
            text: "working",
            timestamp: 100
        )
        model.setStatus(
            sessionId: completed.id,
            status: .idle,
            text: nil,
            timestamp: 200
        )

        XCTAssertEqual(model.remoteWorkspaceSnapshot(), RemoteWorkspaceSnapshot(
            projects: [
                RemoteProjectSnapshot(
                    id: selected.id,
                    name: selected.name,
                    selectedSessionId: waiting.id,
                    sessions: [
                        RemoteSessionSnapshot(
                            id: waiting.id,
                            title: waiting.title,
                            status: SessionStatus.waiting.rawValue,
                            statusText: "needs input",
                            unread: false,
                            ready: false,
                            background: true,
                            scheduled: false,
                            promptable: false
                        ),
                        RemoteSessionSnapshot(
                            id: completed.id,
                            title: completed.title,
                            status: SessionStatus.idle.rawValue,
                            statusText: nil,
                            unread: false,
                            ready: true,
                            background: false,
                            scheduled: false,
                            promptable: false
                        ),
                    ]
                ),
                RemoteProjectSnapshot(
                    id: other.id,
                    name: other.name,
                    selectedSessionId: nil,
                    sessions: []
                ),
            ],
            selectedProjectId: selected.id
        ))
    }

    func testAgentActivitySnapshotDecodesModelInfo() throws {
        let base = "\"schemaVersion\":1,\"updatedAt\":\"2026-07-14T00:00:00Z\","
            + "\"foregroundTurnActive\":false,\"scheduledTurnActive\":false,"
            + "\"activeSubagents\":[],\"schedules\":[],\"idleGeneration\":0,"
            + "\"lastIdleAborted\":false"
        let full = Data(("{" + base + ",\"model\":{\"name\":\"gpt-5.5\","
            + "\"reasoningEffort\":\"high\",\"contextTier\":\"long_context\"}}").utf8)
        let info = try XCTUnwrap(
            try JSONDecoder().decode(AgentActivitySnapshot.self, from: full).remoteModelInfo()
        )
        XCTAssertEqual(info.name, "gpt-5.5")
        XCTAssertEqual(info.reasoningEffort, "high")
        XCTAssertEqual(info.contextTier, "long_context")

        let bare = Data(("{" + base + "}").utf8)
        XCTAssertNil(
            try JSONDecoder().decode(AgentActivitySnapshot.self, from: bare).remoteModelInfo()
        )
    }

    func testRemoteTerminalScreenCaptureNormalizesCells() {
        XCTAssertEqual(RemoteTerminalScreen.captureVisible(
            sessionId: "session",
            cols: 2,
            rows: 2,
            lineAt: { ["A\u{0}", "\u{0}B"][$0] }
        ), RemoteTerminalScreen(
            sessionId: "session",
            cols: 2,
            rows: 2,
            scrollMode: .terminal,
            historyStartLine: 0,
            firstLine: 0,
            liveTopLine: 0,
            reset: true,
            lines: ["A ", " B"]
        ))
    }

    func testRemoteTerminalHistoryUsesAbsoluteIncrementalSegments() {
        let values = Dictionary(uniqueKeysWithValues: (100 ..< 108).map {
            ($0, "line-\($0)")
        })
        let initial = RemoteTerminalScreen.captureHistory(
            sessionId: "session",
            cols: 20,
            rows: 3,
            absoluteStart: 100,
            scanRows: 8,
            maximumRows: 6,
            afterLine: nil,
            lineExists: { values[$0] != nil },
            lineAt: { values[$0] }
        )
        XCTAssertEqual(initial.historyStartLine, 102)
        XCTAssertEqual(initial.firstLine, 102)
        XCTAssertEqual(initial.liveTopLine, 105)
        XCTAssertTrue(initial.reset)
        XCTAssertEqual(initial.lines, (102 ..< 108).map { "line-\($0)" })

        let delta = RemoteTerminalScreen.captureHistory(
            sessionId: "session",
            cols: 20,
            rows: 3,
            absoluteStart: 100,
            scanRows: 8,
            maximumRows: 6,
            afterLine: 106,
            lineExists: { values[$0] != nil },
            lineAt: { values[$0] }
        )
        XCTAssertEqual(delta.firstLine, 103)
        XCTAssertFalse(delta.reset)
        XCTAssertEqual(delta.lines, (103 ..< 108).map { "line-\($0)" })
    }

    func testRemoteTerminalHistoryScansPastDisplayedWindowToLiveRows() {
        let values = Dictionary(uniqueKeysWithValues: (0 ..< 12).map {
            ($0, "line-\($0)")
        })
        let screen = RemoteTerminalScreen.captureHistory(
            sessionId: "session",
            cols: 20,
            rows: 3,
            absoluteStart: 0,
            scanRows: 12,
            maximumRows: 6,
            afterLine: nil,
            lineExists: { values[$0] != nil },
            lineAt: { values[$0] }
        )
        XCTAssertEqual(screen.historyStartLine, 6)
        XCTAssertEqual(screen.liveTopLine, 9)
        XCTAssertEqual(screen.lines, (6 ..< 12).map { "line-\($0)" })
    }

    func testRemoteScrollMessageRoundTrips() throws {
        let message = RemoteClientMessage(
            type: "scroll",
            clientId: "phone",
            sessionId: "session",
            delta: -4
        )
        let decoded = try JSONDecoder().decode(
            RemoteClientMessage.self,
            from: JSONEncoder().encode(message)
        )
        XCTAssertEqual(decoded.type, "scroll")
        XCTAssertEqual(decoded.delta, -4)
    }

    func testRemoteSessionSnapshotDecodesWithoutPromptableField() throws {
        let data = Data("""
        {
          "id":"session",
          "title":"shell",
          "status":"idle",
          "unread":false,
          "ready":false,
          "background":false,
          "scheduled":false
        }
        """.utf8)
        let snapshot = try JSONDecoder().decode(RemoteSessionSnapshot.self, from: data)
        XCTAssertNil(snapshot.promptable)
    }

    func testRemoteSessionSnapshotDecodesWithoutPendingUserInputs() throws {
        let data = Data("""
        {
          "id":"session",
          "title":"shell",
          "status":"idle",
          "unread":false,
          "ready":false,
          "background":false,
          "scheduled":false,
          "promptable":true
        }
        """.utf8)
        let snapshot = try JSONDecoder().decode(RemoteSessionSnapshot.self, from: data)
        XCTAssertNil(snapshot.pendingUserInputs)
    }

    func testRemoteUserInputRequestPreservesVerbatimChoices() throws {
        let request = RemoteUserInputRequest(
            requestId: "req-1",
            question: "Deploy to production?",
            choices: ["Yes, deploy", "No — keep the current build"],
            allowFreeform: true,
            requestedAt: Date(timeIntervalSince1970: 1_700_000_000),
            agentId: "agent-3"
        )
        let decoded = try JSONDecoder().decode(
            RemoteUserInputRequest.self,
            from: JSONEncoder().encode(request)
        )
        XCTAssertEqual(decoded, request)
        XCTAssertEqual(decoded.id, "req-1")
        XCTAssertEqual(decoded.choices, ["Yes, deploy", "No — keep the current build"])
    }

    func testRemoteWebCommandInputHasAccessibleName() {
        XCTAssertTrue(RemoteWebAssets.html.contains("aria-label=\"Command input\""))
        XCTAssertTrue(RemoteWebAssets.html.contains("aria-label=\"Message Copilot\""))
        XCTAssertTrue(RemoteWebAssets.html.contains(#"aria-describedby="prompt-warning""#))
        XCTAssertTrue(RemoteWebAssets.html.contains(
            #"id="prompt-status" role="status" aria-live="polite" aria-atomic="true""#
        ))
        XCTAssertTrue(RemoteWebAssets.html.contains(
            "Sending clears any unsent desktop draft."
        ))
    }

    func testRemoteWebInputRequeuesAfterNetworkFailure() {
        XCTAssertTrue(RemoteWebAssets.javascript.contains(
            "pendingActions.unshift(action);"
        ))
        XCTAssertTrue(RemoteWebAssets.javascript.contains(
            "setTimeout(flushInput, 1000);"
        ))
        XCTAssertTrue(RemoteWebAssets.javascript.contains(
            "pendingActions.push({type:'key', data:key});"
        ))
    }

    func testRemoteWebIgnoresStaleTranscriptAndPromptResponses() {
        XCTAssertTrue(RemoteWebAssets.javascript.contains(
            "const requestId = ++transcriptRequestId;"
        ))
        XCTAssertTrue(RemoteWebAssets.javascript.contains(
            "requestId === transcriptRequestId"
        ))
        XCTAssertTrue(RemoteWebAssets.javascript.contains(
            "const submittedGeneration = selectionGeneration;"
        ))
        XCTAssertTrue(RemoteWebAssets.javascript.contains(
            "selectionGeneration !== submittedGeneration"
        ))
        XCTAssertTrue(RemoteWebAssets.javascript.contains(
            "if (selected !== id || selectionGeneration !== submittedGeneration) return;"
        ))
        XCTAssertTrue(RemoteWebAssets.javascript.contains(
            "if ((state?.pendingUserInputs || []).length > 0) return;"
        ))
    }

    func testRemoteWebSurfacesUserInputCardsSafely() {
        XCTAssertTrue(RemoteWebAssets.html.contains(#"id="user-input""#))
        // Untrusted question/choice text is only ever set via textContent.
        XCTAssertTrue(RemoteWebAssets.javascript.contains(
            "question.textContent = request.question;"
        ))
        XCTAssertTrue(RemoteWebAssets.javascript.contains("button.textContent = choice;"))
        // Choice buttons submit the exact choice with wasFreeform = false.
        XCTAssertTrue(RemoteWebAssets.javascript.contains(
            "submitUserInput(request.requestId, choice, false)"
        ))
        XCTAssertTrue(RemoteWebAssets.javascript.contains(
            "submitUserInput(request.requestId, value, true)"
        ))
        XCTAssertTrue(RemoteWebAssets.javascript.contains("type: 'answer-user-input'"))
        XCTAssertTrue(RemoteWebAssets.javascript.contains(
            "data: JSON.stringify({ requestId, answer, wasFreeform })"
        ))
        // Composer is suppressed while questions are pending.
        XCTAssertTrue(RemoteWebAssets.javascript.contains(
            "promptForm.classList.toggle('hidden', hasQuestions)"
        ))
        // Retry/removal semantics: 15s fallback, snapshot-driven removal, error codes.
        XCTAssertTrue(RemoteWebAssets.javascript.contains("}, 15000);"))
        XCTAssertTrue(RemoteWebAssets.javascript.contains(
            "sessionHasUserInput(submittedSession, requestId)"
        ))
        XCTAssertTrue(RemoteWebAssets.javascript.contains("if (!ids.has(requestId)) {"))
        XCTAssertTrue(RemoteWebAssets.javascript.contains("entry.token !== token"))
        XCTAssertTrue(RemoteWebAssets.javascript.contains(
            "latestUserInputAttempts.get(requestId) !== token"
        ))
        XCTAssertTrue(RemoteWebAssets.javascript.contains("response?.status === 403"))
        XCTAssertTrue(RemoteWebAssets.javascript.contains(
            "if (!selected || !writable || submittingUserInputs.has(requestId)) return;"
        ))
        XCTAssertTrue(RemoteWebAssets.javascript.contains("aria-labelledby"))
        XCTAssertTrue(RemoteWebAssets.javascript.contains("aria-describedby"))
        XCTAssertTrue(RemoteWebAssets.javascript.contains("refreshUserInputCardStates();"))
        XCTAssertTrue(RemoteWebAssets.javascript.contains("response?.status === 409"))
        XCTAssertTrue(RemoteWebAssets.javascript.contains("response?.status === 422"))
    }

    func testRemoteServiceWorkerClearsSyncedNotifications() {
        XCTAssertTrue(RemoteWebAssets.serviceWorker.contains("payload.action === 'clear'"))
        XCTAssertTrue(RemoteWebAssets.serviceWorker.contains(
            "self.registration.getNotifications"
        ))
        XCTAssertTrue(RemoteWebAssets.serviceWorker.contains("notification.close()"))
    }

    func testRemoteWebSessionPivotMirrorsIOS() {
        // The web UI shows one pane at a time behind a Conversation/Terminal pivot,
        // mirroring the iOS SessionScreenView segmented control.
        XCTAssertTrue(RemoteWebAssets.html.contains(#"id="content" data-mode="conversation""#))
        XCTAssertTrue(RemoteWebAssets.html.contains(
            #"<div id="pivot-tabs" role="tablist" aria-label="Session view">"#
        ))
        XCTAssertTrue(RemoteWebAssets.html.contains(
            #"data-mode="conversation">Conversation</button>"#
        ))
        XCTAssertTrue(RemoteWebAssets.html.contains(
            #"data-mode="terminal">Terminal</button>"#
        ))
        // Panes are toggled purely by the content mode.
        XCTAssertTrue(RemoteWebAssets.css.contains(
            #"#content[data-mode="conversation"] #terminal-pane { display:none; }"#
        ))
        XCTAssertTrue(RemoteWebAssets.css.contains(
            #"#content[data-mode="terminal"] #transcript-pane { display:none; }"#
        ))
        // Terminal frames are only rendered while the Terminal tab is active.
        XCTAssertTrue(RemoteWebAssets.javascript.contains(
            "if (viewMode === 'terminal') renderLines(message.data);"
        ))
        XCTAssertTrue(RemoteWebAssets.javascript.contains("function setViewMode(mode"))
    }

    func testRemoteWebPromptSubmitsOnEnter() {
        // Enter sends the Copilot prompt; Shift+Enter keeps inserting a newline.
        XCTAssertTrue(RemoteWebAssets.javascript.contains(
            "prompt.addEventListener('keydown', (event) => {"
        ))
        XCTAssertTrue(RemoteWebAssets.javascript.contains(
            "if (event.key === 'Enter' && !event.shiftKey && !event.isComposing) {"
        ))
        XCTAssertTrue(RemoteWebAssets.javascript.contains("promptForm.requestSubmit();"))
    }

    func testRemoteWebConversationQueuesPromptsWhileBusy() {
        // Conversation mode queues messages per session and flushes them in
        // order once Copilot is promptable again.
        XCTAssertTrue(RemoteWebAssets.html.contains(
            #"<div id="prompt-queue" role="list" aria-label="Queued messages" hidden></div>"#
        ))
        XCTAssertTrue(RemoteWebAssets.css.contains(".queue-item {"))
        XCTAssertTrue(RemoteWebAssets.javascript.contains("const QUEUE_CAP = 25;"))
        XCTAssertTrue(RemoteWebAssets.javascript.contains("const promptQueues = new Map();"))
        XCTAssertTrue(RemoteWebAssets.javascript.contains("function enqueuePrompt(value)"))
        XCTAssertTrue(RemoteWebAssets.javascript.contains("async function flushQueue()"))
        // Only releases the next message when the session is idle/promptable.
        XCTAssertTrue(RemoteWebAssets.javascript.contains(
            "if (!(writable && state?.promptable === true"
        ))
        // Per-session removal from the queue.
        XCTAssertTrue(RemoteWebAssets.javascript.contains(
            "sessionQueue(selected).splice(index, 1);"
        ))
    }

    func testRemoteWebNewSessionButtonCreatesInHostSelectedProject() {
        // The button and its status live in the header.
        XCTAssertTrue(RemoteWebAssets.html.contains(#"id="new-session""#))
        XCTAssertTrue(RemoteWebAssets.html.contains(#"id="create-status""#))
        // Track the host's selected project and create only there.
        XCTAssertTrue(RemoteWebAssets.javascript.contains(
            "const nextProjectId = data.selectedProjectId || null;"
        ))
        XCTAssertTrue(RemoteWebAssets.javascript.contains(
            "body: JSON.stringify({ requestId: createRequestId, projectId })"
        ))
        // Disable without a selected project or while a request is active; double
        // clicks are blocked by the same guard.
        XCTAssertTrue(RemoteWebAssets.javascript.contains(
            "newSessionButton.disabled = !hostSelectedProjectId || creating;"
        ))
        XCTAssertTrue(RemoteWebAssets.javascript.contains(
            "if (creating || !hostSelectedProjectId) return;"
        ))
        // Retain one request id across network/5xx retries.
        XCTAssertTrue(RemoteWebAssets.javascript.contains(
            "if (!createRequestId || createRequestProjectId !== hostSelectedProjectId) {"
        ))
        XCTAssertTrue(RemoteWebAssets.javascript.contains("if (response.status >= 500) {"))
        // Clear the request id on 410 (and on success) so the next click is fresh.
        XCTAssertTrue(RemoteWebAssets.javascript.contains("if (response.status === 410) {"))
        XCTAssertTrue(RemoteWebAssets.javascript.contains("createRequestId = null;"))
        XCTAssertTrue(RemoteWebAssets.javascript.contains("createRequestProjectId = null;"))
        XCTAssertTrue(RemoteWebAssets.javascript.contains(
            "if (hostSelectedProjectId !== nextProjectId && !creating) {"
        ))
        // In insecure browser contexts randomUUID may be unavailable. The fallback
        // must still satisfy the host's UUID-decoded request contract.
        XCTAssertTrue(RemoteWebAssets.javascript.contains("function newUUID() {"))
        XCTAssertTrue(RemoteWebAssets.javascript.contains(
            "bytes[6] = (bytes[6] & 0x0f) | 0x40;"
        ))
        XCTAssertTrue(RemoteWebAssets.javascript.contains(
            "bytes[8] = (bytes[8] & 0x3f) | 0x80;"
        ))
        // Concise, specific messaging including unsupported (404) and 422.
        XCTAssertTrue(RemoteWebAssets.javascript.contains("if (response.status === 404) {"))
        XCTAssertTrue(RemoteWebAssets.javascript.contains("if (response.status === 422) {"))
        // Select the created session once the host snapshot includes it.
        XCTAssertTrue(RemoteWebAssets.javascript.contains(
            "if (pendingCreatedSessionId && sessionState.has(pendingCreatedSessionId)) {"
        ))
    }

    func testRemoteWebJavaScriptSyntax() throws {
        try requireNodeForJavaScriptTests()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("app.js")
        try RemoteWebAssets.javascript.write(
            to: script,
            atomically: true,
            encoding: .utf8
        )
        let process = Process()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", "--check", script.path]
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let output = stderr.fileHandleForReading.readDataToEndOfFile()
        XCTAssertEqual(
            process.terminationStatus,
            0,
            String(data: output, encoding: .utf8) ?? "node --check failed"
        )
    }

    func testWebPushStoreRejectsUnsafeEndpointsAndPersistsSubscriptions() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("nested", isDirectory: true)
        let url = directory.appendingPathComponent("subscriptions.json")
        let store = WebPushSubscriptionStore(url: url)

        let safe = try JSONDecoder().decode(
            WebPushRegistration.self,
            from: webPushRegistrationData(
                endpoint: "https://wns2-by3p.notify.windows.com/sub/1"
            )
        )
        try store.add(safe)
        XCTAssertEqual(store.all().count, 1)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[
            .posixPermissions
        ] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        let directoryPermissions = try FileManager.default.attributesOfItem(
            atPath: directory.path
        )[.posixPermissions] as? NSNumber
        XCTAssertEqual(directoryPermissions?.intValue, 0o700)

        let unsafe = try JSONDecoder().decode(
            WebPushRegistration.self,
            from: webPushRegistrationData(endpoint: "https://127.0.0.1/push")
        )
        XCTAssertThrowsError(try store.add(unsafe))
        XCTAssertEqual(store.all().count, 1)
    }

    func testWebPushServiceSendsTimestampedNotificationPayload() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WebPushSubscriptionStore(
            url: root.appendingPathComponent("subscriptions.json")
        )
        try store.add(JSONDecoder().decode(
            WebPushRegistration.self,
            from: webPushRegistrationData(
                endpoint: "https://wns2-by3p.notify.windows.com/sub/1"
            )
        ))
        let sender = WebPushSenderSpy()
        let service = WebPushService(
            publicKey: VAPID.Key().id.description,
            store: store,
            sender: sender
        )
        let sentAt = Date(timeIntervalSince1970: 1_800_000_000)
        await service.send(NotificationEvent(
            kind: .permission,
            title: "Copilot needs permission",
            subtitle: "Project · Session",
            body: nil,
            projectId: "project",
            sessionId: "session",
            sentAt: sentAt
        ))
        let firstPayload = await sender.firstPayload()
        let payload = try XCTUnwrap(firstPayload)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: payload) as? [String: Any]
        )
        XCTAssertEqual(object["kind"] as? String, "permission")
        XCTAssertEqual(object["sessionId"] as? String, "session")
        XCTAssertEqual(object["sentAt"] as? String, "2027-01-15T08:00:00Z")
        XCTAssertEqual(object["body"] as? String, "Project · Session")
        XCTAssertTrue(RemoteWebAssets.serviceWorker.contains("Sent at ${sentTime}"))
        XCTAssertEqual(service.status().subscriptions, 1)
        XCTAssertNotNil(service.status().lastSuccessAt)
        XCTAssertNil(service.status().lastError)
    }

    func testWebPushClearSkipsLegacySubscriptionsWithoutCapability() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WebPushSubscriptionStore(
            url: root.appendingPathComponent("subscriptions.json")
        )
        try store.add(JSONDecoder().decode(
            WebPushRegistration.self,
            from: webPushRegistrationData(
                endpoint: "https://wns2-by3p.notify.windows.com/sub/capable"
            )
        ))
        try store.add(JSONDecoder().decode(
            WebPushRegistration.self,
            from: webPushRegistrationData(
                endpoint: "https://wns2-by3p.notify.windows.com/sub/legacy",
                supportsClearAction: false
            )
        ))
        let sender = WebPushSenderSpy()
        let service = WebPushService(
            publicKey: VAPID.Key().id.description,
            store: store,
            sender: sender
        )

        await service.sendDismissal(id: UUID())

        let payloads = await sender.sentPayloads()
        let endpoints = await sender.sentEndpoints()
        XCTAssertEqual(payloads.count, 1)
        XCTAssertEqual(endpoints.map(\.lastPathComponent), ["capable"])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(
            try decoder.decode(RemoteNotificationPayload.self, from: payloads[0]).action,
            .clear
        )
    }

    func testAPNsProviderTokenUsesRawES256Signature() async throws {
        let key = P256.Signing.PrivateKey()
        let configuration = APNsConfiguration(
            keyID: "KEY123",
            teamID: "TEAM123",
            topic: "com.example.app",
            privateKeyPEM: key.pemRepresentation
        )
        let provider = try APNsProvider(configuration: configuration)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let token = try await provider.providerToken(now: now)
        let segments = token.split(separator: ".")
        XCTAssertEqual(segments.count, 3)
        let header = try XCTUnwrap(JSONSerialization.jsonObject(
            with: try XCTUnwrap(CloudflareAccessVerifier.base64URLDecode(
                String(segments[0])
            ))
        ) as? [String: Any])
        let claims = try XCTUnwrap(JSONSerialization.jsonObject(
            with: try XCTUnwrap(CloudflareAccessVerifier.base64URLDecode(
                String(segments[1])
            ))
        ) as? [String: Any])
        let signature = try XCTUnwrap(
            CloudflareAccessVerifier.base64URLDecode(String(segments[2]))
        )
        XCTAssertEqual(header["alg"] as? String, "ES256")
        XCTAssertEqual(header["kid"] as? String, "KEY123")
        XCTAssertEqual(claims["iss"] as? String, "TEAM123")
        XCTAssertEqual(claims["iat"] as? Int, 1_800_000_000)
        XCTAssertEqual(signature.count, 64)
    }

    func testAPNsServiceStoresEnvironmentAndFansOut() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = APNsDeviceStore(url: root.appendingPathComponent("devices.json"))
        try store.add(APNsRegistration(
            token: String(repeating: "ab", count: 32),
            environment: .production,
            label: "iPhone"
        ))
        let sender = APNsSenderSpy()
        let service = APNsService(store: store, provider: sender)
        await service.send(NotificationEvent(
            kind: .completed,
            title: "Complete",
            subtitle: "Project · Session",
            body: nil,
            projectId: "project",
            sessionId: "session"
        ))
        let device = await sender.firstDevice()
        let payloads = await sender.sentPayloads()
        XCTAssertEqual(device?.environment, .production)
        XCTAssertEqual(device?.token, String(repeating: "ab", count: 32))
        XCTAssertEqual(payloads.first?.action, .show)
        let permissions = try FileManager.default.attributesOfItem(
            atPath: root.appendingPathComponent("devices.json").path
        )[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    func testRemoteWebAssetsIncludePushLinksAndConnectionState() {
        XCTAssertTrue(RemoteWebAssets.html.contains("manifest.webmanifest"))
        XCTAssertTrue(RemoteWebAssets.html.contains("connection-dot"))
        XCTAssertTrue(RemoteWebAssets.html.contains("role=\"region\" aria-live=\"off\""))
        XCTAssertTrue(RemoteWebAssets.javascript.contains("document.createDocumentFragment()"))
        XCTAssertTrue(RemoteWebAssets.javascript.contains(
            "registerSubscription(subscription, applicationServerKey)"
        ))
        XCTAssertTrue(RemoteWebAssets.javascript.contains("capabilities: ['clear-action']"))
        XCTAssertTrue(RemoteWebAssets.javascript.contains("rel = 'noopener noreferrer'"))
        XCTAssertTrue(RemoteWebAssets.javascript.contains("push/subscribe"))
        XCTAssertTrue(RemoteWebAssets.javascript.contains("type: 'prompt'"))
        XCTAssertTrue(RemoteWebAssets.javascript.contains(
            "transcript?s=${encodeURIComponent(sessionId)}"
        ))
        XCTAssertTrue(RemoteWebAssets.javascript.contains("response?.status === 409"))
        XCTAssertTrue(RemoteWebAssets.javascript.contains("response?.status === 422"))
        XCTAssertTrue(RemoteWebAssets.serviceWorker.contains("notificationclick"))
        XCTAssertTrue(RemoteWebAssets.serviceWorker.contains("notificationclose"))
        XCTAssertTrue(RemoteWebAssets.serviceWorker.contains(
            NotificationSyncContract.dismissPath
        ))
        XCTAssertTrue(RemoteWebAssets.javascript.contains("dismissed-notifications"))
        XCTAssertTrue(RemoteWebAssets.javascript.contains("clearDismissedNotifications"))
    }

    func testRemoteQueryItemsParsesSession() {
        let items = RemoteRequestAuth.queryItems("/events?s=session%2Fid")
        XCTAssertEqual(items["s"], "session/id")
    }

    func testRemoteWriterLeaseTakeoverGivesControlToLatestClient() {
        let leases = RemoteWriterLeases()
        leases.acquire(sessionId: "session", clientId: "phone")
        XCTAssertTrue(leases.holds(sessionId: "session", clientId: "phone"))
        XCTAssertFalse(leases.holds(sessionId: "session", clientId: "laptop"))
        // A second device takes over by acquiring; the previous holder loses it.
        leases.acquire(sessionId: "session", clientId: "laptop")
        XCTAssertTrue(leases.holds(sessionId: "session", clientId: "laptop"))
        XCTAssertFalse(leases.holds(sessionId: "session", clientId: "phone"))
        // Leases are scoped per session.
        leases.acquire(sessionId: "other", clientId: "phone")
        XCTAssertTrue(leases.holds(sessionId: "other", clientId: "phone"))
        XCTAssertTrue(leases.holds(sessionId: "session", clientId: "laptop"))
    }

    func testRemoteWriterLeaseLinearizesInjectionAndTakeover() {
        let leases = RemoteWriterLeases()
        leases.acquire(sessionId: "session", clientId: "phone")
        let injectionStarted = DispatchSemaphore(value: 0)
        let finishInjection = DispatchSemaphore(value: 0)
        let injectionFinished = DispatchSemaphore(value: 0)
        let takeoverFinished = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
            _ = leases.withHeldLease(
                sessionId: "session",
                clientId: "phone"
            ) {
                injectionStarted.signal()
                finishInjection.wait()
            }
            injectionFinished.signal()
        }
        XCTAssertEqual(injectionStarted.wait(timeout: .now() + 1), .success)

        DispatchQueue.global().async {
            leases.acquire(sessionId: "session", clientId: "laptop")
            takeoverFinished.signal()
        }
        XCTAssertEqual(
            takeoverFinished.wait(timeout: .now() + 0.05),
            .timedOut
        )

        finishInjection.signal()
        XCTAssertEqual(injectionFinished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(takeoverFinished.wait(timeout: .now() + 1), .success)
        XCTAssertTrue(leases.holds(sessionId: "session", clientId: "laptop"))
    }

    func testRemoteWriterLeaseGatesPromptUntilTransitionOrTimeout() {
        let leases = RemoteWriterLeases()
        leases.acquire(sessionId: "session", clientId: "phone")
        let submittedAt = Date(timeIntervalSince1970: 100)
        var sentValues: [String] = []

        XCTAssertEqual(
            leases.submitPrompt(
                sessionId: "session",
                clientId: "phone",
                now: submittedAt
            ) {
                sentValues.append("first")
                return .sent
            },
            .sent
        )
        XCTAssertEqual(
            leases.submitPrompt(
                sessionId: "session",
                clientId: "phone",
                now: submittedAt.addingTimeInterval(1)
            ) {
                sentValues.append("duplicate")
                return .sent
            },
            .busy
        )
        XCTAssertEqual(sentValues, ["first"])

        leases.observePromptUnavailable(
            sessionId: "session",
            observedAt: submittedAt.addingTimeInterval(-1)
        )
        XCTAssertEqual(
            leases.submitPrompt(
                sessionId: "session",
                clientId: "phone",
                now: submittedAt.addingTimeInterval(2)
            ) {
                sentValues.append("stale-cleared")
                return .sent
            },
            .busy
        )

        leases.observePromptUnavailable(
            sessionId: "session",
            observedAt: submittedAt.addingTimeInterval(2)
        )
        XCTAssertEqual(
            leases.submitPrompt(
                sessionId: "session",
                clientId: "phone",
                now: submittedAt.addingTimeInterval(2)
            ) {
                sentValues.append("after-transition")
                return .sent
            },
            .sent
        )
        XCTAssertEqual(
            leases.submitPrompt(
                sessionId: "session",
                clientId: "phone",
                now: submittedAt.addingTimeInterval(8)
            ) {
                sentValues.append("after-timeout")
                return .sent
            },
            .sent
        )
        XCTAssertEqual(sentValues, ["first", "after-transition", "after-timeout"])
    }

    func testCLIParsesStatusNotificationFlagIntoControlRequest() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let socketPath = root.appendingPathComponent("control.sock").path
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var received: ControlRequest?
        let server = ControlServer(socketPath: socketPath) { request in
            received = request
            return .success()
        }
        XCTAssertTrue(server.start())
        defer { server.stop() }

        var environment = ProcessInfo.processInfo.environment
        environment["COPILOT_PROJECTS_SOCKET"] = socketPath

        XCTAssertEqual(CLIMain.run([
            "set-status", "waiting",
            "--notification", "permission",
            "--session", "session-1",
            "--copilot-session", "copilot-session-1",
        ], environment: environment), 0)
        XCTAssertEqual(received?.status, "waiting")
        XCTAssertEqual(received?.notification, .permission)
        XCTAssertEqual(received?.sessionId, "session-1")
        XCTAssertEqual(received?.copilotSessionId, "copilot-session-1")
    }

    func testControlServerSurvivesClientDisconnectBeforeResponse() throws {
        let socketPath = "/tmp/cp-\(UUID().uuidString.prefix(8)).sock"
        let server = ControlServer(socketPath: socketPath) { request in
            if request.command == "slow" { usleep(100_000) }
            return .success(request.command)
        }
        XCTAssertTrue(server.start())
        defer {
            server.stop()
            try? FileManager.default.removeItem(atPath: socketPath)
        }

        let fd = try connectUnixSocket(path: socketPath)
        let request = ControlRequest(command: "slow")
        let payload = try Wire.encodeLine(request)
        _ = payload.withUnsafeBytes {
            Darwin.write(fd, $0.baseAddress, $0.count)
        }
        close(fd)

        Thread.sleep(forTimeInterval: 0.5)
        let response = try ControlClient(socketPath: socketPath)
            .send(ControlRequest(command: "ping"))
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.text, "ping")
    }

    private func runHook(
        hookURL: URL,
        action: String,
        payload: String,
        tabId: String,
        root: URL,
        bin: URL,
        capture: URL
    ) throws {
        let process = try startHook(
            hookURL: hookURL,
            action: action,
            payload: payload,
            tabId: tabId,
            root: root,
            bin: bin,
            capture: capture
        )
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    private func startHook(
        hookURL: URL,
        action: String,
        payload: String,
        tabId: String,
        root: URL,
        bin: URL,
        capture: URL
    ) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [hookURL.path, action]
        var environment = ProcessInfo.processInfo.environment
        environment["COPILOT_PROJECTS_SESSION"] = tabId
        environment["COPILOT_PROJECTS_SOCKET"] = root.appendingPathComponent("control.sock").path
        environment["CAPTURE_FILE"] = capture.path
        environment["PATH"] = "\(bin.path):/usr/bin:/bin"
        process.environment = environment
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        input.fileHandleForWriting.write(Data(payload.utf8))
        try input.fileHandleForWriting.close()
        return process
    }

    private func cliCallLines(in capture: URL) throws -> [String] {
        try String(contentsOf: capture, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
    }

    private func completionSignals(in calls: [String]) -> Int {
        calls.filter {
            $0.contains("--source agent-stop") || $0.contains("--notification completed")
        }.count
    }

    private func makeRSAKeyPair() throws -> (privateKey: SecKey, publicKey: SecKey) {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2_048,
        ]
        var creationError: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(
            attributes as CFDictionary,
            &creationError
        ), let publicKey = SecKeyCopyPublicKey(privateKey) else {
            if let creationError {
                throw creationError.takeRetainedValue() as Error
            }
            throw NSError(domain: "CloudflareAccessTests", code: 1)
        }
        return (privateKey, publicKey)
    }

    private func accessToken(
        kid: String,
        claims: [String: Any],
        privateKey: SecKey
    ) throws -> String {
        let header: [String: Any] = ["alg": "RS256", "kid": kid, "typ": "JWT"]
        let headerData = try JSONSerialization.data(
            withJSONObject: header,
            options: [.sortedKeys]
        )
        let claimsData = try JSONSerialization.data(
            withJSONObject: claims,
            options: [.sortedKeys]
        )
        let signingInput = "\(base64URL(headerData)).\(base64URL(claimsData))"
        var signingError: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            privateKey,
            .rsaSignatureMessagePKCS1v15SHA256,
            Data(signingInput.utf8) as CFData,
            &signingError
        ) as Data? else {
            if let signingError {
                throw signingError.takeRetainedValue() as Error
            }
            throw NSError(domain: "CloudflareAccessTests", code: 2)
        }
        return "\(signingInput).\(base64URL(signature))"
    }

    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func webPushRegistrationData(
        endpoint: String,
        supportsClearAction: Bool = true
    ) throws -> Data {
        let key = VAPID.Key().id.description
        var registration: [String: Any] = [
            "subscription": [
                "endpoint": endpoint,
                "keys": [
                    "p256dh": key,
                    "auth": base64URL(Data(repeating: 7, count: 16)),
                ],
                "applicationServerKey": key,
            ],
            "label": "Test Browser",
        ]
        if supportsClearAction {
            registration["capabilities"] = ["clear-action"]
        }
        return try JSONSerialization.data(withJSONObject: registration)
    }

    private func remoteHTTPStatus(
        port: Int,
        path: String,
        method: String = "GET",
        token: String? = nil,
        origin: String? = nil,
        body: Data? = nil
    ) async throws -> Int {
        let response = try await remoteHTTPResponse(
            port: port,
            path: path,
            method: method,
            token: token,
            origin: origin,
            body: body
        )
        return response.statusCode
    }

    private func remoteHTTPResponse(
        port: Int,
        path: String,
        method: String = "GET",
        token: String? = nil,
        origin: String? = nil,
        body: Data? = nil
    ) async throws -> HTTPURLResponse {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 5
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)\(path)"))
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("close", forHTTPHeaderField: "Connection")
        if let token {
            request.setValue(token, forHTTPHeaderField: "Cf-Access-Jwt-Assertion")
        }
        if let origin {
            request.setValue(origin, forHTTPHeaderField: "Origin")
        }
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (_, response) = try await session.data(for: request)
        return try XCTUnwrap(response as? HTTPURLResponse)
    }

    private func remoteHTTPResponseWithBody(
        port: Int,
        path: String,
        method: String = "GET",
        token: String? = nil,
        origin: String? = nil,
        body: Data? = nil
    ) async throws -> (HTTPURLResponse, Data) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 5
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)\(path)"))
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("close", forHTTPHeaderField: "Connection")
        if let token {
            request.setValue(token, forHTTPHeaderField: "Cf-Access-Jwt-Assertion")
        }
        if let origin {
            request.setValue(origin, forHTTPHeaderField: "Origin")
        }
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        return (try XCTUnwrap(response as? HTTPURLResponse), data)
    }

    private func remoteHTTPData(
        port: Int,
        path: String,
        token: String? = nil
    ) async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 5
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)\(path)"))
        var request = URLRequest(url: url)
        request.setValue("close", forHTTPHeaderField: "Connection")
        if let token {
            request.setValue(token, forHTTPHeaderField: "Cf-Access-Jwt-Assertion")
        }
        let (data, response) = try await session.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        return data
    }

    private func connectUnixSocket(path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.ENOTSOCK) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else {
            close(fd)
            throw POSIXError(.ENAMETOOLONG)
        }
        withUnsafeMutablePointer(to: &address.sun_path) { raw in
            raw.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                for (index, byte) in bytes.enumerated() {
                    destination[index] = CChar(bitPattern: byte)
                }
                destination[bytes.count] = 0
            }
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let code = errno
            close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .ECONNREFUSED)
        }
        return fd
    }
}
