import AppKit
import SwiftUI
import XCTest
@testable import CopilotProjectsHost
import CopilotProjectsProtocol

final class RequestFailureTests: XCTestCase {
    private let message = "Execution failed: 400 internal server error (Request ID: 00000-f881)"
    private let failedAt = "2026-10-10T23:38:00.191Z"

    private var trackerError: String {
        #"{"message":"\#(message)","errorType":"query","timestamp":"\#(failedAt)","statusCode":400}"#
    }

    private func failedAtDate() throws -> Date {
        try Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(failedAt)
    }

    private func failedActivity() throws -> AgentActivitySnapshot {
        let heartbeat = #"""
        {"schemaVersion":1,"updatedAt":"\#(failedAt)","foregroundTurnActive":false,
         "scheduledTurnActive":false,"activeSubagents":[],"schedules":[],"idleGeneration":3,
         "lastIdleAborted":false,"lastIdleTurnKind":"foreground","lastTurnError":\#(trackerError)}
        """#
        return try JSONDecoder().decode(AgentActivitySnapshot.self, from: Data(heartbeat.utf8))
    }

    private func transcriptDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        decoder.dateDecodingStrategy = .custom {
            try fractional.parse(try $0.singleValueContainer().decode(String.self))
        }
        return decoder
    }

    func testTranscriptTurnCarriesTheTrackerErrorThroughImageAssociation() throws {
        let json = #"""
        {"id":"turn","startedAt":"2026-10-10T22:00:00.000Z","endedAt":"\#(failedAt)",
         "kind":"foreground","userContent":"record","assistantMessages":[],"tools":[],
         "isAborted":false,"images":[],"error":\#(trackerError)}
        """#
        let turn = try transcriptDecoder().decode(TranscriptTurn.self, from: Data(json.utf8))
        let expected = TranscriptTurnError(
            message: message, errorType: "query", statusCode: 400, timestamp: try failedAtDate()
        )
        XCTAssertEqual(turn.error, expected)

        let associated = TranscriptImageAssociation.attach(
            images: [],
            to: TranscriptSnapshot(
                schemaVersion: 3, updatedAt: Date(), copilotSessionId: "copilot", turns: [turn]
            )
        )
        XCTAssertNil(associated.turns[0].images)
        XCTAssertEqual(associated.turns[0].error, expected)
    }

    func testTurnsWithoutAnErrorStillEncodeWithoutTheKey() throws {
        let turn = TranscriptTurn(
            id: "turn", startedAt: Date(), endedAt: nil, kind: "foreground",
            userContent: "hi", assistantMessages: [], tools: [], isAborted: false
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(turn)) as? [String: Any]
        )
        XCTAssertNil(object["error"])
        let legacy = #"""
        {"id":"turn","startedAt":"2026-10-10T22:00:00.000Z","endedAt":null,"kind":"foreground",
         "userContent":"hi","assistantMessages":[],"tools":[],"isAborted":false}
        """#
        XCTAssertNil(try transcriptDecoder().decode(TranscriptTurn.self, from: Data(legacy.utf8)).error)
    }

    func testHeartbeatFailureDecodesWithoutRejectingTheSnapshot() throws {
        let base = #""schemaVersion":1,"updatedAt":"2026-10-10T23:38:01Z","foregroundTurnActive":false,"#
            + #""scheduledTurnActive":false,"activeSubagents":[],"schedules":[],"idleGeneration":3,"#
            + #""lastIdleAborted":false"#
        let failed = try JSONDecoder().decode(
            AgentActivitySnapshot.self,
            from: Data("{\(base),\"lastTurnError\":\(trackerError)}".utf8)
        )
        XCTAssertEqual(failed.remoteLastError(), TranscriptTurnError(
            message: message, errorType: "query", statusCode: 400, timestamp: try failedAtDate()
        ))

        let partial = try JSONDecoder().decode(
            AgentActivitySnapshot.self,
            from: Data("{\(base),\"lastTurnError\":{\"message\":\"Rate limited\"}}".utf8)
        )
        XCTAssertEqual(partial.remoteLastError()?.message, "Rate limited")
        XCTAssertNil(partial.remoteLastError()?.statusCode)
        XCTAssertEqual(partial.remoteLastError(), partial.remoteLastError(),
                       "repeated projections must compare equal")
        XCTAssertEqual(partial.remoteLastError()?.timestamp, Date(timeIntervalSince1970: 0))

        for blank in [#"{"message":"  "}"#, "{}"] {
            let snapshot = try JSONDecoder().decode(
                AgentActivitySnapshot.self, from: Data("{\(base),\"lastTurnError\":\(blank)}".utf8)
            )
            XCTAssertNil(snapshot.remoteLastError())
        }
        XCTAssertNil(try JSONDecoder().decode(
            AgentActivitySnapshot.self, from: Data("{\(base)}".utf8)
        ).remoteLastError())

        let mistyped = try JSONDecoder().decode(
            AgentActivitySnapshot.self,
            from: Data(("{\(base),\"lastTurnError\":{\"message\":\"Rate limited\","
                + "\"errorType\":7,\"statusCode\":\"429\",\"timestamp\":42}}").utf8)
        )
        XCTAssertEqual(mistyped.remoteLastError(), TranscriptTurnError(
            message: "Rate limited", errorType: nil, statusCode: nil,
            timestamp: Date(timeIntervalSince1970: 0)
        ))
        for malformed in [#""oops""#, "[]", "3", #"{"message":5}"#] {
            let snapshot = try JSONDecoder().decode(
                AgentActivitySnapshot.self,
                from: Data("{\(base),\"lastTurnError\":\(malformed)}".utf8)
            )
            XCTAssertEqual(snapshot.idleGeneration, 3)
            XCTAssertNil(snapshot.remoteLastError())
        }
    }

    func testDisconnectedHeartbeatDoesNotReportItsFrozenFailure() throws {
        let base = #""schemaVersion":1,"updatedAt":"2026-10-10T23:38:01Z","foregroundTurnActive":false,"#
            + #""scheduledTurnActive":false,"activeSubagents":[],"schedules":[],"idleGeneration":3,"#
            + #""lastIdleAborted":false,"lastTurnError":\#(trackerError)"#
        for disconnect in ["Connection is closed.", "Connection is disposed."] {
            let snapshot = try JSONDecoder().decode(
                AgentActivitySnapshot.self,
                from: Data("{\(base),\"error\":\"\(disconnect)\"}".utf8)
            )
            XCTAssertTrue(snapshot.reportsTerminalDisconnect)
            XCTAssertNil(snapshot.remoteLastError())
        }
        let transient = try JSONDecoder().decode(
            AgentActivitySnapshot.self,
            from: Data("{\(base),\"error\":\"rename failed\"}".utf8)
        )
        XCTAssertEqual(transient.remoteLastError()?.message, message)
    }

    @MainActor
    func testIdleSessionReportsItsFailureLocallyAndRemotely() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = Session(title: "voice", cwd: root.path)
        let project = Project(name: "Skills", cwd: root.path, sessions: [session])
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(projects: [project], selectedProjectId: project.id))
        let now = Date()
        let updatedAt = ISO8601DateFormatter().string(from: now)
        let heartbeat = #"""
        {"schemaVersion":1,"updatedAt":"\#(updatedAt)","foregroundTurnActive":false,
         "scheduledTurnActive":false,"activeSubagents":[],"schedules":[],"idleGeneration":3,
         "lastIdleAborted":false,"lastIdleTurnKind":"foreground","lastTurnError":\#(trackerError)}
        """#
        try Data(heartbeat.utf8).write(
            to: root.appendingPathComponent("\(session.id).agent-activity.json")
        )
        let model = AppModel(stateRepository: repository, agentActivityDirectory: root)
        model.refreshAgentActivitySnapshots(now: now)

        let expected = TranscriptTurnError(
            message: message, errorType: "query", statusCode: 400, timestamp: try failedAtDate()
        )
        let local = model.projects[0].sessions[0]
        XCTAssertEqual(local.failedRequest, expected)
        XCTAssertEqual(local.attentionLabel, "Request failed")
        XCTAssertEqual(model.projects[0].failedCount, 1)
        XCTAssertEqual(model.remoteWorkspaceSnapshot().projects[0].sessions[0].lastError, expected)

        var running = local
        running.status = .running
        XCTAssertNil(running.failedRequest)
        XCTAssertEqual(running.attentionLabel, "Running")
        model.setStatus(.running, sessionId: session.id)
        XCTAssertEqual(model.projects[0].sessions[0].status, .running)
        XCTAssertEqual(model.projects[0].failedCount, 0)
        XCTAssertNil(model.remoteWorkspaceSnapshot().projects[0].sessions[0].lastError)
    }

    func testProjectRowCountsFailedSessionsAfterWaiting() throws {
        var failed = Session(title: "failed", cwd: "/tmp")
        failed.agentActivity = try failedActivity()
        var waiting = Session(title: "waiting", cwd: "/tmp")
        waiting.status = .waiting
        var running = Session(title: "running", cwd: "/tmp")
        running.status = .running

        func descriptions(_ sessions: [Session]) -> [String] {
            ProjectRow.activityDescriptions(for: Project(name: "P", cwd: "/tmp", sessions: sessions))
        }
        XCTAssertEqual(descriptions([failed, Session(title: "idle", cwd: "/tmp")]), ["1 failed"])
        XCTAssertEqual(
            descriptions([running, failed, waiting, failed]),
            ["1 waiting for input", "2 failed", "1 running"]
        )
        var retried = failed
        retried.status = .running
        XCTAssertEqual(descriptions([retried]), ["1 running"])
        XCTAssertEqual(descriptions([Session(title: "idle", cwd: "/tmp")]), [])
    }

    @MainActor
    func testProjectRowDrawsTheRedFailureSymbol() throws {
        var failed = Session(title: "failed", cwd: "/tmp")
        failed.agentActivity = try failedActivity()
        var waiting = Session(title: "waiting", cwd: "/tmp")
        waiting.status = .waiting

        func redPixels(_ sessions: [Session]) throws -> Int {
            let renderer = ImageRenderer(
                content: ProjectRow(project: Project(name: "P", cwd: "/tmp", sessions: sessions))
                    .frame(width: 176)
                    .background(Color.white)
                    .environment(\.colorScheme, .light)
            )
            let image = try XCTUnwrap(renderer.cgImage)
            let bitmap = NSBitmapImageRep(cgImage: image)
            var count = 0
            for x in 0..<bitmap.pixelsWide {
                for y in 0..<bitmap.pixelsHigh {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                    // System red, not orange (waiting) or green (running).
                    if color.redComponent > 0.8, color.greenComponent < 0.4, color.blueComponent < 0.4 {
                        count += 1
                    }
                }
            }
            return count
        }

        XCTAssertGreaterThan(try redPixels([failed]), 10)
        XCTAssertEqual(try redPixels([waiting]), 0)
    }
}
