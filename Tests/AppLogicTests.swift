import XCTest
@testable import copilot_projects
import CopilotProjectsCore
import AppKit
import Security
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
        var onPost: ((Call) -> Void)?

        func post(
            title: String,
            subtitle: String?,
            body: String?,
            projectId: String?,
            sessionId: String?
        ) {
            let call = Call(
                title: title,
                subtitle: subtitle,
                body: body,
                projectId: projectId,
                sessionId: sessionId
            )
            calls.append(call)
            onPost?(call)
        }
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
        try await Task.sleep(nanoseconds: 50_000_000)

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
        XCTAssertTrue(TerminalController.isSafeSessionId(UUID().uuidString))
        XCTAssertFalse(TerminalController.isSafeSessionId("../../bad"))
        XCTAssertEqual(TerminalController.shellSingleQuote("a'b"), "'a'\\''b'")
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
        XCTAssertEqual(configuration.localPort, 49_271)
        XCTAssertEqual(configuration.access.teamDomain, "team.cloudflareaccess.com")
        XCTAssertEqual(configuration.access.audTag, "audience")
        XCTAssertEqual(configuration.access.allowedEmail, "user@example.com")

        defaults.set("%", forKey: RemoteAccessConfiguration.teamDomainKey)
        XCTAssertNil(RemoteAccessConfiguration.load(defaults: defaults))
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

        let gateway = RemoteGateway()
        let port = try gateway.start(
            bridge: RemoteModelBridge(model: model),
            expectedHost: "127.0.0.1",
            expectedOrigin: "https://projects.example.com",
            verifier: verifier,
            port: 0
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
                    + "script-src 'self'; frame-ancestors 'none'; base-uri 'none'"
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
                            scheduled: false
                        ),
                        RemoteSessionSnapshot(
                            id: completed.id,
                            title: completed.title,
                            status: SessionStatus.idle.rawValue,
                            statusText: nil,
                            unread: false,
                            ready: true,
                            background: false,
                            scheduled: false
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

    func testRemoteTerminalScreenCaptureNormalizesCells() {
        let cells: [[Character?]] = [
            ["A", "\u{0}"],
            [nil, "B"],
        ]
        XCTAssertEqual(RemoteTerminalScreen.capture(
            sessionId: "session",
            cols: 2,
            rows: 2,
            characterAt: { cells[$1][$0] }
        ), RemoteTerminalScreen(
            sessionId: "session",
            cols: 2,
            rows: 2,
            lines: ["A ", " B"]
        ))
    }

    func testRemoteWebCommandInputHasAccessibleName() {
        XCTAssertTrue(RemoteWebAssets.html.contains("aria-label=\"Command input\""))
    }

    func testRemoteWebInputRequeuesAfterNetworkFailure() {
        XCTAssertTrue(RemoteWebAssets.javascript.contains(
            "pendingInput = data + pendingInput;"
        ))
        XCTAssertTrue(RemoteWebAssets.javascript.contains(
            "setTimeout(flushInput, 1000);"
        ))
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
        ], environment: environment), 0)
        XCTAssertEqual(received?.status, "waiting")
        XCTAssertEqual(received?.notification, .permission)
        XCTAssertEqual(received?.sessionId, "session-1")
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
