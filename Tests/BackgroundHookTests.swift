import XCTest
import CopilotProjectsCore
@testable import CopilotProjectsHost

final class BackgroundHookTests: XCTestCase {
    final class Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let tabId = UUID().uuidString
        let ownerId = UUID().uuidString.lowercased()
        let childId = UUID().uuidString.lowercased()

        var sessions: URL { root.appendingPathComponent("sessions") }
        var capture: URL { root.appendingPathComponent("calls.txt") }
        var hook: URL { root.appendingPathComponent("hook.sh") }

        init() throws {
            let fm = FileManager.default
            for directory in ["sessions", "bin", ".local/bin", "tmp"] {
                try fm.createDirectory(
                    at: root.appendingPathComponent(directory),
                    withIntermediateDirectories: true)
            }
            try CopilotHooks.script.write(to: hook, atomically: true, encoding: .utf8)
            try executable(".local/bin/copilot-projects", """
            #!/bin/sh
            [ "$1" = "resolve-session" ] || exit 1
            printf '%s\\n' "$COPILOT_PROJECTS_SESSION"
            """)
            try executable("bin/copilot-projects", """
            #!/bin/sh
            printf '%s\\n' "$*" >> "$CAPTURE_FILE"
            """)
            try Data().write(to: capture)
            try ownerId.write(
                to: file("copilot-session"), atomically: true, encoding: .utf8)
        }

        func file(_ suffix: String) -> URL {
            sessions.appendingPathComponent("\(tabId).\(suffix)")
        }

