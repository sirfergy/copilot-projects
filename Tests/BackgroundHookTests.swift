import XCTest
import CopilotProjectsCore
@testable import copilot_projects

final class BackgroundHookTests: XCTestCase {
    private final class Fixture {
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

        func markerContents() throws -> [String: Data] {
            let files = try FileManager.default.contentsOfDirectory(
                at: sessions, includingPropertiesForKeys: nil)
            return try Dictionary(uniqueKeysWithValues: files.map {
                ($0.lastPathComponent, try Data(contentsOf: $0))
            })
        }
    }

    func testChildToolHooksDoNotChangeForegroundStateOrClocks() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        for status in ["idle", "running", "waiting"] {
            try fixture.run("running", payload:
                #"{"sessionId":"\#(fixture.ownerId)","timestamp":100}"#)
            let record = SessionStatusRecord(
                status: try XCTUnwrap(SessionStatus(rawValue: status)),
                statusTimestamp: 100, promptStatusTimestamp: 90)
            try JSONEncoder().encode(record).write(to: fixture.file("status-record.json"))
            try Data(status.utf8).write(to: fixture.file("status"))
            let before = try fixture.markerContents()
            let calls = try Data(contentsOf: fixture.capture)
            for action in ["pre", "post"] {
                for timestamp in ["", ",\"timestamp\":200"] {
                    try fixture.run(action, payload:
                        #"{"sessionId":"\#(fixture.childId)"\#(timestamp),"toolCalls":[{"name":"read_bash","result":null}]}"#)
                    XCTAssertEqual(try fixture.markerContents(), before, "\(status), \(action)")
                    XCTAssertEqual(try Data(contentsOf: fixture.capture), calls)
                }
            }
        }
    }

    func testChildToolHooksCannotInvalidateBackgroundPromptEvidence() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.run("running", payload:
            #"{"sessionId":"\#(fixture.ownerId)","timestamp":100}"#)
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

    func testOwnerToolHooksStillAdvanceForegroundClock() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        for action in ["pre", "post"] {
            try fixture.run(action, payload:
                #"{"sessionId":"\#(fixture.ownerId.uppercased())","timestamp":300,"toolCalls":[{"result":null}]}"#)
            let record = try JSONDecoder().decode(
                SessionStatusRecord.self,
                from: Data(contentsOf: fixture.file("status-record.json")))
            XCTAssertEqual(record.status, .running)
            XCTAssertEqual(record.promptStatusTimestamp, 300)
        }
        try Data("idle".utf8).write(to: fixture.file("status"))
        try fixture.run("pre", payload:
            #"{"sessionId":"\#(fixture.ownerId)","toolCalls":[{"name":"read_bash","result":null}]}"#)
        XCTAssertEqual(try String(contentsOf: fixture.file("status")), "running")
        XCTAssertEqual(
            try String(contentsOf: fixture.capture).split(separator: "\n").last,
            "set-status running --session \(fixture.tabId)")
    }

    func testChildToolHooksLeaveScheduledAndCompletionMarkersUntouched() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        for suffix in ["scheduled-turn", "background-agents", "session-idle-hook",
                       "active-turn", "agent-stop-completion"] {
            try Data("preserve".utf8).write(to: fixture.file(suffix))
        }
        let before = try fixture.markerContents()
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
        XCTAssertEqual(try String(contentsOf: fixture.file("status")), "running")
        try fixture.run("notify", payload:
            #"{"sessionId":"\#(fixture.ownerId)","timestamp":600,"notification_type":"session_idle"}"#)
        XCTAssertEqual(try String(contentsOf: fixture.file("status")), "idle")
    }

    func testMissingOrInvalidIdentityKeepsLegacyToolStatus() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let payloads = [
            #"{"timestamp":301}"#,
            #"{"sessionId":"invalid","timestamp":302}"#,
            #"{"timestamp":303,"toolArgs":{"sessionId":"\#(fixture.childId)"}}"#,
            #"{"toolArgs":{"sessionId":"\#(fixture.childId)"},"sessionId":"\#(fixture.ownerId)","timestamp":304}"#,
        ]
        for (index, payload) in payloads.enumerated() {
            try fixture.run("pre", payload: payload)
            let record = try JSONDecoder().decode(
                SessionStatusRecord.self,
                from: Data(contentsOf: fixture.file("status-record.json")))
            XCTAssertEqual(record.status, .running)
            XCTAssertEqual(record.promptStatusTimestamp, Int64(301 + index))
        }
        for (index, marker) in ["", "not-a-session", String(repeating: "-", count: 36)]
            .enumerated() {
            let timestamp = 401 + index
            try Data(marker.utf8).write(to: fixture.file("copilot-session"))
            try fixture.run("post", payload:
                #"{"sessionId":"\#(fixture.childId)","timestamp":\#(timestamp)}"#)
            let record = try JSONDecoder().decode(
                SessionStatusRecord.self,
                from: Data(contentsOf: fixture.file("status-record.json")))
            XCTAssertEqual(record.promptStatusTimestamp, Int64(timestamp))
        }
    }

    func testOwnerRotationDoesNotFilterSessionStartOrNewOwnerTools() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let nextOwner = UUID().uuidString.lowercased()
        try fixture.run("start", payload:
            #"{"sessionId":"\#(nextOwner)","timestamp":300}"#)
        XCTAssertEqual(try String(contentsOf: fixture.file("status")), "idle")
        let beforeRotation = try fixture.markerContents()
        try fixture.run("pre", payload:
            #"{"sessionId":"\#(nextOwner)","timestamp":350}"#)
        XCTAssertEqual(try fixture.markerContents(), beforeRotation)
        try Data("  \(nextOwner.uppercased()) \n".utf8)
            .write(to: fixture.file("copilot-session"))
        try fixture.run("pre", payload:
            #"{"sessionId":"\#(nextOwner)","timestamp":400}"#)
        let record = try JSONDecoder().decode(
            SessionStatusRecord.self,
            from: Data(contentsOf: fixture.file("status-record.json")))
        XCTAssertEqual(record.status, .running)
        XCTAssertEqual(record.promptStatusTimestamp, 400)
    }

    func testRootIdleClearsPreviouslyPoisonedStatusWithoutClockRollback() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let poisoned = SessionStatusRecord(
            status: .running, statusTimestamp: 300, promptStatusTimestamp: 300)
        try JSONEncoder().encode(poisoned).write(to: fixture.file("status-record.json"))
        try Data("running".utf8).write(to: fixture.file("status"))

        try fixture.run("post", payload:
            #"{"sessionId":"\#(fixture.childId)","timestamp":400}"#)
        XCTAssertEqual(try JSONDecoder().decode(
            SessionStatusRecord.self,
            from: Data(contentsOf: fixture.file("status-record.json"))), poisoned)

        try fixture.run("notify", payload:
            #"{"sessionId":"\#(fixture.ownerId)","timestamp":500,"notification_type":"session_idle"}"#)
        let settled = try JSONDecoder().decode(
            SessionStatusRecord.self,
            from: Data(contentsOf: fixture.file("status-record.json")))
        XCTAssertEqual(settled.status, .idle)
        XCTAssertEqual(settled.promptStatusTimestamp, 500)
        XCTAssertEqual(AppModel.remotePromptEligibility(
            status: settled.status, hasLiveAgent: true, footerActivity: .idle), .sent)
    }
}
