import XCTest
@testable import copilot_projects
import CopilotProjectsCore
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

    func testStatusEventClockRejectsLateHookEvents() {
        let sessionId = UUID().uuidString
        var clock = StatusEventClock()
        XCTAssertTrue(clock.shouldApply(sessionId: sessionId, timestamp: 200))
        XCTAssertFalse(clock.shouldApply(sessionId: sessionId, timestamp: 100))
        XCTAssertTrue(clock.shouldApply(sessionId: sessionId, timestamp: 300))
        XCTAssertTrue(clock.shouldApply(sessionId: sessionId, timestamp: nil))
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

    func testCopilotHookNotifiesNtfyForWaitingAndCompletedTurns() throws {
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

        let notifierCapture = root.appendingPathComponent("notifier-args.txt")
        let notifier = root.appendingPathComponent("ntfy-notifier")
        try """
        #!/bin/sh
        printf '%s\n' "$*" >> "$NOTIFIER_CAPTURE"
        """.write(to: notifier, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: notifier.path)

        let tabId = UUID().uuidString
        try runHook(
            hookURL: hookURL,
            action: "start",
            payload: #"{"timestamp":100}"#,
            tabId: tabId,
            root: root,
            bin: bin,
            capture: capture,
            notifier: notifier,
            notifierCapture: notifierCapture
        )
        try runHook(
            hookURL: hookURL,
            action: "notify",
            payload: #"{"timestamp":110,"notification_type":"session_idle","aborted":false}"#,
            tabId: tabId,
            root: root,
            bin: bin,
            capture: capture,
            notifier: notifier,
            notifierCapture: notifierCapture
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: notifierCapture.path))

        try runHook(
            hookURL: hookURL,
            action: "notify",
            payload: #"{"timestamp":120,"notification_type":"elicitation_dialog"}"#,
            tabId: tabId,
            root: root,
            bin: bin,
            capture: capture,
            notifier: notifier,
            notifierCapture: notifierCapture
        )
        XCTAssertTrue(waitForFile(notifierCapture, toContain: "waiting \(tabId)"))

        try runHook(
            hookURL: hookURL,
            action: "running",
            payload: #"{"timestamp":130}"#,
            tabId: tabId,
            root: root,
            bin: bin,
            capture: capture,
            notifier: notifier,
            notifierCapture: notifierCapture
        )
        try runHook(
            hookURL: hookURL,
            action: "idle",
            payload: #"{"timestamp":135}"#,
            tabId: tabId,
            root: root,
            bin: bin,
            capture: capture,
            notifier: notifier,
            notifierCapture: notifierCapture
        )
        try runHook(
            hookURL: hookURL,
            action: "notify",
            payload: #"{"timestamp":140,"notification_type":"session_idle","aborted":false}"#,
            tabId: tabId,
            root: root,
            bin: bin,
            capture: capture,
            notifier: notifier,
            notifierCapture: notifierCapture
        )
        XCTAssertTrue(waitForFile(notifierCapture, toContain: "completed \(tabId)"))

        let beforeAbort = try String(contentsOf: notifierCapture, encoding: .utf8)
        try runHook(
            hookURL: hookURL,
            action: "running",
            payload: #"{"timestamp":150}"#,
            tabId: tabId,
            root: root,
            bin: bin,
            capture: capture,
            notifier: notifier,
            notifierCapture: notifierCapture
        )
        try runHook(
            hookURL: hookURL,
            action: "notify",
            payload: #"{"timestamp":160,"notification_type":"session_idle","unaborted":true,"aborted":true}"#,
            tabId: tabId,
            root: root,
            bin: bin,
            capture: capture,
            notifier: notifier,
            notifierCapture: notifierCapture
        )
        usleep(100_000)
        XCTAssertEqual(try String(contentsOf: notifierCapture, encoding: .utf8), beforeAbort)
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
            diagnostics: { "" }
        ))
        XCTAssertFalse(router.handle(ControlRequest(command: "set-status")).ok)
        XCTAssertFalse(didSetStatus)
        XCTAssertFalse(router.handle(ControlRequest(command: "unknown")).ok)
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
        capture: URL,
        notifier: URL? = nil,
        notifierCapture: URL? = nil
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [hookURL.path, action]
        var environment = ProcessInfo.processInfo.environment
        environment["COPILOT_PROJECTS_SESSION"] = tabId
        environment["COPILOT_PROJECTS_SOCKET"] = root.appendingPathComponent("control.sock").path
        environment["CAPTURE_FILE"] = capture.path
        if let notifier {
            environment["COPILOT_PROJECTS_NTFY_NOTIFIER"] = notifier.path
        }
        if let notifierCapture {
            environment["NOTIFIER_CAPTURE"] = notifierCapture.path
        }
        environment["PATH"] = "\(bin.path):/usr/bin:/bin"
        process.environment = environment
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        input.fileHandleForWriting.write(Data(payload.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    private func waitForFile(_ url: URL, toContain expected: String) -> Bool {
        let deadline = Date().addingTimeInterval(1)
        repeat {
            if let contents = try? String(contentsOf: url, encoding: .utf8),
               contents.contains(expected)
            {
                return true
            }
            usleep(10_000)
        } while Date() < deadline
        return false
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