        func executable(_ name: String, _ contents: String) throws {
            let url = root.appendingPathComponent(name)
            try contents.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: url.path)
        }

        func run(_ action: String, payload: String) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [hook.path, action]
            process.environment = [
                "HOME": root.path,
                "CFFIXED_USER_HOME": root.path,
                "TMPDIR": root.appendingPathComponent("tmp").path,
                "PATH": "\(root.appendingPathComponent("bin").path):/usr/bin:/bin",
                "COPILOT_PROJECTS_SESSION": tabId,
                "COPILOT_PROJECTS_SOCKET": root.appendingPathComponent("control.sock").path,
                "CAPTURE_FILE": capture.path,
            ]
            let input = Pipe()
            let output = Pipe()
            let errors = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = errors
            try process.run()
            input.fileHandleForWriting.write(Data(payload.utf8))
            try input.fileHandleForWriting.close()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            XCTAssertEqual(
                String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
                "{}\n")
            XCTAssertEqual(
                String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
                "")
        }

        func statusRecord() throws -> SessionStatusRecord {
            try JSONDecoder().decode(
                SessionStatusRecord.self, from: Data(contentsOf: file("status-record.json")))
        }

        func markerContents() throws -> [String: Data] {
            let files = try FileManager.default.contentsOfDirectory(
                at: sessions, includingPropertiesForKeys: nil)
            return try Dictionary(uniqueKeysWithValues: files.map {
                ($0.lastPathComponent, try Data(contentsOf: $0))
            })
        }
    }

    func testChildActivityHooksDoNotChangeForegroundStateOrClocks() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        for status in ["idle", "running", "waiting"] {
            try fixture.run("running", payload:
                #"{"sessionId":"\#(fixture.ownerId)","timestamp":100}"#)
            let record = SessionStatusRecord(
                status: try XCTUnwrap(SessionStatus(rawValue: status)),
                statusTimestamp: 100, promptStatusTimestamp: 90)
            try JSONEncoder().encode(record).write(to: fixture.file("status-record.json"))
            let before = try fixture.markerContents()
            let calls = try Data(contentsOf: fixture.capture)
            for action in ["running", "pre", "post"] {
                let fields = action == "running"
                    ? #","prompt":"background child task""#
                    : #","toolCalls":[{"name":"read_bash","result":null}]"#
                for timestamp in ["", ",\"timestamp\":200"] {
                    try fixture.run(action, payload:
                        #"{"sessionId":"\#(fixture.childId)"\#(timestamp)\#(fields)}"#)
                    XCTAssertEqual(try fixture.markerContents(), before, "\(status), \(action)")
                    XCTAssertEqual(try Data(contentsOf: fixture.capture), calls)
                }
            }
        }
    }

    func testChildActivityHooksCannotInvalidateBackgroundPromptEvidence() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.run("running", payload:
            #"{"sessionId":"\#(fixture.ownerId)","timestamp":100}"#)
        try fixture.run("running", payload:
            #"{"sessionId":"\#(fixture.childId)","timestamp":300,"prompt":"background child task"}"#)
        try fixture.run("pre", payload:
            #"{"sessionId":"\#(fixture.childId)","timestamp":300}"#)
        let record = try JSONDecoder().decode(
            SessionStatusRecord.self,
            from: Data(contentsOf: fixture.file("status-record.json")))
        let snapshot = AgentActivitySnapshot(
            schemaVersion: 1,
            updatedAt: "1970-01-01T00:00:00.400Z",
            foregroundTurnActive: false,
            foregroundTransitionAt: "1970-01-01T00:00:00.200Z",
            scheduledTurnActive: false,
            activeSubagents: [],
            schedules: [],
            idleGeneration: 0,
            lastIdleAborted: false,
            lastIdleTurnKind: nil,
            error: nil,
            copilotSessionId: fixture.ownerId)
        let backgroundOnly = AppModel.backgroundOnlyPromptEvidence(
            status: record.status,
            snapshot: snapshot,
            backgroundAgentsActive: true,
            now: Date(timeIntervalSince1970: 0.4),
            nowMs: 400,
            clockMs: record.promptStatusTimestamp)
        XCTAssertTrue(backgroundOnly)
        XCTAssertEqual(AppModel.remotePromptEligibility(
            status: record.status, hasLiveAgent: true,
            backgroundOnly: backgroundOnly, footerActivity: .idle), .sent)

        try fixture.run("pre", payload:
            #"{"sessionId":"\#(fixture.ownerId)","timestamp":300}"#)
        let foregroundRecord = try JSONDecoder().decode(
            SessionStatusRecord.self,
            from: Data(contentsOf: fixture.file("status-record.json")))
        XCTAssertFalse(AppModel.backgroundOnlyPromptEvidence(
            status: foregroundRecord.status, snapshot: snapshot,
            backgroundAgentsActive: true,
            now: Date(timeIntervalSince1970: 0.4), nowMs: 400,
            clockMs: foregroundRecord.promptStatusTimestamp))
    }

    func testChildPromptDoesNotBlockAnIdleForeground() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.run("running", payload:
            #"{"sessionId":"\#(fixture.ownerId)","timestamp":100}"#)
        try fixture.run("idle", payload:
            #"{"sessionId":"\#(fixture.ownerId)","timestamp":200}"#)
        let before = try fixture.markerContents()
        let calls = try Data(contentsOf: fixture.capture)

        try fixture.run("running", payload:
            #"{"sessionId":"\#(fixture.childId)","timestamp":300,"prompt":"background child task"}"#)

        XCTAssertEqual(try fixture.markerContents(), before)
        XCTAssertEqual(try Data(contentsOf: fixture.capture), calls)
        let record = try JSONDecoder().decode(
            SessionStatusRecord.self,
            from: Data(contentsOf: fixture.file("status-record.json")))
        XCTAssertEqual(record.status, .idle)
        XCTAssertEqual(record.promptStatusTimestamp, 200)
        XCTAssertEqual(AppModel.remotePromptEligibility(
            status: record.status, hasLiveAgent: true, footerActivity: .idle), .sent)
    }

    func testOwnerActivityHooksStillAdvanceForegroundClock() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        for (index, action) in ["running", "pre", "post"].enumerated() {
            let timestamp = Int64(300 + index)
            try fixture.run(action, payload:
                #"{"sessionId":"\#(fixture.ownerId.uppercased())","timestamp":\#(timestamp),"prompt":"foreground prompt","toolCalls":[{"result":null}]}"#)
            let record = try JSONDecoder().decode(
                SessionStatusRecord.self,
                from: Data(contentsOf: fixture.file("status-record.json")))
            XCTAssertEqual(record.status, .running)
            XCTAssertEqual(record.promptStatusTimestamp, timestamp)
        }
        try fixture.run("pre", payload:
            #"{"sessionId":"\#(fixture.ownerId)","toolCalls":[{"name":"read_bash","result":null}]}"#)
        XCTAssertEqual(
            try String(contentsOf: fixture.capture).split(separator: "\n").last,
            "set-status running --session \(fixture.tabId)")
    }

    func testOwnerScheduledPromptStillUsesBackgroundStatus() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.run("running", payload:
            #"{"sessionId":"\#(fixture.ownerId)","timestamp":100,"prompt":"[Scheduled prompt #2] check"}"#)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fixture.file("scheduled-turn").path))
        XCTAssertEqual(
            try String(contentsOf: fixture.capture).split(separator: "\n").last,
            "set-status idle --session \(fixture.tabId) --timestamp 100 --source scheduled-start")
        for (index, action) in ["pre", "post"].enumerated() {
            let timestamp = Int64(200 + index)
            try fixture.run(action, payload:
                #"{"sessionId":"\#(fixture.ownerId)","timestamp":\#(timestamp)}"#)
            let record = try JSONDecoder().decode(
                SessionStatusRecord.self,
                from: Data(contentsOf: fixture.file("status-record.json")))
            XCTAssertEqual(record.status, .idle)
            XCTAssertEqual(record.statusTimestamp, timestamp)
            XCTAssertEqual(record.promptStatusTimestamp, 100)
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: fixture.file("active-turn").path))
        }
    }

    func testChildActivityHooksLeaveScheduledAndCompletionMarkersUntouched() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        for suffix in ["scheduled-turn", "background-agents", "active-turn"] {
            try Data("preserve".utf8).write(to: fixture.file(suffix))
        }
        let before = try fixture.markerContents()
        for prompt in ["background child task", "[Scheduled prompt #1] background child task"] {
            try fixture.run("running", payload:
                #"{"sessionId":"\#(fixture.childId)","timestamp":500,"prompt":"\#(prompt)"}"#)
            XCTAssertEqual(try fixture.markerContents(), before)
        }
        for action in ["pre", "post"] {
            try fixture.run(action, payload:
                #"{"sessionId":"\#(fixture.childId)","timestamp":500}"#)
            XCTAssertEqual(try fixture.markerContents(), before)
        }
        XCTAssertEqual(try Data(contentsOf: fixture.capture), Data())
    }

    func testChildToolCompletionCannotClearPermissionWait() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.run("notify", payload:
            #"{"sessionId":"\#(fixture.childId)","timestamp":300,"notification_type":"permission_prompt"}"#)
        try fixture.run("post", payload:
            #"{"sessionId":"\#(fixture.childId)","timestamp":400}"#)
        let record = try JSONDecoder().decode(
            SessionStatusRecord.self,
            from: Data(contentsOf: fixture.file("status-record.json")))
        XCTAssertEqual(record.status, .waiting)
        XCTAssertEqual(record.promptStatusTimestamp, 300)
        XCTAssertEqual(AppModel.remotePromptEligibility(
            status: record.status, hasLiveAgent: true,
            backgroundOnly: true, footerActivity: .idle), .busy)

        try fixture.run("post", payload:
            #"{"sessionId":"\#(fixture.ownerId)","timestamp":500}"#)
        XCTAssertEqual(try fixture.statusRecord().status, .running)
        try fixture.run("idle", payload:
            #"{"sessionId":"\#(fixture.ownerId)","timestamp":600}"#)
        XCTAssertEqual(try fixture.statusRecord().status, .idle)
    }

    func testMissingOrInvalidIdentityKeepsLegacyActivityStatus() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let identities = [
            "",
            #","sessionId":"invalid""#,
            #","toolArgs":{"sessionId":"\#(fixture.childId)"}"#,
            #","toolArgs":{"sessionId":"\#(fixture.childId)"},"sessionId":"\#(fixture.ownerId)""#,
        ]
        var timestamp: Int64 = 300
        for identity in identities {
            for action in ["running", "pre", "post"] {
                timestamp += 1
                try fixture.run(action, payload:
                    #"{"timestamp":\#(timestamp)\#(identity)}"#)
                let record = try JSONDecoder().decode(
                    SessionStatusRecord.self,
                    from: Data(contentsOf: fixture.file("status-record.json")))
                XCTAssertEqual(record.status, .running)
                XCTAssertEqual(record.promptStatusTimestamp, timestamp)
            }
        }
        for marker in ["", "not-a-session", String(repeating: "-", count: 36)] {
            try Data(marker.utf8).write(to: fixture.file("copilot-session"))
            for action in ["running", "pre", "post"] {
                timestamp += 1
                try fixture.run(action, payload:
                    #"{"sessionId":"\#(fixture.childId)","timestamp":\#(timestamp)}"#)
                let record = try JSONDecoder().decode(
                    SessionStatusRecord.self,
                    from: Data(contentsOf: fixture.file("status-record.json")))
                XCTAssertEqual(record.promptStatusTimestamp, timestamp)
            }
        }
    }

    func testOwnerRotationDoesNotFilterSessionStartOrNewOwnerActivity() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let nextOwner = UUID().uuidString.lowercased()
        try fixture.run("start", payload:
            #"{"sessionId":"\#(nextOwner)","timestamp":300}"#)
        XCTAssertEqual(try fixture.statusRecord().status, .idle)
        let beforeRotation = try fixture.markerContents()
        for action in ["running", "pre"] {
            try fixture.run(action, payload:
                #"{"sessionId":"\#(nextOwner)","timestamp":350,"prompt":"new foreground prompt"}"#)
            XCTAssertEqual(try fixture.markerContents(), beforeRotation)
        }
        try Data("  \(nextOwner.uppercased()) \n".utf8)
            .write(to: fixture.file("copilot-session"))
        for (index, action) in ["running", "pre"].enumerated() {
            let timestamp = Int64(400 + index)
            try fixture.run(action, payload:
                #"{"sessionId":"\#(nextOwner)","timestamp":\#(timestamp),"prompt":"new foreground prompt"}"#)
            let record = try JSONDecoder().decode(
                SessionStatusRecord.self,
                from: Data(contentsOf: fixture.file("status-record.json")))
            XCTAssertEqual(record.status, .running)
            XCTAssertEqual(record.promptStatusTimestamp, timestamp)
        }
    }

    func testRootIdleClearsPreviouslyPoisonedStatusWithoutClockRollback() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let poisoned = SessionStatusRecord(
            status: .running, statusTimestamp: 300, promptStatusTimestamp: 300)
        try JSONEncoder().encode(poisoned).write(to: fixture.file("status-record.json"))

        try fixture.run("post", payload:
            #"{"sessionId":"\#(fixture.childId)","timestamp":400}"#)
        XCTAssertEqual(try JSONDecoder().decode(
            SessionStatusRecord.self,
            from: Data(contentsOf: fixture.file("status-record.json"))), poisoned)

        try fixture.run("idle", payload:
            #"{"sessionId":"\#(fixture.ownerId)","timestamp":500}"#)
        let settled = try JSONDecoder().decode(
            SessionStatusRecord.self,
            from: Data(contentsOf: fixture.file("status-record.json")))
        XCTAssertEqual(settled.status, .idle)
        XCTAssertEqual(settled.promptStatusTimestamp, 500)
        XCTAssertEqual(AppModel.remotePromptEligibility(
            status: settled.status, hasLiveAgent: true, footerActivity: .idle), .sent)
    }

    func testChildLifecycleHooksPreserveForegroundStateAndMarkers() throws {
        for status in ["idle", "running", "waiting"] {
            let fixture = try Fixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            try fixture.run("running", payload:
                #"{"sessionId":"\#(fixture.ownerId)","timestamp":100}"#)
            let record = SessionStatusRecord(
                status: try XCTUnwrap(SessionStatus(rawValue: status)),
                statusTimestamp: 100, promptStatusTimestamp: 90)
            try JSONEncoder().encode(record).write(to: fixture.file("status-record.json"))
            for suffix in ["background-agents", "active-turn", "scheduled-turn"] {
                try Data("preserve".utf8).write(to: fixture.file(suffix))
            }
            let before = try fixture.markerContents()
            let calls = try Data(contentsOf: fixture.capture)
            for action in ["idle", "end"] {
                try fixture.run(action, payload:
                    #"{"sessionId":"\#(fixture.childId)","timestamp":300}"#)
                XCTAssertEqual(try fixture.markerContents(), before, "\(status), \(action)")
                XCTAssertEqual(try Data(contentsOf: fixture.capture), calls)
            }
        }
    }

    func testNotificationDialectsBothPreserveSharedPermissionWaits() throws {
        for key in ["notificationType", "notification_type"] {
            for (kind, notification) in [
                ("permission_prompt", "permission"),
                ("elicitation_dialog", "elicitation"),
            ] {
                let fixture = try Fixture()
                defer { try? FileManager.default.removeItem(at: fixture.root) }
                try fixture.run("running", payload:
                    #"{"sessionId":"\#(fixture.ownerId)","timestamp":100}"#)
                try fixture.run("notify", payload:
                    #"{"sessionId":"\#(fixture.childId)","timestamp":200,"\#(key)":"\#(kind)"}"#)
                let record = try JSONDecoder().decode(
                    SessionStatusRecord.self,
                    from: Data(contentsOf: fixture.file("status-record.json")))
                XCTAssertEqual(record.status, .waiting)
                XCTAssertEqual(record.promptStatusTimestamp, 200)
                XCTAssertEqual(
                    try String(contentsOf: fixture.capture).split(separator: "\n").last,
                    "set-status waiting --session \(fixture.tabId) --timestamp 200 --notification \(notification) --copilot-session \(fixture.childId)")
            }
        }
    }

    func testChildIdleNotificationIsNotForegroundIdle() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.run("running", payload:
            #"{"sessionId":"\#(fixture.ownerId)","timestamp":100}"#)
        let before = try fixture.markerContents()
        let calls = try Data(contentsOf: fixture.capture)
        for fields in [
            #""notificationType":"agent_idle""#,
            #""notificationType":"agent_idle","notification_type":"permission_prompt""#,
            #""notificationType":{},"notification_type":"permission_prompt""#,
            #""message":{"notificationType":"permission_prompt"}"#,
        ] {
            try fixture.run("notify", payload:
                #"{"sessionId":"\#(fixture.ownerId)","timestamp":200,\#(fields)}"#)
            XCTAssertEqual(try fixture.markerContents(), before)
            XCTAssertEqual(try Data(contentsOf: fixture.capture), calls)
        }
    }

    func testChildStopDoesNotConsumeAnActiveForegroundTurn() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.run("running", payload:
            #"{"sessionId":"\#(fixture.ownerId)","timestamp":100}"#)
        let before = try fixture.markerContents()
        let calls = try Data(contentsOf: fixture.capture)
        try fixture.run("idle", payload:
            #"{"sessionId":"\#(fixture.childId)","timestamp":300}"#)
        XCTAssertEqual(try fixture.markerContents(), before)
        XCTAssertEqual(try Data(contentsOf: fixture.capture), calls)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.file("active-turn").path))
    }

    func testWaitContextBindsSenderAndConversationAtomically() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let epoch = "\(UUID().uuidString.lowercased()):2"
        try Data(#"{"copilotSessionId":"\#(fixture.ownerId)","conversationEpoch":"\#(epoch)"}"#.utf8)
            .write(to: fixture.file("agent-activity.json"))
        try fixture.run("notify", payload:
            #"{"sessionId":"\#(fixture.childId)","timestamp":200,"notificationType":"permission_prompt"}"#)
        let record = try JSONDecoder().decode(
            SessionStatusRecord.self,
            from: Data(contentsOf: fixture.file("status-record.json")))
        XCTAssertEqual(record.inputWait, InputWaitContext(
            senderSessionId: fixture.childId,
            rootSessionId: fixture.ownerId,
            conversationEpoch: epoch))
    }

    func testNestedTimestampAndIdentityAreNotStatusAuthority() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.run("running", payload:
            #"{"sessionId":"\#(fixture.ownerId)","timestamp":100}"#)
        try fixture.run("pre", payload:
            #"{"toolArgs":{"timestamp":999999,"sessionId":"\#(fixture.childId)"},"sessionId":"\#(fixture.ownerId)"}"#)
        let record = try JSONDecoder().decode(
            SessionStatusRecord.self,
            from: Data(contentsOf: fixture.file("status-record.json")))
        XCTAssertEqual(record.statusTimestamp, 100)
        XCTAssertEqual(
            try String(contentsOf: fixture.capture).split(separator: "\n").last,
            "set-status running --session \(fixture.tabId)")
    }

    func testNonIntegerTimestampsDoNotAdvanceClocks() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.run("running", payload:
            #"{"sessionId":"\#(fixture.ownerId)","timestamp":100}"#)
        for timestamp in ["123.5", "-1", #""999""#] {
            try fixture.run("pre", payload:
                #"{"sessionId":"\#(fixture.ownerId)","timestamp":\#(timestamp)}"#)
            let record = try JSONDecoder().decode(
                SessionStatusRecord.self,
                from: Data(contentsOf: fixture.file("status-record.json")))
            XCTAssertEqual(record.statusTimestamp, 100)
        }
    }

    func testSessionCleanupRemovesEveryFileAnInterruptedTurnLeaves() throws {
        let fixture = try Fixture()
        let previous = ProcessInfo.processInfo.environment["COPILOT_PROJECTS_STATE_DIR"]
        setenv("COPILOT_PROJECTS_STATE_DIR", fixture.root.path, 1)
        defer {
            if let previous { setenv("COPILOT_PROJECTS_STATE_DIR", previous, 1) }
            else { unsetenv("COPILOT_PROJECTS_STATE_DIR") }
            try? FileManager.default.removeItem(at: fixture.root)
        }
        try fixture.run("running", payload:
            #"{"sessionId":"\#(fixture.ownerId)","timestamp":100}"#)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.file("active-turn").path))
        // A hook killed between writing its record and renaming it into place.
        try Data("{}".utf8).write(to: fixture.file("status-record.json.4242"))
        let other = fixture.sessions.appendingPathComponent("\(UUID().uuidString).active-turn")
        try Data().write(to: other)

        SessionArtifacts.removeFiles(sessionId: fixture.tabId)

        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: fixture.sessions.path),
            [other.lastPathComponent])
    }

    private func spawnSleepProcess() throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["60"]
        try process.run()
        return process
    }

    private func currentKernelBootTime() throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/sysctl")
        process.arguments = ["-n", "kern.boottime"]
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        return String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func testOtherLiveOwnerProcessBlocksNestedStartAndPermissionNotifications() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.run("running", payload:
            #"{"sessionId":"\#(fixture.ownerId)","timestamp":100}"#)

        let ownerCLI = try spawnSleepProcess()
        let ownerTracker = try spawnSleepProcess()
        defer {
            ownerCLI.terminate()
            ownerTracker.terminate()
        }
        // kern.boottime's usec moves within one boot, so the owner's reading can
        // differ from the hook's.
        let bootTime = try currentKernelBootTime().replacingOccurrences(
            of: #"usec = \d+"#, with: "usec = 1", options: .regularExpression
        )
        let ownerJSON = """
        {"appSessionId":"\(fixture.tabId)","copilotSessionId":"\(fixture.ownerId)","pid":\(ownerTracker.processIdentifier),"bootTime":"\(bootTime)","parentPid":\(ownerCLI.processIdentifier),"claimedAt":100}
        """
        try Data(ownerJSON.utf8).write(to: fixture.file("transcript-owner.json"))

        let before = try fixture.markerContents()
        let calls = try Data(contentsOf: fixture.capture)
        for (action, payload) in [
            ("start", #"{"sessionId":"\#(fixture.childId)","timestamp":200}"#),
            ("running", #"{"sessionId":"\#(fixture.childId)","timestamp":201,"prompt":"autofind review"}"#),
            ("pre", #"{"sessionId":"\#(fixture.childId)","timestamp":202}"#),
            ("notify", #"{"sessionId":"\#(fixture.childId)","timestamp":203,"notificationType":"permission_prompt"}"#),
            ("notify", #"{"sessionId":"\#(fixture.childId)","timestamp":204,"notificationType":"elicitation_dialog"}"#),
            ("post", #"{"sessionId":"\#(fixture.childId)","timestamp":205}"#),
            ("idle", #"{"sessionId":"\#(fixture.childId)","timestamp":206}"#),
            ("end", #"{"sessionId":"\#(fixture.childId)","timestamp":207}"#),
        ] {
            try fixture.run(action, payload: payload)
            XCTAssertEqual(try fixture.markerContents(), before, action)
            XCTAssertEqual(try Data(contentsOf: fixture.capture), calls, action)
        }

        // Even when the tracker PID has exited or restarted while `parentPid` remains
        // alive on the same boot, nested start and permission notifications stay blocked.
        ownerTracker.terminate()
        ownerTracker.waitUntilExit()
        for (action, payload) in [
            ("start", #"{"sessionId":"\#(fixture.childId)","timestamp":208}"#),
            ("notify", #"{"sessionId":"\#(fixture.childId)","timestamp":209,"notificationType":"permission_prompt"}"#),
            ("notify", #"{"sessionId":"\#(fixture.childId)","timestamp":210,"notificationType":"elicitation_dialog"}"#),
        ] {
            try fixture.run(action, payload: payload)
            XCTAssertEqual(try fixture.markerContents(), before, "dead-tracker \(action)")
            XCTAssertEqual(try Data(contentsOf: fixture.capture), calls, "dead-tracker \(action)")
        }

        // Even when the nested non-wrapper process (`xctest`, standing in for `exec copilot -p`)
        // is a direct child of `parentPid` (`getppid()`), it is still blocked.
        let parentOfThisProcess = getppid()
        if parentOfThisProcess > 1 && Darwin.kill(parentOfThisProcess, 0) == 0 {
            let directChildOwnerJSON = """
            {"appSessionId":"\(fixture.tabId)","copilotSessionId":"\(fixture.ownerId)","pid":\(ownerTracker.processIdentifier),"bootTime":"\(bootTime)","parentPid":\(parentOfThisProcess),"claimedAt":100}
            """
            try Data(directChildOwnerJSON.utf8).write(to: fixture.file("transcript-owner.json"))
            let directBefore = try fixture.markerContents()
            for (action, payload) in [
                ("start", #"{"sessionId":"\#(fixture.childId)","timestamp":211}"#),
                ("notify", #"{"sessionId":"\#(fixture.childId)","timestamp":212,"notificationType":"permission_prompt"}"#),
            ] {
                try fixture.run(action, payload: payload)
                XCTAssertEqual(try fixture.markerContents(), directBefore, "direct-child \(action)")
                XCTAssertEqual(try Data(contentsOf: fixture.capture), calls, "direct-child \(action)")
            }
        }
        let record = try fixture.statusRecord()
        XCTAssertEqual(record.status, .running)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.file("active-turn").path))
    }

    func testRecordedOwnerProcessAllowsDirectAndWrappedSubagentNotificationsAndRotation() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let ownerTracker = try spawnSleepProcess()
        defer { ownerTracker.terminate() }
        let bootTime = try currentKernelBootTime()
        let thisPID = ProcessInfo.processInfo.processIdentifier
        let ownerJSON = """
        {"appSessionId":"\(fixture.tabId)","copilotSessionId":"\(fixture.ownerId)","pid":\(ownerTracker.processIdentifier),"bootTime":"\(bootTime)","parentPid":\(thisPID),"claimedAt":100}
        """
        try Data(ownerJSON.utf8).write(to: fixture.file("transcript-owner.json"))

        try fixture.run("running", payload:
            #"{"sessionId":"\#(fixture.ownerId)","timestamp":100}"#)
        XCTAssertEqual(try fixture.statusRecord().status, .running)

        // Wrap through `/bin/sh -c` (with `&& :` so `/bin/sh` cannot `exec` the child)
        // to exercise the shell-wrapper ancestor walk.
        let wrapped = Process()
        wrapped.executableURL = URL(fileURLWithPath: "/bin/sh")
        wrapped.arguments = ["-c", "/bin/bash \"\(fixture.hook.path)\" notify && :"]
        wrapped.environment = [
            "HOME": fixture.root.path,
            "CFFIXED_USER_HOME": fixture.root.path,
            "TMPDIR": fixture.root.appendingPathComponent("tmp").path,
            "PATH": "\(fixture.root.appendingPathComponent("bin").path):/usr/bin:/bin",
            "COPILOT_PROJECTS_SESSION": fixture.tabId,
            "COPILOT_PROJECTS_SOCKET": fixture.root.appendingPathComponent("control.sock").path,
            "CAPTURE_FILE": fixture.capture.path,
        ]
        let input = Pipe()
        wrapped.standardInput = input
        wrapped.standardOutput = Pipe()
        wrapped.standardError = Pipe()
        try wrapped.run()
        input.fileHandleForWriting.write(
            Data(#"{"sessionId":"\#(fixture.childId)","timestamp":200,"notificationType":"permission_prompt"}"#.utf8)
        )
        try input.fileHandleForWriting.close()
        wrapped.waitUntilExit()
        XCTAssertEqual(wrapped.terminationStatus, 0)
        XCTAssertEqual(try fixture.statusRecord().status, .waiting)

        // `/new` inside the same owner process still resets status to idle.
        let nextOwner = UUID().uuidString.lowercased()
        try fixture.run("start", payload:
            #"{"sessionId":"\#(nextOwner)","timestamp":300}"#)
        XCTAssertEqual(try fixture.statusRecord().status, .idle)
    }

    func testDeadOrStaleBootOwnerProcessDoesNotBlockNewSession() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let ownerCLI = try spawnSleepProcess()
        let ownerTracker = try spawnSleepProcess()
        defer {
            ownerCLI.terminate()
            ownerTracker.terminate()
        }

        // Mismatched bootTime is treated as a stale owner from a previous boot.
        let staleBootJSON = """
        {"appSessionId":"\(fixture.tabId)","copilotSessionId":"\(fixture.ownerId)","pid":\(ownerTracker.processIdentifier),"bootTime":"{ sec = 1, usec = 0 }","parentPid":\(ownerCLI.processIdentifier),"claimedAt":100}
        """
        try Data(staleBootJSON.utf8).write(to: fixture.file("transcript-owner.json"))
        try fixture.run("notify", payload:
            #"{"sessionId":"\#(fixture.childId)","timestamp":200,"notificationType":"permission_prompt"}"#)
        XCTAssertEqual(try fixture.statusRecord().status, .waiting)

        // Mismatched appSessionId is treated as a foreign owner record and does not block.
        let bootTime = try currentKernelBootTime()
        let mismatchedSessionJSON = """
        {"appSessionId":"\(UUID().uuidString)","copilotSessionId":"\(fixture.ownerId)","pid":\(ownerTracker.processIdentifier),"bootTime":"\(bootTime)","parentPid":\(ownerCLI.processIdentifier),"claimedAt":100}
        """
        try Data(mismatchedSessionJSON.utf8).write(to: fixture.file("transcript-owner.json"))
        try fixture.run("start", payload:
            #"{"sessionId":"\#(fixture.childId)","timestamp":250}"#)
        XCTAssertEqual(try fixture.statusRecord().status, .idle)

        // Dead owner PIDs also fall back to allowing hooks.
        ownerCLI.terminate()
        ownerCLI.waitUntilExit()
        let deadOwnerJSON = """
        {"appSessionId":"\(fixture.tabId)","copilotSessionId":"\(fixture.ownerId)","pid":\(ownerTracker.processIdentifier),"bootTime":"\(bootTime)","parentPid":\(ownerCLI.processIdentifier),"claimedAt":100}
        """
        try Data(deadOwnerJSON.utf8).write(to: fixture.file("transcript-owner.json"))
        try fixture.run("notify", payload:
            #"{"sessionId":"\#(fixture.childId)","timestamp":300,"notificationType":"permission_prompt"}"#)
        XCTAssertEqual(try fixture.statusRecord().status, .waiting)
    }
}
