import XCTest
@testable import copilot_projects
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
}

private extension Date.ISO8601FormatStyle {
    static var iso8601IncludingFractionalSeconds: Self {
        Self(includingFractionalSeconds: true)
    }
}
